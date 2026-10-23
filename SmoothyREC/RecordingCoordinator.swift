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

// Capture engines are injectable so lifecycle failures can be tested without
// accessing a user's screen, camera or microphone.
@MainActor
protocol ScreenRecording: AnyObject {
    var state: RecordingState { get }
    var statePublisher: AnyPublisher<RecordingState, Never> { get }
    var captureAnchor: CMTime? { get }
    var supportsPause: Bool { get }
    func startRecording(configuration: RecordingConfiguration) async throws
    func stopRecording() async throws -> URL
    func discardRecording() async
    func pauseRecording() async
    func resumeRecording() async
}

@MainActor
protocol MicrophoneRecording: AnyObject {
    var state: MicRecorderState { get }
    var statePublisher: AnyPublisher<MicRecorderState, Never> { get }
    func startRecording(configuration: MicrophoneConfiguration, syncTime: CMTime) async throws
    func stopRecording() async throws -> URL
    func discardRecording() async
    func pauseRecording()
    func resumeRecording()
}

@MainActor
protocol CameraRecording: AnyObject {
    var state: CameraRecorderState { get }
    var statePublisher: AnyPublisher<CameraRecorderState, Never> { get }
    var currentFrame: CGImage? { get }
    func startRecording(configuration: CameraConfiguration, syncTime: CMTime) async throws
    func stopRecording() async throws -> URL
    func discardRecording() async
    func pauseRecording()
    func resumeRecording()
}

extension ScreenRecorder: ScreenRecording {
    var statePublisher: AnyPublisher<RecordingState, Never> { $state.eraseToAnyPublisher() }
}

extension MicRecorder: MicrophoneRecording {
    var statePublisher: AnyPublisher<MicRecorderState, Never> { $state.eraseToAnyPublisher() }
}

