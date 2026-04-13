//
//  MainWindowView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI
import ScreenCaptureKit
import AVFoundation
import AppKit

struct MainWindowView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var settings = SettingsManager.shared
    
    // Form inputs
    @State private var videoName: String = ""
    @State private var selectedDisplay: Display?
    @State private var selectedWindow: CaptureWindow?
    @State private var selectedCamera: Camera?
    @State private var selectedMicrophone: Microphone?
    @State private var recordMode: RecordMode = .fullScreen
    
    // UI States
    @State private var isRecording = false
    @State private var isStarting = false
    
    enum RecordMode: String, CaseIterable, Identifiable {
        case fullScreen = "Full Screen"
        case specificWindow = "Specific Window"
        
        var id: String { rawValue }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView
            
            Divider()
            
            // Form Content
            ScrollView {
                VStack(spacing: 20) {
                    // Video Name
                    videoNameSection
                    
                    Divider()
                        .padding(.horizontal, -20)
                    
                    // Record Source
                    recordSourceSection
                    
                    Divider()
                        .padding(.horizontal, -20)
                    
                    // Camera Selection
                    cameraSection
                    
                    Divider()
                        .padding(.horizontal, -20)
                    
                    // Microphone Selection
                    microphoneSection
                }
                .padding(24)
            }
            
            Divider()
            
            // Bottom Record Button
            recordButtonSection
        }
        .frame(minWidth: 480, idealWidth: 480, maxWidth: 480,
               minHeight: 580, idealHeight: 580, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            if videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                videoName = suggestedVideoName()
            }
            Task {
                await refreshDevices()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if deviceManager.displays.isEmpty {
                Task { await refreshDevices() }
            }
        }
        .onChange(of: deviceManager.displays) { displays in
            if selectedDisplay == nil, let first = displays.first {
                selectedDisplay = first
            }
        }
    }
    
    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 28))
                .foregroundColor(.red)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("SmoothyREC")
                    .font(.system(size: 18, weight: .semibold))
                
                Text("Screen Recorder")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                NSApp.keyWindow?.close()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Color(.controlBackgroundColor))
    }
    
    // MARK: - Video Name Section
    private var videoNameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Video Name")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "text.quote")
                    .foregroundColor(.blue)
            }
            
            TextField("Enter video name...", text: $videoName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
        }
    }
    
    // MARK: - Record Source Section
    private var recordSourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Record Source")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "display")
                    .foregroundColor(.blue)
            }
            
            // Record Mode Picker
            Picker("", selection: $recordMode) {
                ForEach(RecordMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: recordMode) { _ in
                selectedWindow = nil
            }
            
            if recordMode == .fullScreen {
                // Display Selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Display")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if deviceManager.displays.isEmpty {
                        VStack(spacing: 8) {
                            if appDelegate.screenPermissionRequiresRelaunch {
                                Text("Screen Recording changed in System Settings. Relaunch SmoothyREC before starting another test.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            
                            Button(action: {
                                Task {
                                    if appDelegate.screenPermissionRequiresRelaunch {
                                        appDelegate.relaunchApplication()
                                    } else {
                                        await refreshDevices()
                                        if deviceManager.displays.isEmpty {
                                            appDelegate.openScreenRecordingSettings(fromPermissionFlow: true)
                                        }
                                    }
                                }
                            }) {
                                HStack {
                                    if deviceManager.isLoading {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                    }
                                    Text(appDelegate.screenPermissionRequiresRelaunch ? "Relaunch SmoothyREC" : (deviceManager.screenPermissionGranted ? "Refresh Devices" : "Open Screen Recording Settings"))
                                        .font(.system(size: 12))
                                }
                            }
                            .buttonStyle(.plain)
                            
                            if !appDelegate.screenPermissionRequiresRelaunch {
                                Text("If you change Screen Recording permission, macOS may require relaunching SmoothyREC before capture starts.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Picker("", selection: $selectedDisplay) {
                            ForEach(deviceManager.displays) { display in
                                Text(display.name).tag(display as Display?)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }
                }
            } else {
                // Window Selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Window")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    Picker("", selection: $selectedWindow) {
                        Text("Select a window...")
                            .tag(nil as CaptureWindow?)
                        
                        ForEach(deviceManager.windows) { window in
                            Text(window.description)
                                .tag(window as CaptureWindow?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }
            }
        }
    }
    
    // MARK: - Camera Section
    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Camera")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "video.fill")
                    .foregroundColor(.blue)
            }
            
            Picker("", selection: $selectedCamera) {
                Text("No Camera")
                    .tag(nil as Camera?)
                
                ForEach(deviceManager.cameras) { camera in
                    HStack {
                        Image(systemName: camera.icon)
                        Text(camera.name)
                    }
                    .tag(camera as Camera?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            
            if selectedCamera != nil {
                Toggle("Show camera overlay", isOn: .constant(true))
                    .font(.system(size: 12))
                    .toggleStyle(.checkbox)
            }
        }
    }
    
    // MARK: - Microphone Section
    private var microphoneSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Microphone")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "mic.fill")
                    .foregroundColor(.blue)
            }
            
            Picker("", selection: $selectedMicrophone) {
                Text("No Microphone")
                    .tag(nil as Microphone?)
                
                ForEach(deviceManager.microphones) { mic in
                    HStack {
                        Image(systemName: mic.icon)
                        Text(mic.name)
                    }
                    .tag(mic as Microphone?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }
    }
    
    // MARK: - Record Button Section
    private var recordButtonSection: some View {
        HStack(spacing: 12) {
            Button(action: {
                appDelegate.openSettings()
            }) {
                Image(systemName: "gear")
                    .font(.system(size: 16))
            }
            .buttonStyle(.bordered)
            .help("Settings")
            
            Spacer()
            
            Button(action: {
                startRecording()
            }) {
                HStack(spacing: 8) {
                    if isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "record.circle.fill")
                            .font(.system(size: 18))
                    }
                    Text(isStarting ? "Starting..." : "Start Recording")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(minWidth: 160)
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .disabled(!canStartRecording || isStarting || deviceManager.isLoading)
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
    }
    
    // MARK: - Computed Properties
    private var canStartRecording: Bool {
        if videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if recordMode == .fullScreen && selectedDisplay == nil { return false }
        if recordMode == .specificWindow && selectedWindow == nil { return false }
        return true
    }
    
    // MARK: - Actions
    private func startRecording() {
        guard !isStarting else { return }

        // Create recording target
        let target: RecordingSessionConfiguration.ScreenRecordTarget
        switch recordMode {
        case .fullScreen:
            guard let display = selectedDisplay else { return }
            target = .fullScreen(display)
        case .specificWindow:
            guard let window = selectedWindow else { return }
            target = .window(window)
        }
        
        // Create session configuration
        let configuration = RecordingSessionConfiguration(
            videoName: videoName,
            recordTarget: target,
            includeSystemAudio: settings.includeSystemAudio,
            selectedMicrophone: selectedMicrophone,
            selectedCamera: selectedCamera,
            quality: settings.defaultQuality,
            frameRate: settings.defaultFrameRate
        )

        Task {
            isStarting = true
            defer { isStarting = false }

            do {
                try await appDelegate.startRecording(configuration: configuration)
                NSApp.keyWindow?.close()
            } catch {
                await refreshDevices()

                if case .failed = appDelegate.recordingCoordinator.state {
                    return
                }

                appDelegate.showRecordingErrorAlert(error: error)
            }
        }
    }

    private func refreshDevices() async {
        await deviceManager.refreshAllDevices()

        if selectedDisplay == nil || !deviceManager.displays.contains(where: { $0.id == selectedDisplay?.id }) {
            selectedDisplay = deviceManager.displays.first
        }

        if selectedWindow == nil || !deviceManager.windows.contains(where: { $0.id == selectedWindow?.id }) {
            selectedWindow = deviceManager.windows.first
        }
    }
    private func suggestedVideoName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH-mm"
        return "Recording \(formatter.string(from: Date()))"
    }
}

#Preview {
    MainWindowView()
        .environmentObject(AppDelegate())
}
