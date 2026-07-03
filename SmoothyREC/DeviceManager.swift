//
//  DeviceManager.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine
import CoreGraphics

// MARK: - Device Models

struct Display: Identifiable, Hashable, CustomStringConvertible {
    let id: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let isMain: Bool

    var description: String {
        "\(name) (\(width)×\(height))"
    }

    var displaySize: String {
        "\(width) × \(height)"
    }
}

struct CaptureWindow: Identifiable, Hashable, CustomStringConvertible {
    let id: CGWindowID
    let name: String
    let applicationName: String
    let applicationBundleID: String?
    let icon: NSImage?
    let frame: CGRect
    let isOnScreen: Bool

    var description: String {
        if applicationName.isEmpty || applicationName == name {
            return name
        }
        return "\(applicationName) — \(name)"
    }

    var size: CGSize {
        frame.size
    }
}

struct Camera: Identifiable, Hashable, CustomStringConvertible {
    let id: String
    let name: String
    let uniqueID: String
    let isBuiltIn: Bool
    let position: AVCaptureDevice.Position
    let formats: [AVCaptureDevice.Format]

    var description: String {
        name
    }

    var icon: String {
        isBuiltIn ? "laptopcomputer" : "web.camera.fill"
    }
}

struct Microphone: Identifiable, Hashable, CustomStringConvertible {
    let id: String
    let name: String
    let uniqueID: String
    let isBuiltIn: Bool
    let supportedSampleRates: [Double]
    let inputChannels: Int

    var description: String {
        name
    }

    var icon: String {
        isBuiltIn ? "mic" : "mic.fill"
    }
}

// MARK: - Errors

enum DeviceEnumerationError: Error, LocalizedError {
    case noDisplaysFound
    case screenCapturePermissionDenied
    case avFoundationError(Error)
    case invalidWindowFilter

    var errorDescription: String? {
        switch self {
        case .noDisplaysFound:
            return "No displays found. Please check your monitor connections."
        case .screenCapturePermissionDenied:
            return "Screen capture permission denied. Please enable it in System Settings > Privacy & Security > Screen Recording."
        case .avFoundationError(let error):
            return "AVFoundation error: \(error.localizedDescription)"
        case .invalidWindowFilter:
            return "Invalid window filter configuration."
        }
    }
}

// MARK: - Device Manager

@MainActor
class DeviceManager: ObservableObject {

    // MARK: - Published Properties

    @Published var displays: [Display] = []
    @Published var windows: [CaptureWindow] = []
    @Published var cameras: [Camera] = []
    @Published var microphones: [Microphone] = []
    @Published private(set) var screenPermissionGranted = false
    @Published private(set) var cameraPermissionStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var microphonePermissionStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    @Published var isLoading = false
    @Published var lastError: Error?

    // MARK: - Internal State

    private var hasRequestedScreenPermission = false
    private var isRefreshing = false

    // MARK: - Configuration

    var minimumWindowArea: CGFloat = 10000

    var excludedWindowTitles: [String] = [
        "",
        "dock",
        "menubar",
        "statusbar",
        "notification center",
        "control center",
        "spotlight"
    ]

    var excludedBundleIDs: [String] = [
        "com.apple.dock",
        "com.apple.menuextra",
        "com.apple.systemuiserver",
        "com.apple.notificationcenterui",
        "com.apple.controlcenter"
    ]

    // MARK: - Initialization

