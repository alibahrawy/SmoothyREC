# SmoothyREC

A beautiful menu bar screen recorder for macOS.

![macOS 13.0+](https://img.shields.io/badge/macOS-13.0+-blue.svg)
![Swift 5](https://img.shields.io/badge/Swift-5-orange.svg)

## Features

- **Menu Bar App** - Lives in your menu bar, no dock icon
- **Screen Recording** - Capture your entire screen or selected display
- **Audio Recording** - Record system audio, microphone, or both
- **Camera Overlay** - Include webcam feed as picture-in-picture
- **High Quality** - Up to 4K resolution at 60 FPS
- **Modern UI** - Native SwiftUI interface

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)

## Installation

### From DMG

1. Download the latest `SmoothyREC-x.x.x.dmg` from the releases page
2. Open the DMG and drag `SmoothyREC.app` to your Applications folder
3. Launch SmoothyREC from your Applications folder

### Build from Source

```bash
git clone https://github.com/yourusername/SmoothyREC.git
cd SmoothyREC
./build-dev.sh
open build/SmoothyREC.app
```

## Permissions

On first launch, SmoothyREC will request the following permissions:

1. **Screen Recording** - Required to capture your screen
2. **Camera** - Required for camera overlay (optional)
3. **Microphone** - Required for microphone audio (optional)

To grant permissions:
1. Go to **System Settings > Privacy & Security**
2. Enable permissions for SmoothyREC in the respective sections

## Usage

1. Click the **record icon** in your menu bar to open the control panel
2. Configure your recording settings:
   - Select quality (720p, 1080p, 1440p, 4K)
   - Set frame rate (24, 30, 60 FPS)
   - Choose audio source (System Audio, Microphone, Both)
   - Enable camera overlay (optional)
3. Click **Start Recording**
4. Click **Stop Recording** when finished

Recordings are saved to your Movies folder with the format `SmoothyREC_YYYY-MM-DD_HH-MM-SS.mov`.

## Building for Distribution

### Unsigned Build (for testing)

```bash
./build-dev.sh
```

### Creating a DMG Installer

The easiest way to create a professional DMG is using `create-dmg`:

#### 1. Install create-dmg

```bash
brew install create-dmg
```

#### 2. Create the DMG

```bash
# Build the app first
./build-dev.sh

# Create the DMG
./create-dmg.sh

# Or specify custom directories:
./create-dmg.sh build ./releases
```

This creates `SmoothyREC.dmg` with:
- Custom background with app name
- App icon positioned on the left
- Applications folder shortcut on the right
- Clean, professional appearance
- UDZO compression for smaller file size

### Signed Build (for distribution)

1. Update `build-and-sign.sh` with your Developer ID
2. Run the build script:

```bash
./build-and-sign.sh
```

This will:
- Build the app
- Sign with your Developer ID
- Create a DMG
- Submit for notarization
- Staple the notarization ticket

## Project Structure

```
SmoothyREC/
├── SmoothyREC/
│   ├── SmoothyRECApp.swift           # App entry point & menu bar setup
│   ├── ContentView.swift             # Main popover UI
│   ├── MainWindowView.swift          # Recording setup window
│   ├── SettingsView.swift            # Full settings panel
│   ├── SettingsPanelView.swift       # Quick settings from menu bar
│   ├── RecordingStatusView.swift     # Recording controls popover
│   ├── CompletionView.swift          # Post-recording file manager
│   ├── ScreenRecorder.swift          # Screen capture engine
│   ├── CameraRecorder.swift          # Camera capture engine
│   ├── MicRecorder.swift             # Microphone capture engine
│   ├── RecordingCoordinator.swift    # Syncs all recorders
│   ├── DeviceManager.swift           # Device enumeration
│   ├── SettingsManager.swift         # User preferences
│   ├── Assets.xcassets/              # App icons
│   ├── SmoothyREC.entitlements       # App entitlements
│   └── Info.plist                    # App configuration (LSUIElement)
├── SmoothyREC.xcodeproj/             # Xcode project
├── build.sh                          # Build script (unsigned)
├── build-and-sign.sh                 # Build script (signed)
├── build-dev.sh                      # Quick dev build
├── create-dmg.sh                     # DMG creation script
└── README.md
```

## Configuration

### Info.plist

Key settings:
- `LSUIElement` = `true` - Runs as menu bar app (no dock icon)
- `NSCameraUsageDescription` - Camera permission prompt
- `NSMicrophoneUsageDescription` - Microphone permission prompt

### Entitlements

The app requires these entitlements for screen recording:

```xml
<key>com.apple.security.screen-recording</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.microphone</key>
<true/>
```

**Note:** App Sandbox is disabled (`com.apple.security.app-sandbox` = `false`) to allow screen recording functionality.

## Keyboard Shortcuts

- `⌃⌘R` - Start/Stop Recording
- `⌃⌘P` - Pause/Resume
- `⌃⌘S` - Open Settings

## DMG Creation Details

The `create-dmg.sh` script uses [create-dmg](https://github.com/create-dmg/create-dmg) to generate a professional installer:

### Features
- **Custom Background**: Gradient background with app name
- **Icon Layout**: App on the left, Applications shortcut on the right
- **Window Size**: 540×380 pixels (standard DMG window)
- **Compression**: UDZO format for optimal size
- **Internet Enable**: Disabled (prevents "downloaded from internet" warning)

### DMG Layout
```
┌──────────────────────────────────────┐
│      SmoothyREC                      │
│                                      │
│  [🔴 SmoothyREC.app]  →  [📂 Apps]  │
│       (drag here)                      │
│                                      │
└──────────────────────────────────────┘
```

### Usage Examples

```bash
# Use default build directory
./create-dmg.sh

# Specify build directory
./create-dmg.sh ./build

# Specify both build and output directories
./create-dmg.sh ./build ./releases
```

The script will:
1. Search for `SmoothyREC.app` in common build locations
2. Generate a background image
3. Create the DMG with proper layout
4. Show file size and verify contents
5. Clean up temporary files

## License

MIT License - See LICENSE file for details

## Credits

Built with:
- [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)
- [AVFoundation](https://developer.apple.com/documentation/avfoundation)
