//
//  SmoothyRECApp.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit
import UserNotifications
import Combine
import os.log

private let logger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "App")

enum AppError: LocalizedError {
    case screenPermissionChangeRequiresRelaunch
    
    var errorDescription: String? {
        switch self {
        case .screenPermissionChangeRequiresRelaunch:
            return "Screen Recording permission changed while SmoothyREC was open. macOS requires relaunching the app before screen capture will work reliably."
        }
    }
}

@main
struct SmoothyRECApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    
    // MARK: - Menu Bar Items
    
    /// Main menu bar item (always visible) - opens the main control window
    var mainStatusItem: NSStatusItem?
    var mainPopover: NSPopover?
    
    /// Recording status popover (uses the same menu bar item while recording)
    var recordingStatusPopover: NSPopover?
    
    // MARK: - Windows
    
    var mainWindow: NSWindow?
    
    // MARK: - Recording Coordinator
    
    let recordingCoordinator = RecordingCoordinator()
    
    // MARK: - UI State
    
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var screenPermissionRequiresRelaunch = false
    
    private var cancellables = Set<AnyCancellable>()
    private var timerUpdateCancellable: AnyCancellable?
    private var awaitingScreenPermissionReturn = false
    private var launchScreenPermissionGranted = false
    
    // MARK: - Lifecycle
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon
        NSApp.setActivationPolicy(.accessory)
        
        // Setup user notifications
        setupNotifications()
        
        // Setup menu bar items
        setupMainMenuBar()
        setupRecordingStatusMenuBar()
        
        // Bind to coordinator state
        setupCoordinatorBindings()

        Task { @MainActor in
            self.launchScreenPermissionGranted = await self.queryScreenCaptureAccess()
        }
        
        // Show main window on first launch
        showMainWindow()
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        guard awaitingScreenPermissionReturn else { return }
        
        Task { @MainActor in
            await self.handleReturnFromScreenPermissionSettings()
        }
    }
    
    // MARK: - Setup
    
    private func setupCoordinatorBindings() {
        // Watch coordinator state changes
        recordingCoordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleCoordinatorStateChange(state)
            }
            .store(in: &cancellables)
        
        // Watch duration updates
        recordingCoordinator.$currentDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.recordingDuration = duration
                self?.updateMainStatusButton()
                self?.updateRecordingStatusButton()
            }
            .store(in: &cancellables)
    }
    
    private func handleCoordinatorStateChange(_ state: CoordinatorState) {
        switch state {
        case .recording:
            isRecording = true
            isPaused = false
            updateMainStatusButton()
            updateRecordingStatusButton()
            showRecordingStartedNotification()
            print("Recording started - showing status indicator")
            
        case .paused:
            isRecording = true
            isPaused = true
            updateRecordingStatusButton()
            updateMainStatusButton()
            
        case .finished(let result):
            isRecording = false
            isPaused = false
            recordingStatusPopover?.performClose(nil)
            updateMainStatusButton()
            showCompletionWindow(result: result)
            print("Recording finished - \(result.allURLs.count) files saved")
            
        case .failed(let error):
            isRecording = false
            isPaused = false
            recordingStatusPopover?.performClose(nil)
            updateMainStatusButton()
            showRecordingErrorAlert(error: error)
            print("Recording failed: \(error.localizedDescription)")
            
        case .preparing:
            print("Preparing to record...")
            
        case .stopping:
            print("Stopping recording...")
            
        default:
            isRecording = false
            isPaused = false
            recordingStatusPopover?.performClose(nil)
            updateMainStatusButton()
        }
    }
    
    // MARK: - Completion Window
    
    func showCompletionWindow(result: RecordingResult) {
        let completionWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        completionWindow.title = "Recording Complete"
        completionWindow.center()
        completionWindow.contentViewController = NSHostingController(
            rootView: CompletionView(recordingResult: result).environmentObject(self)
        )
        completionWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Main Menu Bar (Always Visible)
    
    private func setupMainMenuBar() {
        // Create main popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView().environmentObject(self))
        self.mainPopover = popover
        
        // Create main status item
        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = mainStatusItem?.button {
            updateMainStatusButton()
            button.action = #selector(toggleMainPopover)
            button.target = self
        }
    }
    
    @objc private func toggleMainPopover() {
        guard let button = mainStatusItem?.button else { return }
        
        let activePopover = isRecording ? recordingStatusPopover : mainPopover
        let inactivePopover = isRecording ? mainPopover : recordingStatusPopover
        
        guard let popover = activePopover else { return }
        
        if popover.isShown {
            popover.performClose(nil)
        } else {
            inactivePopover?.performClose(nil)
            
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    private func updateMainStatusButton() {
        guard let button = mainStatusItem?.button else { return }
        
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        
        if isRecording {
            let symbolName = isPaused ? "pause.circle.fill" : "record.circle.fill"
            let symbolColor = isPaused ? NSColor.systemOrange : NSColor.systemRed
            button.image = configuredStatusImage(symbolName: symbolName, color: symbolColor)
            button.attributedTitle = statusButtonTitle(" \(recordingCoordinator.formattedDuration)")
            button.contentTintColor = nil
        } else {
            button.image = configuredStatusImage(symbolName: "record.circle", color: .labelColor)
            button.attributedTitle = statusButtonTitle("")
            button.contentTintColor = nil
        }
    }
    
    // MARK: - Recording Status Menu Bar (Visible Only During Recording)
    
    private func setupRecordingStatusMenuBar() {
        // Create recording status popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RecordingStatusView().environmentObject(self))
        self.recordingStatusPopover = popover
    }
    
    private func updateRecordingStatusButton() {
        guard isRecording else { return }
        
        updateMainStatusButton()
    }
    
    // MARK: - Permissions & Notifications
    
    private func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            print("Notification permission: \(granted)")
        }
    }
    
    // MARK: - Window Management
    
    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SmoothyREC"
            window.center()
            window.isReleasedWhenClosed = false
            mainWindow = window
        }

        mainWindow?.contentViewController = NSHostingController(rootView: MainWindowView().environmentObject(self))
        
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    // MARK: - Recording Control
    
    func startRecording(configuration: RecordingSessionConfiguration) async throws {
        if screenPermissionRequiresRelaunch {
            throw AppError.screenPermissionChangeRequiresRelaunch
        }
        
        logger.info("startRecording called with videoName: \(configuration.videoName)")

        try await recordingCoordinator.start(configuration: configuration)
    }
    
    func stopRecordingFromStatusBar() {
        logger.info("stopRecording called")
        recordingStatusPopover?.performClose(nil)
        
        Task {
            do {
                let result = try await recordingCoordinator.stop()
                print("Recording completed with \(result.allURLs.count) files")
            } catch {
                print("Failed to stop recording: \(error)")
                await MainActor.run {
                    showRecordingErrorAlert(error: error)
                }
            }
        }
    }
    
    // MARK: - Error Alerts
    
    func showRecordingErrorAlert(error: Error) {
        let alert = NSAlert()
        alert.messageText = "Recording Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    
    func togglePauseResume() {
        Task {
            if isPaused {
                await recordingCoordinator.resume()
            } else {
                await recordingCoordinator.pause()
            }
        }
    }
    
    func discardRecording() {
        Task {
            await recordingCoordinator.discard()
        }
    }
    
    // MARK: - Helper Methods
    
    func openSettings() {
        openFullSettings()
    }

    func openScreenRecordingSettings(fromPermissionFlow: Bool = false) {
        if fromPermissionFlow {
            awaitingScreenPermissionReturn = true
        }
        
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        
        NSWorkspace.shared.open(url)
    }
    
    func relaunchApplication() {
        let appURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Failed to relaunch app: \(error.localizedDescription)")
                return
            }
            
            NSApp.terminate(nil)
        }
    }
    
    func openFullSettings() {
        mainPopover?.performClose(nil)
        
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = "SmoothyREC Settings"
        settingsWindow.center()
        settingsWindow.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(self))
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeMainPopover() {
        mainPopover?.performClose(nil)
        recordingStatusPopover?.performClose(nil)
    }
    
    func quitApp() {
        NSApp.terminate(nil)
    }
    
    // MARK: - Notifications
    
    private func showRecordingStartedNotification() {
        let notification = UNMutableNotificationContent()
        notification.title = "Recording Started"
        notification.body = "Click the timer in your menu bar to pause or stop."
        notification.sound = nil
        
        let request = UNNotificationRequest(
            identifier: "recording-started",
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func showRecordingFinishedNotification(result: RecordingResult) {
        let notification = UNMutableNotificationContent()
        notification.title = "Recording Saved"
        
        var bodyParts: [String] = []
        if result.screenRecordingURL != nil { bodyParts.append("Screen") }
        if result.microphoneRecordingURL != nil { bodyParts.append("Mic") }
        if result.cameraRecordingURL != nil { bodyParts.append("Camera") }
        
        notification.body = "Saved: \(bodyParts.joined(separator: ", ")) (\(formatDuration(result.duration)))"
        notification.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "recording-finished-\(result.startTime)",
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    private func showRecordingErrorNotification(error: Error) {
        let notification = UNMutableNotificationContent()
        notification.title = "Recording Error"
        notification.body = error.localizedDescription
        notification.sound = .default
        
        let request = UNNotificationRequest(
            identifier: "recording-error-\(Date())",
            content: notification,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request)
    }
    
    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
    
    private func configuredStatusImage(symbolName: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SmoothyREC")
        let image = baseImage?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
    
    private func statusButtonTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }
    
    private func handleReturnFromScreenPermissionSettings() async {
        awaitingScreenPermissionReturn = false
        
        let currentPermissionGranted = await queryScreenCaptureAccess()
        guard currentPermissionGranted, currentPermissionGranted != launchScreenPermissionGranted else { return }
        
        screenPermissionRequiresRelaunch = true
        showScreenPermissionRelaunchAlert()
    }
    
    private func queryScreenCaptureAccess() async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return !content.displays.isEmpty
        } catch {
            return false
        }
    }
    
    private func showScreenPermissionRelaunchAlert() {
        let alert = NSAlert()
        alert.messageText = "Relaunch Required"
        alert.informativeText = "macOS requires restarting SmoothyREC after you change Screen Recording permission. Relaunch now before testing capture again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        
        if alert.runModal() == .alertFirstButtonReturn {
            relaunchApplication()
        }
    }
}
