# macOS Screen Recording App Architecture Patterns

## Research Report

This document provides comprehensive technical information on macOS app architecture patterns for screen recording apps, covering all critical aspects from app lifecycle to memory management and sandboxing.

---

## 1. App Lifecycle and Background Recording

### 1.1 Application Lifecycle Architecture

macOS applications use the `NSApplication` and `NSApplicationDelegate` protocols to manage lifecycle events:

**Key Lifecycle Methods:**

```swift
// AppDelegate.swift
class AppDelegate: NSObject, NSApplicationDelegate {
    
    // Called when the app finishes launching
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize screen recording components
        setupScreenRecording()
    }
    
    // Called when app is about to become active
    func applicationWillBecomeActive(_ notification: Notification) {
        // Resume UI updates
    }
    
    // Called when app is about to resign active
    func applicationWillResignActive(_ notification: Notification) {
        // Continue recording if needed
    }
    
    // Called before app terminates
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Check if recording is in progress
        if RecordingManager.shared.isRecording {
            // Prompt user or auto-save
            return .terminateLater
        }
        return .terminateNow
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        // Cleanup resources
    }
}
```

### 1.2 Background Recording Strategy

Screen recording on macOS requires special handling since macOS apps don't use traditional "background modes" like iOS:

**Background Recording Approaches:**

1. **Agent Application Model (UIElement)**
   - Set `LSUIElement` to `YES` in Info.plist
   - App runs without dock icon or menu bar
   - Recording continues without user interaction
   - Best for menu bar-style recording apps

2. **Preventing App Nap**
   ```swift
   // Prevent system from throttling the app
   let activity = NSActivityOptions.userInitiatedAllowingIdleSystemSleep
   ProcessInfo.processInfo.performActivity(options: activity, reason: "Screen Recording") {
       // Recording code here
   }
   ```

3. **Power Assertion Management**
   ```swift
   import IOKit.pwr_mgt
   
   var assertionID: IOPMAssertionID = 0
   
   func preventSystemSleep() {
       IOPMAssertionCreateWithName(
           kIOPMAssertionTypeNoIdleSleep as CFString,
           IOPMAssertionLevel(kIOPMAssertionLevelOn),
           "Screen Recording in Progress" as CFString,
           &assertionID
       )
   }
   
   func allowSystemSleep() {
       IOPMAssertionRelease(assertionID)
   }
   ```

### 1.3 State Restoration and Persistence

```swift
class RecordingManager: NSObject {
    static let shared = RecordingManager()
    
    private let stateKey = "RecordingState"
    
    func saveRecordingState() {
        let state: [String: Any] = [
            "isRecording": isRecording,
            "startTime": recordingStartTime ?? Date(),
            "outputPath": currentOutputPath ?? ""
        ]
        UserDefaults.standard.set(state, forKey: stateKey)
    }
    
    func restoreRecordingState() -> RecordingState? {
        guard let state = UserDefaults.standard.dictionary(forKey: stateKey) else {
            return nil
        }
        // Restore state after app relaunch
        return RecordingState(from: state)
    }
}
```

---

## 2. Menu Bar Extra (Status Bar) App Setup

### 2.1 Traditional AppKit Approach

```swift
import Cocoa

class StatusBarManager: NSObject {
    static let shared = StatusBarManager()
    
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    
    override init() {
        super.init()
        setupStatusItem()
        setupPopover()
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            button.image = NSImage(named: "recording-icon")
            button.image?.isTemplate = true  // Makes icon follow system theme
            button.action = #selector(togglePopover)
            button.target = self
        }
    }
    
    private func setupPopover() {
        popover = NSPopover()
        popover?.behavior = .transient  // Closes when clicking outside
        popover?.contentViewController = RecordingControlsViewController()
    }
    
    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            popover?.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
```

### 2.2 Modern SwiftUI Approach (macOS 13+)

