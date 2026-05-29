//
//  SettingsManager.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import Combine
import AppKit

// MARK: - Settings Keys

enum SettingsKey: String {
    case outputFolder = "outputFolderPath"
    case defaultQuality = "defaultQuality"
    case defaultFrameRate = "defaultFrameRate"
    case includeSystemAudio = "includeSystemAudio"
    case captureCursor = "captureCursor"
    case countdownEnabled = "countdownEnabled"
    case countdownSeconds = "countdownSeconds"
    case lastCameraID = "lastCameraID"
    case lastMicrophoneID = "lastMicrophoneID"
    case lastDisplayID = "lastDisplayID"
    case lastRecordMode = "lastRecordMode"
    case micGain = "micGain"
    case pipAutoExport = "pipAutoExport"
    case pipCorner = "pipCorner"
    case startStopKeyCode = "startStopKeyCode"
    case startStopModifiers = "startStopModifiers"
    case pauseKeyCode = "pauseKeyCode"
    case pauseModifiers = "pauseModifiers"

    var defaultValue: Any? {
        switch self {
        case .outputFolder:
            return nil
        case .defaultQuality:
            return RecordingQuality.high.rawValue
        case .defaultFrameRate:
            return FrameRate.fps30.rawValue
        case .includeSystemAudio:
            return true
        case .captureCursor:
            return true
        case .countdownEnabled:
            return true
        case .countdownSeconds:
            return 3
        case .lastCameraID, .lastMicrophoneID, .lastDisplayID, .lastRecordMode:
            return nil
        case .micGain:
            return 1.0
        case .pipAutoExport:
            return false
        case .pipCorner:
            return "bottomRight"
        case .startStopKeyCode:
            return 15 // R
        case .startStopModifiers:
            return 768 // cmd + shift
        case .pauseKeyCode:
            return 35 // P
        case .pauseModifiers:
            return 768 // cmd + shift
        }
    }
}

// MARK: - Settings Manager

