//
//  MicMonitorManager.swift
//  SmoothyREC
//
//  Microphone monitoring with volume meter and audio passthrough for sound check
//

import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import SwiftUI

/// Manages microphone monitoring with volume meter and optional audio passthrough (hear yourself)
@MainActor
class MicMonitorManager: NSObject, ObservableObject {

    // MARK: - Published Properties

    @Published private(set) var audioLevel: Float = 0.0 // Normalized 0.0-1.0
    @Published private(set) var dbLevel: Float = -160.0 // dB level for display
    @Published private(set) var isMonitoring = false
    @Published private(set) var isPassthroughEnabled = false
    @Published private(set) var error: MicMonitorError?

    // MARK: - Private Properties

    private var captureSession: AVCaptureSession?
    private var audioInput: AVCaptureDeviceInput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var currentMicID: String?

    private let sessionQueue = DispatchQueue(label: "com.smoothyrec.micmonitor", qos: .userInitiated)

    // Audio engine for passthrough
    private var audioEngine: AVAudioEngine?
    private var audioPlayer: AVAudioPlayerNode?

    // Audio level smoothing
    private var smoothedLevel: Float = 0.0
    private let smoothingFactor: Float = 0.35

    // MARK: - Error Types

    enum MicMonitorError: Error, LocalizedError {
        case permissionDenied
        case microphoneNotAvailable
        case sessionSetupFailed
        case inputDeviceNotAvailable
        case audioEngineSetupFailed

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return "Microphone permission denied. Please enable it in System Settings."
            case .microphoneNotAvailable:
                return "Selected microphone is not available."
            case .sessionSetupFailed:
                return "Failed to setup microphone monitoring session."
            case .inputDeviceNotAvailable:
                return "Microphone input device is no longer available."
            case .audioEngineSetupFailed:
                return "Failed to setup audio passthrough."
            }
        }
    }

    // MARK: - Public Methods

    /// Starts microphone monitoring for the specified microphone
    func startMonitoring(microphone: Microphone?) async {
        // Stop existing monitoring first
        await stopMonitoring()

        guard let microphone = microphone else {
            return
        }

        // Check permission
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            error = .permissionDenied
            return
        }

        currentMicID = microphone.uniqueID

        do {
            try await setupCaptureSession(microphone: microphone)
            await startSession()
            isMonitoring = true
            error = nil
        } catch let monitorError as MicMonitorError {
            error = monitorError
            isMonitoring = false
        } catch {
            self.error = .sessionSetupFailed
            isMonitoring = false
        }
    }

    /// Stops microphone monitoring
    func stopMonitoring() async {
        // Disable passthrough first
        await setPassthroughEnabled(false)

        guard captureSession != nil else { return }

        await stopSession()

        captureSession = nil
        audioInput = nil
        audioOutput = nil
        currentMicID = nil

        audioLevel = 0.0
        dbLevel = -160.0
        smoothedLevel = 0.0

        isMonitoring = false
        isPassthroughEnabled = false
    }

    /// Switches to a different microphone
    func switchMicrophone(to microphone: Microphone?) async {
        // If same mic, do nothing
        if let mic = microphone, mic.uniqueID == currentMicID {
            return
        }

        // Remember passthrough state
        let wasPassthroughEnabled = isPassthroughEnabled

        // Stop current and start new
        await startMonitoring(microphone: microphone)

        // Restore passthrough state if it was enabled
        if wasPassthroughEnabled && isMonitoring {
            await setPassthroughEnabled(true)
        }
    }

    /// Toggles audio passthrough (hear yourself)
    func setPassthroughEnabled(_ enabled: Bool) async {
        guard isMonitoring else {
            isPassthroughEnabled = false
            return
        }

        if enabled == isPassthroughEnabled {
            return
        }

        if enabled {
            do {
                try setupAudioEngine()
                try audioEngine?.start()
                isPassthroughEnabled = true
            } catch {
                isPassthroughEnabled = false
                self.error = .audioEngineSetupFailed
            }
        } else {
            audioEngine?.stop()
            audioEngine = nil
            audioPlayer = nil
            isPassthroughEnabled = false
        }
    }

    /// Toggles passthrough on/off
    func togglePassthrough() async {
        await setPassthroughEnabled(!isPassthroughEnabled)
    }

    // MARK: - Private Setup Methods

    private func setupCaptureSession(microphone: Microphone) async throws {
        // Find the AVCaptureDevice
        guard let device = AVCaptureDevice(uniqueID: microphone.uniqueID) else {
            throw MicMonitorError.microphoneNotAvailable
        }

        // Create capture session
        let session = AVCaptureSession()

        // Create input
        do {
            audioInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw MicMonitorError.inputDeviceNotAvailable
        }

        guard let audioInput = audioInput else {
            throw MicMonitorError.inputDeviceNotAvailable
        }

        // Add input to session
        guard session.canAddInput(audioInput) else {
            throw MicMonitorError.sessionSetupFailed
        }
        session.addInput(audioInput)

        // Create output
        audioOutput = AVCaptureAudioDataOutput()
        audioOutput?.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: max(1, microphone.inputChannels),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioOutput?.setSampleBufferDelegate(self, queue: sessionQueue)

        guard let audioOutput = audioOutput else {
            throw MicMonitorError.sessionSetupFailed
        }

        guard session.canAddOutput(audioOutput) else {
            throw MicMonitorError.sessionSetupFailed
        }
        session.addOutput(audioOutput)

        self.captureSession = session
    }

    private func setupAudioEngine() throws {
        let engine = AVAudioEngine()

        // Get the input node (microphone)
        let inputNode = engine.inputNode

        // AVAudioEngine's input node defaults to the SYSTEM default microphone.
        // Bind it to the mic the user actually selected, or "Hear Microphone"
        // plays back the wrong device.
        if let uid = currentMicID {
            bindInput(of: inputNode, toDeviceWithUID: uid)
        }

        // Get the output format
        let outputNode = engine.outputNode
        let outputFormat = outputNode.outputFormat(forBus: 0)

        // Install tap on input node to process audio
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputNode.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            guard let self = self else { return }

            // Calculate audio level
            let level = self.calculateAudioLevel(from: buffer)

            Task { @MainActor in
                self.updateAudioLevel(level)
            }

            // If passthrough is enabled, also schedule the buffer for playback
            if self.isPassthroughEnabled {
                self.scheduleBufferForPlayback(buffer, format: outputFormat)
            }
        }

        // Connect input to output for passthrough
        // Note: We use a player node for more control over the audio flow
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: outputNode, format: outputFormat)

        self.audioEngine = engine
        self.audioPlayer = player
    }

    /// Points an AVAudioEngine input node at a specific CoreAudio device.
    /// AVCaptureDevice.uniqueID for microphones is the CoreAudio device UID,
    /// so it translates directly. Best-effort: on failure the engine keeps the
    /// system default input rather than breaking passthrough entirely.
    private func bindInput(of inputNode: AVAudioInputNode, toDeviceWithUID uid: String) {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var translationAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString

        let translateStatus = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &translationAddress,
                UInt32(MemoryLayout<CFString>.size),
                uidPointer,
                &size,
                &deviceID
            )
        }

        guard translateStatus == noErr, deviceID != kAudioObjectUnknown else { return }
        guard let audioUnit = inputNode.audioUnit else { return }

        var mutableDeviceID = deviceID
        AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
    }

    private func scheduleBufferForPlayback(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let player = audioPlayer else { return }

        // Convert buffer to output format if needed
        guard let convertedBuffer = convertBuffer(buffer, toFormat: format) else { return }

        // Schedule the buffer for playback
        player.scheduleBuffer(convertedBuffer, at: nil, options: .interrupts, completionHandler: nil)

        // Start playing if not already
        if !player.isPlaying {
            player.play()
        }
    }

    private func convertBuffer(_ buffer: AVAudioPCMBuffer, toFormat format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // If formats match, return as-is
        if buffer.format == format {
            return buffer
        }

        // Simple conversion for mono to stereo or sample rate changes
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else { return nil }

        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { return nil }

        var error: NSError?
        let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        return status == .haveData ? outputBuffer : nil
    }

    private func startSession() async {
        guard let session = captureSession else { return }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.startRunning()
                continuation.resume()
            }
        }
    }

    private func stopSession() async {
        guard let session = captureSession else { return }

        await withCheckedContinuation { continuation in
            sessionQueue.async {
                session.stopRunning()
                continuation.resume()
            }
        }
    }

    // MARK: - Audio Level Calculation

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return 0.0 }

        let channelCount = max(1, Int(buffer.format.channelCount))
        let frameLength = Int(buffer.frameLength)
        var sum: Double = 0
        var peak: Double = 0
        var sampleCount = 0

        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameLength {
                let sample = Double(samples[frameIndex])
                sum += sample * sample
                peak = max(peak, abs(sample))
                sampleCount += 1
            }
        }

        return Self.normalizedMeterLevel(sum: sum, peak: peak, sampleCount: sampleCount)
    }

    nonisolated private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return 0.0
        }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return 0.0 }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return calculateAudioLevelFromCopiedSamples(sampleBuffer, asbd: asbd)
        }

        let dataLength = CMBlockBufferGetDataLength(dataBuffer)
        guard dataLength > 0 else { return 0.0 }

        var bytes = [UInt8](repeating: 0, count: dataLength)
        let copyStatus = bytes.withUnsafeMutableBytes { rawBuffer in
            CMBlockBufferCopyDataBytes(
                dataBuffer,
                atOffset: 0,
                dataLength: dataLength,
                destination: rawBuffer.baseAddress!
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return 0.0 }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        var sum: Double = 0
        var peak: Double = 0
        var sampleCount = 0

        bytes.withUnsafeBytes { rawBuffer in
            switch (isFloat, isSignedInteger, bitsPerChannel) {
            case (true, _, 32):
                for sample in rawBuffer.bindMemory(to: Float32.self) {
                    let value = Double(sample)
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (true, _, 64):
                for sample in rawBuffer.bindMemory(to: Double.self) {
                    sum += sample * sample
                    peak = max(peak, abs(sample))
                    sampleCount += 1
                }
            case (false, true, 16):
                for sample in rawBuffer.bindMemory(to: Int16.self) {
                    let value = Double(sample) / Double(Int16.max)
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (false, true, 32):
                for sample in rawBuffer.bindMemory(to: Int32.self) {
                    let value = Double(sample) / Double(Int32.max)
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (false, false, 8):
                for sample in rawBuffer.bindMemory(to: UInt8.self) {
                    let value = (Double(sample) - 128.0) / 128.0
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            default:
                break
            }
        }

        let normalized = Self.normalizedMeterLevel(sum: sum, peak: peak, sampleCount: sampleCount)
        if normalized > 0 {
            return normalized
        }

        return calculateAudioLevelFromCopiedSamples(sampleBuffer, asbd: asbd)
    }

    @MainActor
    private func updateAudioLevel(_ level: Float) {
        // Apply smoothing
        smoothedLevel = (smoothingFactor * level) + ((1 - smoothingFactor) * smoothedLevel)

        audioLevel = smoothedLevel

        // Invert the meter mapping (0…1 ↔ -60…0 dB) for the readout so the
        // number matches what the bar shows.
        let db = (smoothedLevel * 60) - 60
        dbLevel = max(-60, min(0, db))
    }

    nonisolated private static func normalizedMeterLevel(sum: Double, peak: Double, sampleCount: Int) -> Float {
        guard sampleCount > 0 else { return 0.0 }

        let rms = sqrt(sum / Double(sampleCount))
        let responsiveAmplitude = max(rms, peak * 0.55)
        let db = 20 * log10(max(responsiveAmplitude, 0.000001))
        // Map -60 dB…0 dB linearly onto 0…1 with no artificial boost, so the
        // meter only approaches full scale when the signal approaches clipping.
        let normalized = (db + 60.0) / 60.0

        return Float(max(0.0, min(1.0, normalized)))
    }

    nonisolated private func calculateAudioLevelFromCopiedSamples(
        _ sampleBuffer: CMSampleBuffer,
        asbd: AudioStreamBasicDescription
    ) -> Float {
        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 0,
                mDataByteSize: 0,
                mData: nil
            )
        )

        let status = withUnsafeMutablePointer(to: &audioBufferList) { pointer in
            pointer.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { reboundPointer in
                CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: reboundPointer,
                    bufferListSize: MemoryLayout<AudioBufferList>.size,
                    blockBufferAllocator: kCFAllocatorDefault,
                    blockBufferMemoryAllocator: kCFAllocatorDefault,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
            }
        }

        guard status == noErr else { return 0.0 }

        let buffers = UnsafeMutableAudioBufferListPointer(&audioBufferList)
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isSignedInteger = (asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger) != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)

        var sum: Double = 0
        var peak: Double = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            let byteCount = Int(buffer.mDataByteSize)

            switch (isFloat, isSignedInteger, bitsPerChannel) {
            case (true, _, 32):
                let samples = data.bindMemory(to: Float32.self, capacity: byteCount / MemoryLayout<Float32>.size)
                for index in 0..<(byteCount / MemoryLayout<Float32>.size) {
                    let value = Double(samples[index])
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (true, _, 64):
                let samples = data.bindMemory(to: Double.self, capacity: byteCount / MemoryLayout<Double>.size)
                for index in 0..<(byteCount / MemoryLayout<Double>.size) {
                    let value = samples[index]
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (false, true, 16):
                let samples = data.bindMemory(to: Int16.self, capacity: byteCount / MemoryLayout<Int16>.size)
                for index in 0..<(byteCount / MemoryLayout<Int16>.size) {
                    let value = Double(samples[index]) / Double(Int16.max)
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            case (false, true, 32):
                let samples = data.bindMemory(to: Int32.self, capacity: byteCount / MemoryLayout<Int32>.size)
                for index in 0..<(byteCount / MemoryLayout<Int32>.size) {
                    let value = Double(samples[index]) / Double(Int32.max)
                    sum += value * value
                    peak = max(peak, abs(value))
                    sampleCount += 1
                }
            default:
                continue
            }
        }

        return Self.normalizedMeterLevel(sum: sum, peak: peak, sampleCount: sampleCount)
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension MicMonitorManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Calculate audio level from sample buffer
        let level = calculateAudioLevel(from: sampleBuffer)

        Task { @MainActor in
            self.updateAudioLevel(level)
        }

        // If passthrough is enabled and audio engine is running, we need to convert and play
        // This is handled by the AVAudioEngine tap in setupAudioEngine
    }
}

// MARK: - SwiftUI Volume Meter View

/// Custom volume meter view with color-coded levels
struct VolumeMeterView: View {
    let level: Float // 0.0-1.0
    let dbLevel: Float // For display

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Volume bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        // Background
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.gray.opacity(0.2))

                        // Fill
                        RoundedRectangle(cornerRadius: 4)
                            .fill(volumeColor)
                            .frame(width: max(0, min(CGFloat(level) * geometry.size.width, geometry.size.width)))
                    }
                }
                .frame(height: 12)

                // dB label
                Text(formattedDB)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .frame(height: 20)
        }
    }

    private var volumeColor: Color {
        if level < 0.5 {
            return .green
        } else if level < 0.8 {
            return .yellow
        } else {
            return .red
        }
    }

    private var formattedDB: String {
        if dbLevel <= -59 {
            return "— dB"
        } else {
            return String(format: "%.1f dB", dbLevel)
        }
    }
}