```swift
import SwiftUI

@main
struct ScreenRecorderApp: App {
    @State private var isRecording = false
    
    var body: some Scene {
        // Remove WindowGroup for pure menu bar app
        MenuBarExtra("Screen Recorder", systemImage: isRecording ? "record.circle.fill" : "record.circle") {
            RecordingMenuView(isRecording: $isRecording)
        }
    }
}

struct RecordingMenuView: View {
    @Binding var isRecording: Bool
    
    var body: some View {
        Button(isRecording ? "Stop Recording" : "Start Recording") {
            isRecording.toggle()
        }
        .keyboardShortcut("r")
        
        Divider()
        
        Button("Preferences...") {
            openPreferences()
        }
        .keyboardShortcut(",")
        
        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
    
    private func openPreferences() {
        // Open preferences window
    }
}
```

### 2.3 Info.plist Configuration for Menu Bar Apps

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0">
<dict>
    <!-- Hide dock icon - makes app an agent -->
    <key>LSUIElement</key>
    <true/>
    
    <!-- Background execution support -->
    <key>UIBackgroundModes</key>
    <array>
        <string>continuous</string>
    </array>
    
    <!-- Required for screen recording -->
    <key>NSCameraUsageDescription</key>
    <string>This app needs access to camera for recording.</string>
    
    <key>NSMicrophoneUsageDescription</key>
    <string>This app needs access to microphone for audio recording.</string>
</dict>
</plist>
```

---

## 3. Window Management for Recording Controls

### 3.1 Recording Control Window Architecture

```swift
import Cocoa

class RecordingControlsWindowController: NSWindowController {
    
    convenience init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating  // Keep above other windows
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.init(window: window)
        setupUI()
    }
    
    private func setupUI() {
        // Add recording controls
        let contentView = NSView()
        window?.contentView = contentView
        
        // Add visual effect background
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 12
        contentView.addSubview(visualEffectView)
    }
    
    func showAtMouseLocation() {
        let mouseLoc = NSEvent.mouseLocation
        window?.setFrameOrigin(NSPoint(
            x: mouseLoc.x - (window?.frame.width ?? 0) / 2,
            y: mouseLoc.y
        ))
        window?.makeKeyAndOrderFront(nil)
    }
}
```

### 3.2 Floating Control Panel

```swift
class FloatingControlPanel: NSPanel {
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 60),
            styleMask: [.borderless, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        
        // Configure as floating HUD
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.level = .floating
        
        // Allow showing on all spaces
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Transparent background with blur
        self.isOpaque = false
        self.backgroundColor = .clear
        
        setupControls()
    }
    
    private func setupControls() {
        let visualEffect = NSVisualEffectView(frame: contentView?.bounds ?? .zero)
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        contentView?.addSubview(visualEffect)
        
        // Add record button, timer, stop button
        // ...
    }
}
```

### 3.3 Window Positioning Strategy

```swift
class WindowPositionManager {
    
    static func positionWindow(_ window: NSWindow, on screen: NSScreen, position: WindowPosition) {
        guard let screenFrame = screen.visibleFrame else { return }
        
        let windowSize = window.frame.size
        var origin = NSPoint.zero
        
        switch position {
        case .topLeft:
            origin = NSPoint(x: screenFrame.minX + 20, y: screenFrame.maxY - windowSize.height - 20)
        case .topRight:
            origin = NSPoint(x: screenFrame.maxX - windowSize.width - 20, y: screenFrame.maxY - windowSize.height - 20)
        case .topCenter:
            origin = NSPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.maxY - windowSize.height - 20)
        case .center:
            origin = NSPoint(x: screenFrame.midX - windowSize.width / 2, y: screenFrame.midY - windowSize.height / 2)
        }
        
        window.setFrameOrigin(origin)
    }
}