@MainActor
class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    static let settingsInitializedKey = "settingsInitialized"

    @Published var outputFolderURL: URL? {
        didSet {
            if let url = outputFolderURL {
                UserDefaults.standard.set(url.path, forKey: SettingsKey.outputFolder.rawValue)
            } else {
                UserDefaults.standard.removeObject(forKey: SettingsKey.outputFolder.rawValue)
            }
            objectWillChange.send()
        }
    }

    @Published var defaultQuality: RecordingQuality {
        didSet {
            UserDefaults.standard.set(defaultQuality.rawValue, forKey: SettingsKey.defaultQuality.rawValue)
        }
    }

    @Published var defaultFrameRate: FrameRate {
        didSet {
            UserDefaults.standard.set(defaultFrameRate.rawValue, forKey: SettingsKey.defaultFrameRate.rawValue)
        }
    }

    @Published var includeSystemAudio: Bool {
        didSet {
            UserDefaults.standard.set(includeSystemAudio, forKey: SettingsKey.includeSystemAudio.rawValue)
        }
    }

    @Published var captureCursor: Bool {
        didSet {
            UserDefaults.standard.set(captureCursor, forKey: SettingsKey.captureCursor.rawValue)
        }
    }

    @Published var countdownEnabled: Bool {
        didSet {
            UserDefaults.standard.set(countdownEnabled, forKey: SettingsKey.countdownEnabled.rawValue)
        }
    }

    @Published var countdownSeconds: Int {
        didSet {
            UserDefaults.standard.set(countdownSeconds, forKey: SettingsKey.countdownSeconds.rawValue)
        }
    }

    // MARK: - Last-Selected Devices

    /// Stable identifiers for the most recently used capture devices, restored
    /// on each launch so the user doesn't have to re-pick their setup.
    @Published var lastCameraID: String? {
        didSet { persistOptionalString(lastCameraID, forKey: .lastCameraID) }
    }

    @Published var lastMicrophoneID: String? {
        didSet { persistOptionalString(lastMicrophoneID, forKey: .lastMicrophoneID) }
    }

    @Published var lastDisplayID: String? {
        didSet { persistOptionalString(lastDisplayID, forKey: .lastDisplayID) }
    }

    @Published var lastRecordMode: String? {
        didSet { persistOptionalString(lastRecordMode, forKey: .lastRecordMode) }
    }

    // MARK: - Audio / PiP / Shortcuts

    /// Linear gain multiplier applied to microphone samples (1.0 = unchanged).
    @Published var micGain: Double {
        didSet { UserDefaults.standard.set(micGain, forKey: SettingsKey.micGain.rawValue) }
    }

    /// When true, a combined picture-in-picture file is exported automatically
    /// after a recording that captured both screen and camera.
    @Published var pipAutoExport: Bool {
        didSet { UserDefaults.standard.set(pipAutoExport, forKey: SettingsKey.pipAutoExport.rawValue) }
    }

    @Published var pipCorner: String {
        didSet { UserDefaults.standard.set(pipCorner, forKey: SettingsKey.pipCorner.rawValue) }
    }

    @Published var startStopKeyCode: Int {
        didSet { UserDefaults.standard.set(startStopKeyCode, forKey: SettingsKey.startStopKeyCode.rawValue) }
    }

    @Published var startStopModifiers: Int {
        didSet { UserDefaults.standard.set(startStopModifiers, forKey: SettingsKey.startStopModifiers.rawValue) }
    }

    @Published var pauseKeyCode: Int {
        didSet { UserDefaults.standard.set(pauseKeyCode, forKey: SettingsKey.pauseKeyCode.rawValue) }
    }

    @Published var pauseModifiers: Int {
        didSet { UserDefaults.standard.set(pauseModifiers, forKey: SettingsKey.pauseModifiers.rawValue) }
    }

    private func persistOptionalString(_ value: String?, forKey key: SettingsKey) {
        if let value {
            UserDefaults.standard.set(value, forKey: key.rawValue)
        } else {
            UserDefaults.standard.removeObject(forKey: key.rawValue)
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        // Load output folder
        if let path = defaults.string(forKey: SettingsKey.outputFolder.rawValue) {
            self.outputFolderURL = URL(fileURLWithPath: path)
        } else {
            self.outputFolderURL = nil
        }

        // Load default quality
        let qualityRaw = defaults.string(forKey: SettingsKey.defaultQuality.rawValue)
        self.defaultQuality = RecordingQuality(rawValue: qualityRaw ?? "") ?? .high

        // Load default frame rate
        let frameRateRaw = defaults.object(forKey: SettingsKey.defaultFrameRate.rawValue) as? Int ?? FrameRate.fps30.rawValue
        self.defaultFrameRate = FrameRate(rawValue: frameRateRaw) ?? .fps30

        // Load other settings
        self.includeSystemAudio = defaults.object(forKey: SettingsKey.includeSystemAudio.rawValue) as? Bool ?? true
        self.captureCursor = defaults.object(forKey: SettingsKey.captureCursor.rawValue) as? Bool ?? true
        self.countdownEnabled = defaults.object(forKey: SettingsKey.countdownEnabled.rawValue) as? Bool ?? true
        self.countdownSeconds = defaults.object(forKey: SettingsKey.countdownSeconds.rawValue) as? Int ?? 3

        // Load last-selected devices
        self.lastCameraID = defaults.string(forKey: SettingsKey.lastCameraID.rawValue)
        self.lastMicrophoneID = defaults.string(forKey: SettingsKey.lastMicrophoneID.rawValue)
        self.lastDisplayID = defaults.string(forKey: SettingsKey.lastDisplayID.rawValue)
        self.lastRecordMode = defaults.string(forKey: SettingsKey.lastRecordMode.rawValue)

        // Audio / PiP / Shortcuts
        self.micGain = defaults.object(forKey: SettingsKey.micGain.rawValue) as? Double ?? 1.0
        self.pipAutoExport = defaults.object(forKey: SettingsKey.pipAutoExport.rawValue) as? Bool ?? false
        self.pipCorner = defaults.string(forKey: SettingsKey.pipCorner.rawValue) ?? "bottomRight"
        self.startStopKeyCode = defaults.object(forKey: SettingsKey.startStopKeyCode.rawValue) as? Int ?? 15
        self.startStopModifiers = defaults.object(forKey: SettingsKey.startStopModifiers.rawValue) as? Int ?? 768
        self.pauseKeyCode = defaults.object(forKey: SettingsKey.pauseKeyCode.rawValue) as? Int ?? 35
        self.pauseModifiers = defaults.object(forKey: SettingsKey.pauseModifiers.rawValue) as? Int ?? 768

        // Set defaults if not set
        if !defaults.bool(forKey: Self.settingsInitializedKey) {
            setDefaults()
            defaults.set(true, forKey: Self.settingsInitializedKey)
        }
    }

    private func setDefaults() {
        outputFolderURL = defaultOutputFolder()
        defaultQuality = .high
        defaultFrameRate = .fps30
        includeSystemAudio = true
        captureCursor = true
        countdownEnabled = true
        countdownSeconds = 3
    }

    /// Returns the default output folder (~/Movies/SmoothyREC)
    func defaultOutputFolder() -> URL? {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first?.appendingPathComponent("SmoothyREC", isDirectory: true)
    }

    /// Returns the current output folder (custom or default)
    var effectiveOutputFolder: URL? {
        outputFolderURL ?? defaultOutputFolder()
    }

    /// Presents NSOpenPanel to choose output folder
    func chooseOutputFolder() -> URL? {
        let openPanel = NSOpenPanel()
        openPanel.title = "Choose Output Folder"
        openPanel.message = "Select the folder where recordings will be saved"
        openPanel.canChooseFiles = false
        openPanel.canChooseDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.canCreateDirectories = true

        // Set current folder as starting point
        openPanel.directoryURL = effectiveOutputFolder

        if openPanel.runModal() == .OK {
            return openPanel.url
        }
        return nil
    }

    /// Resets output folder to default
    func resetOutputFolder() {
        outputFolderURL = nil
    }

    /// Formatted path for display
    var formattedOutputPath: String {
        guard let url = effectiveOutputFolder else {
            return "Not set"
        }

        // Show shortened path
        let path = url.path
        let home = NSHomeDirectory()

        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Convenience Extensions

extension URL {
    /// Returns a display-friendly path string
    var displayPath: String {
        let path = self.path
        let home = NSHomeDirectory()

        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
