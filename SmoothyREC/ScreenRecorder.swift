//
//  ScreenRecorder.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import ScreenCaptureKit
@preconcurrency import AVFoundation
import VideoToolbox
@preconcurrency import CoreMedia
import CoreGraphics
import os.log

private let screenLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "ScreenRecorder")

// MARK: - Recording Configuration

struct RecordingConfiguration {
    let videoName: String
    let outputDirectory: URL
    let recordTarget: RecordTarget
    let includeSystemAudio: Bool
    let includeMicrophone: Bool
    let selectedMicrophone: Microphone?
    let selectedCamera: Camera?
    let showCameraOverlay: Bool
    let quality: RecordingQuality
    let frameRate: FrameRate
    var showsCursor: Bool = true

    enum RecordTarget {
        case fullScreen(Display)
        case window(CaptureWindow)
        case area(Display, CGRect, CGFloat)
    }
}

enum RecordingQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case ultra = "Ultra"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .low: return "720p"
        case .medium: return "1080p"
        case .high: return "1440p"
        case .ultra: return "4K"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .low: return (1280, 720)
        case .medium: return (1920, 1080)
        case .high: return (2560, 1440)
        case .ultra: return (3840, 2160)
        }
    }

    var videoBitrate: Int {
        switch self {
        case .low: return 5_000_000
        case .medium: return 10_000_000
        case .high: return 20_000_000
        case .ultra: return 40_000_000
        }
    }
}

enum FrameRate: Int, CaseIterable, Identifiable {
    case fps24 = 24
    case fps30 = 30
    case fps60 = 60

    var id: Int { rawValue }

    var description: String {
        return "\(rawValue) FPS"
    }
}

enum AudioSource: String, CaseIterable, Identifiable {
    case systemAudio = "System Audio"
    case microphone = "Microphone"
    case both = "Both"

    var id: String { rawValue }
}

// MARK: - Recording State

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording(startTime: Date)
    case paused
    case stopping
    case failed(Error)
    case finished(URL)

    static func == (lhs: RecordingState, rhs: RecordingState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.preparing, .preparing), (.paused, .paused), (.stopping, .stopping):
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
        if case .idle = self { return true }
        if case .finished = self { return true }
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Recording Error

enum RecordingError: Error, LocalizedError {
    case permissionDenied
    case noTargetSelected
    case assetWriterCreationFailed(String)
    case assetWriterStartFailed
    case invalidOutputURL
    case outputFileSetupFailed(String)
    case captureStreamFailed(Error)
    case encodingFailed(String)
    case diskSpaceLow
    case alreadyRecording
    case notRecording

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission denied. Please enable it in System Settings > Privacy & Security > Screen Recording."
        case .noTargetSelected:
            return "No display or window selected for recording."
        case .assetWriterCreationFailed(let detail):
            return "Failed to create video file writer: \(detail)"
        case .assetWriterStartFailed:
            return "Failed to start video encoding. Try a different quality setting."
        case .invalidOutputURL:
            return "Invalid output file location. Check your output folder in Settings."
        case .outputFileSetupFailed(let detail):
            return "Could not prepare the output file. \(detail)"
        case .captureStreamFailed(let error):
            return "Screen capture failed: \(error.localizedDescription)"
        case .encodingFailed(let message):
            return "Video encoding failed: \(message)"
        case .diskSpaceLow:
            return "Not enough disk space to continue recording."
        case .alreadyRecording:
            return "A recording is already in progress."
        case .notRecording:
            return "No active recording to stop."
        }
    }
}

// MARK: - Screen Recorder