enum WindowPosition {
    case topLeft, topRight, topCenter, center
}
```

---

## 4. Sandboxing and Entitlements for Screen Recording

### 4.1 Required Entitlements

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN">
<plist version="1.0">
<dict>
    <!-- App Sandbox - Required for Mac App Store -->
    <key>com.apple.security.app-sandbox</key>
    <true/>
    
    <!-- Screen Recording Capability (macOS 10.15+) -->
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    
    <!-- Allow screen capture -->
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    
    <!-- Outgoing network connections (for streaming) -->
    <key>com.apple.security.network.client</key>
    <true/>
    
    <!-- File access for saving recordings -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    
    <!-- Downloads folder access -->
    <key>com.apple.security.files.downloads.read-write</key>
    <true/>
    
    <!-- If saving to Movies folder -->
    <key>com.apple.security.assets.movies.read-write</key>
    <true/>
    
    <!-- Camera access -->
    <key>com.apple.security.device.camera</key>
    <true/>
    
    <!-- Microphone access -->
    <key>com.apple.security.device.microphone</key>
    <true/>
    
    <!-- Temporary exception for ScreenCaptureKit -->
    <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
    <array>
        <string>com.apple.screencapturekit</string>
    </array>
</dict>
</plist>
```

### 4.2 Screen Recording Permission Handling

```swift
import ScreenCaptureKit

class PermissionManager {
    
    static func checkScreenRecordingPermission() -> Bool {
        // On macOS 10.15+, check for screen recording permission
        if #available(macOS 10.15, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }
    
    static func requestScreenRecordingPermission() {
        if #available(macOS 10.15, *) {
            CGRequestScreenCaptureAccess()
        }
    }
    
    // Alternative using ScreenCaptureKit (macOS 12.3+)
    @available(macOS 12.3, *)
    static func checkPermissionWithScreenCaptureKit() async throws -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }
}
```

### 4.3 Privacy Descriptions in Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to include your camera in recordings.</string>

<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record audio.</string>

<key>NSScreenRecordingUsageDescription</key>
<string>This app needs to record your screen to capture video content.</string>

<key>NSAccessibilityUsageDescription</key>
<string>This app needs accessibility access to detect window positions.</string>
```

### 4.4 Sandboxing Limitations and Workarounds

**Key Limitations:**
1. Cannot capture other app's audio without special entitlements
2. Cannot write to arbitrary file paths - must use user-selected locations or standard directories
3. Cannot access all system APIs while sandboxed

**Workarounds:**
- Use Security-Scoped Bookmarks for persistent file access
- Use `NSOpenPanel`/`NSSavePanel` for user-selected directories
- Store recordings in Movies or Downloads folders

```swift
class FileAccessManager {
    
    // Request persistent access to a directory
    static func requestDirectoryAccess() {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.allowsMultipleSelection = false
        openPanel.prompt = "Select Save Location"
        
        openPanel.begin { result in
            if result == .OK, let url = openPanel.url {
                // Create security-scoped bookmark
                do {
                    let bookmarkData = try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    UserDefaults.standard.set(bookmarkData, forKey: "saveLocationBookmark")
                } catch {
                    print("Failed to create bookmark: \(error)")
                }
            }
        }
    }
    
    // Access directory using bookmark
    static func accessSavedDirectory() -> URL? {
        guard let bookmarkData = UserDefaults.standard.data(forKey: "saveLocationBookmark") else {
            return nil
        }
        
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            
            if isStale {
                // Renew bookmark if stale
                let newBookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(newBookmark, forKey: "saveLocationBookmark")
            }
            
            // Start accessing the resource
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}
```

---

## 5. Efficient Memory Management for Long Recording Sessions

### 5.1 Memory Management Strategy

```swift
import Foundation

class MemoryEfficientRecorder {
    
    // Use autorelease pools for tight loops
    func processFrames(_ frames: [CMSampleBuffer]) {
        for frame in frames {
            autoreleasepool {
                // Process frame within autorelease pool
                processFrame(frame)
            }
        }
    }
    
    // Weak references to avoid retain cycles
    weak var delegate: RecordingDelegate?
    
    // Use structs for value types where possible
    struct FrameMetadata {
        let timestamp: CMTime
        let size: CGSize
        let scale: CGFloat
    }
}
```

### 5.2 Streaming and Buffer Management

```swift
class BufferManager {
    
    // Use circular buffer for efficient memory reuse
    private var bufferPool: [CVPixelBuffer] = []
    private let maxBufferCount = 5
    private let bufferLock = NSLock()
    
