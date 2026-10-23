import Foundation

/// Stable operation IDs. Never include recording metadata in a report.
enum RecorderFeature: String, CaseIterable {
    case appLaunch = "app_launch", heartbeat
    case recordingStart = "recording_start"
    case recordScreen = "record_screen", recordWindow = "record_window", recordArea = "record_area"
    case recordCamera = "record_camera", recordMicrophone = "record_microphone"
    case recordSystemAudio = "record_system_audio", recordCursor = "record_cursor"
    case recordingSave = "recording_save", recordingRecover = "recording_recover"
    case recordingPause = "recording_pause", recordingResume = "recording_resume", recordingDiscard = "recording_discard"
    case pipExport = "pip_export", fileCompress = "file_compress", recordingPreview = "recording_preview"
}

@MainActor
final class RecorderTelemetry {
    static let enabledKey = "anonymousUsageEnabled"
    static let shared = RecorderTelemetry()
    private let defaults: UserDefaults
    private let environment: [String: String]
    private let version: String
    private let send: (URLRequest) async throws -> Void
    private var started = false
    private var timer: Timer?
    private var pending: [UUID: Task<Void, Never>] = [:]
    private var previewed = Set<URL>() // Local memory only; never encoded.

    init(defaults: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         version: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
         send: ((URLRequest) async throws -> Void)? = nil) {
        self.defaults = defaults
        self.environment = environment
        self.version = version
        self.send = send ?? { request in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            _ = try await session.data(for: request)
        }
    }

    var environmentDisabled: Bool {
        environment["SMOOTHY_TELEMETRY"] == "0" || environment["XCTestConfigurationFilePath"] != nil
    }
    var enabled: Bool { !environmentDisabled && (defaults.object(forKey: Self.enabledKey) as? Bool ?? true) }

    func start() {
        guard !started else { return }
        started = true
        track(.appLaunch)
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.track(.heartbeat) }
        }
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.enabledKey)
        if !value {
            pending.values.forEach { $0.cancel() }
            pending.removeAll()
        }
    }

    func trackPreview(_ url: URL) {
        guard enabled, previewed.insert(url).inserted else { return }
        track(.recordingPreview)
    }

    func track(_ feature: RecorderFeature) {
        guard enabled, pending.count < 32 else { return }
        let key = "smoothyrecAnonymousInstallId"
        let installId: String
        if let saved = defaults.string(forKey: key), UUID(uuidString: saved) != nil { installId = saved }
        else { installId = UUID().uuidString; defaults.set(installId, forKey: key) }
        let id = UUID()
        let payload = ["id": id.uuidString, "installId": installId, "feature": feature.rawValue, "appVersion": version]
        guard let body = try? JSONEncoder().encode(payload) else { return }
        var request = URLRequest(url: URL(string: "https://smoothyedit.com/api/smoothyrec/telemetry")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 5
        pending[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.pending[id] = nil }
            guard self.enabled, !Task.isCancelled else { return }
            try? await self.send(request)
        }
    }

    /// Tests can await mocked transports; recording operations never wait on this.
    func flush() async {
        for task in Array(pending.values) { await task.value }
    }
    func stop() {
        timer?.invalidate(); timer = nil
        pending.values.forEach { $0.cancel() }; pending.removeAll()
    }
}
