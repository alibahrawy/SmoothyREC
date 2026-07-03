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

    // Preview managers
    @StateObject private var screenPreviewManager = ScreenPreviewManager()
    @StateObject private var cameraPreviewManager = CameraPreviewManager()
    @StateObject private var micMonitorManager = MicMonitorManager()

    // Form inputs
    @State private var videoName: String = ""
    @State private var selectedDisplay: Display?
    @State private var selectedWindow: CaptureWindow?
    @State private var selectedCamera: Camera?
    @State private var selectedMicrophone: Microphone?
    @State private var recordMode: RecordMode = .fullScreen
    @State private var selectedRegion: SelectedRegion?
    @State private var regionController = RegionSelectionController()

    // UI States
    @State private var isRecording = false
    @State private var isStarting = false
    @State private var countdownRemaining: Int?
    @State private var countdownCancelled = false

    enum RecordMode: String, CaseIterable, Identifiable {
        case fullScreen = "Full Screen"
        case specificWindow = "Specific Window"
        case area = "Area"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Permission hint banner (if any permissions are missing)
            permissionHintBanner

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
        .frame(minWidth: 760, idealWidth: 760, maxWidth: 900,
               minHeight: 840, idealHeight: 920, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            if videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                videoName = suggestedVideoName()
            }
            if let savedMode = settings.lastRecordMode,
               let mode = RecordMode(rawValue: savedMode) {
                recordMode = mode
            }
            Task {
                await refreshDevices()
                if appDelegate.consumePendingHotKeyStart() {
                    startRecording()
                }
            }
            // Kick off live preview immediately if a target is already selected
            // (e.g. the user reopened the window after previously picking one).
            // No-op when nothing is selected yet — selection-change handlers
            // will start it later.
            startLiveScreenPreview()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // The view lives for the life of the app (the window is reused,
            // not rebuilt), so window reopen — not onAppear — is where devices
            // and previews get refreshed.
            guard (note.object as? NSWindow) === appDelegate.mainWindow else { return }
            if deviceManager.displays.isEmpty {
                Task { await refreshDevices() }
            }
            startLiveScreenPreview()
            if selectedCamera != nil, !cameraPreviewManager.isRunning {
                Task { await cameraPreviewManager.startPreview(camera: selectedCamera) }
            }
            if selectedMicrophone != nil, !micMonitorManager.isMonitoring {
                Task { await micMonitorManager.startMonitoring(microphone: selectedMicrophone) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            // Closing the window must stop the live capture pipelines — the
            // persistent view's onDisappear never fires on a mere orderOut.
            guard (note.object as? NSWindow) === appDelegate.mainWindow else { return }
            Task { await screenPreviewManager.stopLive() }
            Task {
                await cameraPreviewManager.stopPreview()
                await micMonitorManager.stopMonitoring()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .smoothyHotKeyStart)) { _ in
            if countdownRemaining != nil {
                // Hotkey during the countdown aborts it instead of stacking a
                // second start.
                _ = appDelegate.consumePendingHotKeyStart()
                cancelCountdown()
            } else if appDelegate.consumePendingHotKeyStart() {
                startRecording()
            }
        }
        .onChange(of: deviceManager.displays) { displays in
            if selectedDisplay == nil, let first = displays.first {
                selectedDisplay = first
            }
        }
        .onChange(of: selectedDisplay) { display in
            if let display {
                settings.lastDisplayID = String(display.id)
            }
            startLiveScreenPreview()
        }
        .onChange(of: selectedWindow) { _ in
            startLiveScreenPreview()
        }
        .onChange(of: appDelegate.isRecording) { recording in
            // The recorder owns the screen capture pipeline during recording;
            // running two SCStreams against the same target wastes power and
            // can hit OS-level frame drops.
            if recording {
                Task { await screenPreviewManager.stopLive() }
            } else {
                startLiveScreenPreview()
            }
        }
        .onDisappear {
            Task { await screenPreviewManager.stopLive() }
            screenPreviewManager.clear()
            Task {
                await cameraPreviewManager.stopPreview()
                await micMonitorManager.stopMonitoring()
            }
        }
    }

    // Session-only dismissal: persisting it meant the banner never came back,
    // even after the user revoked a permission in System Settings.
    @State private var hidePermissionBanner: Bool = false

    // MARK: - Permission Hint Banner
    @ViewBuilder
    private var permissionHintBanner: some View {
        let missingPermissions = getMissingPermissions()

        if !hidePermissionBanner && !missingPermissions.isEmpty {
            VStack(spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Permission Status: \(missingPermissions.joined(separator: ", "))")
                            .font(.system(size: 13, weight: .semibold))

                        Text("Screen Recording is required. Camera and microphone are optional until selected.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Review") {
                            appDelegate.reopenOnboarding()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.blue)

                        Button("Dismiss") {
                            hidePermissionBanner = true
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.orange.opacity(0.1))
        }
    }

    private func getMissingPermissions() -> [String] {
        var missing: [String] = []

        if !CGPreflightScreenCaptureAccess() {
            missing.append(SmoothyPermission.screenRecording.missingBannerLabel)
        }
        if deviceManager.cameraPermissionStatus != .authorized {
            missing.append(SmoothyPermission.camera.missingBannerLabel)
        }
        if deviceManager.microphonePermissionStatus != .authorized {
            missing.append(SmoothyPermission.microphone.missingBannerLabel)
        }

        return missing
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
            .onChange(of: recordMode) { mode in
                settings.lastRecordMode = mode.rawValue
                selectedWindow = nil
                startLiveScreenPreview()
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
                                        if deviceManager.displays.isEmpty && !deviceManager.screenPermissionGranted {
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
            } else if recordMode == .specificWindow {
                // Window Selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Window")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if deviceManager.windows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Window lists require macOS screen capture access. Load them only when you want to record a specific window.")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            Button(action: {
                                Task {
                                    await refreshDevices(includeScreenCaptureContent: true)
                                }
                            }) {
                                HStack {
                                    if deviceManager.isLoading {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "macwindow")
                                    }
                                    Text("Load Windows")
                                        .font(.system(size: 12))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
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
            } else {
                areaSelectionView
            }

            Toggle(isOn: $settings.captureCursor) {
                Text("Capture mouse cursor")
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            sourcePreviewSection
        }
    }

    // MARK: - Area Selection
    private var areaSelectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Area")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 10) {
                Button(action: { selectRegion() }) {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                        Text(selectedRegion == nil ? "Select Area…" : "Reselect Area")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.bordered)

                if let region = selectedRegion {
                    Label(region.displayString, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                } else {
                    Text("Drag a rectangle on screen to capture just that region.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func selectRegion() {
        let display = selectedDisplay ?? deviceManager.displays.first
        guard let display else { return }

        // Hide our window so the marquee covers a clean screen, then restore.
        let keyWindow = NSApp.keyWindow
        keyWindow?.orderOut(nil)

        regionController.begin(on: display) { region in
            keyWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if let region {
                selectedRegion = region
                // Refresh the live preview so it shows the cropped region.
                startLiveScreenPreview()
            }
        }
    }

    // MARK: - Source Preview Section
    private var sourcePreviewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Screen Recording Preview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)

                    Text(screenPreviewHint)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button(action: {
                    previewSelectedSource()
                }) {
                    HStack(spacing: 6) {
                        if screenPreviewManager.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: screenPreviewManager.hasPreview ? "arrow.clockwise" : "eye.fill")
                        }
                        Text(screenPreviewManager.hasPreview ? "Refresh Preview" : "Preview Screen")
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(screenPreviewManager.isLoading || currentScreenPreviewTarget == nil)
            }

            ScreenPreviewView(
                previewManager: screenPreviewManager,
                height: 460
            )

            if screenPreviewManager.errorMessage != nil {
                Button("Review Permissions") {
                    appDelegate.reopenOnboarding()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.blue)
            }
        }
        .padding(.top, 4)
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
            .onChange(of: selectedCamera) { newCamera in
                settings.lastCameraID = newCamera?.id
                Task {
                    await cameraPreviewManager.switchCamera(to: newCamera)
                }
            }

            if selectedCamera != nil {
                HStack(spacing: 6) {
                    Image(systemName: cameraPreviewManager.isRunning ? "video.fill" : "hourglass")
                        .foregroundColor(cameraPreviewManager.isRunning ? .green : .secondary)
                    Text(cameraPreviewManager.isRunning ? "Webcam preview is live." : "Starting webcam preview...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                CameraPreviewView(
                    previewManager: cameraPreviewManager,
                    height: 280
                )
                .onAppear {
                    Task {
                        await cameraPreviewManager.startPreview(camera: selectedCamera)
                    }
                }
                .onDisappear {
                    Task {
                        await cameraPreviewManager.stopPreview()
                    }
                }

                Label("Camera is always saved as its own file. Recordings stay as separate screen + camera files unless you turn on picture-in-picture below.", systemImage: "doc.badge.plus")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $settings.pipAutoExport) {
                        Text("Also export a picture-in-picture file")
                            .font(.system(size: 12))
                    }
                    .toggleStyle(.checkbox)

                    if settings.pipAutoExport {
                        HStack(spacing: 8) {
                            Text("Camera corner")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Picker("", selection: $settings.pipCorner) {
                                ForEach(PiPCorner.allCases) { corner in
                                    Text(corner.displayName).tag(corner.rawValue)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .frame(width: 130)
                        }
                    }
                }
                .padding(.top, 2)
            } else {
                Text(cameraGuidanceText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            .onChange(of: selectedMicrophone) { newMic in
                settings.lastMicrophoneID = newMic?.id
                Task {
                    await micMonitorManager.switchMicrophone(to: newMic)
                }
            }

            if selectedMicrophone != nil {
                HStack(spacing: 6) {
                    Image(systemName: micMonitorManager.isMonitoring ? "waveform" : "hourglass")
                        .foregroundColor(micMonitorManager.isMonitoring ? .green : .secondary)
                    Text(micMonitorManager.isMonitoring ? "Microphone levels are live." : "Starting microphone level monitor...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                MicMonitorControls(monitorManager: micMonitorManager)
                    .onAppear {
                        Task {
                            await micMonitorManager.startMonitoring(microphone: selectedMicrophone)
                        }
                    }
                    .onDisappear {
                        Task {
                            await micMonitorManager.stopMonitoring()
                        }
                    }
            } else {
                Text(microphoneGuidanceText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

            Button(action: {
                appDelegate.reopenOnboarding()
            }) {
                Image(systemName: "checklist")
                    .font(.system(size: 16))
            }
            .buttonStyle(.bordered)
            .help("Permissions")

            Spacer()

            if let countdownRemaining {
                // During the countdown the button turns into an escape hatch —
                // Esc works too via the cancel keyboard shortcut.
                Button(action: {
                    cancelCountdown()
                }) {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18))
                        Text("Cancel (\(countdownRemaining))")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .frame(minWidth: 160)
                    .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.gray)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
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
                        Text(startButtonTitle)
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
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
    }

    // MARK: - Computed Properties
    private var canStartRecording: Bool {
        if videoName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if recordMode == .fullScreen && selectedDisplay == nil { return false }
        if recordMode == .specificWindow && selectedWindow == nil { return false }
        if recordMode == .area && selectedRegion == nil { return false }
        return true
    }

    private var startButtonTitle: String {
        if let countdownRemaining {
            return "Starting in \(countdownRemaining)..."
        }

        return isStarting ? "Starting..." : "Start Recording"
    }

    // MARK: - Actions
    private func cancelCountdown() {
        countdownCancelled = true
    }

    private func startRecording() {
        guard !isStarting else { return }

        Task {
            isStarting = true
            countdownCancelled = false
            defer {
                isStarting = false
                countdownRemaining = nil
            }

            let countdownCompleted = await performCountdownIfNeeded()
            guard countdownCompleted else {
                appDelegate.countdownOverlay.hide()
                return
            }

            // Stop preview and monitoring before recording starts
            // (The actual recorders will take over the camera/mic)
            screenPreviewManager.clear()
            await cameraPreviewManager.stopPreview()
            await micMonitorManager.stopMonitoring()

            // Create recording target
            let target: RecordingSessionConfiguration.ScreenRecordTarget
            switch recordMode {
            case .fullScreen:
                guard let display = selectedDisplay else { return }
                target = .fullScreen(display)
            case .specificWindow:
                guard let window = selectedWindow else { return }
                target = .window(window)
            case .area:
                guard let region = selectedRegion,
                      let display = deviceManager.display(withID: region.displayID) ?? selectedDisplay else { return }
                target = .area(display, region.rect, region.scale)
            }

            // Create session configuration
            let configuration = RecordingSessionConfiguration(
                videoName: videoName,
                recordTarget: target,
                includeSystemAudio: settings.includeSystemAudio,
                captureCursor: settings.captureCursor,
                selectedMicrophone: selectedMicrophone,
                selectedCamera: selectedCamera,
                quality: settings.defaultQuality,
                frameRate: settings.defaultFrameRate,
                countdownSeconds: settings.countdownEnabled ? settings.countdownSeconds : 0
            )

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

    /// Returns false when the user cancelled during the countdown.
    private func performCountdownIfNeeded() async -> Bool {
        guard settings.countdownEnabled else {
            countdownRemaining = nil
            return true
        }

        let seconds = max(0, settings.countdownSeconds)
        guard seconds > 0 else {
            countdownRemaining = nil
            return true
        }

        appDelegate.countdownOverlay.show(startingAt: seconds)
        for remaining in stride(from: seconds, through: 1, by: -1) {
            countdownRemaining = remaining
            appDelegate.countdownOverlay.update(remaining)
            // Tick in tenths so a cancel takes effect promptly, not at the
            // next whole second.
            for _ in 0..<10 {
                if countdownCancelled { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if countdownCancelled {
                appDelegate.countdownOverlay.hide()
                countdownRemaining = nil
                return false
            }
        }
        appDelegate.countdownOverlay.hide()

        countdownRemaining = nil
        return true
    }

    private func refreshDevices(includeScreenCaptureContent: Bool = false) async {
        await deviceManager.refreshAllDevices(includeScreenCaptureContent: includeScreenCaptureContent)

        restoreSavedSelections()

        if selectedDisplay == nil || !deviceManager.displays.contains(where: { $0.id == selectedDisplay?.id }) {
            selectedDisplay = deviceManager.displays.first
        }

        if includeScreenCaptureContent,
           selectedWindow == nil || !deviceManager.windows.contains(where: { $0.id == selectedWindow?.id }) {
            selectedWindow = deviceManager.windows.first
        }
    }

    /// Re-applies the user's last-used camera/mic/display so reopening the app
    /// lands on the same setup. Only fills selections that aren't already set,
    /// so it never overrides a choice the user just made this session.
    private func restoreSavedSelections() {
        if selectedDisplay == nil,
           let savedID = settings.lastDisplayID,
           let displayID = CGDirectDisplayID(savedID),
           let display = deviceManager.display(withID: displayID) {
            selectedDisplay = display
        }

        if selectedCamera == nil,
           let savedID = settings.lastCameraID,
           let camera = deviceManager.camera(withID: savedID) {
            selectedCamera = camera
        }

        if selectedMicrophone == nil,
           let savedID = settings.lastMicrophoneID,
           let microphone = deviceManager.microphone(withID: savedID) {
            selectedMicrophone = microphone
        }
    }
    private func suggestedVideoName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH-mm"
        return "Recording \(formatter.string(from: Date()))"
    }

    private var currentScreenPreviewTarget: ScreenPreviewManager.Target? {
        switch recordMode {
        case .fullScreen:
            guard let selectedDisplay else { return nil }
            return .display(selectedDisplay)
        case .specificWindow:
            guard let selectedWindow else { return nil }
            return .window(selectedWindow)
        case .area:
            guard let selectedDisplay else { return nil }
            // Preview just the chosen region; fall back to the full display
            // until the user has dragged one out.
            if let region = selectedRegion {
                return .area(selectedDisplay, region.rect)
            }
            return .display(selectedDisplay)
        }
    }

    private var screenPreviewHint: String {
        switch recordMode {
        case .fullScreen:
            return selectedDisplay == nil ? "Choose a display to see a live preview." : "Live preview at ~30fps. Pauses while recording."
        case .specificWindow:
            return selectedWindow == nil ? "Load windows and choose one to see a live preview." : "Live preview at ~30fps. Pauses while recording."
        case .area:
            return selectedRegion == nil ? "Select an area to record." : "Recording the selected \(selectedRegion?.displayString ?? "") region."
        }
    }

    private var cameraGuidanceText: String {
        switch deviceManager.cameraPermissionStatus {
        case .authorized:
            return "Choose a camera to show a live webcam preview before recording."
        case .notDetermined:
            return "Camera permission has not been granted yet. Use Permissions to enable webcam preview."
        default:
            return "Camera permission is missing. Use Permissions to enable webcam preview."
        }
    }

    private var microphoneGuidanceText: String {
        switch deviceManager.microphonePermissionStatus {
        case .authorized:
            return "Choose a microphone to show live input levels before recording."
        case .notDetermined:
            return "Microphone permission has not been granted yet. Use Permissions to enable input levels."
        default:
            return "Microphone permission is missing. Use Permissions to enable input levels."
        }
    }

    private func previewSelectedSource() {
        // If there's nothing to preview yet (e.g. user switched to specific
        // window before loading the window list), clear instead of triggering
        // an error-state capture.
        guard let target = currentScreenPreviewTarget else {
            screenPreviewManager.clear()
            return
        }
        Task {
            await screenPreviewManager.capturePreview(for: target)
        }
    }

    private func startLiveScreenPreview() {
        guard !appDelegate.isRecording else { return }
        guard let target = currentScreenPreviewTarget else {
            Task { await screenPreviewManager.stopLive() }
            screenPreviewManager.clear()
            return
        }
        Task {
            await screenPreviewManager.startLive(for: target)
        }
    }
}

#Preview {
    MainWindowView()
        .environmentObject(AppDelegate())
}
