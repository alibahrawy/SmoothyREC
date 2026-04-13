//
//  CameraRecorder.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import AVFoundation
import CoreMedia
import CoreImage
import VideoToolbox

// MARK: - Camera Configuration

struct CameraConfiguration {
    let videoName: String
    let selectedCamera: Camera
    let quality: CameraQuality
    let frameRate: FrameRate
    let overlayPosition: OverlayPosition
    let overlaySize: CGSize
    
    enum CameraQuality {
        case low    // 480p
        case medium // 720p
        case high   // 1080p
        
        var dimensions: (width: Int, height: Int) {
            switch self {
            case .low: return (640, 480)
            case .medium: return (1280, 720)
            case .high: return (1920, 1080)
            }
        }
        
        var videoBitrate: Int {
            switch self {
            case .low: return 2_000_000      // 2 Mbps
            case .medium: return 5_000_000   // 5 Mbps
            case .high: return 10_000_000    // 10 Mbps
            }
        }
    }
    
    enum OverlayPosition {
        case bottomLeft
        case bottomRight
        case topLeft
        case topRight
        
        var corner: CGRect.Corner {
            switch self {
            case .bottomLeft: return .bottomLeft
            case .bottomRight: return .bottomRight
            case .topLeft: return .topLeft
            case .topRight: return .topRight
            }
        }
    }
}

extension CGRect {
    enum Corner {
        case bottomLeft, bottomRight, topLeft, topRight
    }
    
    func position(for size: CGSize, at corner: Corner, padding: CGFloat = 20) -> CGRect {
        let x: CGFloat
        let y: CGFloat
        
        switch corner {
        case .bottomLeft:
            x = padding
            y = self.height - size.height - padding
        case .bottomRight:
            x = self.width - size.width - padding
            y = self.height - size.height - padding
        case .topLeft:
            x = padding
            y = padding
        case .topRight:
            x = self.width - size.width - padding
            y = padding
        }
        
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

// MARK: - Camera Recorder State

enum CameraRecorderState: Equatable {
    case idle
    case preparing
    case recording(startTime: Date)
    case stopping
    case failed(Error)
    case finished(URL)
    
    static func == (lhs: CameraRecorderState, rhs: CameraRecorderState) -> Bool {
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

// MARK: - Camera Recorder Error

enum CameraRecorderError: Error, LocalizedError {
    case permissionDenied
    case noCameraSelected
    case assetWriterCreationFailed
    case assetWriterStartFailed
    case invalidOutputURL
    case captureSessionSetupFailed
    case inputDeviceNotAvailable
    case encodingFailed(String)
    case alreadyRecording
    case notRecording
    
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Camera permission denied. Please enable it in System Settings > Privacy & Security > Camera."
        case .noCameraSelected:
            return "No camera selected for recording."
        case .assetWriterCreationFailed:
            return "Failed to create video file writer."
        case .assetWriterStartFailed:
            return "Failed to start video encoding."
        case .invalidOutputURL:
            return "Invalid output file location."
        case .captureSessionSetupFailed:
            return "Failed to setup camera capture session."
        case .inputDeviceNotAvailable:
            return "Selected camera is no longer available."
        case .encodingFailed(let message):
            return "Video encoding failed: \(message)"
        case .alreadyRecording:
            return "Camera recording is already in progress."
        case .notRecording:
            return "No active camera recording to stop."
        }
    }
}

// MARK: - Camera Recorder

@MainActor
class CameraRecorder: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published private(set) var state: CameraRecorderState = .idle
    @Published private(set) var currentDuration: TimeInterval = 0
    @Published private(set) var fileSize: Int64 = 0
    @Published private(set) var currentFrame: CGImage?
    
    // MARK: - Private Properties
    
    private var captureSession: AVCaptureSession?
    private var videoInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    
    private struct RecorderState {
        var assetWriter: AVAssetWriter?
        var assetWriterInput: AVAssetWriterInput?
        var isRecording = false
        var hasStartedWriting = false
    }
    
    nonisolated(unsafe) private var recorderState = RecorderState()
    private let stateLock = NSLock()
    
    private var currentConfiguration: CameraConfiguration?
    private var outputURL: URL?
    private var recordingStartTime: Date?
    private var durationTimer: Timer?
    
    private let sessionQueue = DispatchQueue(label: "com.smoothyrec.camerarecorder", qos: .userInitiated)
    
    private var ciContext = CIContext()
    
    private let writerQueue = DispatchQueue(label: "com.smoothyrec.camerarecorder.writer", qos: .userInteractive)
    
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
    
    // MARK: - Public Methods
    
    /// Starts camera recording with the given configuration and sync time
    func startRecording(configuration: CameraConfiguration, syncTime: CMTime) async throws {
        guard state.canStart else {
            if case .recording = state {
                throw CameraRecorderError.alreadyRecording
            }
            return
        }
        
        state = .preparing
        currentConfiguration = configuration
        
        do {
            try await checkCameraPermission()
            
            try setupOutputFile(configuration: configuration)
            
            try setupAssetWriter(configuration: configuration)
            
            try setupCaptureSession(configuration: configuration)
            
            try await startCaptureSession(syncTime: syncTime)
            
            recordingStartTime = Date()
            state = .recording(startTime: recordingStartTime!)
            startDurationTimer()
            
        } catch {
            state = .failed(error)
            await cleanup()
            throw error
        }
    }
    
    func stopRecording() async throws -> URL {
        let wasRecording = readState { $0.isRecording }
        guard wasRecording else {
            throw CameraRecorderError.notRecording
        }
        
        state = .stopping
        stopDurationTimer()
        
        await stopCaptureSession()
        
        try await finishWriting()
        
        guard let outputURL = outputURL else {
            throw CameraRecorderError.invalidOutputURL
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
        await stopCaptureSession()
        
        if let outputURL = outputURL {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        await cleanup()
        state = .idle
    }
    
    // MARK: - Setup Methods
    
    private func checkCameraPermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                throw CameraRecorderError.permissionDenied
            }
        case .denied, .restricted:
            throw CameraRecorderError.permissionDenied
        @unknown default:
            throw CameraRecorderError.permissionDenied
        }
    }
    
