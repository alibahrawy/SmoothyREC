# macOS Screen Recording App Development Guide

> A comprehensive reference for building native macOS screen recording apps similar to Screen Studio using Swift and modern Apple frameworks.

## Table of Contents

1. [Overview](#overview)
2. [ScreenCaptureKit Framework](#screencapturekit-framework)
3. [AVFoundation for Camera & Microphone](#avfoundation-for-camera--microphone)
4. [Video Composition & Export](#video-composition--export)
5. [App Architecture & Patterns](#app-architecture--patterns)
6. [Screen Studio Feature Analysis](#screen-studio-feature-analysis)
7. [Implementation Roadmap](#implementation-roadmap)

---

## Overview

Building a native macOS screen recording app requires combining multiple Apple frameworks:

- **ScreenCaptureKit** (macOS 12.3+) - Modern screen recording API
- **AVFoundation** - Camera, microphone, and video processing
- **AppKit** - macOS-specific UI and window management
- **Metal/Core Image** - Real-time video processing (optional)

### Target Platforms

| macOS Version | Key Features Available |
|---------------|----------------------|
| macOS 12.3+ | ScreenCaptureKit basic screen capture |
| macOS 13+ | System audio capture, SCScreenshotManager |
| macOS 14+ | SCContentSharingPicker, Presenter Overlay |
| macOS 15+ | Enhanced features |
| macOS 26 (Tahoe) | WWDC 2026 (June 8-12, 2026) - Features TBD |

---

## ScreenCaptureKit Framework

### Key Classes

| Class | Purpose |
|-------|---------|
| `SCShareableContent` | Discover available content (displays, windows, apps) |
| `SCDisplay` | Represents a physical display |
| `SCWindow` | Represents a window for capture |
| `SCRunningApplication` | Represents a running application |
| `SCContentFilter` | Determines what content to capture |
| `SCStreamConfiguration` | Configures how content is captured |
| `SCStream` | Main capture stream object |

### Content Selection

```swift
import ScreenCaptureKit

// Get all shareable content
let content = try await SCShareableContent.excludingDesktopWindows(
    false,               // Include desktop windows
    onScreenWindowsOnly: true  // Only visible windows
)

let displays = content.displays
let windows = content.windows
let apps = content.applications
```

### Display Filter (Exclude Own App)

```swift
// Exclude own app to avoid "hall of mirrors"
let excludedApps = content.applications.filter {
    $0.bundleIdentifier == Bundle.main.bundleIdentifier
}

let filter = SCContentFilter(
    display: display,
    excludingApplications: excludedApps,
    exceptingWindows: []
)
```

### Window Filter (Display Independent)

```swift
// Capture a single window regardless of display
let filter = SCContentFilter(desktopIndependentWindow: window)
```

### Stream Configuration

```swift
let config = SCStreamConfiguration()

// Resolution
config.width = 1920
config.height = 1080

// Frame rate (60 FPS)
config.minimumFrameInterval = CMTime(value: 1, timescale: 60)

// Pixel format
config.pixelFormat = kCVPixelFormatType_32BGRA

// Cursor and audio
config.showsCursor = true
config.capturesAudio = true
config.sampleRate = 48000
config.channelCount = 2

// Queue depth (3-8, affects latency vs performance)
config.queueDepth = 5
```

### Complete Screen Capture Implementation

```swift
import ScreenCaptureKit
import CoreMedia

class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let videoQueue = DispatchQueue(label: "videoQueue")
    private let audioQueue = DispatchQueue(label: "audioQueue")
    
    func startCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        
        guard let display = content.displays.first else {
            throw NSError(domain: "CaptureError", code: -1)
        }
        
        // Exclude own app
        let excludedApps = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )
        
        let config = SCStreamConfiguration()
        config.width = 1920
        config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        
        try await stream?.startCapture()
    }
    
    func stopCapture() async throws {
        try await stream?.stopCapture()
        stream = nil
    }
    
    func stream(_ stream: SCStream, 
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer, 
                of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleVideoSample(sampleBuffer)
        case .audio:
            handleAudioSample(sampleBuffer)
        @unknown default:
            break
        }
    }
    
    private func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        // Get metadata
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let attachments = attachmentsArray.first else { return }
        
        let status = attachments[.status] as? SCFrameStatus
        let contentRect = attachments[.contentRect] as? CGRect
        let contentScale = attachments[.contentScale] as? CGFloat
        
        // Process frame...
    }
    
    private func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        // Process audio sample buffer
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(error.localizedDescription)")
    }
}
```

### Screenshot API (macOS 13+)

```swift
// Capture as CGImage
if let image = try? await SCScreenshotManager.captureImage(
    contentFilter: filter,
    configuration: config
) {
    // Use CGImage
}

// Or capture as CMSampleBuffer
if let sampleBuffer = try? await SCScreenshotManager.captureSampleBuffer(
    contentFilter: filter,
    configuration: config
) {
    // Use CMSampleBuffer
}
```

### System Picker Integration (macOS 14+)

```swift
class CaptureManager: NSObject, SCContentSharingPickerObserver {
    private let picker = SCContentSharingPicker.shared()
    
    func setupPicker() {
        picker.addObserver(self)
        picker.active = true
    }
    
    func showPicker() {
        picker.present(for: nil, using: .window)
    }
    
    func contentSharingPicker(_ picker: SCContentSharingPicker, 
                              didUpdateWith filter: SCContentFilter, 
                              for stream: SCStream?) {
        // Handle selection
    }
    
    func contentSharingPicker(_ picker: SCContentSharingPicker, 
                              didCancelFor stream: SCStream?) {
        // Handle cancellation
    }
}
```

---

## AVFoundation for Camera & Microphone

### Device Discovery

```swift
import AVFoundation

// Camera discovery
let cameraDiscovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.external, .builtInWideAngleCamera],
    mediaType: .video,
    position: .unspecified
)
let cameras = cameraDiscovery.devices

// Microphone discovery
let audioDiscovery = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone, .external],
    mediaType: .audio,
    position: .unspecified
)
let microphones = audioDiscovery.devices

// Default devices
let defaultCamera = AVCaptureDevice.default(for: .video)
let defaultMicrophone = AVCaptureDevice.default(for: .audio)
```

### Camera Manager Implementation

```swift
import AVFoundation
import Combine

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    
    @Published var isRunning = false
    @Published var error: String?
    
    let videoDataOutput = AVCaptureVideoDataOutput()
    let audioDataOutput = AVCaptureAudioDataOutput()
    
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    
    func setupCamera(device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                
                // Video output
                self.videoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                }
                
            } catch {
                DispatchQueue.main.async {
                    self.error = error.localizedDescription
                }
            }
            
            self.session.commitConfiguration()
        }
    }
    
    func setupMicrophone(device: AVCaptureDevice) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.session.beginConfiguration()
            
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                
                self.audioDataOutput.setSampleBufferDelegate(self, queue: self.sessionQueue)
                
                if self.session.canAddOutput(self.audioDataOutput) {
                    self.session.addOutput(self.audioDataOutput)
                }
                
            } catch {
                print("Audio setup error: \(error)")
            }
            
            self.session.commitConfiguration()
        }
    }
    
    func start() {
        sessionQueue.async { [weak self] in
            self?.session.startRunning()
            DispatchQueue.main.async {
                self?.isRunning = true
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === videoDataOutput {
            onVideoSampleBuffer?(sampleBuffer)
        } else if output === audioDataOutput {
            onAudioSampleBuffer?(sampleBuffer)
        }
    }
}
```

### Camera Preview View (AppKit)

```swift
import Cocoa
import AVFoundation

class CameraPreviewView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer!
    
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        layer = previewLayer
        wantsLayer = true
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
```

### Floating Camera Window (Picture-in-Picture UI)

```swift
import AppKit
import AVFoundation
import SwiftUI

final class FloatingCameraWindowController: ObservableObject {
    @Published var isVisible = false
    @Published var windowSize: CGFloat = 300
    
    private var panel: NSPanel?
    private var session: AVCaptureSession?
    
    func show(session: AVCaptureSession) {
        self.session = session
        
        if let panel {
            panel.orderFront(nil)
            isVisible = true
            return
        }
        
        let panel = NSPanel(
            contentRect: NSRect(x: 100, y: 100, width: windowSize, height: windowSize * 9/16),
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        
        // Position bottom-right
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.maxX - windowSize - 30
            let y = screenFrame.minY + 30
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        
        // Set content
        let previewView = CameraPreviewView(session: session)
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 16
        previewView.layer?.masksToBounds = true
        
        panel.contentView = previewView
        panel.orderFront(nil)
        
        self.panel = panel
        isVisible = true
    }
    
    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
}
```

### Permission Handling

```swift
import AVFoundation

enum CapturePermission {
    case authorized
    case denied
    case notDetermined
    case restricted
    
    static var videoStatus: CapturePermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }
    
    static var audioStatus: CapturePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        @unknown default: return .notDetermined
        }
    }
    
    static func requestVideoAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
    
    static func requestAudioAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}
```

### Info.plist Requirements

```xml
<!-- Camera Permission -->
<key>NSCameraUsageDescription</key>
<string>This app needs access to the camera to record video.</string>

<!-- Microphone Permission -->
<key>NSMicrophoneUsageDescription</key>
<string>This app needs access to the microphone to record audio.</string>

<!-- Screen Recording Permission -->
<key>NSScreenCaptureUsageDescription</key>
<string>This app needs to record the screen to capture video.</string>
```

### Entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.microphone</key>
    <true/>
</dict>
</plist>
```

---

## Video Composition & Export

### Recording with AVAssetWriter

```swift
import AVFoundation

class AssetRecorder {
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private let writerQueue = DispatchQueue(label: "recorder.writer")
    private var isReady = false
    
    func startRecording(outputURL: URL, width: Int, height: Int) {
        do {
            let writer = try AVAssetWriter(url: outputURL, fileType: .mov)
            
            // Video settings
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 4,
                    AVVideoExpectedSourceFrameRateKey: 30,
                ],
            ]
            
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vInput.expectsMediaDataInRealTime = true
            
            if writer.canAdd(vInput) {
                writer.add(vInput)
                self.videoInput = vInput
            }
            
            // Audio settings
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128000,
            ]
            
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aInput.expectsMediaDataInRealTime = true
            
            if writer.canAdd(aInput) {
                writer.add(aInput)
                self.audioInput = aInput
            }
            
            writer.startWriting()
            self.assetWriter = writer
            
        } catch {
            print("Failed to create asset writer: \(error)")
        }
    }
    
    func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self = self,
                  let writer = self.assetWriter,
                  let input = self.videoInput,
                  writer.status == .writing else { return }
            
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            
            if !self.isReady {
                writer.startSession(atSourceTime: timestamp)
                self.isReady = true
            }
            
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
    
    func appendAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.async { [weak self] in
            guard let self = self,
                  let writer = self.assetWriter,
                  let input = self.audioInput,
                  writer.status == .writing,
                  self.isReady else { return }
            
            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
    
    func stopRecording(completion: @escaping () -> Void) {
        writerQueue.async { [weak self] in
            self?.videoInput?.markAsFinished()
            self?.audioInput?.markAsFinished()
            
            self?.assetWriter?.finishWriting {
                DispatchQueue.main.async {
                    completion()
                }
            }
        }
    }
}
```

### Picture-in-Picture Composition (Post-Processing)

```swift
import AVFoundation

class PictureInPictureComposer {
    
    struct PIPConfiguration {
        let screenAsset: AVAsset
        let webcamAsset: AVAsset
        let outputURL: URL
        let renderSize: CGSize
        let webcamSize: CGSize
        let webcamPosition: WebcamPosition
        
        enum WebcamPosition {
            case topLeft, topRight, bottomLeft, bottomRight
        }
    }
    
    func createPIPComposition(config: PIPConfiguration) async throws -> URL {
        
        // 1. Create composition with layered tracks
        guard let composition = createLayeredComposition(
            screenAsset: config.screenAsset,
            webcamAsset: config.webcamAsset
        ) else {
            throw PIPError.compositionCreationFailed
        }
        
        // 2. Create video composition for PIP layout
        let videoComposition = try createPIPVideoComposition(
            composition: composition,
            config: config
        )
        
        // 3. Export
        return try await export(
            composition: composition,
            videoComposition: videoComposition,
            outputURL: config.outputURL
        )
    }
    
    private func createLayeredComposition(
        screenAsset: AVAsset,
        webcamAsset: AVAsset
    ) -> AVMutableComposition? {
        
        let composition = AVMutableComposition()
        
        // Screen track (Track 1 - background)
        guard let screenTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: 1
        ) else { return nil }
        
        // Webcam track (Track 2 - foreground/PIP)
        guard let webcamTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: 2
        ) else { return nil }
        
        // Audio track
        guard let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        
        do {
            let screenDuration = screenAsset.tracks(withMediaType: .video).first?.timeRange.duration ?? .zero
            let webcamDuration = webcamAsset.tracks(withMediaType: .video).first?.timeRange.duration ?? .zero
            let duration = CMTimeMinimum(screenDuration, webcamDuration)
            
            // Insert tracks
            if let track = screenAsset.tracks(withMediaType: .video).first {
                try screenTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track, at: .zero
                )
            }
            
            if let track = webcamAsset.tracks(withMediaType: .video).first {
                try webcamTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track, at: .zero
                )
            }
            
            if let track = screenAsset.tracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: track, at: .zero
                )
            }
            
        } catch {
            print("Error: \(error)")
            return nil
        }
        
        return composition
    }
    
    private func createPIPVideoComposition(
        composition: AVMutableComposition,
        config: PIPConfiguration
    ) throws -> AVMutableVideoComposition {
        
        guard let videoComposition = AVMutableVideoComposition() else {
            throw PIPError.videoCompositionCreationFailed
        }
        
        videoComposition.renderSize = config.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        
        let videoTracks = composition.tracks(withMediaType: .video)
        guard videoTracks.count >= 2 else {
            throw PIPError.insufficientTracks
        }
        
        let screenTrack = videoTracks[0]
        let webcamTrack = videoTracks[1]
        
        // Calculate PIP position
        let pipOrigin = calculatePIPPosition(
            position: config.webcamPosition,
            containerSize: config.renderSize,
            pipSize: config.webcamSize
        )
        
        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        
        // Screen layer (background)
        let screenLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: screenTrack)
        let screenTransform = calculateAspectFitTransform(
            naturalSize: screenTrack.naturalSize,
            targetSize: config.renderSize
        )
        screenLayerInstruction.setTransform(screenTransform, at: .zero)
        
        // Webcam layer (PIP)
        let webcamLayerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: webcamTrack)
        let webcamNaturalSize = webcamTrack.naturalSize
        let webcamScale = min(
            config.webcamSize.width / webcamNaturalSize.width,
            config.webcamSize.height / webcamNaturalSize.height
        )
        
        var webcamTransform = CGAffineTransform.identity
        webcamTransform = webcamTransform.scaledBy(x: webcamScale, y: webcamScale)
        webcamTransform = webcamTransform.translatedBy(
            x: pipOrigin.x / webcamScale,
            y: pipOrigin.y / webcamScale
        )
        
        webcamLayerInstruction.setTransform(webcamTransform, at: .zero)
        
        // Layer order: First = background, Last = foreground
        mainInstruction.layerInstructions = [screenLayerInstruction, webcamLayerInstruction]
        videoComposition.instructions = [mainInstruction]
        
        return videoComposition
    }
    
    private func calculatePIPPosition(
        position: PIPConfiguration.WebcamPosition,
        containerSize: CGSize,
        pipSize: CGSize
    ) -> CGPoint {
        let padding: CGFloat = 20
        
        switch position {
        case .topLeft:
            return CGPoint(x: padding, y: padding)
        case .topRight:
            return CGPoint(x: containerSize.width - pipSize.width - padding, y: padding)
        case .bottomLeft:
            return CGPoint(x: padding, y: containerSize.height - pipSize.height - padding)
        case .bottomRight:
            return CGPoint(
                x: containerSize.width - pipSize.width - padding,
                y: containerSize.height - pipSize.height - padding
            )
        }
    }
    
    private func calculateAspectFitTransform(
        naturalSize: CGSize,
        targetSize: CGSize
    ) -> CGAffineTransform {
        let scale = min(
            targetSize.width / naturalSize.width,
            targetSize.height / naturalSize.height
        )
        
        let scaledWidth = naturalSize.width * scale
        let scaledHeight = naturalSize.height * scale
        let offsetX = (targetSize.width - scaledWidth) / 2
        let offsetY = (targetSize.height - scaledHeight) / 2
        
        var transform = CGAffineTransform.identity
        transform = transform.scaledBy(x: scale, y: scale)
        transform = transform.translatedBy(x: offsetX / scale, y: offsetY / scale)
        
        return transform
    }
    
    private func export(
        composition: AVComposition,
        videoComposition: AVVideoComposition,
        outputURL: URL
    ) async throws -> URL {
        
        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw PIPError.exportSessionCreationFailed
        }
        
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        
        await exporter.export()
        
        switch exporter.status {
        case .completed:
            return outputURL
        case .failed:
            throw exporter.error ?? PIPError.exportFailed
        case .cancelled:
            throw PIPError.exportCancelled
        default:
            throw PIPError.exportFailed
        }
    }
    
    enum PIPError: Error {
        case compositionCreationFailed
        case videoCompositionCreationFailed
        case insufficientTracks
        case exportSessionCreationFailed
        case exportFailed
        case exportCancelled
    }
}
```

### Export Presets

| Preset | Resolution | Use Case |
|--------|-----------|----------|
| `AVAssetExportPresetLowQuality` | Variable | Small file size |
| `AVAssetExportPresetMediumQuality` | Variable | Balance |
| `AVAssetExportPresetHighestQuality` | Original | Best quality |
| `AVAssetExportPreset640x480` | 640x480 | SD |
| `AVAssetExportPreset1280x720` | 1280x720 | HD |
| `AVAssetExportPreset1920x1080` | 1920x1080 | Full HD |
| `AVAssetExportPreset3840x2160` | 3840x2160 | 4K |
| `AVAssetExportPresetHEVC1920x1080` | 1920x1080 | HEVC/H.265 |

---

## App Architecture & Patterns

### Menu Bar App Structure

```swift
import SwiftUI

