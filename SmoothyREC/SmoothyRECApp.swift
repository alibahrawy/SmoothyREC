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
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
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

    // MARK: - Recording Coordinator

    let recordingCoordinator = RecordingCoordinator()

    // MARK: - UI State

    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var screenPermissionRequiresRelaunch = false

    private var cancellables = Set<AnyCancellable>()
    private var awaitingScreenPermissionReturn = false
    private var launchScreenPermissionGranted = false

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupNotifications()
        setupMainMenuBar()
        setupRecordingStatusMenuBar()
        setupCoordinatorBindings()

        launchScreenPermissionGranted = CGPreflightScreenCaptureAccess()

        if shouldShowPermissionPanelOnLaunch {
            hasShownInitialPermissionPanel = true
            showOnboardingWindow()
        } else {
            showMainWindow()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard awaitingScreenPermissionReturn else { return }

        Task { @MainActor in
            await self.handleReturnFromScreenPermissionSettings()
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
        logger.info("stopRecording called")
        recordingStatusPopover?.performClose(nil)

        Task {
            do {
                let result = try await recordingCoordinator.stop()
                logger.info("Recording completed with \(result.allURLs.count) files")
            } catch {
                logger.error("Failed to stop recording: \(error.localizedDescription)")
                await MainActor.run {
                    // Force the UI back to a sensible state — if stop() threw
                    // because the coordinator is in an unexpected state, the
                    // .finished branch in handleCoordinatorStateChange never
                    // fires, leaving the menu bar stuck in "recording" mode
                    // with a popover that just re-throws on every click.
                    self.forceResetRecordingUI()
                    self.showRecordingErrorAlert(error: error)
                }
            }
        }
    }

    /// Resets all "currently recording" UI state regardless of what the
    /// coordinator thinks. Called when stop() fails and leaves the UI orphaned.
    private func forceResetRecordingUI() {
        isRecording = false
        isPaused = false
        recordingStatusPopover?.performClose(nil)
        updateMainStatusButton()

        // Also tell the coordinator to discard if it's stuck — best-effort,
        // don't await so the alert below doesn't block.
        Task {
            await self.recordingCoordinator.discard()
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

        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                logger.error("Failed to relaunch app: \(error.localizedDescription)")
                return
            }

            NSApp.terminate(nil)
        }
    }

    private var shouldShowPermissionPanelOnLaunch: Bool {
        !hasCompletedOnboarding || !hasShownInitialPermissionPanel || isMissingRequiredPermission
    }

    private var isMissingRequiredPermission: Bool {
        !CGPreflightScreenCaptureAccess()
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
        alert.alertStyle = .critical
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