    func acquireBuffer() -> CVPixelBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if let buffer = bufferPool.popLast() {
            return buffer
        }
        return createNewBuffer()
    }
    
    func releaseBuffer(_ buffer: CVPixelBuffer) {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        if bufferPool.count < maxBufferCount {
            bufferPool.append(buffer)
        }
        // Otherwise, let it be deallocated
    }
    
    private func createNewBuffer() -> CVPixelBuffer? {
        // Create pixel buffer
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            1920,
            1080,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        return pixelBuffer
    }
}
```

### 5.3 Efficient Video Writing

```swift
import AVFoundation

class EfficientVideoWriter {
    
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private let writingQueue = DispatchQueue(label: "com.app.video-writing")
    
    func setupWriter(outputURL: URL, width: Int, height: Int) throws {
        assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5000000, // 5 Mbps
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput?.expectsMediaDataInRealTime = true
        
        if let input = videoInput {
            assetWriter?.add(input)
        }
    }
    
    func writeSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        writingQueue.async { [weak self] in
            guard let self = self,
                  let input = self.videoInput,
                  input.isReadyForMoreMediaData else {
                return
            }
            
            autoreleasepool {
                input.append(sampleBuffer)
            }
        }
    }
    
    // Periodic flushing for long recordings
    func periodicFlush() {
        writingQueue.async { [weak self] in
            // Force write to disk periodically
            self?.videoInput?.markAsFinished()
            // Create new segment if needed
        }
    }
}
```

### 5.4 Memory Warning Handling

```swift
class MemoryMonitor {
    
    init() {
        // Register for memory pressure notifications
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .all)
        source.setEventHandler { [weak self] in
            let event = source.data
            self?.handleMemoryPressure(event)
        }
        source.resume()
    }
    
    private func handleMemoryPressure(_ event: DispatchSource.MemoryPressureEvent) {
        switch event {
        case .normal:
            break
        case .warning:
            // Reduce quality, clear caches
            RecordingManager.shared.reduceQuality()
            clearCaches()
        case .critical:
            // Pause recording if possible
            RecordingManager.shared.pauseRecording()
            NotificationCenter.default.post(name: .recordingPausedDueToMemory, object: nil)
        default:
            break
        }
    }
    
    private func clearCaches() {
        // Clear any in-memory caches
        URLCache.shared.removeAllCachedResponses()
        // Flush buffers
    }
}

extension Notification.Name {
    static let recordingPausedDueToMemory = Notification.Name("recordingPausedDueToMemory")
}
```

### 5.5 Best Practices for Long Sessions

```swift
class RecordingOptimization {
    
    // 1. Use appropriate bitrates for long recordings
    static func recommendedSettings(for duration: TimeInterval) -> [String: Any] {
        if duration > 3600 { // > 1 hour
            return [
                AVVideoCodecKey: AVVideoCodecType.hevc, // More efficient
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3000000 // Lower bitrate
                ]
            ]
        } else {
            return [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 1920,
                AVVideoHeightKey: 1080,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 6000000
                ]
            ]
        }
    }
    
    // 2. Segment long recordings
    static func segmentRecording(after duration: TimeInterval) -> Bool {
        return duration > 3600 // Create new file every hour
    }
    
    // 3. Monitor file size
    static func checkDiskSpace() -> Bool {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let available = values.volumeAvailableCapacity {
                // Require at least 1GB free
                return available > 1_000_000_000
            }
        } catch {
            print("Error checking disk space: \(error)")
        }
        return false
    }
}
```

---

## 6. Handling App Termination During Recording

### 6.1 Preventing Accidental Termination

```swift
class TerminationManager: NSObject {
    
    static let shared = TerminationManager()
    
    func preventTermination() {
        // Disable sudden termination
        ProcessInfo.processInfo.disableSuddenTermination()
        
        // Disable automatic termination
        NSApplication.shared.disableRelaunchOnLogin()
    }
    
    func allowTermination() {
        ProcessInfo.processInfo.enableSuddenTermination()
    }
}
```

### 6.2 Graceful Shutdown Handler

```swift
class RecordingTerminationHandler {
    