    private func setupOutputFile(configuration: CameraConfiguration) throws {
        let fileManager = FileManager.default
        
        // Get output directory from settings (or default)
        guard let outputDirectory = SettingsManager.shared.effectiveOutputFolder else {
            throw CameraRecorderError.invalidOutputURL
        }
        
        // Create output directory if needed
        try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        
        // Generate filename: VideoName_camera_YYYY-MM-DD_HH-MM-SS.mov
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dateString = dateFormatter.string(from: Date())
        
        let sanitizedName = sanitizeFileName(configuration.videoName)
        let filename = "\(sanitizedName)_camera_\(dateString).mov"
        
        outputURL = outputDirectory.appendingPathComponent(filename)
        
        // Remove existing file if present
        if let outputURL = outputURL, fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }
    
    private func setupAssetWriter(configuration: CameraConfiguration) throws {
        guard let outputURL = outputURL else {
            throw CameraRecorderError.invalidOutputURL
        }
        
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: outputURL, fileType: .mov)
        } catch {
            throw CameraRecorderError.assetWriterCreationFailed
        }
        
        writer.shouldOptimizeForNetworkUse = false
        
        let dims = configuration.quality.dimensions
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: dims.width,
            AVVideoHeightKey: dims.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel,
                AVVideoAverageBitRateKey: configuration.quality.videoBitrate,
                AVVideoMaxKeyFrameIntervalKey: configuration.frameRate.rawValue,
                AVVideoMaxKeyFrameIntervalDurationKey: 1.0,
                AVVideoAllowFrameReorderingKey: true
            ] as [String: Any]
        ]
        
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = true
        
        if writer.canAdd(input) {
            writer.add(input)
        } else {
            throw CameraRecorderError.assetWriterCreationFailed
        }
        
        updateState { state in
            state.assetWriter = writer
            state.assetWriterInput = input
        }
    }
    
    private func setupCaptureSession(configuration: CameraConfiguration) throws {
        // Find the AVCaptureDevice for the selected camera
        guard let device = AVCaptureDevice(uniqueID: configuration.selectedCamera.uniqueID) else {
            throw CameraRecorderError.inputDeviceNotAvailable
        }
        
        // Create capture session
        captureSession = AVCaptureSession()
        captureSession?.sessionPreset = .high
        
        // Create input
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraRecorderError.captureSessionSetupFailed
        }
        
        // Add input to session
        guard let videoInput = videoInput else {
            throw CameraRecorderError.captureSessionSetupFailed
        }
        
        if captureSession?.canAddInput(videoInput) == true {
            captureSession?.addInput(videoInput)
        } else {
            throw CameraRecorderError.captureSessionSetupFailed
        }
        
        // Create output
        videoOutput = AVCaptureVideoDataOutput()
        videoOutput?.setSampleBufferDelegate(self, queue: sessionQueue)
        videoOutput?.alwaysDiscardsLateVideoFrames = true
        
        // Set pixel format
        if let videoOutput = videoOutput {
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        }
        
        guard let videoOutput = videoOutput else {
            throw CameraRecorderError.captureSessionSetupFailed
        }
        
        if captureSession?.canAddOutput(videoOutput) == true {
            captureSession?.addOutput(videoOutput)
        } else {
            throw CameraRecorderError.captureSessionSetupFailed
        }
    }
    
    private func startCaptureSession(syncTime: CMTime) async throws {
        guard let captureSession = captureSession else {
            throw CameraRecorderError.captureSessionSetupFailed
        }
        
        let writer = readState { $0.assetWriter }
        guard let writer = writer, writer.startWriting() else {
            throw CameraRecorderError.assetWriterStartFailed
        }
        
        writer.startSession(atSourceTime: syncTime)
        
        updateState { state in
            state.isRecording = true
            state.hasStartedWriting = true
        }
        
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                captureSession.startRunning()
                continuation.resume()
            }
        }
    }
    
    private func stopCaptureSession() async {
        guard let captureSession = captureSession else { return }
        
        await withCheckedContinuation { continuation in
            sessionQueue.async {
                captureSession.stopRunning()
                continuation.resume()
            }
        }
        
        updateState { $0.isRecording = false }
    }
    
    // MARK: - Pause/Resume
    
    func pauseRecording() {
        let recording = readState { $0.isRecording }
        guard recording else { return }
        updateState { state in
            state.assetWriterInput?.markAsFinished()
            state.hasStartedWriting = false
        }
    }

    func resumeRecording() {
        let recording = readState { $0.isRecording }
        guard recording else { return }
        updateState { state in
            if let assetWriter = state.assetWriter, assetWriter.status == .writing {
                let resumeTime = CMClockGetTime(CMClockGetHostTimeClock())
                assetWriter.startSession(atSourceTime: resumeTime)
                state.hasStartedWriting = true
            }
        }
    }
    
    // MARK: - Cleanup
    
    private func finishWriting() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writerQueue.async {
                let writer = self.readState { $0.assetWriter }
                let hasStarted = self.readState { $0.hasStartedWriting }
                
                self.updateState { $0.assetWriterInput?.markAsFinished() }
                
                if let writer = writer, writer.status == .writing, hasStarted {
                    writer.finishWriting {
                        if writer.status == .failed {
                            let detail = writer.error?.localizedDescription ?? "Unknown error"
                            continuation.resume(throwing: CameraRecorderError.encodingFailed(detail))
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
        videoInput = nil
        videoOutput = nil
        updateState { state in
            state.assetWriter = nil
            state.assetWriterInput = nil
            state.isRecording = false
            state.hasStartedWriting = false
        }
        currentConfiguration = nil
        recordingStartTime = nil
        currentFrame = nil
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
    
    private func sanitizeFileName(_ name: String) -> String {
        var sanitized = name
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>")
        sanitized = sanitized.components(separatedBy: invalidCharacters).joined(separator: "_")
        sanitized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if sanitized.isEmpty {
            return "Untitled"
        }
        
        return String(sanitized.prefix(100))
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let ciImage = CIImage(cvPixelBuffer: imageBuffer)
            let ctx = CIContext()
            if let cgImage = ctx.createCGImage(ciImage, from: ciImage.extent) {
                Task { @MainActor in
                    self.currentFrame = cgImage
                }
            }
        }
        
        writerQueue.async { [weak self] in
            guard let self else { return }
            
            self.updateState { state in
                guard state.isRecording else { return }
                
                if let input = state.assetWriterInput, input.isReadyForMoreMediaData {
                    input.append(sampleBuffer)
                }
            }
        }
    }
}

// MARK: - Preview Support

extension CameraRecorder {
    static var preview: CameraRecorder {
        let recorder = CameraRecorder()
        return recorder
    }
}
