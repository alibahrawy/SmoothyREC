//
//  ContentView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var settings = SettingsManager.shared
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "record.circle")
                    .font(.title2)
                    .foregroundColor(.red)
                Text("SmoothyREC")
                    .font(.headline)
                Spacer()

                // Settings toggle button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettings.toggle()
                    }
                }) {
                    Image(systemName: showSettings ? "xmark" : "gear")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help(showSettings ? "Close Settings" : "Quick Settings")
            }
            .padding(.horizontal)
            .padding(.top, 12)

            Divider()

            // Main content or settings
            if showSettings {
                SettingsPanelView()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainContent
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Main Content
    private var mainContent: some View {
        VStack(spacing: 16) {
            // Recording Status
            VStack(spacing: 8) {
                if appDelegate.isRecording {
                    HStack {
                        Image(systemName: "record.circle.fill")
                            .foregroundColor(.red)
                        Text("Recording...")
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }

                    Text(appDelegate.formatDuration(appDelegate.recordingDuration))
                        .font(.system(size: 32, weight: .semibold, design: .monospaced))
                        .foregroundColor(.primary)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))

                        Text("Ready to Record")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button("Open Recorder") {
                            appDelegate.showMainWindow()
                            appDelegate.closeMainPopover()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 20)
                }
            }
            .padding(.vertical, 8)

            Divider()

            // Current Output Folder (brief display)
            if !appDelegate.isRecording {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Output: \(settings.formattedOutputPath)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal)
            }

            // Quick Settings (only show when not recording)
            if !appDelegate.isRecording {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Settings")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Quality Picker
                    HStack {
                        Text("Quality")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $settings.defaultQuality) {
                            ForEach(RecordingQuality.allCases) { quality in
                                Text(quality.description).tag(quality)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 100)
                    }

                    // Frame Rate Picker
                    HStack {
                        Text("Frame Rate")
                            .font(.subheadline)
                        Spacer()
                        Picker("", selection: $settings.defaultFrameRate) {
                            ForEach(FrameRate.allCases) { fps in
                                Text(fps.description).tag(fps)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 100)
                    }
                }
                .padding(.horizontal)

                Spacer()
            }

            Divider()

            // Action Buttons
            VStack(spacing: 8) {
                if appDelegate.isRecording {
                    Button(action: {
                        appDelegate.stopRecordingFromStatusBar()
                    }) {
                        HStack {
                            Image(systemName: "stop.fill")
                            Text("Stop Recording")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.large)
                }

                HStack(spacing: 8) {
                    Button("New Recording") {
                        appDelegate.showMainWindow()
                        appDelegate.closeMainPopover()
                    }
                    .buttonStyle(.bordered)
                    .disabled(appDelegate.isRecording)

                    if !showSettings {
                        Button("Settings") {
                            withAnimation {
                                showSettings = true
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    Button("Permissions") {
                        appDelegate.reopenOnboarding()
                        appDelegate.closeMainPopover()
                    }
                    .buttonStyle(.bordered)

                    Button("Quit") {
                        appDelegate.quitApp()
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.small)

                footer
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .transition(.move(edge: .leading).combined(with: .opacity))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(versionString)
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Text("·")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button("Check for Updates") {
                appDelegate.checkForUpdates()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.accentColor)
        }
        .padding(.top, 4)
    }

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        return "v\(version)"
    }
}

#Preview {
    ContentView()
        .environmentObject(AppDelegate())
}