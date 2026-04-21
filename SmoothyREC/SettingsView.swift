//
//  SettingsView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var settings = SettingsManager.shared

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
                Text("SmoothyREC keeps recording controls in the menu bar and opens setup windows only when needed.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                Text("Microphone input is selected per recording so unavailable or missing microphone permission does not block screen-only capture.")
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

            Text("Version 1.0.0")
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

            Text("Copyright 2024 SmoothyREC. All rights reserved.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
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

#Preview {
    SettingsView()
}