@main
struct ScreenRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        MenuBarExtra("Screen Recorder", systemImage: "record.circle") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon for menu bar only app
        NSApp.setActivationPolicy(.accessory)
    }
}
```

### Info.plist for Menu Bar App

```xml
<!-- Hide dock icon -->
<key>LSUIElement</key>
<true/>

<!-- Or use LSBackgroundOnly for background apps -->
<key>LSBackgroundOnly</key>
<false/>
```

### Recording Coordinator

```swift
import Combine

@MainActor
class RecordingCoordinator: ObservableObject {
    let cameraManager = CameraManager()
    let screenCaptureManager = ScreenCaptureManager()
    let assetRecorder = AssetRecorder()
    let floatingCameraController = FloatingCameraWindowController()
    
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    
    private var screenURL: URL?
    private var cameraURL: URL?
    private var timer: Timer?
    private var startTime: Date?
    
    func startRecording() async {
        // Check permissions
        guard await checkPermissions() else { return }
        
        // Setup URLs
        let tempDir = FileManager.default.temporaryDirectory
        screenURL = tempDir.appendingPathComponent("screen_\(UUID().uuidString).mov")
        cameraURL = tempDir.appendingPathComponent("camera_\(UUID().uuidString).mov")
        
        // Start camera
        if let camera = AVCaptureDevice.default(for: .video) {
            cameraManager.setupCamera(device: camera)
            cameraManager.start()
            floatingCameraController.show(session: cameraManager.session)
        }
        
        // Start screen capture
        try? await screenCaptureManager.startCapture()
        
        // Setup recording
        if let screenURL = screenURL {
            assetRecorder.startRecording(
                outputURL: screenURL,
                width: 1920,
                height: 1080
            )
        }
        
        // Connect sample buffers to recorder
        screenCaptureManager.onVideoSample = { [weak self] sampleBuffer in
            self?.assetRecorder.appendVideoSampleBuffer(sampleBuffer)
        }
        
        screenCaptureManager.onAudioSample = { [weak self] sampleBuffer in
            self?.assetRecorder.appendAudioSampleBuffer(sampleBuffer)
        }
        
        // Start timer
        startTime = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let startTime = self?.startTime else { return }
            self?.recordingDuration = Date().timeIntervalSince(startTime)
        }
        