    init() {
        // Don't auto-refresh displays on init - SCShareableContent triggers permission dialog
        // even when permission is already granted (macOS bug FB22261705)
        // Only refresh when explicitly requested (e.g., when starting recording)
        setupObservers()

        // Check camera/mic permissions silently (these don't trigger dialogs)
        Task {
            cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
            microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Screen Permission

    func checkScreenPermission() -> Bool {
        return screenPermissionGranted
    }

    /// Checks screen-recording permission WITHOUT triggering any dialog.
    /// Uses CGPreflightScreenCaptureAccess which is silent (no user prompt).
    /// This is for UI status display only - not for actual capture.
    func checkScreenPermissionStatusSilently() -> Bool {
        let hasPermission = CGPreflightScreenCaptureAccess()
        screenPermissionGranted = hasPermission
        return hasPermission
    }

    /// Checks screen-recording permission state via SCShareableContent.
    /// This can trigger the system permission dialog on some macOS versions.
    /// Only call this from explicit user actions or when starting capture.
    @discardableResult
    func requestScreenRecordingPermission() async -> Bool {
        await refreshDisplays()
        return screenPermissionGranted
    }

    // MARK: - Public Methods

    func refreshAllDevices(includeScreenCaptureContent: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        isLoading = true
        defer { isLoading = false }

        cameraPermissionStatus = AVCaptureDevice.authorizationStatus(for: .video)
        microphonePermissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        refreshDisplaysSilently()

        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.refreshCameras() }
            group.addTask { await self.refreshMicrophones() }
            if includeScreenCaptureContent {
                group.addTask { await self.refreshWindows() }
            }
        }
    }

    /// Populates the display picker without touching ScreenCaptureKit. This never
    /// triggers the macOS screen/audio recording prompt.
    func refreshDisplaysSilently() {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success, displayCount > 0 else {
            displays = []
            screenPermissionGranted = CGPreflightScreenCaptureAccess()
            lastError = DeviceEnumerationError.noDisplaysFound
            return
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = displayIDs.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(displayCount, buffer.baseAddress, &displayCount)
        }

        guard listResult == .success else {
            displays = []
            screenPermissionGranted = CGPreflightScreenCaptureAccess()
            lastError = DeviceEnumerationError.noDisplaysFound
            return
        }

        let discovered = displayIDs.prefix(Int(displayCount)).map { displayID in
            Display(
                id: displayID,
                name: getDisplayName(for: displayID),
                width: CGDisplayPixelsWide(displayID),
                height: CGDisplayPixelsHigh(displayID),
                isMain: displayID == CGMainDisplayID()
            )
        }.sorted { $0.isMain && !$1.isMain }

        displays = discovered
        screenPermissionGranted = CGPreflightScreenCaptureAccess()
        lastError = discovered.isEmpty ? DeviceEnumerationError.noDisplaysFound : nil
    }

