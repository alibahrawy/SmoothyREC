//
//  SettingsView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @Environment(\.dismiss) private var dismiss
    
    // Settings state
    @AppStorage("saveLocation") private var saveLocation: String = ""
    @AppStorage("showMouseClicks") private var showMouseClicks = true
    @AppStorage("highlightCursor") private var highlightCursor = false
    @AppStorage("countdownEnabled") private var countdownEnabled = true
    @AppStorage("countdownSeconds") private var countdownSeconds = 3
    @AppStorage("autoStopEnabled") private var autoStopEnabled = false
    @AppStorage("autoStopMinutes") private var autoStopMinutes = 60
    @AppStorage("defaultQuality") private var defaultQuality: RecordingQuality = .high
    @AppStorage("defaultFrameRate") private var defaultFrameRate: FrameRate = .fps30
    
    var body: some View {
        TabView {
            // General Settings
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }
            
            // Recording Settings
            recordingSettings
                .tabItem {
                    Label("Recording", systemImage: "video")
                }
            
            // Audio Settings
            audioSettings
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }
            
            // Shortcuts Settings
            shortcutsSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
            
            // About
            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .padding()
    }
    
    // MARK: - General Settings
    private var generalSettings: some View {
        Form {
            Section("Save Location") {
                HStack {
                    TextField("Save to folder", text: $saveLocation)
                        .disabled(true)
                    Button("Choose...") {
                        chooseSaveLocation()
                    }
                }
            }
            
            Section("Startup") {
                Toggle("Start at login", isOn: .constant(false))
                Toggle("Show in menu bar", isOn: .constant(true))
                    .disabled(true)
            }
            
            Section("Appearance") {
                Picker("Icon style", selection: .constant(0)) {
                    Text("Color").tag(0)
                    Text("Monochrome").tag(1)
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Recording Settings
    private var recordingSettings: some View {
        Form {
            Section("Defaults") {
                Picker("Default Quality", selection: $defaultQuality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text("\(quality.rawValue) (\(quality.description))").tag(quality)
                    }
                }
                
                Picker("Default Frame Rate", selection: $defaultFrameRate) {
                    ForEach(FrameRate.allCases) { fps in
                        Text(fps.description).tag(fps)
                    }
                }
            }
            
            Section("Cursor") {
                Toggle("Show mouse clicks", isOn: $showMouseClicks)
                Toggle("Highlight cursor", isOn: $highlightCursor)
            }
            
            Section("Timer") {
                Toggle("Enable countdown", isOn: $countdownEnabled)
                if countdownEnabled {
                    Stepper("Countdown: \(countdownSeconds) seconds", value: $countdownSeconds, in: 1...10)
                }
                
                Toggle("Auto-stop recording", isOn: $autoStopEnabled)
                if autoStopEnabled {
                    Stepper("Stop after: \(autoStopMinutes) minutes", value: $autoStopMinutes, in: 1...180)
                }
            }
        }
        .formStyle(.grouped)
    }
    
    @State private var selectedAudioSource: AudioSource = .systemAudio
    @State private var includeMicrophoneDefault: Bool = true

    // MARK: - Audio Settings
    private var audioSettings: some View {
        Form {
            Section("Input") {
                Picker("Default Audio Source", selection: $selectedAudioSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                
                Toggle("Include microphone by default", isOn: $includeMicrophoneDefault)
            }
            
            Section("Output") {
                Toggle("Normalize audio levels", isOn: .constant(true))
                Slider(value: .constant(0.8), in: 0...1) {
                    Text("System Audio Volume")
                }
                Slider(value: .constant(0.6), in: 0...1) {
                    Text("Microphone Volume")
                }
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - Shortcuts Settings
    private var shortcutsSettings: some View {
        Form {
            Section("Global Shortcuts") {
                HStack {
                    Text("Start/Stop Recording")
                    Spacer()
                    KeyboardShortcutView(shortcut: "⌃⌘R")
                }
                
                HStack {
                    Text("Pause/Resume")
                    Spacer()
                    KeyboardShortcutView(shortcut: "⌃⌘P")
                }
                
                HStack {
                    Text("Quick Settings")
                    Spacer()
                    KeyboardShortcutView(shortcut: "⌃⌘S")
                }
            }
            
            Section("Note") {
                Text("Shortcuts can be customized in System Preferences > Keyboard > Shortcuts > App Shortcuts")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
    
    // MARK: - About View
    private var aboutView: some View {
        VStack(spacing: 20) {
            Image(systemName: "record.circle")
                .font(.system(size: 64))
                .foregroundColor(.red)
            
            Text("SmoothyREC")
                .font(.title)
                .fontWeight(.bold)
            
            Text("Version 1.0.0")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Text("A beautiful screen recorder for macOS")
                .font(.body)
                .foregroundColor(.secondary)
            
            Divider()
                .padding(.horizontal, 40)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Screen Recording with audio")
                }
                
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Camera overlay support")
                }
                
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("System audio + microphone mix")
                }
                
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("High-quality output up to 4K")
                }
            }
            .font(.subheadline)
            
            Spacer()
            
            Button("Check for Updates") {
                // Check for updates
            }
            
            Text("© 2024 SmoothyREC. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
    
    private func chooseSaveLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        
        if panel.runModal() == .OK {
            saveLocation = panel.url?.path ?? ""
        }
    }
}

// MARK: - Keyboard Shortcut View
struct KeyboardShortcutView: View {
    let shortcut: String
    
    var body: some View {
        Text(shortcut)
            .font(.system(.body, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.gray.opacity(0.2))
            .cornerRadius(6)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppDelegate())
}
