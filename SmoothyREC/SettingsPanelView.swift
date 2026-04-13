//
//  SettingsPanelView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI

struct SettingsPanelView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var settings = SettingsManager.shared
    @State private var showingFolderPicker = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Image(systemName: "gear")
                    .font(.title3)
                    .foregroundColor(.secondary)
                
                Text("Quick Settings")
                    .font(.headline)
                
                Spacer()
            }
            
            Divider()
            
            // Output Folder Section
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Output Folder")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.blue)
                }
                
                HStack(spacing: 8) {
                    Text(settings.formattedOutputPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    
                    Spacer()
                    
                    Button("Change...") {
                        changeOutputFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                if settings.outputFolderURL != nil {
                    Button("Reset to Default") {
                        settings.resetOutputFolder()
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }
            
            Divider()
            
            // Default Quality
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Default Quality")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "film.fill")
                        .foregroundColor(.purple)
                }
                
                Picker("", selection: $settings.defaultQuality) {
                    ForEach(RecordingQuality.allCases) { quality in
                        Text("\(quality.rawValue) (\(quality.description))").tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            
            // Default Frame Rate
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Default Frame Rate")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "timer")
                        .foregroundColor(.orange)
                }
                
                Picker("", selection: $settings.defaultFrameRate) {
                    ForEach(FrameRate.allCases) { fps in
                        Text(fps.description).tag(fps)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            Divider()
            
            // Audio Options
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Audio Options")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundColor(.green)
                }
                
                Toggle("Include system audio", isOn: $settings.includeSystemAudio)
                    .font(.caption)
            }
            
            Divider()
            
            // Countdown Options
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Countdown")
                        .font(.subheadline)
                        .fontWeight(.medium)
                } icon: {
                    Image(systemName: "number")
                        .foregroundColor(.red)
                }
                
                Toggle("Enable countdown", isOn: $settings.countdownEnabled)
                    .font(.caption)
                
                if settings.countdownEnabled {
                    HStack {
                        Text("Seconds:")
                            .font(.caption)
                        
                        Stepper(value: $settings.countdownSeconds, in: 1...10) {
                            Text("\(settings.countdownSeconds)")
                                .font(.caption)
                                .monospacedDigit()
                                .frame(width: 20)
                        }
                    }
                }
            }
            
            Spacer()
            
            Divider()
            
            // Full Settings Button
            Button(action: {
                appDelegate.openFullSettings()
            }) {
                HStack {
                    Image(systemName: "gear")
                    Text("Open Full Settings")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 300)
    }
    
    private func changeOutputFolder() {
        if let newURL = settings.chooseOutputFolder() {
            settings.outputFolderURL = newURL
            
            // Create directory if needed
            try? FileManager.default.createDirectory(
                at: newURL,
                withIntermediateDirectories: true
            )
        }
    }
}

#Preview {
    SettingsPanelView()
        .environmentObject(AppDelegate())
}