    /// Refresh displays using ScreenCaptureKit. Does NOT call
    /// CGPreflightScreenCaptureAccess or CGRequestScreenCaptureAccess because
    /// both are broken on macOS Tahoe (see FB22261705) and unreliable on Sequoia.
    /// SCShareableContent is the only reliable permission check.
    func refreshDisplays() async {
        for attempt in 0..<4 {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )

                let discovered = content.displays.map { scDisplay in
                    Display(
                        id: scDisplay.displayID,
                        name: self.getDisplayName(for: scDisplay.displayID),
                        width: Int(scDisplay.width),
                        height: Int(scDisplay.height),
                        isMain: scDisplay.displayID == CGMainDisplayID()
                    )
                }.sorted { $0.isMain && !$1.isMain }

                await MainActor.run {
                    self.displays = discovered
                    self.screenPermissionGranted = true
                    self.lastError = discovered.isEmpty ? DeviceEnumerationError.noDisplaysFound : nil
                }
                return

            } catch {
                if ScreenCapturePermissionClassifier.isPermissionDenied(error) {
                    await MainActor.run {
                        let hasPermission = CGPreflightScreenCaptureAccess()
                        self.screenPermissionGranted = hasPermission
                        self.lastError = hasPermission ? nil : DeviceEnumerationError.screenCapturePermissionDenied
                    }
                    return
                }

                // Transient error (daemon not ready, etc.) — back off and retry
                let delay = UInt64(750_000_000) * UInt64(attempt + 1)
                try? await Task.sleep(nanoseconds: delay)
            }
        }
    }

    /// Refreshes window list using ScreenCaptureKit with retry logic
    func refreshWindows() async {
        for attempt in 0..<3 {
            do {
                let shareableContent = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )

                let windows = shareableContent.windows
                    .filter { shouldIncludeCaptureWindow($0) }
                    .map { scWindow in
                        CaptureWindow(
                            id: scWindow.windowID,
                            name: scWindow.title ?? "Untitled Window",
                            applicationName: scWindow.owningApplication?.applicationName ?? "Unknown App",
                            applicationBundleID: scWindow.owningApplication?.bundleIdentifier,
                            icon: getAppIcon(for: scWindow.owningApplication?.bundleIdentifier),
                            frame: CGRect(
                                x: CGFloat(scWindow.frame.origin.x),
                                y: CGFloat(scWindow.frame.origin.y),
                                width: CGFloat(scWindow.frame.width),
                                height: CGFloat(scWindow.frame.height)
                            ),
                            isOnScreen: scWindow.isOnScreen
                        )
                    }
                    .sorted { $0.applicationName < $1.applicationName }

                await MainActor.run {
                    self.windows = windows
                    // Optimistically set permission if we found windows
                    if !windows.isEmpty {
                        self.screenPermissionGranted = true
                    }
                }
                return

            } catch {
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }

                await MainActor.run {
                    self.windows = []
                }
            }
        }
    }

    func refreshCameras() async {
        // Only enumerate if already authorized - don't auto-request
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            await MainActor.run {
                self.cameras = []
                self.cameraPermissionStatus = status
            }
            return
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .externalUnknown
            ],
            mediaType: .video,
            position: .unspecified
        )

        let cameras = discoverySession.devices.map { device in
            Camera(
                id: device.uniqueID,
                name: device.localizedName,
                uniqueID: device.uniqueID,
                isBuiltIn: device.deviceType != .externalUnknown,
                position: device.position,
                formats: device.formats
            )
        }.sorted { $0.isBuiltIn && !$1.isBuiltIn }

        await MainActor.run {
            self.cameras = cameras
        }
    }

    func refreshMicrophones() async {
        // Only enumerate if already authorized - don't auto-request
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            await MainActor.run {
                self.microphones = []
                self.microphonePermissionStatus = status
            }
            return
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInMicrophone,
                .externalUnknown
            ],
            mediaType: .audio,
            position: .unspecified
        )

        let microphones = discoverySession.devices.map { device -> Microphone in
            let sampleRates = device.formats
                .filter { $0.mediaType == .audio }
                .compactMap { format -> Double? in
                    let desc = format.formatDescription
                    let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)
                    return asbd?.pointee.mSampleRate
                }
                .unique()
                .sorted()

            let channelCount: Int
            if let audioFormat = device.formats.first(where: { $0.mediaType == .audio }) {
                let desc = audioFormat.formatDescription
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                    channelCount = Int(asbd.pointee.mChannelsPerFrame)
                } else {
                    channelCount = 0
                }
            } else {
                channelCount = 0
            }

            return Microphone(
                id: device.uniqueID,
                name: device.localizedName,
                uniqueID: device.uniqueID,
                isBuiltIn: device.deviceType == .builtInMicrophone,
                supportedSampleRates: sampleRates.isEmpty ? [48000.0] : sampleRates,
                inputChannels: channelCount
            )
        }.sorted { $0.isBuiltIn && !$1.isBuiltIn }

        await MainActor.run {
            self.microphones = microphones
        }
    }

    func display(withID id: CGDirectDisplayID) -> Display? {
        displays.first { $0.id == id }
    }

    func window(withID id: CGWindowID) -> CaptureWindow? {
        windows.first { $0.id == id }
    }

    func camera(withID id: String) -> Camera? {
        cameras.first { $0.id == id }
    }

    func microphone(withID id: String) -> Microphone? {
        microphones.first { $0.id == id }
    }

    // MARK: - Permission Requests

    func requestCameraPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .authorized:
            cameraPermissionStatus = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraPermissionStatus = granted ? .authorized : .denied
            return granted
        case .denied, .restricted:
            cameraPermissionStatus = status
            return false
        @unknown default:
            return false
        }
    }

    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            microphonePermissionStatus = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermissionStatus = granted ? .authorized : .denied
            return granted
        case .denied, .restricted:
            microphonePermissionStatus = status
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - Private Helpers

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceWasConnected),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceWasDisconnected),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )

        // Re-check local device state whenever our app is foregrounded. Do not call
        // ScreenCaptureKit here; it can trigger the screen/audio recording prompt.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }

        Task {
            await MainActor.run {
                self.refreshDisplaysSilently()
            }
            await refreshCameras()
            await refreshMicrophones()
        }
    }

    @objc private func deviceWasConnected(_ notification: Notification) {
        Task {
            await refreshCameras()
            await refreshMicrophones()
        }
    }

    @objc private func deviceWasDisconnected(_ notification: Notification) {
        Task {
            await refreshCameras()
            await refreshMicrophones()
        }
    }

    private func shouldIncludeCaptureWindow(_ window: SCWindow) -> Bool {
        let area = CGFloat(window.frame.width) * CGFloat(window.frame.height)
        guard area >= minimumWindowArea else {
            return false
        }

        let title = window.title?.lowercased() ?? ""
        guard !title.isEmpty else {
            return false
        }

        for excluded in excludedWindowTitles {
            if title.contains(excluded.lowercased()) {
                return false
            }
        }

        if let bundleID = window.owningApplication?.bundleIdentifier {
            for excluded in excludedBundleIDs {
                if bundleID.lowercased().contains(excluded.lowercased()) {
                    return false
                }
            }
        }

        guard window.isOnScreen else {
            return false
        }

        return true
    }

    private func getDisplayName(for displayID: CGDirectDisplayID) -> String {
        // "Built-in" is a hardware property, not "whichever display is main" —
        // in clamshell mode an external monitor is the main display.
        if CGDisplayIsBuiltin(displayID) != 0 {
            return "Built-in Display"
        }

        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) {
            let screenName = screen.localizedName
            if !screenName.isEmpty && screenName != "Unknown" {
                return screenName
            }
        }

        return "Display \(displayID)"
    }

    private func getAppIcon(for bundleID: String?) -> NSImage? {
        guard let bundleID = bundleID else { return nil }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: appURL.path)
        }

        return nil
    }
}

