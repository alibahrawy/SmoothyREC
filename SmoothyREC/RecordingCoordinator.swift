//
//  RecordingCoordinator.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import AVFoundation
import CoreMedia
import Combine
import os.log

private let coordLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "RecordingCoordinator")

// MARK: - Recording Session Configuration

struct RecordingSessionConfiguration {
    let videoName: String
    let recordTarget: ScreenRecordTarget
    let includeSystemAudio: Bool
    let captureCursor: Bool
    let selectedMicrophone: Microphone?
    let selectedCamera: Camera?
    let quality: RecordingQuality
    let frameRate: FrameRate
    let countdownSeconds: Int

    enum ScreenRecordTarget {
        case fullScreen(Display)
        case window(CaptureWindow)
        case area(Display, CGRect, CGFloat)
    }

    init(
        videoName: String,
        recordTarget: ScreenRecordTarget,
        includeSystemAudio: Bool,
        captureCursor: Bool = true,
        selectedMicrophone: Microphone?,
        selectedCamera: Camera?,
        quality: RecordingQuality,
        frameRate: FrameRate,
        countdownSeconds: Int = 0
    ) {
        self.videoName = videoName
        self.recordTarget = recordTarget
        self.includeSystemAudio = includeSystemAudio
        self.captureCursor = captureCursor
        self.selectedMicrophone = selectedMicrophone
        self.selectedCamera = selectedCamera
        self.quality = quality
        self.frameRate = frameRate
        self.countdownSeconds = max(0, countdownSeconds)
    }
}

// MARK: - Recording Result

struct RecordingResult {
    let videoName: String
    let screenRecordingURL: URL?
    let microphoneRecordingURL: URL?
    let cameraRecordingURL: URL?
    let duration: TimeInterval
    let startTime: Date
    let endTime: Date
    let warnings: [RecordingWarning]
    /// How many seconds the camera/mic stems lead the screen file. Camera and
    /// mic timelines are anchored at the session sync clock, but the screen
    /// stream takes a few hundred ms to deliver its first frame — compositing
    /// without skipping this much of the camera/mic heads causes lip-sync drift.
    let screenStartOffset: TimeInterval

    init(
        videoName: String,
        screenRecordingURL: URL?,
        microphoneRecordingURL: URL?,
        cameraRecordingURL: URL?,
        duration: TimeInterval,
        startTime: Date,
        endTime: Date,
        warnings: [RecordingWarning] = [],
        screenStartOffset: TimeInterval = 0
    ) {
        self.videoName = videoName
        self.screenRecordingURL = screenRecordingURL
        self.microphoneRecordingURL = microphoneRecordingURL
        self.cameraRecordingURL = cameraRecordingURL
        self.duration = duration
        self.startTime = startTime
        self.endTime = endTime
        self.warnings = warnings
        self.screenStartOffset = screenStartOffset
    }

    var allURLs: [URL] {
        [screenRecordingURL, microphoneRecordingURL, cameraRecordingURL].compactMap { $0 }
    }

    var isComplete: Bool {
        screenRecordingURL != nil
    }

    var warningSummary: String {
        warnings.map(\.displayText).joined(separator: "\n")
    }
}

// MARK: - Coordinator State

enum CoordinatorState: Equatable {
    case idle
    case preparing
    case recording(startTime: Date)
    case paused(startTime: Date, pausedDuration: TimeInterval)
    case stopping
    case failed(Error)
    case finished(RecordingResult)

    static func == (lhs: CoordinatorState, rhs: CoordinatorState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.stopping, .stopping):
            return true
        case (.recording(let lhsTime), .recording(let rhsTime)):
            return lhsTime == rhsTime
        case (.paused(let lhsTime, let lhsDuration), .paused(let rhsTime, let rhsDuration)):
            return lhsTime == rhsTime && lhsDuration == rhsDuration
        case (.finished(let lhsResult), .finished(let rhsResult)):
            return lhsResult.videoName == rhsResult.videoName
        case (.failed(let lhsError), .failed(let rhsError)):
            return lhsError.localizedDescription == rhsError.localizedDescription
        default:
            return false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    var canStart: Bool {
        switch self {
        case .idle, .failed, .finished:
            return true
        default:
            return false
        }
    }