    private var terminationTask: Task<Void, Never>?
    
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard RecordingManager.shared.isRecording else {
            return .terminateNow
        }
        
        // Show alert asking user what to do
        let alert = NSAlert()
        alert.messageText = "Recording in Progress"
        alert.informativeText = "You have an active recording. What would you like to do?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop & Save")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Stop and save
            terminationTask = Task {
                await RecordingManager.shared.stopAndSave()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        
        return .terminateCancel
    }
}
```

### 6.3 Auto-Save on Crash/Force Quit

```swift
class CrashRecoveryManager {
    
    private let recoveryPath: URL
    
    init() {
        recoveryPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("recording_recovery")
        
        setupSignalHandlers()
    }
    
    private func setupSignalHandlers() {
        // Handle common termination signals
        signal(SIGTERM) { _ in
            CrashRecoveryManager.shared.emergencySave()
            exit(0)
        }
        
        signal(SIGINT) { _ in
            CrashRecoveryManager.shared.emergencySave()
            exit(0)
        }
    }
    
    func emergencySave() {
        // Quick save current recording state
        if RecordingManager.shared.isRecording {
            RecordingManager.shared.emergencyStop()
        }
    }
    
    func checkForRecovery() {
        // Check if there's a recording to recover from previous session
        let recoveryFile = recoveryPath.appendingPathComponent("last_recording.plist")
        if FileManager.default.fileExists(atPath: recoveryFile.path) {
            // Offer to recover
            showRecoveryDialog()
        }
    }
    
    private func showRecoveryDialog() {
        let alert = NSAlert()
        alert.messageText = "Recover Recording?"
        alert.informativeText = "A recording from your previous session can be recovered."
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Discard")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            performRecovery()
        }
    }
    
    private func performRecovery() {
        // Implement recovery logic
    }
    
    static let shared = CrashRecoveryManager()
}
```

### 6.4 State Persistence

```swift
class RecordingStatePersistence {
    
    private let stateURL: URL
    
    init() {
        stateURL = FileManager.default.applicationSupportDirectory
            .appendingPathComponent("recording_state.json")
    }
    
    func saveState(_ state: RecordingState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: stateURL)
        } catch {
            print("Failed to save state: \(error)")
        }
    }
    
    func loadState() -> RecordingState? {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return nil
        }
        
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try JSONDecoder().decode(RecordingState.self, from: data)
            return state
        } catch {
            print("Failed to load state: \(error)")
            return nil
        }
    }
    
    func clearState() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}

struct RecordingState: Codable {
    let isRecording: Bool
    let startTime: Date
    let outputPath: String
    let duration: TimeInterval
    let settings: RecordingSettings
}
```

---

## 7. Best Practices for macOS App Structure

### 7.1 Recommended Project Architecture

```
ScreenRecorderApp/
├── App/
│   ├── AppDelegate.swift          # App lifecycle
│   ├── ScreenRecorderApp.swift    # SwiftUI app entry (if using SwiftUI)
│   └── Info.plist
├── Core/
│   ├── Recording/
│   │   ├── RecordingManager.swift     # Main recording coordinator
│   │   ├── ScreenCaptureManager.swift # ScreenCaptureKit wrapper
│   │   ├── VideoWriter.swift          # AVAssetWriter management
│   │   └── AudioRecorder.swift        # Audio capture
│   ├── Models/
│   │   ├── RecordingSettings.swift
│   │   ├── RecordingSession.swift
│   │   └── VideoFormat.swift
│   └── Services/
│       ├── FileManager.swift
│       ├── PermissionManager.swift
│       └── MemoryMonitor.swift
├── UI/
│   ├── StatusBar/
│   │   ├── StatusBarManager.swift
│   │   └── MenuBuilder.swift
│   ├── Windows/
│   │   ├── RecordingControlsWindow.swift
│   │   ├── PreferencesWindow.swift
│   │   └── PreviewWindow.swift
│   └── Views/
│       ├── RecordingControlsView.swift
│       ├── SettingsView.swift
│       └── PreviewView.swift
├── Utilities/
│   ├── Extensions/
│   ├── Helpers/
│   └── Constants.swift
└── Resources/
    ├── Assets.xcassets
    └── Localizable.strings
