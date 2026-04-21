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
    case countdownEnabled = "countdownEnabled"
    case countdownSeconds = "countdownSeconds"

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
        case .countdownEnabled:
            return true
        case .countdownSeconds:
            return 3
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
        self.countdownEnabled = defaults.object(forKey: SettingsKey.countdownEnabled.rawValue) as? Bool ?? true
        self.countdownSeconds = defaults.object(forKey: SettingsKey.countdownSeconds.rawValue) as? Int ?? 3

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