        isRecording = true
    }
    
    func stopRecording() async -> URL? {
        timer?.invalidate()
        timer = nil
        
        cameraManager.stop()
        floatingCameraController.hide()
        
        try? await screenCaptureManager.stopCapture()
        
        // Stop recording and get output URL
        var finalURL: URL?
        let semaphore = DispatchSemaphore(value: 0)
        
        assetRecorder.stopRecording {
            semaphore.signal()
        }
        
        semaphore.wait()
        finalURL = screenURL
        
        isRecording = false
        recordingDuration = 0
        
        return finalURL
    }
    
    private func checkPermissions() async -> Bool {
        // Check and request all necessary permissions
        let videoAuthorized = await checkVideoPermission()
        let audioAuthorized = await checkAudioPermission()
        
        return videoAuthorized && audioAuthorized
    }
    
    private func checkVideoPermission() async -> Bool {
        switch CapturePermission.videoStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await CapturePermission.requestVideoAccess()
        default:
            return false
        }
    }
    
    private func checkAudioPermission() async -> Bool {
        switch CapturePermission.audioStatus {
        case .authorized:
            return true
        case .notDetermined:
            return await CapturePermission.requestAudioAccess()
        default:
            return false
        }
    }
}
```

### Control Window (NSPanel)

```swift
import SwiftUI

