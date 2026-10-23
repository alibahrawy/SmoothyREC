//
//  SmoothyRECApp.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import AppKit
import Combine
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "App")

extension Notification.Name {
    static let smoothyHotKeyStart = Notification.Name("smoothyHotKeyStart")
    /// Posted when the user stops capture from the macOS menu bar
    /// screen-recording indicator — treated as a normal Stop, not an error.
    static let smoothySystemStopRequested = Notification.Name("smoothySystemStopRequested")
}

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

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    // MARK: - Menu Bar Items

    var mainStatusItem: NSStatusItem?
    var mainPopover: NSPopover?
    var recordingStatusPopover: NSPopover?

    // MARK: - Windows

    var mainWindow: NSWindow?
    var onboardingWindow: NSWindow?
    var settingsWindow: NSWindow?

    // MARK: - Onboarding

    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding: Bool = false
    @AppStorage("hasShownInitialPermissionPanel") var hasShownInitialPermissionPanel: Bool = false
    // Once the user closes the permission panel even a single time, we never
    // auto-open it again on launch — the main window's banner remains the
    // fallback for surfacing any still-missing permission.
    @AppStorage("hasDismissedPermissionPanel") var hasDismissedPermissionPanel: Bool = false

    // MARK: - Recording Coordinator

    let recordingCoordinator = RecordingCoordinator()
    let countdownOverlay = CountdownOverlayController()

    // MARK: - UI State

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var screenPermissionRequiresRelaunch = false

    private var cancellables = Set<AnyCancellable>()
    private var awaitingScreenPermissionReturn = false
    private var launchScreenPermissionGranted = false
    private var pendingHotKeyStart = false
    private var stopRequestInFlight = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests use fake capture engines and synthetic media. Do not open
        // windows, access devices, request permissions or check for updates.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        RecorderTelemetry.shared.start()
        // Regular app: visible in the Dock and ⌘Tab so it clearly reads as
        // "open" while its menu bar item is present. Closing the window keeps
        // it running; quitting removes the menu bar item with it.
        NSApp.setActivationPolicy(.regular)

        setupNotifications()
        setupMainMenuBar()
        setupRecordingStatusMenuBar()
        setupCoordinatorBindings()
        reloadHotKeys()

        launchScreenPermissionGranted = CGPreflightScreenCaptureAccess()

        // Always open the full main window first (never just the menu-bar popover).
        showMainWindow()

        // Show the permission panel on top until the user dismisses it once.
        if !hasDismissedPermissionPanel {
            hasShownInitialPermissionPanel = true
            showOnboardingWindow()
        }

        // Once-a-day background update check; silent unless a newer release
        // exists on GitHub.
        let lastCheck = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - lastCheck > 86_400 {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
            Task { await self.checkForUpdates(interactive: false) }
        }
    }

    /// Clicking the Dock icon with no windows open reopens the recorder.
    func applicationWillTerminate(_ notification: Notification) {
        RecorderTelemetry.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard awaitingScreenPermissionReturn else { return }

        Task { @MainActor in
            await self.handleReturnFromScreenPermissionSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let state = recordingCoordinator.state
        if case .stopping = state {
            Task { @MainActor in
                do {
                    _ = try await self.recordingCoordinator.stop()
                    NSApp.reply(toApplicationShouldTerminate: true)
                } catch {
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        }
        guard state.isRecording || state.isPaused else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "A recording is in progress"
        alert.informativeText = "Quitting now interrupts the recording. Save what's been captured so far, or discard it?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save & Quit")
        alert.addButton(withTitle: "Discard & Quit")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                do {
                    _ = try await self.recordingCoordinator.stop()
                    NSApp.reply(toApplicationShouldTerminate: true)
                } catch {
                    // Stay open so the user can inspect files kept on disk.
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            Task { @MainActor in
                await self.recordingCoordinator.discard()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    // MARK: - Coordinator Binding

    private func setupCoordinatorBindings() {
        recordingCoordinator.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleCoordinatorStateChange(state)
            }
            .store(in: &cancellables)

        recordingCoordinator.$currentDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.recordingDuration = duration
                self?.updateMainStatusButton()
                self?.updateRecordingStatusButton()
            }
            .store(in: &cancellables)

        // Stop requested from the macOS menu bar screen-recording indicator:
        // finish and save exactly like pressing Stop in the app.
        NotificationCenter.default.publisher(for: .smoothySystemStopRequested)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isRecording else { return }
                self.stopRecordingFromStatusBar()
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
            logger.info("Recording started")

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
            showRecordingFinishedNotification(result: result)
            showCompletionWindow(result: result)
            logger.info("Recording finished with \(result.allURLs.count) saved files and \(result.warnings.count) warnings")

        case .failed(let error):
            isRecording = false
            isPaused = false
            recordingStatusPopover?.performClose(nil)
            updateMainStatusButton()
            showRecordingErrorNotification(error: error)
            showRecordingErrorAlert(error: error)
            logger.error("Recording failed: \(error.localizedDescription)")

        case .preparing:
            logger.info("Preparing to record")

        case .stopping:
            logger.info("Stopping recording")

        default:
            isRecording = false
            isPaused = false
            recordingStatusPopover?.performClose(nil)
            updateMainStatusButton()
        }
    }

    // MARK: - Recording Control

    func startRecording(configuration: RecordingSessionConfiguration) async throws {
        if screenPermissionRequiresRelaunch {
            throw AppError.screenPermissionChangeRequiresRelaunch
        }

        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.permissionDenied
        }

        logger.info("startRecording called with videoName: \(configuration.videoName)")
        try await recordingCoordinator.start(configuration: configuration)
    }

    func stopRecordingFromStatusBar() {
        guard !stopRequestInFlight,
              recordingCoordinator.state.isRecording || recordingCoordinator.state.isPaused else { return }
        stopRequestInFlight = true
        logger.info("stopRecording called")
        recordingStatusPopover?.performClose(nil)

        Task {
            defer { stopRequestInFlight = false }
            do {
                let result = try await recordingCoordinator.stop()
                logger.info("Recording completed with \(result.allURLs.count) files")
            } catch {
                logger.error("Failed to stop recording: \(error.localizedDescription)")
                // The coordinator publishes the error and preserves recoverable
                // files. A save failure must never turn into a Discard action.
            }
        }
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

    // MARK: - Global Hotkeys

    func reloadHotKeys() {
        HotKeyManager.shared.unregisterAll()

        let settings = SettingsManager.shared

        HotKeyManager.shared.register(
            HotKeyCombo(keyCode: settings.startStopKeyCode, modifiers: settings.startStopModifiers)
        ) { [weak self] in
            self?.hotKeyToggleRecord()
        }

        HotKeyManager.shared.register(
            HotKeyCombo(keyCode: settings.pauseKeyCode, modifiers: settings.pauseModifiers)
        ) { [weak self] in
            self?.hotKeyTogglePause()
        }
    }

    private func hotKeyToggleRecord() {
        guard !recordingCoordinator.isStopping else { return }
        if isRecording {
            stopRecordingFromStatusBar()
        } else {
            guard recordingCoordinator.state.canStart else { return }
            // Bring the recorder window forward and let it start with the
            // current device selections, countdown, and overlay.
            pendingHotKeyStart = true
            showMainWindow()
            NotificationCenter.default.post(name: .smoothyHotKeyStart, object: nil)
        }
    }

    private func hotKeyTogglePause() {
        guard isRecording, recordingCoordinator.canPause else { return }
        togglePauseResume()
    }

    /// Returns true exactly once after a hotkey requested a start, so the main
    /// window can trigger recording whether it was already open or just created.
    func consumePendingHotKeyStart() -> Bool {
        guard pendingHotKeyStart else { return false }
        pendingHotKeyStart = false
        return true
    }

    func discardRecording() {
        Task {
            await recordingCoordinator.discard()
        }
    }

    // MARK: - Permissions

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
        // Without this, openApplication just activates the already-running
        // instance and the terminate below turns "relaunch" into plain "quit".
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Failed to relaunch app: \(error.localizedDescription)")
                return
            }

            NSApp.terminate(nil)
        }
    }

    private func handleReturnFromScreenPermissionSettings() async {
        awaitingScreenPermissionReturn = false
        await detectScreenPermissionFlipSinceLaunch()
    }

    /// Detects whether Screen Recording flipped from denied→granted since launch.
    /// macOS requires the app to relaunch in that case before SCStream will work
    /// reliably, so we surface a clear prompt. Called from both the Settings-return
    /// path and from any flow (e.g. onboarding) that may have produced a grant.
    func detectScreenPermissionFlipSinceLaunch() async {
        let currentPermissionGranted = await queryScreenCaptureAccess()
        guard currentPermissionGranted, currentPermissionGranted != launchScreenPermissionGranted else { return }
        guard !screenPermissionRequiresRelaunch else { return }

        screenPermissionRequiresRelaunch = true
        showScreenPermissionRelaunchAlert()
    }

    private func queryScreenCaptureAccess() async -> Bool {
        // Use silent preflight check. SCShareableContent can trigger dialogs even when already granted.
        CGPreflightScreenCaptureAccess()
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

    // MARK: - Alerts & Formatting

    func showRecordingErrorAlert(error: Error) {
        if isScreenPermissionChangeRequiresRelaunch(error) {
            showScreenPermissionRelaunchAlert()
            return
        }

        if isScreenRecordingPermissionDenied(error) {
            showScreenRecordingPermissionAlert()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Recording Error"
        alert.informativeText = error.localizedDescription
        if let directory = recordingCoordinator.recoveryDirectory {
            alert.informativeText += "\n\nExisting recording files were kept in:\n\(directory.path)"
            alert.addButton(withTitle: "Show Files")
        }
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn,
           let directory = recordingCoordinator.recoveryDirectory {
            NSWorkspace.shared.open(directory)
        }
    }

    func isScreenPermissionChangeRequiresRelaunch(_ error: Error) -> Bool {
        guard let appError = error as? AppError else { return false }

        if case .screenPermissionChangeRequiresRelaunch = appError {
            return true
        }

        return false
    }

    func isScreenRecordingPermissionDenied(_ error: Error) -> Bool {
        if let coordinatorError = error as? CoordinatorError {
            switch coordinatorError {
            case .screenRecorderFailed(let underlyingError):
                return isScreenRecordingPermissionDenied(underlyingError)
            case .partialFailure(let errors):
                guard let screenError = errors[.screen] else { return false }
                return isScreenRecordingPermissionDenied(screenError)
            default:
                return false
            }
        }

        if let recordingError = error as? RecordingError {
            switch recordingError {
            case .permissionDenied:
                return true
            case .captureStreamFailed(let underlyingError):
                return ScreenCapturePermissionClassifier.isPermissionDenied(underlyingError)
            default:
                return false
            }
        }

        return ScreenCapturePermissionClassifier.isPermissionDenied(error)
    }

    private func showScreenRecordingPermissionAlert() {
        let hasPermission = CGPreflightScreenCaptureAccess()
        let alert = NSAlert()
        alert.alertStyle = .warning

        if hasPermission {
            alert.messageText = "Relaunch Required"
            alert.informativeText = "macOS is still blocking screen capture even though Screen Recording appears enabled. Relaunch SmoothyREC, then try recording again."
            alert.addButton(withTitle: "Relaunch Now")
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "OK")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                relaunchApplication()
            case .alertSecondButtonReturn:
                openScreenRecordingSettings(fromPermissionFlow: true)
            default:
                break
            }

            return
        }

        alert.messageText = "Screen Recording Permission Required"
        alert.informativeText = "SmoothyREC needs Screen Recording access before it can capture your display. Enable SmoothyREC in System Settings > Privacy & Security > Screen Recording, then relaunch if macOS asks."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings(fromPermissionFlow: true)
        }
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = Int(duration) / 60 % 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}
