//
//  MicRecorder.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
@preconcurrency import AVFoundation
@preconcurrency import CoreMedia
import os.log

private let micLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "MicRecorder")

// MARK: - Microphone Configuration

struct MicrophoneConfiguration {
    let videoName: String
    let outputDirectory: URL
    let selectedMicrophone: Microphone
    let sampleRate: Double = 48000.0
    let channels: Int = 1  // Mono for microphone
    // 192 kbps is the practical ceiling for mono AAC-LC. Requesting more
    // (this used to be 320000) makes the encoder reject EVERY buffer with
    // "Cannot Encode Media" and the recording silently ends up as a 0-byte
    // file.
    let bitrate: Int = 192000
}

// MARK: - Mic Recorder State

enum MicRecorderState: Equatable {
    case idle
    case preparing
    case recording(startTime: Date)
    case stopping
    case failed(Error)
    case finished(URL)

    static func == (lhs: MicRecorderState, rhs: MicRecorderState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.stopping, .stopping):
            return true
        case (.recording(let lhsTime), .recording(let rhsTime)):
            return lhsTime == rhsTime
        case (.finished(let lhsURL), .finished(let rhsURL)):
            return lhsURL == rhsURL
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

    var canStart: Bool {
        switch self {
        case .idle, .failed, .finished:
            return true
        default:
            return false
        }
    }
}

// MARK: - Mic Recorder Error

enum MicRecorderError: Error, LocalizedError {
    case permissionDenied
    case noMicrophoneSelected
    case assetWriterCreationFailed
    case assetWriterStartFailed
    case invalidOutputURL
    case outputFileSetupFailed(String)
    case captureSessionSetupFailed
    case inputDeviceNotAvailable
    case encodingFailed(String)
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Microphone permission denied. Please enable it in System Settings > Privacy & Security > Microphone."
        case .noMicrophoneSelected:
            return "No microphone selected for recording."
        case .assetWriterCreationFailed:
            return "Failed to create audio file writer."
        case .assetWriterStartFailed:
            return "Failed to start audio encoding."
        case .invalidOutputURL:
            return "Invalid output file location."
        case .outputFileSetupFailed(let detail):
            return "Could not prepare the microphone output file. \(detail)"
        case .captureSessionSetupFailed:
            return "Failed to setup microphone capture session."
        case .inputDeviceNotAvailable:
            return "Selected microphone is no longer available."
        case .encodingFailed(let message):
            return "Audio encoding failed: \(message)"
        case .alreadyRecording:
            return "Microphone recording is already in progress."
        case .notRecording:
            return "No active microphone recording to stop."
        }
    }
}

// MARK: - Mic Recorder