/// Microphone monitor controls with volume meter and passthrough toggle
struct MicMonitorControls: View {
    @ObservedObject var monitorManager: MicMonitorManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Volume meter
            VStack(alignment: .leading, spacing: 4) {
                Text("Volume")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                VolumeMeterView(
                    level: monitorManager.audioLevel,
                    dbLevel: monitorManager.dbLevel
                )
            }

            // Passthrough toggle
            Button(action: {
                Task {
                    await monitorManager.togglePassthrough()
                }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: monitorManager.isPassthroughEnabled ? "speaker.wave.3.fill" : "speaker.slash.fill")
                    Text(monitorManager.isPassthroughEnabled ? "Hear Microphone (On)" : "Hear Microphone")
                    Spacer()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(monitorManager.isPassthroughEnabled ? .blue : .secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(monitorManager.isPassthroughEnabled ? Color.blue.opacity(0.1) : Color(.controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(monitorManager.isPassthroughEnabled ? Color.blue.opacity(0.3) : Color.gray.opacity(0.2), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!monitorManager.isMonitoring)

            if monitorManager.isPassthroughEnabled {
                Text("⚠️ Hearing your own microphone may cause feedback if speakers are too loud.")
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error = monitorManager.error {
                Text(error.localizedDescription)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Preview Support

extension MicMonitorManager {
    static var preview: MicMonitorManager {
        let manager = MicMonitorManager()
        return manager
    }
}