    var startTime: Date? {
        switch self {
        case .recording(let startTime), .paused(let startTime, _):
            return startTime
        default:
            return nil
        }
    }
}

// MARK: - Coordinator Error

enum CoordinatorError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case screenRecorderFailed(Error)
    case micRecorderFailed(Error)
    case cameraRecorderFailed(Error)
    case noScreenTargetSelected
    case syncClockFailed
    case partialFailure([RecordingComponent: Error])

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording session is already in progress."
        case .notRecording:
            return "No recording session is currently active."
        case .screenRecorderFailed(let error):
            return "Screen recording failed: \(error.localizedDescription)"
        case .micRecorderFailed(let error):
            return "Microphone recording failed: \(error.localizedDescription)"
        case .cameraRecorderFailed(let error):
            return "Camera recording failed: \(error.localizedDescription)"
        case .noScreenTargetSelected:
            return "No screen or window selected for recording."
        case .syncClockFailed:
            return "Failed to initialize synchronization clock."
        case .partialFailure(let errors):
            let errorList = errors
                .map { "\($0.key.displayName): \($0.value.localizedDescription)" }
                .joined(separator: "\n")
            return "Partial recording failure:\n\(errorList)"
        }
    }
}

// MARK: - Recording Coordinator

@MainActor
class RecordingCoordinator: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var state: CoordinatorState = .idle
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var isStopping = false

    // Individual recorder states for UI binding
    @Published var screenRecorderState: RecordingState = .idle
    @Published var micRecorderState: MicRecorderState = .idle
    @Published var cameraRecorderState: CameraRecorderState = .idle

    // MARK: - Recorders

    let screenRecorder = ScreenRecorder()
    let micRecorder = MicRecorder()
    let cameraRecorder = CameraRecorder()

    // MARK: - Private Properties

    private var currentConfiguration: RecordingSessionConfiguration?
    private(set) var currentSessionDirectory: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    // Shared sync clock
    private var syncClock: CMClock?
    private var syncTime: CMTime?

    // Recording results
    private var screenResultURL: URL?
    private var micResultURL: URL?
    private var cameraResultURL: URL?

    // Error tracking
    private var recorderErrors: [RecordingComponent: Error] = [:]

    // MARK: - Computed Properties

    var isCurrentlyRecording: Bool {
        state.isRecording
    }

    /// Whether the active session supports pausing. The macOS 15+ native
    /// screen-recording path can't pause (ScreenCaptureKit writes the file
    /// itself), and pausing only the mic/camera would desync every track.
    var canPause: Bool {
        screenRecorder.supportsPause
    }

    var formattedDuration: String {
        let hours = Int(currentDuration) / 3600
        let minutes = Int(currentDuration) / 60 % 60
        let seconds = Int(currentDuration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var activeRecorders: [String] {
        var active: [String] = []
        if screenRecorderState.isRecording { active.append("Screen") }
        if micRecorderState.isRecording { active.append("Microphone") }
        if cameraRecorderState.isRecording { active.append("Camera") }
        return active
    }

    // MARK: - Initialization

    override init() {
        super.init()
        setupBindings()
    }

    private func setupBindings() {
        // Bind individual recorder states to coordinator
        screenRecorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.screenRecorderState = state
                self?.handlePrimaryRecorderStateChange(state)
            }
            .store(in: &cancellables)

        micRecorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.micRecorderState = state
            }
            .store(in: &cancellables)

        cameraRecorder.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.cameraRecorderState = state
            }
            .store(in: &cancellables)
    }

    private func handlePrimaryRecorderStateChange(_ state: RecordingState) {
        guard isSessionActive else { return }

        if case .failed(let error) = state {
            stopDurationTimer()
            isStopping = false
            self.state = .failed(CoordinatorError.screenRecorderFailed(error))

            Task {
                await self.micRecorder.discardRecording()
                await self.cameraRecorder.discardRecording()
            }

            cleanup()
        }
    }

    // MARK: - Public Methods

    /// Starts a synchronized recording session with all configured recorders
    func start(configuration: RecordingSessionConfiguration) async throws {
        // Throw for every non-startable state — a silent return here left the
        // caller thinking a session started when nothing was recording.
        guard state.canStart else {
            throw CoordinatorError.alreadyRecording
        }

        state = .preparing
        currentConfiguration = configuration
        recorderErrors.removeAll()
        screenResultURL = nil
        micResultURL = nil
        cameraResultURL = nil

        coordLogger.info("RecordingCoordinator: Starting recording session...")
        coordLogger.info("RecordingCoordinator: Video name = \(configuration.videoName)")

        do {
            // Initialize shared sync clock using host time clock
            syncClock = CMClockGetHostTimeClock()
            guard let clock = syncClock else {
                throw CoordinatorError.syncClockFailed
            }

            // Get the current time from the sync clock
            let time = CMClockGetTime(clock)
            syncTime = time

            // Start all recorders concurrently
            try await startAllRecorders(configuration: configuration, syncTime: time)

            recordingStartTime = Date()
            state = .recording(startTime: recordingStartTime!)
            startDurationTimer()
            coordLogger.info("RecordingCoordinator: Recording started successfully")

        } catch {
            coordLogger.info("RecordingCoordinator: Failed to start - \(error)")
            // If any recorder failed to start, stop the others
            await stopAllRecorders()
            state = .failed(error)
            cleanup()
            throw error
        }
    }

    /// Stops all recorders and waits for completion
    func stop() async throws -> RecordingResult {
        // Stopping straight from pause is fine: every recorder can finalize
        // from its paused state, so nothing needs to briefly resume capture.
        let startTime: Date
        let pausedDurationOverride: TimeInterval?

        switch state {
        case .recording(let recordingStart):
            startTime = recordingStart
            pausedDurationOverride = nil
        case .paused(let recordingStart, let pausedDuration):
            startTime = recordingStart
            pausedDurationOverride = pausedDuration
        default:
            throw CoordinatorError.notRecording
        }

        state = .stopping
        isStopping = true
        stopDurationTimer()

        // Stop all recorders and collect results
        await stopAllRecordersAndCollectResults()

        let endTime = Date()
        let duration = pausedDurationOverride ?? endTime.timeIntervalSince(startTime)

        isStopping = false

        // Check if there were any failures
        if !recorderErrors.isEmpty {
            // At least screen recording should succeed
            if screenResultURL == nil {
                state = .failed(CoordinatorError.partialFailure(recorderErrors))
                cleanup()
                throw CoordinatorError.partialFailure(recorderErrors)
            }
        }

        // Camera/mic stems are anchored at syncTime; the screen file starts at
        // its capture anchor. The difference is the compositing offset.
        var screenStartOffset: TimeInterval = 0
        if let anchor = screenRecorder.captureAnchor, let syncTime {
            let offset = CMTimeSubtract(anchor, syncTime).seconds
            if offset.isFinite {
                screenStartOffset = max(0, offset)
            }
        }

        // Create result
        let result = RecordingResult(
            videoName: currentConfiguration?.videoName ?? "Untitled",
            screenRecordingURL: screenResultURL,
            microphoneRecordingURL: micResultURL,
            cameraRecordingURL: cameraResultURL,
            duration: duration,
            startTime: startTime,
            endTime: endTime,
            warnings: recordingWarnings(from: recorderErrors),
            screenStartOffset: screenStartOffset
        )

        state = .finished(result)
        cleanup()

        return result
    }

    /// Discards the current recording session without saving
    func discard() async {
        stopDurationTimer()

        // Each recorder's discardRecording() stops its own capture, finalizes,
        // and deletes its file. Calling stopAllRecorders() first would clear
        // every outputURL and leave all the files behind.
        await screenRecorder.discardRecording()
        await micRecorder.discardRecording()
        await cameraRecorder.discardRecording()

        // Remove the per-session folder so a discarded take leaves nothing.
        if let sessionDirectory = currentSessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
            currentSessionDirectory = nil
        }

        cleanup()
        state = .idle
    }

    /// Returns a preview image from the camera recorder
    func getCameraPreview() -> CGImage? {
        cameraRecorder.currentFrame
    }

    // MARK: - Pause/Resume

    /// Pauses all active recorders
    func pause() async {
        guard canPause else { return }
        guard case .recording(let startTime) = state else { return }

        // Calculate current duration for when we resume
        let currentDuration = Date().timeIntervalSince(startTime)

        // Pause all recorders
        await screenRecorder.pauseRecording()
        micRecorder.pauseRecording()
        cameraRecorder.pauseRecording()

        // Stop the timer
        stopDurationTimer()

        // Update state
        state = .paused(startTime: startTime, pausedDuration: currentDuration)
    }

    /// Resumes all paused recorders
    func resume() async {
        guard case .paused(_, let pausedDuration) = state else { return }

        // Calculate new start time that accounts for the paused duration
        // This ensures the timer continues from where it left off
        let newStartTime = Date().addingTimeInterval(-pausedDuration)

        // Resume all recorders. The native screen path recreates its capture
        // stream here — if that fails, the recorder enters .failed and the
        // state binding moves the whole session to failed; don't override it.
        await screenRecorder.resumeRecording()
        if case .failed = screenRecorder.state { return }

        micRecorder.resumeRecording()
        cameraRecorder.resumeRecording()

        // Restart the timer
        recordingStartTime = newStartTime
        startDurationTimer()

        // Update state
        state = .recording(startTime: newStartTime)
    }

    // MARK: - Private Methods

    private func startAllRecorders(configuration: RecordingSessionConfiguration, syncTime: CMTime) async throws {
        // Create configurations for each recorder

        let screenTarget: RecordingConfiguration.RecordTarget
        switch configuration.recordTarget {
        case .fullScreen(let display):
            screenTarget = .fullScreen(display)
        case .window(let window):
            screenTarget = .window(window)
        case .area(let display, let rect, let scale):
            screenTarget = .area(display, rect, scale)
        }

        // Resolve ONE per-recording folder up front and share it with every
        // recorder so screen/mic/camera files land together (and same-title
        // recordings get numbered sibling folders).
        guard let baseDirectory = SettingsManager.shared.effectiveOutputFolder else {
            throw CoordinatorError.screenRecorderFailed(RecordingError.invalidOutputURL)
        }
        let sessionDirectory = RecordingOutputFileResolver.uniqueRecordingDirectory(
            videoName: configuration.videoName,
            in: baseDirectory
        )
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            throw CoordinatorError.screenRecorderFailed(RecordingError.outputFileSetupFailed(error.localizedDescription))
        }
        currentSessionDirectory = sessionDirectory

        // 1. Screen Recorder Configuration
        let screenConfig = RecordingConfiguration(
            videoName: configuration.videoName,
            outputDirectory: sessionDirectory,
            recordTarget: screenTarget,
            includeSystemAudio: configuration.includeSystemAudio,
            includeMicrophone: false,
            selectedMicrophone: nil,
            selectedCamera: nil,
            showCameraOverlay: false,
            quality: configuration.quality,
            frameRate: configuration.frameRate,
            showsCursor: configuration.captureCursor
        )

        // Start screen recorder first (it's the primary)
        try await screenRecorder.startRecording(configuration: screenConfig)

        // Start other recorders concurrently - optional recorder failures are tracked but do not fail the session.
        await withTaskGroup(of: Void.self) { group in
            // Microphone
            if let microphone = configuration.selectedMicrophone {
                group.addTask {
                    let micConfig = MicrophoneConfiguration(
                        videoName: configuration.videoName,
                        outputDirectory: sessionDirectory,
                        selectedMicrophone: microphone
                    )
                    if let error = await self.startOptionalMicrophoneRecorder(with: micConfig, syncTime: syncTime) {
                        await MainActor.run {
                            self.recorderErrors[.microphone] = error
                        }
                    }
                }
            }

            // Camera
            if let camera = configuration.selectedCamera {
                group.addTask {
                    let cameraConfig = CameraConfiguration(
                        videoName: configuration.videoName,
                        outputDirectory: sessionDirectory,
                        selectedCamera: camera,
                        quality: .medium,
                        frameRate: configuration.frameRate,
                        overlayPosition: .bottomRight,
                        overlaySize: CGSize(width: 320, height: 240)
                    )
                    if let error = await self.startOptionalCameraRecorder(configuration: cameraConfig, syncTime: syncTime) {
                        await MainActor.run {
                            self.recorderErrors[.camera] = error
                        }
                    }
                }
            }

            for await _ in group {
                // Each completion is handled individually.
            }
        }
    }

    private func startOptionalMicrophoneRecorder(with configuration: MicrophoneConfiguration, syncTime: CMTime) async -> Error? {
        do {
            try await micRecorder.startRecording(configuration: configuration, syncTime: syncTime)
            return nil
        } catch {
            return error
        }
    }

    private func startOptionalCameraRecorder(configuration: CameraConfiguration, syncTime: CMTime) async -> Error? {
        do {
            try await cameraRecorder.startRecording(
                configuration: configuration,
                syncTime: syncTime
            )
            return nil
        } catch {
            return error
        }
    }

    private func stopAllRecorders() async {
        // Stop all recorders concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try? await self.screenRecorder.stopRecording()
            }

            group.addTask {
                _ = try? await self.micRecorder.stopRecording()
            }

            group.addTask {
                _ = try? await self.cameraRecorder.stopRecording()
            }
        }
    }

    private func stopAllRecordersAndCollectResults() async {
        await withTaskGroup(of: (RecordingComponent, URL?).self) { group in
            // Stop screen recorder
            group.addTask {
                do {
                    let url = try await self.screenRecorder.stopRecording()
                    return (.screen, url)
                } catch {
                    await MainActor.run {
                        self.recorderErrors[.screen] = error
                    }
                    return (.screen, nil)
                }
            }

            // Stop mic recorder if it was started
            group.addTask {
                let micIsActive = await self.micRecorder.isCurrentlyRecording
                if micIsActive {
                    do {
                        let url = try await self.micRecorder.stopRecording()
                        return (.microphone, url)
                    } catch {
                        await MainActor.run {
                            self.recorderErrors[.microphone] = error
                        }
                        return (.microphone, nil)
                    }
                }
                return (.microphone, nil)
            }

            // Stop camera recorder if it was started
            group.addTask {
                let camIsActive = await self.cameraRecorder.isCurrentlyRecording
                if camIsActive {
                    do {
                        let url = try await self.cameraRecorder.stopRecording()
                        return (.camera, url)
                    } catch {
                        await MainActor.run {
                            self.recorderErrors[.camera] = error
                        }
                        return (.camera, nil)
                    }
                }
                return (.camera, nil)
            }

            // Collect results
            for await (component, url) in group {
                await MainActor.run {
                    switch component {
                    case .screen:
                        self.screenResultURL = url
                    case .microphone:
                        self.micResultURL = url
                    case .camera:
                        self.cameraResultURL = url
                    }
                }
            }
        }
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                if let startTime = self.recordingStartTime {
                    self.currentDuration = Date().timeIntervalSince(startTime)
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func cleanup() {
        currentConfiguration = nil
        recordingStartTime = nil
        syncClock = nil
        syncTime = nil
    }

    private func recordingWarnings(from errors: [RecordingComponent: Error]) -> [RecordingWarning] {
        errors
            .filter { $0.key != .screen }
            .map { component, error in
                RecordingWarning(
                    component: component,
                    message: error.localizedDescription
                )
            }
            .sorted { $0.component.rawValue < $1.component.rawValue }
    }

    private var isSessionActive: Bool {
        switch state {
        case .preparing, .recording, .paused:
            return true
        default:
            return false
        }
    }
}

// MARK: - Convenience Extensions

extension RecordingCoordinator {
    /// Quick start with minimal configuration
    func quickStart(
        videoName: String,
        display: Display,
        microphone: Microphone? = nil,
        camera: Camera? = nil
    ) async throws {
        let config = RecordingSessionConfiguration(
            videoName: videoName,
            recordTarget: .fullScreen(display),
            includeSystemAudio: true,
            selectedMicrophone: microphone,
            selectedCamera: camera,
            quality: .high,
            frameRate: .fps30
        )
        try await start(configuration: config)
    }
}

// MARK: - Preview Support

extension RecordingCoordinator {
    static var preview: RecordingCoordinator {
        RecordingCoordinator()
    }
}