// MARK: - Extensions

extension Array where Element: Hashable {
    func unique() -> [Element] {
        Array(Set(self))
    }
}

// MARK: - Preview Support

extension DeviceManager {
    static var preview: DeviceManager {
        let manager = DeviceManager()
        manager.displays = [
            Display(id: 1, name: "Built-in Display", width: 2560, height: 1600, isMain: true),
            Display(id: 2, name: "External Monitor", width: 3840, height: 2160, isMain: false)
        ]
        manager.windows = [
            CaptureWindow(id: 1, name: "Main Window", applicationName: "Safari", applicationBundleID: "com.apple.Safari", icon: nil, frame: CGRect(x: 0, y: 0, width: 1200, height: 800), isOnScreen: true),
            CaptureWindow(id: 2, name: "Document.md", applicationName: "Xcode", applicationBundleID: "com.apple.dt.Xcode", icon: nil, frame: CGRect(x: 100, y: 100, width: 1400, height: 900), isOnScreen: true)
        ]
        manager.cameras = [
            Camera(id: "1", name: "FaceTime HD Camera", uniqueID: "builtin", isBuiltIn: true, position: .front, formats: []),
            Camera(id: "2", name: "External Webcam", uniqueID: "external", isBuiltIn: false, position: .unspecified, formats: [])
        ]
        manager.microphones = [
            Microphone(id: "1", name: "MacBook Pro Microphone", uniqueID: "builtin", isBuiltIn: true, supportedSampleRates: [44100, 48000], inputChannels: 2),
            Microphone(id: "2", name: "USB Microphone", uniqueID: "external", isBuiltIn: false, supportedSampleRates: [48000, 96000], inputChannels: 2)
        ]
        return manager
    }
}