```

### 7.2 Dependency Injection Pattern

```swift
// Dependency Container
class AppContainer {
    static let shared = AppContainer()
    
    lazy var recordingManager: RecordingManager = {
        return RecordingManager(
            screenCapture: screenCaptureManager,
            videoWriter: videoWriter,
            settings: recordingSettings
        )
    }()
    
    lazy var screenCaptureManager: ScreenCaptureManager = {
        return ScreenCaptureManager()
    }()
    
    lazy var videoWriter: VideoWriter = {
        return VideoWriter()
    }()
    
    lazy var recordingSettings: RecordingSettings = {
        return RecordingSettings.loadFromUserDefaults()
    }()
}

// Usage
class RecordingViewModel: ObservableObject {
    private let recordingManager: RecordingManager
    
    init(recordingManager: RecordingManager = AppContainer.shared.recordingManager) {
        self.recordingManager = recordingManager
    }
}
```

### 7.3 Configuration Management

```swift
struct AppConfiguration {
    
    // Recording settings
    struct Recording {
        static let defaultFPS: Int = 30
        static let defaultQuality: VideoQuality = .high
        static let maxRecordingDuration: TimeInterval = 3600 * 4 // 4 hours
        static let autoSegmentDuration: TimeInterval = 3600 // 1 hour
        
        enum VideoQuality {
            case low, medium, high, ultra
            
            var bitrate: Int {
                switch self {
                case .low: return 2000000    // 2 Mbps
                case .medium: return 4000000 // 4 Mbps
                case .high: return 8000000   // 8 Mbps
                case .ultra: return 15000000 // 15 Mbps
                }
            }
            
            var resolution: CGSize {
                switch self {
                case .low: return CGSize(width: 1280, height: 720)
                case .medium: return CGSize(width: 1920, height: 1080)
                case .high: return CGSize(width: 2560, height: 1440)
                case .ultra: return CGSize(width: 3840, height: 2160)
                }
            }
        }
    }
    
    // UI settings
    struct UI {
        static let controlPanelHeight: CGFloat = 60
        static let controlPanelWidth: CGFloat = 400
        static let previewUpdateInterval: TimeInterval = 0.1
    }
    
    // File management
    struct FileManagement {
        static let defaultOutputFormat = "mp4"
        static let maxFileSize: UInt64 = 10_000_000_000 // 10 GB
        static let autoDeleteAfterDays: Int = 30
    }
}
```

### 7.4 Error Handling Strategy

```swift
enum RecordingError: Error {
    case permissionDenied
    case screenCaptureFailed
    case diskSpaceInsufficient
    case encodingFailed
    case fileWriteError
    case memoryPressure
    
    var localizedDescription: String {
        switch self {
        case .permissionDenied:
            return "Screen recording permission was denied. Please enable it in System Preferences."
        case .screenCaptureFailed:
            return "Failed to capture screen content."
        case .diskSpaceInsufficient:
            return "Not enough disk space to continue recording."
        case .encodingFailed:
            return "Video encoding failed."
        case .fileWriteError:
            return "Failed to write recording to file."
        case .memoryPressure:
            return "System is low on memory. Recording has been paused."
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .permissionDenied:
            return "Open System Preferences > Security & Privacy > Screen Recording and enable this app."
        case .diskSpaceInsufficient:
            return "Free up disk space or change the save location."
        default:
            return nil
        }
    }
}

class ErrorHandler {
    