struct RecordingControlView: View {
    @StateObject private var coordinator = RecordingCoordinator()
    
    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                // Recording button
                Button(action: {
                    Task {
                        if coordinator.isRecording {
                            _ = await coordinator.stopRecording()
                        } else {
                            await coordinator.startRecording()
                        }
                    }
                }) {
                    Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "record.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(coordinator.isRecording ? .red : .red)
                }
                .buttonStyle(.plain)
                
                // Timer display
                if coordinator.isRecording {
                    Text(formatDuration(coordinator.recordingDuration))
                        .font(.system(size: 24, weight: .medium, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            
            // Settings buttons
            HStack(spacing: 16) {
                Button(action: {}) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                
                Button(action: {}) {
                    Image(systemName: "camera")
                }
                .buttonStyle(.borderless)
                
                Button(action: {}) {
                    Image(systemName: "mic")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(24)
        .frame(width: 200)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}

// Usage in NSPanel
func createControlPanel() -> NSPanel {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
        styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
        backing: .buffered,
        defer: false
    )
    
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    
    let contentView = RecordingControlView()
    panel.contentView = NSHostingView(rootView: contentView)
    
    return panel
}
```

### Performance Best Practices

```swift
class PerformanceOptimizer {
    
    // 1. Use serial queues for video processing to maintain frame order
    let videoProcessingQueue = DispatchQueue(
        label: "com.example.video.processing",
        qos: .userInitiated
    )
    
    // 2. Use autorelease pools for frame processing loops
    func processFrames(reader: AVAssetReader) {
        reader.startReading()
        
        while reader.status == .reading {
            autoreleasepool {
                // Process frames here
                // Memory is released after each iteration
            }
        }
    }
    
    // 3. Efficient pixel buffer handling
    func createPixelBufferAdaptor(for input: AVAssetWriterInput) -> AVAssetWriterInputPixelBufferAdaptor {
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        return AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: attributes
        )
    }
    
    // 4. Memory pressure monitoring
    func setupMemoryPressureMonitoring() {
        DispatchQueue.main.async {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.handleMemoryPressure),
                name: NSNotification.Name("NSProcessInfoMemoryPressureNotification"),
                object: nil
            )
        }
    }
    
    @objc private func handleMemoryPressure() {
        // Reduce quality or free resources
    }
}
```

---

## Screen Studio Feature Analysis

### Core Features

| Feature | Description | Implementation Approach |
|---------|-------------|------------------------|
| **Screen Recording** | Full display, window, or area | ScreenCaptureKit |
| **Webcam Overlay** | Picture-in-picture camera | AVFoundation + PIP composition |
| **Microphone Audio** | Voice recording | AVCaptureDevice |
| **System Audio** | App/system sounds | ScreenCaptureKit (macOS 13+) |
| **Automatic Zoom** | Zoom on clicks | Post-processing with transforms |
| **Motion Blur** | Smooth animations | Frame interpolation during export |
| **Cursor Smoothing** | Gliding cursor movement | Track position, apply Bezier curves |
| **Backgrounds** | Custom styling | Layer composition |
| **AI Captions** | Speech-to-text | Whisper API or Apple Speech |
| **Keyboard Shortcuts** | Visual key display | Event monitoring + overlay |

### Unique Differentiators

1. **Opinionated Design** - Makes professional-looking decisions automatically
2. **Zero-Edit Workflow** - Professional results without complex editing
3. **Automatic Polish** - Motion blur, smooth animations, zooms are automatic
4. **Native Performance** - Built for macOS using native frameworks

### File Format

- Projects saved as `.screenstudio` files
- Contains raw assets + metadata
- Can be large (40GB+ for long recordings)

---

## Implementation Roadmap

### Phase 1: MVP (Core Recording)

- [ ] Screen recording with ScreenCaptureKit
- [ ] Camera recording with AVFoundation
- [ ] Microphone audio capture
- [ ] Basic file saving
- [ ] Menu bar app UI

### Phase 2: Enhanced Recording

- [ ] System audio capture
- [ ] Floating camera window (PIP UI)
- [ ] Recording controls (pause/resume)
- [ ] Quality settings
- [ ] Screen selection (display/window/area)

### Phase 3: Post-Processing

- [ ] Basic timeline editor
- [ ] PIP composition (screen + camera)
- [ ] Trimming/cutting
- [ ] Export presets
- [ ] Background options

### Phase 4: Advanced Features

- [ ] Automatic zoom on clicks
- [ ] Cursor smoothing
- [ ] Motion blur effects
- [ ] Keyboard shortcut display
- [ ] AI captions (Whisper)

### Phase 5: Polish

- [ ] Project file format
- [ ] Cloud sharing
- [ ] Preset system
- [ ] Performance optimization
- [ ] Advanced editing

---

## References

### Apple Documentation

- [ScreenCaptureKit Documentation](https://developer.apple.com/documentation/ScreenCaptureKit)
- [AVFoundation Programming Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/)
- [WWDC 2022: Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [WWDC 2022: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [WWDC 2023: What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)

### Open Source References

- **CapturePlus** - Open source macOS screen recorder
- **Screen Studio** - Commercial reference app

---

## Quick Start Template

```swift
// Minimal screen recorder implementation

import SwiftUI
import ScreenCaptureKit
import AVFoundation

@main
struct ScreenRecorderApp: App {
    var body: some Scene {
        MenuBarExtra("Recorder", systemImage: "record.circle") {
            RecordingView()
        }
        .menuBarExtraStyle(.window)
    }
}

struct RecordingView: View {
    @StateObject private var recorder = SimpleRecorder()
    