extension CameraRecorder: CameraRecording {
    var statePublisher: AnyPublisher<CameraRecorderState, Never> { $state.eraseToAnyPublisher() }
}

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

    let screenRecorder: any ScreenRecording
    let micRecorder: any MicrophoneRecording
    let cameraRecorder: any CameraRecording

    // MARK: - Private Properties

    private var currentConfiguration: RecordingSessionConfiguration?
    private(set) var currentSessionDirectory: URL?
    private(set) var recoveryDirectory: URL?
    private let outputDirectory: URL?
    private let trackUsage: (RecorderFeature) -> Void
    private var startedComponents = Set<RecordingComponent>()
    private var stopTask: Task<RecordingResult, Error>?
    private var pauseResumeTask: Task<Void, Never>?
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

    /// Pause transitions finish before a concurrent Stop finalizes the files.
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

    override convenience init() {
        self.init(screenRecorder: ScreenRecorder(), micRecorder: MicRecorder(), cameraRecorder: CameraRecorder())
    }

    init(screenRecorder: any ScreenRecording, micRecorder: any MicrophoneRecording,
         cameraRecorder: any CameraRecording, outputDirectory: URL? = nil,
         trackUsage: ((RecorderFeature) -> Void)? = nil) {
        self.screenRecorder = screenRecorder
        self.micRecorder = micRecorder
        self.cameraRecorder = cameraRecorder
        self.outputDirectory = outputDirectory
        self.trackUsage = trackUsage ?? { RecorderTelemetry.shared.track($0) }
        super.init()
        setupBindings()
    }

    private func setupBindings() {
        // Bind individual recorder states to coordinator
        screenRecorder.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.screenRecorderState = state
                self?.handlePrimaryRecorderStateChange(state)
            }
            .store(in: &cancellables)

        micRecorder.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.micRecorderState = state
                if case .failed(let error) = state, self?.isSessionActive == true,
                   case .failed = self?.micRecorder.state {
                    self?.recorderErrors[.microphone] = error
                }
            }
            .store(in: &cancellables)

        cameraRecorder.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.cameraRecorderState = state
                if case .failed(let error) = state, self?.isSessionActive == true,
                   case .failed = self?.cameraRecorder.state {
                    self?.recorderErrors[.camera] = error
                }
            }
            .store(in: &cancellables)
    }

    private func handlePrimaryRecorderStateChange(_ state: RecordingState) {
        guard isSessionActive, case .failed = screenRecorder.state else { return }

        if case .failed(let error) = state {
            recorderErrors[.screen] = error
            // Preserve every independently recorded track. Startup handles its
            // own failure; an active take follows the same single Stop path.
            if self.state.isRecording || self.state.isPaused {
                Task { _ = try? await self.stop() }
            }
        }
    }

    // MARK: - Public Methods

    /// Starts a synchronized recording session with all configured recorders
    func start(configuration: RecordingSessionConfiguration) async throws {
        // Throw for every non-startable state — a silent return here left the
        // caller thinking a session started when nothing was recording.
        guard state.canStart, !isStopping else {
            throw CoordinatorError.alreadyRecording
        }

        state = .preparing
        stopTask = nil
        startedComponents.removeAll()
        recoveryDirectory = nil
        currentDuration = 0
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

            if case .failed(let error) = screenRecorder.state {
                throw CoordinatorError.screenRecorderFailed(error)
            }

            recordingStartTime = Date()
            state = .recording(startTime: recordingStartTime!)
            startDurationTimer()
            trackUsage(.recordingStart)
            switch configuration.recordTarget {
            case .fullScreen: trackUsage(.recordScreen)
            case .window: trackUsage(.recordWindow)
            case .area: trackUsage(.recordArea)
            }
            if startedComponents.contains(.camera), recorderErrors[.camera] == nil { trackUsage(.recordCamera) }
            if startedComponents.contains(.microphone), recorderErrors[.microphone] == nil { trackUsage(.recordMicrophone) }
            if configuration.includeSystemAudio { trackUsage(.recordSystemAudio) }
            if configuration.captureCursor { trackUsage(.recordCursor) }
            coordLogger.info("RecordingCoordinator: Recording started successfully")

        } catch {
            coordLogger.info("RecordingCoordinator: Failed to start - \(error)")
            // If any recorder failed to start, stop the others
            await stopAllRecordersAndCollectResults()
            state = .failed(error)
            cleanup()
            throw error
        }
    }

    /// Stops all recorders and waits for completion
    func stop() async throws -> RecordingResult {
        if let stopTask { return try await stopTask.value }
        if case .finished(let result) = state { return result }
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
        let duration = pausedDurationOverride ?? Date().timeIntervalSince(startTime)

        let task = Task {
            await self.pauseResumeTask?.value
            return try await self.finishSession(startTime: startTime, duration: duration)
        }
        stopTask = task
        return try await task.value
    }

    private func finishSession(startTime: Date, duration: TimeInterval) async throws -> RecordingResult {
        defer { isStopping = false }
        captureRecorderFailures()

        // Capture the reference before any engine clears its session state.
        var screenStartOffset: TimeInterval = 0
        if let anchor = screenRecorder.captureAnchor, let syncTime {
            let offset = CMTimeSubtract(anchor, syncTime).seconds
            if offset.isFinite { screenStartOffset = max(0, offset) }
        }

        // Stop all recorders and collect results
        await stopAllRecordersAndCollectResults()
        captureRecorderFailures()

        let endTime = Date()

        // Check if there were any failures
        guard screenResultURL != nil || micResultURL != nil || cameraResultURL != nil else {
            let error = CoordinatorError.partialFailure(recorderErrors)
            state = .failed(error)
            cleanup()
            throw error
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
        trackUsage(result.isComplete ? .recordingSave : .recordingRecover)
        recoveryDirectory = nil
        cleanup()

        return result
    }

    /// Discards the current recording session without saving
    func discard() async {
        // Deletion is only entered for an explicit discard of a live take.
        // Completed/failed sessions keep their files even if a stale UI fires.
        guard state.isRecording || state.isPaused else { return }
        if let pauseResumeTask { await pauseResumeTask.value }
        guard state.isRecording || state.isPaused else { return }
        state = .stopping
        trackUsage(.recordingDiscard)
        isStopping = true
        defer { isStopping = false }
        stopDurationTimer()

        // Each recorder's discardRecording() stops its own capture, finalizes,
        // and deletes its file. Calling stopAllRecorders() first would clear
        // every outputURL and leave all the files behind.
        if startedComponents.contains(.screen) { await screenRecorder.discardRecording() }
        if startedComponents.contains(.microphone) { await micRecorder.discardRecording() }
        if startedComponents.contains(.camera) { await cameraRecorder.discardRecording() }

        // Remove the per-session folder so a discarded take leaves nothing.
        if let sessionDirectory = currentSessionDirectory {
            try? FileManager.default.removeItem(at: sessionDirectory)
            currentSessionDirectory = nil
        }

        cleanup()
        recoveryDirectory = nil
        state = .idle
    }

    /// Returns a preview image from the camera recorder
    func getCameraPreview() -> CGImage? {
        cameraRecorder.currentFrame
    }

    // MARK: - Pause/Resume

    /// Pauses all active recorders
    func pause() async {
        guard canPause, pauseResumeTask == nil else { return }
        guard case .recording(let startTime) = state else { return }

        // Calculate current duration for when we resume
        let currentDuration = Date().timeIntervalSince(startTime)

        // Pause all recorders
        micRecorder.pauseRecording()
        cameraRecorder.pauseRecording()

        // Stop the timer
        stopDurationTimer()

        // Update state
        state = .paused(startTime: startTime, pausedDuration: currentDuration)
        let task = Task { await self.screenRecorder.pauseRecording() }
        pauseResumeTask = task
        await task.value
        pauseResumeTask = nil
        if state.isPaused { trackUsage(.recordingPause) }
    }

    /// Resumes all paused recorders
    func resume() async {
        guard pauseResumeTask == nil else { return }
        guard case .paused(_, let pausedDuration) = state else { return }

        // Calculate new start time that accounts for the paused duration
        // This ensures the timer continues from where it left off
        let newStartTime = Date().addingTimeInterval(-pausedDuration)

        // Resume all recorders. The native screen path recreates its capture
        // stream here — if that fails, the recorder enters .failed and the
        // state binding moves the whole session to failed; don't override it.
        let task = Task { await self.screenRecorder.resumeRecording() }
        pauseResumeTask = task
        await task.value
        pauseResumeTask = nil
        guard state.isPaused else { return }
        if case .failed = screenRecorder.state { return }

        micRecorder.resumeRecording()
        cameraRecorder.resumeRecording()

        // Restart the timer
        recordingStartTime = newStartTime
        startDurationTimer()

        // Update state
        state = .recording(startTime: newStartTime)
        trackUsage(.recordingResume)
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
        guard let baseDirectory = outputDirectory ?? SettingsManager.shared.effectiveOutputFolder else {
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
        recoveryDirectory = sessionDirectory

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
        startedComponents.insert(.screen)

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
            startedComponents.insert(.microphone)
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
            startedComponents.insert(.camera)
            return nil
        } catch {
            return error
        }
    }

    private func stopAllRecordersAndCollectResults() async {
        let started = startedComponents
        await withTaskGroup(of: (RecordingComponent, URL?).self) { group in
            // Stop screen recorder
            group.addTask {
                guard started.contains(.screen) else { return (.screen, nil) }
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
                if started.contains(.microphone) {
                    do {
                        let url = try await self.micRecorder.stopRecording()
                        return (.microphone, url)
                    } catch {
                        await MainActor.run {
                            if self.recorderErrors[.microphone] == nil {
                                self.recorderErrors[.microphone] = error
                            }
                        }
                        return (.microphone, nil)
                    }
                }
                return (.microphone, nil)
            }

            // Stop camera recorder if it was started
            group.addTask {
                if started.contains(.camera) {
                    do {
                        let url = try await self.cameraRecorder.stopRecording()
                        return (.camera, url)
                    } catch {
                        await MainActor.run {
                            if self.recorderErrors[.camera] == nil {
                                self.recorderErrors[.camera] = error
                            }
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
        currentSessionDirectory = nil
        startedComponents.removeAll()
    }

    private func captureRecorderFailures() {
        if case .failed(let error) = screenRecorder.state { recorderErrors[.screen] = error }
        if case .failed(let error) = micRecorder.state { recorderErrors[.microphone] = error }
        if case .failed(let error) = cameraRecorder.state { recorderErrors[.camera] = error }
    }

    private func recordingWarnings(from errors: [RecordingComponent: Error]) -> [RecordingWarning] {
        errors
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