    static func handle(_ error: RecordingError) {
        // Log error
        Logger.shared.error("\(error.localizedDescription)")
        
        // Show user alert
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Recording Error"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            
            if let suggestion = error.recoverySuggestion {
                alert.messageText = suggestion
            }
            
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
```

### 7.5 Testing Strategy

```swift
import XCTest
@testable import ScreenRecorder

class RecordingManagerTests: XCTestCase {
    
    var recordingManager: RecordingManager!
    var mockScreenCapture: MockScreenCaptureManager!
    
    override func setUp() {
        super.setUp()
        mockScreenCapture = MockScreenCaptureManager()
        recordingManager = RecordingManager(
            screenCapture: mockScreenCapture,
            videoWriter: MockVideoWriter(),
            settings: RecordingSettings()
        )
    }
    
    func testStartRecording() {
        // Given
        XCTAssertFalse(recordingManager.isRecording)
        
        // When
        recordingManager.startRecording()
        
        // Then
        XCTAssertTrue(recordingManager.isRecording)
        XCTAssertTrue(mockScreenCapture.startCaptureCalled)
    }
    
    func testStopRecording() {
        // Given
        recordingManager.startRecording()
        
        // When
        recordingManager.stopRecording()
        
        // Then
        XCTAssertFalse(recordingManager.isRecording)
        XCTAssertTrue(mockScreenCapture.stopCaptureCalled)
    }
    
    func testMemoryPressureHandling() {
        // Given
        recordingManager.startRecording()
        
        // When
        recordingManager.handleMemoryPressure(.warning)
        
        // Then
        XCTAssertEqual(recordingManager.currentQuality, .reduced)
    }
}
```

### 7.6 Logging and Analytics

```swift
import OSLog

class Logger {
    static let shared = Logger()
    
    private let logger = os.Logger(subsystem: "com.yourapp.screenrecorder", category: "Recording")
    
    func info(_ message: String) {
        logger.info("\(message)")
    }
    
    func debug(_ message: String) {
        logger.debug("\(message)")
    }
    
    func error(_ message: String) {
        logger.error("\(message)")
    }
    
    func logRecordingEvent(_ event: RecordingEvent) {
        switch event {
        case .started:
            info("Recording started")
        case .stopped(let duration):
            info("Recording stopped. Duration: \(duration)s")
        case .paused:
            info("Recording paused")
        case .resumed:
            info("Recording resumed")
        case .error(let error):
            error("Recording error: \(error.localizedDescription)")
        }
    }
}

enum RecordingEvent {
    case started
    case stopped(duration: TimeInterval)
    case paused
    case resumed
    case error(RecordingError)
}
```

---

## Summary

### Key Takeaways

1. **App Lifecycle**: Use agent application model (`LSUIElement`) for menu bar recording apps, implement proper lifecycle handlers for graceful recording management.

2. **Menu Bar Setup**: Use `NSStatusBar` for traditional AppKit apps or `MenuBarExtra` for SwiftUI apps (macOS 13+).

3. **Window Management**: Use `NSPanel` with appropriate level and collection behavior for floating control panels that work across spaces.

4. **Sandboxing**: Request screen recording permission, use security-scoped bookmarks for file access, handle entitlements properly for Mac App Store.

5. **Memory Management**: Use autorelease pools, buffer pooling, efficient video encoding settings, and monitor memory pressure to prevent crashes during long recordings.

6. **Termination Handling**: Prevent sudden termination during recording, implement graceful shutdown with user prompts, save state for crash recovery.

7. **Architecture**: Use clear separation of concerns (Recording, UI, Core), dependency injection for testability, and comprehensive error handling.

### Recommended Tech Stack

- **Screen Capture**: ScreenCaptureKit (macOS 12.3+) or AVFoundation for older versions
- **Video Encoding**: AVAssetWriter with H.264/HEVC
- **Audio Capture**: ScreenCaptureKit audio capture or AVCaptureSession
- **UI**: SwiftUI for new projects, AppKit for complex custom interfaces
- **Storage**: Security-scoped bookmarks with user-selected directories
- **State Management**: Combine framework or custom observable objects

---

## References

- Apple Documentation: ScreenCaptureKit
- WWDC 2022: "Meet ScreenCaptureKit" (Session 10156)
- WWDC 2022: "Take ScreenCaptureKit to the next level" (Session 10155)
- Apple Documentation: NSStatusBar
- Apple Documentation: App Sandbox Design Guide
- Hacking with Swift: macOS Menu Bar Apps
