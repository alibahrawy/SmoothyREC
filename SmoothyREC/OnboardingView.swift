//
//  OnboardingView.swift
//  SmoothyREC
//
//  Discord-style step-by-step permission onboarding
//

import SwiftUI
import AVFoundation
import ScreenCaptureKit

enum PermissionState: Equatable {
    case notDetermined
    case authorized
    case denied

    var isGranted: Bool {
        self == .authorized
    }

    var displayName: String {
        switch self {
        case .notDetermined:
            return "Not Checked"
        case .authorized:
            return "Access Granted"
        case .denied:
            return "Access Denied"
        }
    }

    var statusColor: Color {
        switch self {
        case .notDetermined:
            return .secondary
        case .authorized:
            return .green
        case .denied:
            return .orange
        }
    }
}

enum PermissionType: Int, CaseIterable, Identifiable {
    case screenRecording = 0
    case camera = 1
    case microphone = 2

    var id: Int { rawValue }

    var icon: String {
        switch self {
        case .screenRecording:
            return "desktopcomputer"
        case .camera:
            return "video.fill"
        case .microphone:
            return "mic.fill"
        }
    }

    var title: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        }
    }

    var description: String {
        switch self {
        case .screenRecording:
            return "SmoothyREC needs this permission to capture your screen. This is required to record your display."
        case .camera:
            return "This permission is needed to include your webcam as a picture-in-picture overlay in recordings."
        case .microphone:
            return "This permission is required if you want to record your voice narration or audio commentary."
        }
    }

    var settingsURL: URL? {
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .camera:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @State private var permissionStates: [PermissionType: PermissionState] = [
        .screenRecording: .notDetermined,
        .camera: .notDetermined,
        .microphone: .notDetermined
    ]
    @State private var currentStep: PermissionType = .screenRecording
    @State private var isCheckingPermissions = false
    @State private var isPolling = false
    @State private var hasInteracted: [PermissionType: Bool] = [
        .screenRecording: false,
        .camera: false,
        .microphone: false
    ]
    @State private var showingAlreadyGrantedConfirmation = false

    var onComplete: () -> Void

    private var allPermissionsResolved: Bool {
        PermissionType.allCases.allSatisfy { type in
            let state = permissionStates[type] ?? .notDetermined
            let interacted = hasInteracted[type] ?? false
            return interacted && (state == .authorized || state == .denied)
        }
    }

    private var hasScreenRecordingPermission: Bool {
        permissionStates[.screenRecording] == .authorized
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            ScrollView {
                VStack(spacing: 16) {
                    introText

                    screenRecordingSection

                    ForEach([PermissionType.camera, .microphone]) { type in
                        PermissionRow(
                            type: type,
                            state: permissionStates[type] ?? .notDetermined,
                            hasInteracted: hasInteracted[type] ?? false,
                            isActive: currentStep == type,
                            isChecking: isCheckingPermissions && currentStep == type,
                            onRequest: { await requestPermission(for: type) },
                            onCheck: { await checkPermission(for: type) }
                        )
                    }

                    reopenNote
                }
                .padding(24)
            }

            Divider()

            bottomActionView
        }
        .frame(minWidth: 520, idealWidth: 520, maxWidth: 520,
               minHeight: 680, idealHeight: 680, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            // Use silent preflight check for screen recording (doesn't trigger dialog)
            // SCShareableContent triggers dialog even when already granted (macOS bug FB22261705)
            Task {
                let screenGranted = CGPreflightScreenCaptureAccess()
                await MainActor.run {
                    permissionStates[.screenRecording] = screenGranted ? .authorized : .notDetermined
                    if screenGranted {
                        hasInteracted[.screenRecording] = true
                    }
                }
                await checkCameraState()
                await checkMicrophoneState()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task {
                await handleAppBecameActive()
            }
        }
        .alert("Already Granted?", isPresented: $showingAlreadyGrantedConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Yes, I've Enabled It", role: .none) {
                markScreenRecordingAsGranted()
            }
            Button("Open System Settings", role: .none) {
                openScreenRecordingSettings()
            }
        } message: {
            Text("If you've already added SmoothyREC to Screen Recording in System Settings but macOS keeps asking, you can mark this as granted. The app will work on the next launch.")
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            Image(systemName: "record.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)

            VStack(spacing: 4) {
                Text("Welcome to SmoothyREC")
                    .font(.system(size: 20, weight: .semibold))

                Text("Review App Permissions")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 32)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(Color(.controlBackgroundColor))
    }

    private var introText: some View {
        Text("SmoothyREC requires explicit permissions to offer certain functions. Click each permission below to review and grant it. You must interact with each one before continuing.")
            .font(.system(size: 13))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var screenRecordingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: PermissionType.screenRecording.icon)
                    .font(.system(size: 20))
                    .foregroundColor(currentStep == .screenRecording ? .blue : .secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(PermissionType.screenRecording.title)
                        .font(.system(size: 15, weight: .semibold))

                    Text(PermissionType.screenRecording.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if hasScreenRecordingPermission {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Access Granted")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                        }
                        .padding(.top, 4)
                    }
                }

                Spacer()
            }

            VStack(spacing: 8) {
                HStack {
                    Spacer()

                    if hasScreenRecordingPermission {
                        Button(action: {}) {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                Text("Access Granted")
                            }
                            .frame(minWidth: 160)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.green)
                        .disabled(true)
                    } else {
                        VStack(spacing: 8) {
                            Button(action: {
                                Task {
                                    hasInteracted[.screenRecording] = true
                                    currentStep = .screenRecording
                                    openScreenRecordingSettings()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    if isCheckingPermissions {
                                        ProgressView()
                                            .controlSize(.small)
                                            .scaleEffect(0.8)
                                    }
                                    Text("Open System Settings")
                                }
                                .frame(minWidth: 160)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.blue)
                            .disabled(isCheckingPermissions)

                            Button(action: {
                                Task {
                                    await requestScreenRecording()
                                }
                            }) {
                                Text("Ask macOS to Add SmoothyREC")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                showingAlreadyGrantedConfirmation = true
                            }) {
                                Text("I Already Granted This")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // macOS Bug Warning
                if !hasScreenRecordingPermission && (hasInteracted[.screenRecording] ?? false) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                        Text("If System Settings already shows SmoothyREC enabled, do not remove and re-add it repeatedly. For local debug builds, macOS can treat each rebuild as a new app unless it is signed with a stable certificate.")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }
            }
        }
        .padding(16)
        .background(currentStep == .screenRecording ? Color.accentColor.opacity(0.05) : Color(.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    hasScreenRecordingPermission ? Color.green.opacity(0.3) :
                        (currentStep == .screenRecording ? Color.blue.opacity(0.5) : Color.gray.opacity(0.2)),
                    lineWidth: hasScreenRecordingPermission ? 1 : 2
                )
        )
    }

    private var reopenNote: some View {
        Text("You can re-open this dialog via the SmoothyREC menu bar icon anytime.")
            .font(.system(size: 12))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 8)
    }

    private var bottomActionView: some View {
        VStack(spacing: 12) {
            Button(action: {
                completeOnboarding()
            }) {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.blue)
            .disabled(!allPermissionsResolved && !hasScreenRecordingPermission)

            permissionsSummary
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
    }

    private var permissionsSummary: some View {
        let grantedCount = permissionStates.values.filter { $0 == .authorized }.count
        let total = PermissionType.allCases.count
        let interactedCount = hasInteracted.values.filter { $0 }.count

        return HStack(spacing: 4) {
            if hasScreenRecordingPermission {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Screen recording ready")
                    .foregroundColor(.green)
            } else if interactedCount < total {
                Image(systemName: "hand.point.right.fill")
                    .foregroundColor(.blue)
                Text("\(interactedCount) of \(total) reviewed — click each permission above")
                    .foregroundColor(.blue)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.orange)
                Text("\(grantedCount) of \(total) granted")
                    .foregroundColor(.orange)
            }
        }
        .font(.system(size: 12))
    }

    private func requestScreenRecording() async {
        hasInteracted[.screenRecording] = true
        currentStep = .screenRecording

        if CGPreflightScreenCaptureAccess() {
            markScreenRecordingAsGranted()
            return
        }

        // CGRequestScreenCaptureAccess() is the correct API to call when the user
        // explicitly asks to grant permission. It shows the one-time system dialog
        // that (re-)adds the app to the Screen Recording list in System Settings.
        // This is intentional — unlike CGPreflightScreenCaptureAccess, it CAN show a prompt.
        // We only call it here, where the user has explicitly pressed the button.
        CGRequestScreenCaptureAccess()

        // After the "add to list" prompt, open Settings so the user can toggle on
        openScreenRecordingSettings()
    }

    private func openScreenRecordingSettings() {
        guard let url = PermissionType.screenRecording.settingsURL else { return }
        NSWorkspace.shared.open(url)
        isPolling = true

        // Start polling for permission change (uses CGPreflightScreenCaptureAccess — silent)
        Task {
            await pollScreenRecordingPermission()
        }
    }

    private func markScreenRecordingAsGranted() {
        hasInteracted[.screenRecording] = true
        permissionStates[.screenRecording] = .authorized
        currentStep = .camera
    }

    private func pollScreenRecordingPermission() async {
        // Poll every 1.5 seconds for up to 45 seconds using CGPreflightScreenCaptureAccess.
        // This is a silent query — it never triggers the permission dialog.
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            await checkScreenRecordingState()

            let state = permissionStates[.screenRecording] ?? .notDetermined
            if state == .authorized {
                isPolling = false
                return
            }
        }
        isPolling = false
    }

    private func checkScreenRecordingState() async {
        // Use CGPreflightScreenCaptureAccess for silent check — SCShareableContent
        // triggers the permission popup even when permission is already granted
        // (macOS bug FB22261705). CGPreflight never shows a dialog.
        let hasPermission = CGPreflightScreenCaptureAccess()
        await MainActor.run {
            permissionStates[.screenRecording] = hasPermission ? .authorized : .notDetermined
        }
    }

    private func checkCameraState() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        await MainActor.run {
            switch status {
            case .authorized:
                permissionStates[.camera] = .authorized
                hasInteracted[.camera] = true
            case .denied, .restricted:
                permissionStates[.camera] = .denied
            case .notDetermined:
                permissionStates[.camera] = .notDetermined
            @unknown default:
                permissionStates[.camera] = .notDetermined
            }
        }
    }

    private func checkMicrophoneState() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        await MainActor.run {
            switch status {
            case .authorized:
                permissionStates[.microphone] = .authorized
                hasInteracted[.microphone] = true
            case .denied, .restricted:
                permissionStates[.microphone] = .denied
            case .notDetermined:
                permissionStates[.microphone] = .notDetermined
            @unknown default:
                permissionStates[.microphone] = .notDetermined
            }
        }
    }

    private func updateCurrentStep() {
        for type in PermissionType.allCases {
            let interacted = hasInteracted[type] ?? false
            if !interacted {
                currentStep = type
                return
            }
        }
    }

    private func requestPermission(for type: PermissionType) async {
        hasInteracted[type] = true
        currentStep = type

        switch type {
        case .screenRecording:
            await requestScreenRecording()
        case .camera:
            await requestCamera()
        case .microphone:
            await requestMicrophone()
        }

        updateCurrentStep()
    }

    private func requestCamera() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        await MainActor.run {
            permissionStates[.camera] = granted ? .authorized : .denied
        }
    }

    private func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        await MainActor.run {
            permissionStates[.microphone] = granted ? .authorized : .denied
        }
    }

    private func checkPermission(for type: PermissionType) async {
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }
        currentStep = type

        switch type {
        case .screenRecording:
            await checkScreenRecordingState()
        case .camera:
            await checkCameraState()
        case .microphone:
            await checkMicrophoneState()
        }
    }

    private func handleAppBecameActive() async {
        if isPolling {
            // Polling handles it
            return
        }

        // When app becomes active, check if screen recording permission was granted
        // but don't trigger a new dialog
        if hasInteracted[.screenRecording] == true {
            await checkScreenRecordingState()
        }
    }

    private func completeOnboarding() {
        onComplete()
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let state: PermissionState
    let hasInteracted: Bool
    let isActive: Bool
    let isChecking: Bool
    let onRequest: () async -> Void
    let onCheck: () async -> Void

    @State private var isProcessing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: type.icon)
                    .font(.system(size: 20))
                    .foregroundColor(isActive ? .blue : .secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(type.title)
                        .font(.system(size: 15, weight: .semibold))

                    Text(type.description)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                statusIndicator
            }

            HStack {
                Spacer()

                if state == .authorized {
                    Button(action: {}) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Access Granted")
                        }
                        .frame(minWidth: 160)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .foregroundColor(.green)
                    .disabled(true)
                } else {
                    Button(action: {
                        Task {
                            isProcessing = true
                            await onRequest()
                            isProcessing = false
                        }
                    }) {
                        HStack(spacing: 6) {
                            if isProcessing || isChecking {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            }
                            Text(hasInteracted ? "Check Again" : "Grant Access")
                        }
                        .frame(minWidth: 160)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)
                }
            }
        }
        .padding(16)
        .background(isActive ? Color.accentColor.opacity(0.05) : Color(.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: state == .authorized ? 1 : 1)
        )
    }

    private var statusIndicator: some View {
        HStack(spacing: 4) {
            Image(systemName: statusIcon)
                .font(.system(size: 12))
            Text(state.displayName)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(state.statusColor)
    }

    private var statusIcon: String {
        switch state {
        case .notDetermined:
            return "circle"
        case .authorized:
            return "checkmark.circle.fill"
        case .denied:
            return "xmark.circle.fill"
        }
    }

    private var borderColor: Color {
        switch state {
        case .authorized:
            return .green.opacity(0.3)
        case .denied:
            return .orange.opacity(0.3)
        case .notDetermined:
            return isActive ? .blue.opacity(0.5) : Color.gray.opacity(0.2)
        }
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .environmentObject(AppDelegate())
}