@MainActor
class ScreenRecorder: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var state: RecordingState = .idle
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var droppedFrames: Int = 0

    // MARK: - Private Properties

    private var captureStream: SCStream?

    // Recording State (synchronized via writerQueue)
    private struct RecorderState {
        var assetWriter: AVAssetWriter?
        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        var micAudioInput: AVAssetWriterInput?
        var usesNativeRecordingOutput = false
        var isRecording = false
        var hasStartedWriting = false
        var videoStartTime: CMTime?
        var frameCount = 0
    }

    nonisolated(unsafe) private var recorderState = RecorderState()
    private let stateLock = NSLock()

    private var currentConfiguration: RecordingConfiguration?
    private var outputURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    private var nativeRecordingOutput: AnyObject?

    // Audio capture
    private var audioCaptureSession: AVCaptureSession?
    private var micInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private let writerQueue = DispatchQueue(label: "com.smoothyrec.screenrecorder.writer", qos: .userInteractive)
    private let continuationLock = NSLock()
    nonisolated(unsafe) private var recordingStartContinuation: CheckedContinuation<Void, Error>?
    nonisolated(unsafe) private var recordingFinishContinuation: CheckedContinuation<Void, Error>?

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

    nonisolated private func replaceRecordingStartContinuation(_ continuation: CheckedContinuation<Void, Error>?) -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }

        let previous = recordingStartContinuation
        recordingStartContinuation = continuation
        return previous
    }

    nonisolated private func replaceRecordingFinishContinuation(_ continuation: CheckedContinuation<Void, Error>?) -> CheckedContinuation<Void, Error>? {
        continuationLock.lock()
        defer { continuationLock.unlock() }

        let previous = recordingFinishContinuation
        recordingFinishContinuation = continuation
        return previous
    }

    nonisolated private func resumePendingRecordingStart(with result: Result<Void, Error>) {
        replaceRecordingStartContinuation(nil)?.resume(with: result)
    }

    nonisolated private func resumePendingRecordingFinish(with result: Result<Void, Error>) {
        replaceRecordingFinishContinuation(nil)?.resume(with: result)
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

    private var supportsNativeRecordingOutput: Bool {
        if #available(macOS 15.0, *) {
            return true
        }

        return false
    }

    // MARK: - Public Methods

    func startRecording(configuration: RecordingConfiguration) async throws {
        guard state.canStart else {
            if case .recording = state {
                throw RecordingError.alreadyRecording
            }
            return
        }

        state = .preparing
        currentConfiguration = configuration

        do {
            try await checkPermissions()

            let useNativeRecordingOutput = supportsNativeRecordingOutput
            try setupOutputFile(configuration: configuration, useNativeRecordingOutput: useNativeRecordingOutput)

            if useNativeRecordingOutput {
                try await setupCaptureStream(configuration: configuration, useNativeRecordingOutput: true)
            } else {
                try setupAssetWriter(configuration: configuration)
                try await setupCaptureStream(configuration: configuration, useNativeRecordingOutput: false)
            }

            guard let stream = captureStream else {
                throw RecordingError.captureStreamFailed(
                    NSError(domain: "SmoothyREC", code: -1,
                           userInfo: [NSLocalizedDescriptionKey: "Capture stream not created"])
                )
            }

            if useNativeRecordingOutput {
                try await startNativeRecording(on: stream)
            } else {
                try await stream.startCapture()
            }

            updateState { state in
                state.usesNativeRecordingOutput = useNativeRecordingOutput
                state.isRecording = true
                state.hasStartedWriting = useNativeRecordingOutput
                state.frameCount = 0
                state.videoStartTime = nil
            }

            recordingStartTime = Date()
            state = .recording(startTime: recordingStartTime!)
            startDurationTimer()

            if configuration.includeMicrophone {
                startMicrophoneCapture(configuration: configuration)
            }

        } catch {
            state = .failed(error)
            await cleanup()
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        let wasRecording = readState { $0.isRecording }
        guard wasRecording else {
            throw RecordingError.notRecording
        }

        state = .stopping
        stopDurationTimer()

        updateState { $0.isRecording = false }

        stopMicrophoneCapture()

        try await stopCaptureAndFinalizeRecording()

        guard let outputURL = outputURL else {
            throw RecordingError.invalidOutputURL
        }

        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path) {
            fileSize = attributes[.size] as? Int64 ?? 0
        }

        state = .finished(outputURL)
        await cleanup()

        return outputURL
    }

    func pauseRecording() {
        if case .recording = state {
            state = .paused
            stopDurationTimer()
        }
    }

    func resumeRecording() {
        if state == .paused, let startTime = recordingStartTime {
            state = .recording(startTime: startTime)
            startDurationTimer()
        }
    }

    func discardRecording() async {
        stopDurationTimer()
        updateState { $0.isRecording = false }
        await stopCaptureDiscardingRecording()
        stopMicrophoneCapture()

        if let outputURL = outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }

        await cleanup()
        state = .idle
    }

    // MARK: - Setup Methods

    private func checkPermissions() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.permissionDenied
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if content.displays.isEmpty {
                throw RecordingError.permissionDenied
            }
        } catch {
            if let permissionError = screenCapturePermissionError(from: error) {
                throw permissionError
            }

            throw error
        }
    }

    private func setupOutputFile(configuration: RecordingConfiguration, useNativeRecordingOutput: Bool) throws {
        let fileExtension = useNativeRecordingOutput ? "mp4" : "mov"

        do {
            outputURL = try RecordingOutputFileResolver.preparedOutputURL(
                videoName: configuration.videoName,
                component: .screen,
                fileExtension: fileExtension,
                outputDirectory: configuration.outputDirectory
            )
        } catch {
            throw RecordingError.outputFileSetupFailed(error.localizedDescription)
        }
    }

    private func setupAssetWriter(configuration: RecordingConfiguration) throws {
        guard let outputURL = outputURL else {
            throw RecordingError.invalidOutputURL
        }

        let captureSize = resolvedCaptureSize(for: configuration)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        } catch {
            throw RecordingError.assetWriterCreationFailed(error.localizedDescription)
        }

        writer.shouldOptimizeForNetworkUse = false

        updateState { state in
            state.assetWriter = writer
        }

        try setupVideoInput(configuration: configuration, captureSize: captureSize)

        if configuration.includeSystemAudio {
            try setupSystemAudioInput()
        }

        if configuration.includeMicrophone {
            try setupMicrophoneAudioInput()
        }

        guard writer.startWriting() else {
            let detail = writer.error?.localizedDescription ?? "Unknown error"
            screenLogger.error("AVAssetWriter.startWriting() failed: \(detail)")
            throw RecordingError.assetWriterStartFailed
        }

        screenLogger.info("AVAssetWriter started successfully for \(outputURL.lastPathComponent)")
    }

    private func setupVideoInput(configuration: RecordingConfiguration, captureSize: CGSize) throws {
        let width = Int(captureSize.width)
        let height = Int(captureSize.height)

        let hevcCompression: [String: Any] = [
            AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
            AVVideoAverageBitRateKey: configuration.quality.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: true
        ]

        let h264Compression: [String: Any] = [
            AVVideoProfileLevelKey: kVTProfileLevel_H264_High_AutoLevel,
            AVVideoAverageBitRateKey: configuration.quality.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
            AVVideoAllowFrameReorderingKey: false
        ]

        let codecPreferences: [(AVVideoCodecType, [String: Any])] = [
            (.h264, h264Compression),
            (.hevc, hevcCompression)
        ]

        var videoInput: AVAssetWriterInput?
        var selectedCodec: AVVideoCodecType?

        updateState { state in
            guard let writer = state.assetWriter else { return }
            for (codec, compression) in codecPreferences {
                let settings: [String: Any] = [
                    AVVideoCodecKey: codec,
                    AVVideoWidthKey: width,
                    AVVideoHeightKey: height,
                    AVVideoCompressionPropertiesKey: compression
                ]
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    videoInput = input
                    selectedCodec = codec
                    break
                }
            }
        }

        guard let input = videoInput, let codec = selectedCodec else {
            throw RecordingError.assetWriterCreationFailed("Cannot add video input (no supported codec)")
        }

        screenLogger.info("Selected video codec: \(codec.rawValue) for size \(width)x\(height)")

        updateState { state in
            state.videoInput = input
        }
    }

    private func setupSystemAudioInput() throws {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        let success = updateState { state -> Bool in
            if let writer = state.assetWriter, writer.canAdd(input) {
                writer.add(input)
                state.audioInput = input
                return true
            }
            return false
        }

        if !success {
            throw RecordingError.assetWriterCreationFailed("Cannot add system audio input")
        }
    }

    private func setupMicrophoneAudioInput() throws {
        let audioSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = true

        let success = updateState { state -> Bool in
            if let writer = state.assetWriter, writer.canAdd(input) {
                writer.add(input)
                state.micAudioInput = input
                return true
            }
            return false
        }

        if !success {
            throw RecordingError.assetWriterCreationFailed("Cannot add microphone audio input")
        }
    }

    private func setupCaptureStream(configuration: RecordingConfiguration, useNativeRecordingOutput: Bool) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.permissionDenied
        }

        let content: SCShareableContent

        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            if let permissionError = screenCapturePermissionError(from: error) {
                throw permissionError
            }

            throw RecordingError.captureStreamFailed(error)
        }

        guard !content.displays.isEmpty else {
            throw RecordingError.permissionDenied
        }

        let filter: SCContentFilter
        let streamConfig = SCStreamConfiguration()

        switch configuration.recordTarget {
        case .fullScreen(let display):
            let scDisplay: SCDisplay
            if let matching = content.displays.first(where: { $0.displayID == display.id }) {
                scDisplay = matching
            } else if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
                scDisplay = mainDisplay
            } else {
                scDisplay = content.displays[0]
            }

            filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])

        case .window(let window):
            if let scWindow = content.windows.first(where: { $0.windowID == window.id }) {
                filter = SCContentFilter(desktopIndependentWindow: scWindow)
            } else {
                throw RecordingError.noTargetSelected
            }

        case .area(let display, let rect, _):
            let scDisplay: SCDisplay
            if let matching = content.displays.first(where: { $0.displayID == display.id }) {
                scDisplay = matching
            } else if let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) {
                scDisplay = mainDisplay
            } else {
                scDisplay = content.displays[0]
            }

            filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
            // Capture only the user-selected sub-region of the display.
            streamConfig.sourceRect = rect
        }

        let captureSize = resolvedCaptureSize(for: configuration, filter: filter)
        streamConfig.width = Int(captureSize.width)
        streamConfig.height = Int(captureSize.height)

        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate.rawValue))
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.scalesToFit = true
        streamConfig.queueDepth = 5
        streamConfig.showsCursor = configuration.showsCursor

        if configuration.includeSystemAudio {
            streamConfig.capturesAudio = true
            streamConfig.excludesCurrentProcessAudio = true
        }

        captureStream = SCStream(filter: filter, configuration: streamConfig, delegate: self)

        guard let captureStream else {
            throw RecordingError.captureStreamFailed(
                NSError(domain: "SmoothyREC", code: -1, userInfo: [NSLocalizedDescriptionKey: "Capture stream was not created"])
            )
        }

        if useNativeRecordingOutput {
            try setupNativeRecordingOutput(on: captureStream)
        } else {
            try captureStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))

            if configuration.includeSystemAudio {
                try captureStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
            }
        }
    }

    // MARK: - Microphone Capture

    private func startMicrophoneCapture(configuration: RecordingConfiguration) {
        guard let microphone = configuration.selectedMicrophone else { return }

        guard let device = AVCaptureDevice(uniqueID: microphone.uniqueID) else { return }

        do {
            audioCaptureSession = AVCaptureSession()

            micInput = try AVCaptureDeviceInput(device: device)

            if audioCaptureSession?.canAddInput(micInput!) == true {
                audioCaptureSession?.addInput(micInput!)
            }

            audioOutput = AVCaptureAudioDataOutput()
            audioOutput?.setSampleBufferDelegate(self, queue: .global(qos: .userInitiated))

            if audioCaptureSession?.canAddOutput(audioOutput!) == true {
                audioCaptureSession?.addOutput(audioOutput!)
            }

            audioCaptureSession?.startRunning()

        } catch {
            screenLogger.error("Failed to start embedded microphone capture: \(error.localizedDescription)")
        }
    }

    private func stopMicrophoneCapture() {
        audioCaptureSession?.stopRunning()
        audioCaptureSession = nil
        micInput = nil
        audioOutput = nil
    }

    // MARK: - Cleanup

    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async {
                let writer = self.readState { $0.assetWriter }
                let hasStarted = self.readState { $0.hasStartedWriting }

                self.updateState { state in
                    state.videoInput?.markAsFinished()
                    state.audioInput?.markAsFinished()
                    state.micAudioInput?.markAsFinished()
                }

                if let writer = writer, writer.status == .writing, hasStarted {
                    nonisolated(unsafe) let writer = writer
                    writer.finishWriting {
                        if writer.status == .failed {
                            let detail = writer.error?.localizedDescription ?? "Unknown error"
                            screenLogger.error("AVAssetWriter.finishWriting() failed: \(detail)")
                            continuation.resume(throwing: RecordingError.encodingFailed(detail))
                        } else {
                            screenLogger.info("AVAssetWriter finished writing successfully")
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

    private func stopCaptureAndFinalizeRecording() async throws {
        let usesNativeRecordingOutput = readState { $0.usesNativeRecordingOutput }

        if usesNativeRecordingOutput {
            try await stopNativeRecording()
            return
        }

        do {
            try await captureStream?.stopCapture()
        } catch { }

        try await finishWriting()
    }

    private func stopCaptureDiscardingRecording() async {
        let usesNativeRecordingOutput = readState { $0.usesNativeRecordingOutput }

        if usesNativeRecordingOutput {
            try? await stopNativeRecording()
            return
        }

        try? await captureStream?.stopCapture()
        try? await finishWriting()
    }

    private func cleanup() async {
        captureStream = nil
        nativeRecordingOutput = nil
        outputURL = nil
        _ = replaceRecordingStartContinuation(nil)
        _ = replaceRecordingFinishContinuation(nil)
        updateState { state in
            state.assetWriter = nil
            state.videoInput = nil
            state.audioInput = nil
            state.micAudioInput = nil
            state.usesNativeRecordingOutput = false
            state.isRecording = false
            state.hasStartedWriting = false
            state.videoStartTime = nil
            state.frameCount = 0
        }
        currentConfiguration = nil
        recordingStartTime = nil
    }

    // MARK: - Helper Methods

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                if let startTime = self.recordingStartTime {
                    self.currentDuration = Date().timeIntervalSince(startTime)
                }

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

    private func resolvedCaptureSize(for configuration: RecordingConfiguration, filter: SCContentFilter? = nil) -> CGSize {
        // Area capture is sized from the selected region (points × backing scale),
        // computed identically whether or not a filter is available so the asset
        // writer and the stream agree on dimensions.
        if case .area(_, let rect, let scale) = configuration.recordTarget {
            let maxSize = CGSize(
                width: configuration.quality.dimensions.width,
                height: configuration.quality.dimensions.height
            )
            let pixelSize = CGSize(width: rect.width * scale, height: rect.height * scale)
            return scaledSize(pixelSize, fittingWithin: maxSize)
        }

        if #available(macOS 14.0, *), let filter {
            let scaledFilterSize = CGSize(
                width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
                height: filter.contentRect.height * CGFloat(filter.pointPixelScale)
            )

            if scaledFilterSize.width > 0, scaledFilterSize.height > 0 {
                let maxSize = CGSize(
                    width: configuration.quality.dimensions.width,
                    height: configuration.quality.dimensions.height
                )
                return scaledSize(scaledFilterSize, fittingWithin: maxSize)
            }
        }

        let sourceSize: CGSize
        switch configuration.recordTarget {
        case .fullScreen(let display):
            sourceSize = CGSize(width: display.width, height: display.height)
        case .window(let window):
            sourceSize = window.size
        case .area(_, let rect, let scale):
            sourceSize = CGSize(width: rect.width * scale, height: rect.height * scale)
        }

        let maxSize = CGSize(
            width: configuration.quality.dimensions.width,
            height: configuration.quality.dimensions.height
        )

        return scaledSize(sourceSize, fittingWithin: maxSize)
    }

    private func scaledSize(_ sourceSize: CGSize, fittingWithin maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return maxSize
        }

        let widthScale = maxSize.width / sourceSize.width
        let heightScale = maxSize.height / sourceSize.height
        let scale = min(1.0, min(widthScale, heightScale))

        let scaledWidth = max(2, Int((sourceSize.width * scale).rounded(.down)))
        let scaledHeight = max(2, Int((sourceSize.height * scale).rounded(.down)))

        let evenWidth = scaledWidth - (scaledWidth % 2)
        let evenHeight = scaledHeight - (scaledHeight % 2)

        return CGSize(width: max(2, evenWidth), height: max(2, evenHeight))
    }

    @MainActor
    private func failRecording(with error: Error) {
        let recording = readState { $0.isRecording }
        guard recording || state == .preparing || state == .paused else { return }

        stopDurationTimer()
        updateState { $0.isRecording = false }
        state = .failed(error)
        stopMicrophoneCapture()

        Task {
            try? await self.captureStream?.stopCapture()
            await self.cleanup()
        }
    }

    private func screenCapturePermissionError(from error: Error) -> RecordingError? {
        ScreenCapturePermissionClassifier.isPermissionDenied(error) ? .permissionDenied : nil
    }

    private nonisolated func isCompleteVideoFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let firstAttachment = attachments.first,
              let rawStatus = firstAttachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .started
    }

    private func startNativeRecording(on stream: SCStream) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = replaceRecordingStartContinuation(continuation)

            Task {
                do {
                    try await stream.startCapture()
                } catch {
                    self.resumePendingRecordingStart(with: .failure(RecordingError.captureStreamFailed(error)))
                }
            }
        }
    }

    private func stopNativeRecording() async throws {
        guard let stream = captureStream else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            _ = replaceRecordingFinishContinuation(continuation)

            Task {
                do {
                    try await stream.stopCapture()
                } catch {
                    self.resumePendingRecordingFinish(with: .failure(RecordingError.captureStreamFailed(error)))
                }
            }
        }
    }

    private func setupNativeRecordingOutput(on stream: SCStream) throws {
        guard let outputURL = outputURL else {
            throw RecordingError.invalidOutputURL
        }

        guard #available(macOS 15.0, *) else {
            throw RecordingError.assetWriterCreationFailed("ScreenCaptureKit recording output is unavailable on this macOS version.")
        }

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL

        if recordingConfiguration.availableVideoCodecTypes.contains(.h264) {
            recordingConfiguration.videoCodecType = .h264
        } else if let fallbackCodec = recordingConfiguration.availableVideoCodecTypes.first {
            recordingConfiguration.videoCodecType = fallbackCodec
        }

        if recordingConfiguration.availableOutputFileTypes.contains(.mp4) {
            recordingConfiguration.outputFileType = .mp4
        } else if let fallbackFileType = recordingConfiguration.availableOutputFileTypes.first {
            recordingConfiguration.outputFileType = fallbackFileType
        }

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        nativeRecordingOutput = recordingOutput
    }
}

