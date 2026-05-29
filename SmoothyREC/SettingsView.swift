//
//  SettingsView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI
import ServiceManagement
import os.log

private let settingsLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "Settings")

struct SettingsView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var settings = SettingsManager.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        TabView {
            generalSettings
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            recordingSettings
                .tabItem {
                    Label("Recording", systemImage: "video")
                }

            audioSettings
                .tabItem {
                    Label("Audio", systemImage: "speaker.wave.2")
                }

            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            aboutView
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 420)
        .padding()
    }

    // MARK: - General Settings

    private var generalSettings: some View {
        Form {
            Section("Output Folder") {
                HStack(spacing: 8) {
                    Text(settings.formattedOutputPath)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button("Choose...") {
                        changeOutputFolder()
                    }
                }

                if settings.outputFolderURL != nil {
                    Button("Reset to Default") {
                        settings.resetOutputFolder()
                    }
                }
            }

            Section("App Behavior") {
                LabeledContent("Launch Mode", value: "Menu bar app")
                Text("SmoothyREC opens the recorder window on launch and keeps quick controls in the menu bar.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle("Launch SmoothyREC at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        setLaunchAtLogin(enabled)
                    }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Recording Settings

    private var recordingSettings: some View {
        Form {
            Section("Defaults") {
                Picker("Default Quality", selection: $settings.defaultQuality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text("\(quality.rawValue) (\(quality.description))").tag(quality)
                    }
                }

                Picker("Default Frame Rate", selection: $settings.defaultFrameRate) {
                    ForEach(FrameRate.allCases) { fps in
                        Text(fps.description).tag(fps)
                    }
                }
            }

            Section("Countdown") {
                Toggle("Enable countdown", isOn: $settings.countdownEnabled)

                if settings.countdownEnabled {
                    Stepper(value: $settings.countdownSeconds, in: 1...10) {
                        Text("\(settings.countdownSeconds) seconds")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Audio Settings

    private var audioSettings: some View {
        Form {
            Section("System Audio") {
                Toggle("Include system audio by default", isOn: $settings.includeSystemAudio)
            }

            Section("Microphone") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Input gain")
                        Spacer()
                        Text(String(format: "%.0f%%", settings.micGain * 100))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.micGain, in: 0.0...3.0, step: 0.05)
                    Text("Boost or attenuate microphone level. 100% leaves the input unchanged.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text("Microphone input is selected per recording so unavailable or missing microphone permission does not block screen-only capture.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Shortcut Settings

    private var shortcutSettings: some View {
        Form {
            Section("Global Shortcuts") {
                LabeledContent("Start / Stop recording") {
                    ShortcutRecorder(
                        keyCode: $settings.startStopKeyCode,
                        modifiers: $settings.startStopModifiers,
                        onChange: { appDelegate.reloadHotKeys() }
                    )
                }

                LabeledContent("Pause / Resume") {
                    ShortcutRecorder(
                        keyCode: $settings.pauseKeyCode,
                        modifiers: $settings.pauseModifiers,
                        onChange: { appDelegate.reloadHotKeys() }
                    )
                }

                Text("Shortcuts work system-wide, even while SmoothyREC is in the background. Use a modifier (⌘, ⌥, ⌃, or ⇧) plus a key.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - About View

    private var aboutView: some View {
        VStack(spacing: 18) {
            Image(systemName: "record.circle")
                .font(.system(size: 64))
                .foregroundColor(.red)

            Text("SmoothyREC")
                .font(.title)
                .fontWeight(.bold)

            Text("Version \(appVersionString)")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("A menu bar screen recorder for macOS.")
                .font(.body)
                .foregroundColor(.secondary)

            Divider()
                .padding(.horizontal, 40)

            VStack(alignment: .leading, spacing: 8) {
                Label("Screen recording with optional system audio", systemImage: "checkmark.circle.fill")
                Label("Separate microphone and camera capture files", systemImage: "checkmark.circle.fill")
                Label("Live screen, webcam, and microphone previews", systemImage: "checkmark.circle.fill")
                Label("Configurable quality, frame rate, and countdown", systemImage: "checkmark.circle.fill")
            }
            .font(.subheadline)
            .foregroundColor(.secondary)
            .labelStyle(.titleAndIcon)

            Spacer()

            Text("Copyright \(currentYearString) SmoothyREC. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }

    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String
        if let build, build != version {
            return "\(version) (\(build))"
        }
        return version
    }

    private var currentYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: Date())
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            settingsLogger.error("Failed to update launch-at-login: \(error.localizedDescription)")
            // Reflect the real state if the system rejected the change.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func changeOutputFolder() {
        if let newURL = settings.chooseOutputFolder() {
            settings.outputFolderURL = newURL

            try? FileManager.default.createDirectory(
                at: newURL,
                withIntermediateDirectories: true
            )
        }
    }
}

// MARK: - Shortcut Recorder

/// A button that captures the next key-with-modifier press and stores it as a
/// Carbon key code + modifier mask. Click to arm, then press the combo.
struct ShortcutRecorder: View {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    var onChange: () -> Void

    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press shortcut…" : HotKeyFormatter.displayString(keyCode: keyCode, modifiers: modifiers))
                .frame(minWidth: 90)
                .monospacedDigit()
        }
        .buttonStyle(.bordered)
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Escape cancels without changing the shortcut.
            if event.keyCode == 53 {
                stop()
                return nil
            }

            let carbon = HotKeyFormatter.carbonModifiers(from: event.modifierFlags)
            // Require at least one modifier so the shortcut can't clash with typing.
            guard carbon != 0 else { return nil }

            keyCode = Int(event.keyCode)
            modifiers = carbon
            onChange()
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppDelegate())
}
