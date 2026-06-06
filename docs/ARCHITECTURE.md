# SmoothyREC — Architecture

This document explains **how SmoothyREC works internally** and the reasoning
behind the key decisions. For the product story ("why it exists") and install
instructions, see the [README](../README.md).

---

## The one idea everything serves

> **Hand the editor separate files, perfectly in sync — never one baked-in MP4.**

Almost every non-obvious choice in this codebase falls out of that single
constraint:

- Three **independent** capture engines instead of one combined stream → so each
  source becomes its own editable file.
- A **shared clock** read once at the start → so those independent files line up
  on a timeline without drifting.
- One **per-recording folder** resolved up front → so the three files always
  travel together and never collide.
- Screen treated as **primary**, mic/camera as **optional** → so a webcam or mic
  hiccup degrades to a warning instead of losing the whole take.

---

## Process & UI shape

SmoothyREC is a single-process AppKit/SwiftUI menu-bar app.

- **`@main SmoothyRECApp`** uses `@NSApplicationDelegateAdaptor` to bring up an
  `AppDelegate` (`NSApplicationDelegate`).
- **`LSUIElement = true`** in `Info.plist` makes it an *accessory* app: it lives
  in the menu bar via `NSStatusItem` ([`AppDelegate+StatusBar.swift`](../SmoothyREC/AppDelegate+StatusBar.swift))
  with no dock icon and no default window.
- SwiftUI views (`MainWindowView`, `SettingsView`, `OnboardingView`,
  `RecordingStatusView`, `CompletionView`, overlays) are presented from the
  delegate as needed. The menu-bar popover is the primary surface.

---

## The recording session, end to end

### 1. Configuration

The UI builds a `RecordingSessionConfiguration` (see
[`RecordingCoordinator.swift`](../SmoothyREC/RecordingCoordinator.swift)):

```swift
struct RecordingSessionConfiguration {
    let videoName: String
    let recordTarget: ScreenRecordTarget   // .fullScreen | .window | .area
    let includeSystemAudio: Bool
    let captureCursor: Bool
    let selectedMicrophone: Microphone?     // nil ⇒ no mic track
    let selectedCamera: Camera?             // nil ⇒ no camera track
    let quality: RecordingQuality           // .low/.medium/.high/.ultra
    let frameRate: FrameRate                // .fps24/.fps30/.fps60
    let countdownSeconds: Int
}
```

`nil` mic/camera simply means that track isn't recorded — the coordinator only
starts the recorders you've configured.

### 2. Start — `RecordingCoordinator.start(configuration:)`

1. Move to `.preparing`, reset per-session result URLs and error map.
2. Grab the **shared clock**:
   ```swift
   syncClock = CMClockGetHostTimeClock()
   let syncTime = CMClockGetTime(syncClock)   // one timestamp for the whole session
   ```
3. Resolve **one** output directory for the whole session:
   ```swift
   let dir = RecordingOutputFileResolver.uniqueRecordingDirectory(
       videoName: configuration.videoName, in: baseOutputFolder)
   // "Client Walkthrough/", then "Client Walkthrough 2/", "… 3/" for repeats
   ```