// MARK: - SCStreamDelegate

extension ScreenRecorder: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        resumePendingRecordingStart(with: .failure(RecordingError.captureStreamFailed(error)))
        resumePendingRecordingFinish(with: .failure(RecordingError.captureStreamFailed(error)))

        Task { @MainActor in
            self.failRecording(with: RecordingError.captureStreamFailed(error))
        }
    }
}

// MARK: - SCStreamOutput

extension ScreenRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }

        nonisolated(unsafe) let sampleBuffer = sampleBuffer
        writerQueue.async { [weak self] in
            guard let self else { return }
            switch outputType {
            case .screen:
                self.handleVideoSampleBuffer(sampleBuffer)
            case .audio:
                self.handleAudioSampleBuffer(sampleBuffer)
            case .microphone:
                break
            @unknown default:
                break
            }
        }
    }

    private nonisolated func handleVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard isCompleteVideoFrame(sampleBuffer) else { return }

        updateState { state in
            guard state.isRecording else { return }

            guard let writer = state.assetWriter, writer.status == .writing else {
                return
            }

            if !state.hasStartedWriting {
                let startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startSession(atSourceTime: startTime)
                state.hasStartedWriting = true
                state.videoStartTime = startTime
            }

            state.frameCount += 1

            if let error = writer.error {
                screenLogger.error("AVAssetWriter entered error state during video capture: \(error.localizedDescription)")
                Task { @MainActor in
                    self.failRecording(with: RecordingError.encodingFailed(error.localizedDescription))
                }
                return
            }

            if let videoInput = state.videoInput, videoInput.isReadyForMoreMediaData {
                if !videoInput.append(sampleBuffer) {
                    let message = writer.error?.localizedDescription ?? "Failed to append video frame."
                    screenLogger.error("Failed to append video frame: \(message)")
                    Task { @MainActor in
                        self.failRecording(with: RecordingError.encodingFailed(message))
                    }
                }
            } else if state.videoInput != nil {
                Task { @MainActor in
                    self.droppedFrames += 1
                }
            }
        }
    }

    private nonisolated func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        updateState { state in
            guard state.isRecording, state.hasStartedWriting else { return }

            if let audioInput = state.audioInput, audioInput.isReadyForMoreMediaData {
                if !audioInput.append(sampleBuffer) {
                    let message = state.assetWriter?.error?.localizedDescription ?? "Failed to append system audio."
                    Task { @MainActor in
                        self.failRecording(with: RecordingError.encodingFailed(message))
                    }
                }
            }
        }
    }
}

@available(macOS 15.0, *)
extension ScreenRecorder: SCRecordingOutputDelegate {
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        resumePendingRecordingStart(with: .success(()))
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let wrappedError = RecordingError.encodingFailed(error.localizedDescription)
        resumePendingRecordingStart(with: .failure(wrappedError))
        resumePendingRecordingFinish(with: .failure(wrappedError))

        Task { @MainActor in
            self.failRecording(with: wrappedError)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        resumePendingRecordingFinish(with: .success(()))
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension ScreenRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        nonisolated(unsafe) let sampleBuffer = sampleBuffer
        writerQueue.async { [weak self] in
            guard let self else { return }

            self.updateState { state in
                guard state.isRecording, state.hasStartedWriting else { return }

                if let micAudioInput = state.micAudioInput, micAudioInput.isReadyForMoreMediaData {
                    if !micAudioInput.append(sampleBuffer) {
                        let message = state.assetWriter?.error?.localizedDescription ?? "Failed to append microphone audio."
                        Task { @MainActor in
                            self.failRecording(with: RecordingError.encodingFailed(message))
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Preview Support

extension ScreenRecorder {
    static var preview: ScreenRecorder {
        ScreenRecorder()
    }
}
