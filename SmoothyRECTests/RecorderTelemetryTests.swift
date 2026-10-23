import XCTest
@testable import SmoothyREC

@MainActor
final class RecorderTelemetryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "SmoothyrecTelemetryTest-\(UUID())")!
    }

    func testReportsOnlyStableAnonymousFieldsAndKeepsInstallationAcrossUpdates() async throws {
        let store = defaults()
        var requests: [URLRequest] = []
        let first = RecorderTelemetry(defaults: store, environment: [:], version: "1.1.0", send: { requests.append($0) })
        first.start(); first.start()
        await first.flush(); first.stop()
        let updated = RecorderTelemetry(defaults: store, environment: [:], version: "1.2.0", send: { requests.append($0) })
        updated.track(.recordingSave)
        await updated.flush()
        XCTAssertEqual(requests.count, 2)
        let payloads = try requests.map { request -> [String: String] in
            XCTAssertEqual(request.url?.absoluteString, "https://smoothyedit.com/api/smoothyrec/telemetry")
            XCTAssertEqual(request.httpMethod, "POST")
            let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(Set(payload.keys), ["id", "installId", "feature", "appVersion"])
            XCTAssertNotNil(UUID(uuidString: payload["id"]!))
            return payload
        }
        XCTAssertEqual(payloads[0]["feature"], "app_launch")
        XCTAssertEqual(payloads[1]["feature"], "recording_save")
        XCTAssertEqual(payloads[0]["installId"], payloads[1]["installId"])
        XCTAssertNotEqual(payloads[0]["id"], payloads[1]["id"])
    }

    func testOptOutAndTestEnvironmentNeverSendOrCreateInstallationIds() async {
        for environment in [["SMOOTHY_TELEMETRY": "0"], ["XCTestConfigurationFilePath": "fixture"], [:]] {
            let store = defaults()
            var sends = 0
            let telemetry = RecorderTelemetry(defaults: store, environment: environment, send: { _ in sends += 1 })
            if environment.isEmpty { telemetry.setEnabled(false) }
            telemetry.start(); telemetry.track(.recordingStart)
            await telemetry.flush(); telemetry.stop()
            XCTAssertEqual(sends, 0)
            XCTAssertNil(store.string(forKey: "smoothyrecAnonymousInstallId"))
        }
    }

    func testPreviewDeduplicatesEachOutputAndNeverEncodesItsPath() async throws {
        var payloads: [String] = []
        let telemetry = RecorderTelemetry(defaults: defaults(), environment: [:], send: { payloads.append(String(data: $0.httpBody!, encoding: .utf8)!) })
        let url = URL(fileURLWithPath: "/private/secret/recording.mov")
        telemetry.trackPreview(url); telemetry.trackPreview(url)
        telemetry.trackPreview(URL(fileURLWithPath: "/private/secret/second.mov"))
        await telemetry.flush()
        XCTAssertEqual(payloads.count, 2)
        XCTAssertFalse(payloads.joined().contains("secret"))
    }

    func testAnalyticsFailuresNeverEscapeAndDisablingCancelsQueuedReports() async {
        var sends = 0
        let telemetry = RecorderTelemetry(defaults: defaults(), environment: [:], send: { _ in sends += 1; throw URLError(.notConnectedToInternet) })
        telemetry.track(.recordingSave)
        await telemetry.flush()
        XCTAssertEqual(sends, 1)
        telemetry.track(.pipExport)
        telemetry.setEnabled(false)
        await telemetry.flush()
        XCTAssertEqual(sends, 1)
    }
}