4. Start the **screen recorder first** (it's primary). If it throws, the whole
   `start` throws and the others never begin.
5. Start mic + camera **concurrently** in a `withTaskGroup`. Each is wrapped so a
   throw is captured into `recorderErrors[.microphone]` / `[.camera]` rather than
   propagated — an optional-track failure must not abort the session.
6. On success: move to `.recording(startTime:)` and start a duration timer.

```
start()
 ├─ CMClockGetHostTimeClock() → syncTime          (shared reference)
 ├─ uniqueRecordingDirectory()  → sessionDir       (shared folder)
 ├─ screenRecorder.startRecording(...)  ← MUST succeed
 └─ TaskGroup:
     ├─ micRecorder.startRecording(...)    ← failure ⇒ warning
     └─ cameraRecorder.startRecording(syncTime:) ← failure ⇒ warning
```

### 3. While recording

- A `Timer` ticks the published `currentDuration` for the UI.
- Each recorder publishes its own `state`; the coordinator mirrors them
  (`screenRecorderState`, `micRecorderState`, `cameraRecorderState`) via Combine
  `sink`s so SwiftUI can show per-source status.
- If the **primary** screen recorder fails mid-session
  (`handlePrimaryRecorderStateChange`), the coordinator fails the session and
  discards the optional recorders.

### 4. Pause / resume

`pause()` and `resume()` fan out to all three recorders. `resume()` recomputes the
start time as `Date().addingTimeInterval(-pausedDuration)` so the on-screen
duration continues seamlessly across the paused window. `stop()` resumes first if
paused, so every writer flushes cleanly.

### 5. Stop — `RecordingCoordinator.stop()`

1. Move to `.stopping`.
2. `stopAllRecordersAndCollectResults()` stops the three recorders **concurrently**
   in a `TaskGroup`, each returning `(component, URL?)`.
3. Assemble a `RecordingResult` with the screen / mic / camera URLs, duration, and
   any non-fatal `RecordingWarning`s (derived from `recorderErrors`, excluding
   screen).
4. If the screen URL is missing, the session is a hard failure; otherwise it's a
   success that may carry warnings.

```swift
struct RecordingResult {
    let screenRecordingURL: URL?
    let microphoneRecordingURL: URL?
    let cameraRecordingURL: URL?
    let duration: TimeInterval
    let warnings: [RecordingWarning]   // e.g. "Camera: device in use"
    var isComplete: Bool { screenRecordingURL != nil }
}
```

---

## Screen capture in depth ([`ScreenRecorder.swift`](../SmoothyREC/ScreenRecorder.swift))

### Two code paths, picked by OS

```swift
private var supportsNativeRecordingOutput: Bool {
    if #available(macOS 15.0, *) { return true }   // SCRecordingOutput
    return false                                    // manual AVAssetWriter
}
```

**macOS 15+ — native `SCRecordingOutput`.** ScreenCaptureKit writes the file
itself. We configure an `SCRecordingOutput` with `.h264` and `.mp4` (falling back
to whatever `availableVideoCodecTypes` / `availableOutputFileTypes` offer) and add
it to the stream. Start/finish are bridged to async with `CheckedContinuation`s
resumed by the `SCRecordingOutputDelegate` callbacks. This is the preferred path:
less code, lower CPU, no manual frame plumbing.

**macOS 13–14 — manual pipeline.** We build the writer ourselves:

- `AVAssetWriter(url:fileType: .mov)` with a video input that tries **H.264**
  (`High_AutoLevel`) and falls back to **HEVC** (`Main_AutoLevel`), plus an AAC
  audio input (48 kHz stereo, 192 kbps) when system audio is on.
- An `SCStream` delivers `CMSampleBuffer`s via `SCStreamOutput`. Buffers are
  dispatched to a dedicated serial `writerQueue` (`.userInteractive`).
- The **first complete video frame** opens the writer session
  (`writer.startSession(atSourceTime: pts)`); subsequent frames are appended when
  `isReadyForMoreMediaData`, otherwise counted as `droppedFrames`.
- Incomplete frames are filtered using the `SCStreamFrameInfo.status` attachment.

### Targets

```swift
switch configuration.recordTarget {
case .fullScreen(display): SCContentFilter(display:excludingApplications:exceptingWindows:)
case .window(window):      SCContentFilter(desktopIndependentWindow:)
case .area(display, rect): // full-display filter + streamConfig.sourceRect = rect
}
```

### Sizing

`resolvedCaptureSize` scales the source down to fit the quality preset's
dimensions (never up), then snaps width/height to **even** numbers — H.264/HEVC
encoders reject odd dimensions. Area capture is sized from `rect × backingScale`
so the stream and writer agree exactly.

| Preset | Pixels | Bitrate | Keyframe interval |
| --- | --- | --- | --- |
| Low | 1280×720 | 5 Mbps | 2 s |
| Medium | 1920×1080 | 10 Mbps | 2 s |
| High | 2560×1440 | 20 Mbps | 2 s |
| Ultra | 3840×2160 | 40 Mbps | 2 s |

---

## Mic & camera

| Recorder | Capture | Container | Codec | Sync |
| --- | --- | --- | --- | --- |
| [`MicRecorder`](../SmoothyREC/MicRecorder.swift) | `AVCaptureSession` (audio) | `.m4a` | AAC | — |
| [`CameraRecorder`](../SmoothyREC/CameraRecorder.swift) | `AVCaptureSession` (video) | `.mov` | HEVC | `startSession(atSourceTime: syncTime)` |

The camera writer is pinned to the coordinator's shared `syncTime`, which is what
keeps the webcam aligned with the screen track on the timeline. Both run their own
isolated `AVAssetWriter`, so one failing can't corrupt the others.

---

## Output file naming ([`RecordingSupport.swift`](../SmoothyREC/RecordingSupport.swift))

`RecordingOutputFileResolver` owns naming:

- `uniqueRecordingDirectory` — one folder per recording, numbered for repeats
  (`Title`, `Title 2`, `Title 3`). Resolved **once** by the coordinator and shared.
- `preparedOutputURL` — `{sanitizedName}_{component}_{yyyy-MM-dd_HH-mm-ss}.{ext}`,
  where `component ∈ {screen, mic, camera}`.

```
Client Walkthrough/
├── Client Walkthrough_screen_2026-06-06_14-22-08.mp4
├── Client Walkthrough_mic_2026-06-06_14-22-08.m4a
└── Client Walkthrough_camera_2026-06-06_14-22-08.mov
```

Names are sanitized (illegal path characters → `_`, capped at 100 chars,
empty → `Untitled`). The resolver is the main unit under test in
[`SmoothyRECTests`](../SmoothyRECTests/RecordingSupportTests.swift).

---

## Optional picture-in-picture ([`PiPCompositor.swift`](../SmoothyREC/PiPCompositor.swift))

For a single ready-to-share file, `PiPCompositor.compose(...)` builds an
`AVMutableComposition`: the screen track is the base layer, the camera track is
overlaid as a corner inset via an `AVVideoComposition`/layer instructions, and the
system + mic audio are mixed in. Duration is clamped to
`min(screenDuration, cameraDuration)`. This is **additive** — it never replaces the
separate source files the editor relies on.

---

## Concurrency model

Real-time A/V capture spans several threads, so the boundaries are explicit:

| Concern | Mechanism |
| --- | --- |
| Public API & UI state | `@MainActor` on coordinator and recorders; `@Published` properties |
| Raw sample-buffer handling | Dedicated serial `DispatchQueue`s (`.userInteractive`/`.userInitiated`) |
| Shared writer state | `RecorderState` struct guarded by `NSLock` (`updateState`/`readState`) |
| Bridging SCKit delegate callbacks → async | `CheckedContinuation` (start/finish), guarded by a lock + "replace" helper |
| Concurrent start/stop of 3 recorders | `withTaskGroup` |
| Recorder → coordinator state mirroring | Combine `sink` on `@Published` `state` |

`nonisolated(unsafe)` is used narrowly where sample buffers cross actor boundaries
into the serial writer queue, which provides the actual serialization.

---

## Permissions & signing

### Entitlements ([`SmoothyREC.entitlements`](../SmoothyREC/SmoothyREC.entitlements))

App Sandbox is **disabled** — sandboxed apps can't do system-wide screen capture
the way SmoothyREC needs. The app declares: `screen-recording`, `device.camera`,
`device.microphone`, `device.audio-input`, `network.client`, and user-selected /
Downloads / Movies file access.

### TCC prompts ([`Info.plist`](../SmoothyREC/Info.plist))

`NSScreenCaptureUsageDescription`, `NSCameraUsageDescription`, and
`NSMicrophoneUsageDescription` provide the human-readable reasons macOS shows.
Screen Recording is **required**; camera and mic are **optional**
(`SmoothyPermission.isRequiredForLaunch`).

### Why a *stable* signature matters when building

macOS keys TCC permissions to the app's **code-signature hash**. An ad-hoc
signature changes on every rebuild, so macOS keeps "forgetting" your granted
Screen Recording permission. [`setup-dev-certificate.sh`](../setup-dev-certificate.sh)
creates a stable self-signed identity so permissions persist across rebuilds while
developing. The public release is ad-hoc/unsigned (no paid Developer ID), which is
why first launch needs a one-time right-click → Open.

### Permission classification

`ScreenCapturePermissionClassifier.isPermissionDenied` normalizes the various ways
ScreenCaptureKit signals "denied" (error domains/codes plus TCC-related message
text) into a single `.permissionDenied` so the UI can route the user to the right
System Settings pane.

---

## Error & warning model

Two tiers, matching the primary/optional split:

- **Fatal** — anything that prevents a screen recording: `CoordinatorError`
  (`.screenRecorderFailed`, `.partialFailure`, `.syncClockFailed`, …) and
  `RecordingError` (`.permissionDenied`, `.assetWriterStartFailed`,
  `.diskSpaceLow`, …). These end the session.
- **Non-fatal warnings** — a mic or camera that failed to start/stop becomes a
  `RecordingWarning` surfaced on the completion screen. The screen recording is
  still saved and usable.

---

## Source map

| Area | Files |
| --- | --- |
| App / menu bar | `SmoothyRECApp.swift`, `AppDelegate+StatusBar.swift`, `AppDelegate+Windows.swift`, `AppDelegate+Notifications.swift` |
| Orchestration | `RecordingCoordinator.swift`, `RecordingSupport.swift` |
| Capture engines | `ScreenRecorder.swift`, `CameraRecorder.swift`, `MicRecorder.swift` |
| Combined export | `PiPCompositor.swift` |
| Devices / settings | `DeviceManager.swift`, `SettingsManager.swift`, `HotKeyManager.swift` |
| UI | `MainWindowView.swift`, `SettingsView.swift`, `SettingsPanelView.swift`, `OnboardingView.swift`, `RecordingStatusView.swift`, `CompletionView.swift`, `ContentView.swift` |
| Overlays / previews | `CountdownOverlay.swift`, `RegionSelectionOverlay.swift`, `CameraPreviewManager.swift`, `ScreenPreviewManager.swift`, `MicMonitorManager.swift` |
| Tests | `SmoothyRECTests/RecordingSupportTests.swift` |
</content>