    var body: some View {
        VStack {
            Button(recorder.isRecording ? "Stop" : "Record") {
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        await recorder.start()
                    }
                }
            }
            .padding()
        }
    }
}

@MainActor
class SimpleRecorder: ObservableObject {
    @Published var isRecording = false
    
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    
    func start() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return }
            
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            
            let config = SCStreamConfiguration()
            config.width = Int(display.width) * 2
            config.height = Int(display.height) * 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("recording.mov")
            
            writer = try AVAssetWriter(url: url, fileType: .mov)
            
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: config.width,
                AVVideoHeightKey: config.height
            ]
            
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput?.expectsMediaDataInRealTime = true
            
            if let input = videoInput, writer?.canAdd(input) == true {
                writer?.add(input)
            }
            
            writer?.startWriting()
            
            stream = SCStream(filter: filter, configuration: config, delegate: nil)
            
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global())
            try await stream?.startCapture()
            
            isRecording = true
            
        } catch {
            print("Error: \(error)")
        }
    }
    
    func stop() async {
        try? await stream?.stopCapture()
        videoInput?.markAsFinished()
        await writer?.finishWriting()
        isRecording = false
    }
}

extension SimpleRecorder: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        
        Task { @MainActor in
            if writer?.status == .writing {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                if writer?.startSession(atSourceTime: timestamp) == true {
                    // Session started
                }
                
                if videoInput?.isReadyForMoreMediaData == true {
                    videoInput?.append(sampleBuffer)
                }
            }
        }
    }
}
```

---

*This document serves as a comprehensive reference for building native macOS screen recording applications. Last updated: April 2026*