@MainActor
class MicRecorder: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var state: MicRecorderState = .idle
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var audioLevel: Float = -160.0  // dB, -160 = silence

    // MARK: - Private Properties

    private var captureSession: AVCaptureSession?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private struct RecorderState {
        var assetWriter: AVAssetWriter?
        var assetWriterInput: AVAssetWriterInput?
        var isRecording = false
        var hasStartedWriting = false
        var isPaused = false
        var pauseStartedAt: CMTime?
        var pauseOffset: CMTime = .zero
    }

    nonisolated(unsafe) private var recorderState = RecorderState()
    private let stateLock = NSLock()

    /// Linear gain applied to captured PCM. Cached here so the nonisolated
    /// capture callback can read it without touching the MainActor settings.
    nonisolated(unsafe) private var captureGain: Float = 1.0

    private var currentConfiguration: MicrophoneConfiguration?
    private var outputURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var pauseBeganAt: Date?

    private let sessionQueue = DispatchQueue(label: "com.smoothyrec.micrecorder", qos: .userInitiated)

    nonisolated private func updateState<T>(_ block: (inout RecorderState) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block(&recorderState)
    }

    nonisolated private func readState<T>(_ block: (RecorderState) -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return block(recorderState)
    }

    // MARK: - Computed Properties

    var isCurrentlyRecording: Bool {
        state.isRecording
    }

    var outputFileURL: URL? {
        outputURL
    }

    var formattedDuration: String {
        let hours = Int(currentDuration) / 3600
        let minutes = Int(currentDuration) / 60 % 60
        let seconds = Int(currentDuration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var formattedAudioLevel: String {
        if audioLevel < -60 {
            return "—"
        } else {
            return String(format: "%.1f dB", audioLevel)
        }
    }

    // MARK: - Public Methods

    /// Starts microphone recording with the given configuration. `syncTime`
    /// anchors the file's timeline to the session-wide sync clock (the same
    /// anchor the camera uses) so all stems line up in an editor.
    func startRecording(configuration: MicrophoneConfiguration, syncTime: CMTime) async throws {
        guard state.canStart else {
            if case .recording = state {
                throw MicRecorderError.alreadyRecording
            }
            return
        }

        state = .preparing
        currentConfiguration = configuration
        captureGain = Float(SettingsManager.shared.micGain)

        do {
            try await checkMicrophonePermission()

            try setupOutputFile(configuration: configuration)

            try setupAssetWriter(configuration: configuration)

            try setupCaptureSession(configuration: configuration)

            try await startCaptureSession(syncTime: syncTime)

            recordingStartTime = Date()
            state = .recording(startTime: recordingStartTime!)
            startDurationTimer()
            startAudioLevelMetering()

        } catch {
            state = .failed(error)
            await cleanup()
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        let wasRecording = readState { $0.isRecording }
        guard wasRecording else {
            throw MicRecorderError.notRecording
        }

        state = .stopping
        stopDurationTimer()
        stopAudioLevelMetering()

        await stopCaptureSession()

        try await finishWriting()

        guard let outputURL = outputURL else {
            throw MicRecorderError.invalidOutputURL
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path) {
            fileSize = attributes[.size] as? Int64 ?? 0
        }

        state = .finished(outputURL)
        await cleanup()

        return outputURL
    }

    /// Discards the current recording without saving
    func discardRecording() async {
        stopDurationTimer()
        stopAudioLevelMetering()
        await stopCaptureSession()

        if let outputURL = outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }

        await cleanup()
        state = .idle
    }

    // MARK: - Setup Methods

    private func checkMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                throw MicRecorderError.permissionDenied
            }
        case .denied, .restricted:
            throw MicRecorderError.permissionDenied
        @unknown default:
            throw MicRecorderError.permissionDenied
        }
    }

    private func setupOutputFile(configuration: MicrophoneConfiguration) throws {
        do {
            outputURL = try RecordingOutputFileResolver.preparedOutputURL(
                videoName: configuration.videoName,
                component: .microphone,
                fileExtension: "m4a",
                outputDirectory: configuration.outputDirectory
            )
        } catch {
            throw MicRecorderError.outputFileSetupFailed(error.localizedDescription)
        }
    }

    private func setupAssetWriter(configuration: MicrophoneConfiguration) throws {
        guard let outputURL = outputURL else {
            throw MicRecorderError.invalidOutputURL
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .m4a)
        } catch {
            throw MicRecorderError.assetWriterCreationFailed
        }

        writer.shouldOptimizeForNetworkUse = false

        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channels,
            AVEncoderBitRateKey: configuration.bitrate,
            AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw MicRecorderError.assetWriterCreationFailed
        }

        updateState { state in
            state.assetWriter = writer
            state.assetWriterInput = input
        }
    }

    private func setupCaptureSession(configuration: MicrophoneConfiguration) throws {
        // Find the AVCaptureDevice for the selected microphone
        guard let device = AVCaptureDevice(uniqueID: configuration.selectedMicrophone.uniqueID) else {
            throw MicRecorderError.inputDeviceNotAvailable
        }

        // Create capture session
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .high

        // Create input
        do {
            audioInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicRecorderError.captureSessionSetupFailed
        }

        // Add input to session
        guard let audioInput = audioInput else {
            throw MicRecorderError.captureSessionSetupFailed
        }

        if captureSession?.canAddInput(audioInput) == true {
            captureSession?.addInput(audioInput)
        } else {
            throw MicRecorderError.captureSessionSetupFailed
        }

        // Create output
        audioOutput = AVCaptureAudioDataOutput()
        // Pin the capture format to interleaved 16-bit integer PCM. The macOS
        // default is Float32, which the level meter and applyGain() would
        // misread as Int16 — producing garbage levels and, with gain applied,
        // corrupted audio.
        audioOutput?.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: configuration.sampleRate,
            AVNumberOfChannelsKey: configuration.channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput?.setSampleBufferDelegate(self, queue: sessionQueue)

        guard let audioOutput = audioOutput else {
            throw MicRecorderError.captureSessionSetupFailed
        }

        if captureSession?.canAddOutput(audioOutput) == true {
            captureSession?.addOutput(audioOutput)
        } else {
            throw MicRecorderError.captureSessionSetupFailed
        }

        // Configure audio settings for capture
        // Note: Manual gain control is not available on macOS
    }

    private func startCaptureSession(syncTime: CMTime) async throws {
        guard let captureSession = captureSession else {
            throw MicRecorderError.captureSessionSetupFailed
        }

        let writer = readState { $0.assetWriter }
        guard let writer = writer, writer.startWriting() else {
            throw MicRecorderError.assetWriterStartFailed
        }

        // Anchor the timeline at the shared sync clock (not the first buffer)
        // so the mic stem aligns with the camera and the PiP compositor can
        // compensate for the screen recorder's startup latency.
        writer.startSession(atSourceTime: syncTime)
        updateState { $0.hasStartedWriting = true }

        await withCheckedContinuation { continuation in
            nonisolated(unsafe) let captureSession = captureSession
            sessionQueue.async {
                captureSession.startRunning()
                continuation.resume()
            }
        }

        updateState { $0.isRecording = true }
    }

    private func stopCaptureSession() async {
        guard let captureSession = captureSession else { return }

        await withCheckedContinuation { continuation in
            nonisolated(unsafe) let captureSession = captureSession
            sessionQueue.async {
                captureSession.stopRunning()
                continuation.resume()
            }
        }

        updateState { $0.isRecording = false }
    }

    // MARK: - Cleanup

    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                let writer = self.readState { $0.assetWriter }
                let hasStarted = self.readState { $0.hasStartedWriting }

                self.updateState { $0.assetWriterInput?.markAsFinished() }

                if let writer = writer, writer.status == .writing, hasStarted {
                    nonisolated(unsafe) let writer = writer
                    writer.finishWriting {
                        if writer.status == .failed {
                            let detail = writer.error?.localizedDescription ?? "Unknown error"
                            continuation.resume(throwing: MicRecorderError.encodingFailed(detail))
                        } else {
                            continuation.resume()
                        }
                    }
                } else {
                    if let writer = writer, writer.status == .writing {
                        writer.cancelWriting()
                    }
                    continuation.resume()
                }
            }
        }
    }

    private func cleanup() async {
        captureSession = nil
        audioInput = nil
        audioOutput = nil
        updateState { state in
            state.assetWriter = nil
            state.assetWriterInput = nil
            state.isRecording = false
            state.hasStartedWriting = false
            state.isPaused = false
            state.pauseStartedAt = nil
            state.pauseOffset = .zero
        }
        currentConfiguration = nil
        recordingStartTime = nil
        pauseBeganAt = nil
        audioLevel = -160.0
    }

    // MARK: - Pause/Resume

    /// Pause drops incoming buffers; resume shifts later buffers back by the
    /// paused duration so the file plays as one continuous take. The writer and
    /// its input are never touched — finishing the input mid-session would make
    /// the next append (or second startSession) throw an NSException.
    func pauseRecording() {
        let paused = updateState { state -> Bool in
            guard state.isRecording, !state.isPaused else { return false }
            state.isPaused = true
            state.pauseStartedAt = CMClockGetTime(CMClockGetHostTimeClock())
            return true
        }
        guard paused else { return }
        pauseBeganAt = Date()
        stopDurationTimer()
    }

    func resumeRecording() {
        let resumed = updateState { state -> Bool in
            guard state.isRecording, state.isPaused else { return false }
            if let startedAt = state.pauseStartedAt {
                state.pauseOffset = state.pauseOffset + (CMClockGetTime(CMClockGetHostTimeClock()) - startedAt)
            }
            state.pauseStartedAt = nil
            state.isPaused = false
            return true
        }
        guard resumed else { return }
        if let began = pauseBeganAt {
            recordingStartTime = recordingStartTime?.addingTimeInterval(Date().timeIntervalSince(began))
        }
        pauseBeganAt = nil
        startDurationTimer()
    }

    // MARK: - Helper Methods

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if let startTime = self.recordingStartTime {
                    self.currentDuration = Date().timeIntervalSince(startTime)
                }

                // Update file size
                if let outputURL = self.outputURL {
                    if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path) {
                        self.fileSize = attributes[.size] as? Int64 ?? 0
                    }
                }
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    private func startAudioLevelMetering() {
        // Levels update straight from the capture callback; nothing to poll.
    }

    private func stopAudioLevelMetering() {
        audioLevel = -160.0
    }

    /// Calculates RMS (Root Mean Square) audio level from sample buffer
    nonisolated private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return -160.0
        }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var dataLength: Int = 0

        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &dataLength, dataPointerOut: &dataPointer)

        guard let pointer = dataPointer else {
            return -160.0
        }

        let samples = pointer.withMemoryRebound(to: Int16.self, capacity: dataLength / 2) {
            UnsafeBufferPointer(start: $0, count: dataLength / 2)
        }

        // Calculate RMS
        var sum: Double = 0
        for sample in samples {
            let s = Double(sample) / 32768.0
            sum += s * s
        }

        let rms = sqrt(sum / Double(samples.count))

        // Convert to dB
        let db = 20 * log10(max(rms, 1e-10))

        return max(-160.0, min(0.0, Float(db)))
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let level = calculateAudioLevel(from: sampleBuffer)
        Task { @MainActor in
            self.audioLevel = level
        }

        nonisolated(unsafe) let sampleBuffer = sampleBuffer
        sessionQueue.async { [weak self] in
            guard let self else { return }

            self.updateState { state in
                guard state.isRecording, !state.isPaused, state.hasStartedWriting else { return }

                let buffer = SampleBufferRetimer.retimed(sampleBuffer, by: state.pauseOffset)

                if let input = state.assetWriterInput, input.isReadyForMoreMediaData {
                    self.applyGain(self.captureGain, to: buffer)
                    if !input.append(buffer) {
                        // Never fail silently: this is exactly how 0-byte
                        // recordings shipped for months.
                        let message = state.assetWriter?.error?.localizedDescription ?? "Failed to append microphone audio."
                        micLogger.error("Mic append failed: \(message)")
                        state.isRecording = false
                        Task { @MainActor in
                            self.state = .failed(MicRecorderError.encodingFailed(message))
                        }
                    }
                }
            }
        }
    }

    /// Scales 16-bit PCM samples in place. No-op at unity gain. Clamps to the
    /// Int16 range so boosting can't wrap loud peaks into noise.
    nonisolated private func applyGain(_ gain: Float, to sampleBuffer: CMSampleBuffer) {
        guard gain != 1.0, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        guard CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer else { return }

        let count = length / MemoryLayout<Int16>.size
        dataPointer.withMemoryRebound(to: Int16.self, capacity: count) { samples in
            for i in 0..<count {
                let scaled = Float(samples[i]) * gain
                samples[i] = Int16(max(-32768.0, min(32767.0, scaled)))
            }
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        micLogger.debug("Dropped audio sample")
    }
}

// MARK: - Preview Support

extension MicRecorder {
    static var preview: MicRecorder {
        let recorder = MicRecorder()
        return recorder
    }
}
