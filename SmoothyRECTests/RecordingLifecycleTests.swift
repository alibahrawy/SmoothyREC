import XCTest
import Combine
import AVFoundation
@testable import SmoothyREC

@MainActor
final class RecordingLifecycleTests: XCTestCase {
    func testUsageCountsRealStartsAndSuccessfulActionsOnce() async throws {
        let f = try Fixture()
        try await f.start()
        XCTAssertEqual(f.usage.events.filter { $0 == .recordingStart }.count, 1)
        for feature in [RecorderFeature.recordScreen, .recordCamera, .recordMicrophone, .recordCursor] {
            XCTAssertTrue(f.usage.events.contains(feature))
        }
        await f.coordinator.pause(); await f.coordinator.pause()
        await f.coordinator.resume(); await f.coordinator.resume()
        _ = try await f.coordinator.stop(); _ = try await f.coordinator.stop()
        await f.coordinator.discard()
        for feature in [RecorderFeature.recordingPause, .recordingResume, .recordingSave] {
            XCTAssertEqual(f.usage.events.filter { $0 == feature }.count, 1)
        }
        XCTAssertFalse(f.usage.events.contains(.recordingDiscard))
    }

    func testFailedCaptureAndFailedSaveDoNotReportSuccess() async throws {
        let failed = try Fixture(microphone: false, camera: false)
        failed.screen.startError = TestFailure.encoder
        do { try await failed.start(); XCTFail("Expected capture failure") } catch {}
        XCTAssertTrue(failed.usage.events.isEmpty)
        let f = try Fixture(microphone: false, camera: false)
        try await f.start()
        f.screen.stopError = TestFailure.encoder
        do { _ = try await f.coordinator.stop(); XCTFail("Expected save failure") } catch {}
        XCTAssertTrue(f.usage.events.contains(.recordingStart))
        XCTAssertFalse(f.usage.events.contains(.recordingSave))
        XCTAssertFalse(f.usage.events.contains(.recordingRecover))
    }

    func testFailedOptionalTrackAndDiscardAreMeasuredHonestly() async throws {
        let f = try Fixture()
        f.mic.startError = TestFailure.encoder
        try await f.start()
        XCTAssertFalse(f.usage.events.contains(.recordMicrophone))
        await f.coordinator.discard(); await f.coordinator.discard()
        XCTAssertEqual(f.usage.events.filter { $0 == .recordingDiscard }.count, 1)
        XCTAssertFalse(f.usage.events.contains(.recordingSave))
    }

    func testRepeatedStopSharesFinalizationAndRetainsFiles() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let entered = expectation(description: "Stop entered")
        var release: CheckedContinuation<Void, Never>?
        fixture.screen.onStop = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let first = Task { try await fixture.coordinator.stop() }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await fixture.coordinator.stop() }
        release?.resume()
        let result = try await first.value
        let repeated = try await second.value
        XCTAssertEqual(result.allURLs, repeated.allURLs)
        XCTAssertEqual(fixture.screen.stopCount, 1)
        await fixture.coordinator.discard() // A stale UI event cannot delete a saved take.
        XCTAssertTrue(result.allURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(fixture.screen.discardCount, 0)
    }

    func testFailedSavePreservesPartsAndDoesNotRetryOrDiscard() async throws {
        let fixture = try Fixture(microphone: false, camera: false)
        try await fixture.start()
        let directory = try XCTUnwrap(fixture.coordinator.currentSessionDirectory)
        let part = directory.appendingPathComponent("part1.mp4")
        try Data("recoverable footage".utf8).write(to: part)
        fixture.screen.stopError = TestFailure.encoder
        for _ in 0..<2 {
            do { _ = try await fixture.coordinator.stop(); XCTFail("Expected failure") }
            catch { XCTAssertTrue(error is CoordinatorError) }
        }
        await fixture.coordinator.discard()
        XCTAssertEqual(fixture.screen.stopCount, 1)
        XCTAssertEqual(fixture.screen.discardCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path))
        XCTAssertEqual(fixture.coordinator.recoveryDirectory, directory)
        XCTAssertFalse(fixture.coordinator.isStopping)
    }

    func testScreenFailureAutomaticallySavesOtherTracksWithWarning() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let finished = expectation(description: "Recovery finished")
        var recovered: RecordingResult?
        let subscription = fixture.coordinator.$state.sink {
            if case .finished(let result) = $0 { recovered = result; finished.fulfill() }
        }
        fixture.screen.stopError = TestFailure.encoder
        fixture.screen.state = .failed(TestFailure.encoder)
        await fulfillment(of: [finished], timeout: 3)
        let result = try XCTUnwrap(recovered)
        XCTAssertEqual(fixture.usage.events.filter { $0 == .recordingRecover }.count, 1)
        XCTAssertFalse(fixture.usage.events.contains(.recordingSave))
        XCTAssertNil(result.screenRecordingURL)
        XCTAssertNotNil(result.microphoneRecordingURL)
        XCTAssertNotNil(result.cameraRecordingURL)
        XCTAssertTrue(result.warnings.contains { $0.component == .screen })
        XCTAssertEqual(fixture.mic.discardCount + fixture.camera.discardCount, 0)
        XCTAssertTrue(result.allURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        withExtendedLifetime(subscription) {}
    }

    func testFailedMicrophoneIsStillStoppedAndReported() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        fixture.mic.state = .failed(TestFailure.encoder)
        fixture.mic.stopError = TestFailure.encoder
        let result = try await fixture.coordinator.stop()
        XCTAssertEqual(fixture.mic.stopCount, 1)
        XCTAssertFalse(fixture.mic.isCapturing)
        XCTAssertNil(result.microphoneRecordingURL)
        XCTAssertTrue(result.warnings.contains { $0.component == .microphone })
        XCTAssertNotNil(result.screenRecordingURL)
    }

    func testOptionalStartupFailureRemainsAWarning() async throws {
        let fixture = try Fixture()
        fixture.mic.startError = TestFailure.encoder
        try await fixture.start()
        let result = try await fixture.coordinator.stop()
        XCTAssertTrue(result.warnings.contains { $0.component == .microphone })
        XCTAssertEqual(fixture.mic.stopCount, 0)
        XCTAssertNotNil(result.screenRecordingURL)
    }

    func testSyncOffsetSurvivesRecorderCleanup() async throws {
        let fixture = try Fixture()
        fixture.mic.onStart = { [weak fixture] syncTime in
            fixture?.screen.captureAnchor = syncTime + CMTime(seconds: 0.375, preferredTimescale: 600)
        }
        try await fixture.start()
        let result = try await fixture.coordinator.stop()
        XCTAssertNil(fixture.screen.captureAnchor)
        XCTAssertEqual(result.screenStartOffset, 0.375, accuracy: 0.0001)
    }

    func testStopWaitsForPauseWithoutResurrectingSession() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let entered = expectation(description: "Pause entered")
        var release: CheckedContinuation<Void, Never>?
        fixture.screen.onPause = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let pause = Task { await fixture.coordinator.pause() }
        await fulfillment(of: [entered], timeout: 2)
        let stop = Task { try await fixture.coordinator.stop() }
        await Task.yield()
        XCTAssertEqual(fixture.screen.stopCount, 0)
        release?.resume()
        await pause.value
        _ = try await stop.value
        guard case .finished = fixture.coordinator.state else { return XCTFail("Expected finished") }
        XCTAssertFalse(fixture.mic.isCapturing)
    }

    func testStopDuringResumeDoesNotRestartFinishedSession() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        await fixture.coordinator.pause()
        let entered = expectation(description: "Resume entered")
        var release: CheckedContinuation<Void, Never>?
        fixture.screen.onResume = {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }
        let resume = Task { await fixture.coordinator.resume() }
        await fulfillment(of: [entered], timeout: 2)
        let stop = Task { try await fixture.coordinator.stop() }
        await Task.yield()
        release?.resume()
        await resume.value
        _ = try await stop.value
        guard case .finished = fixture.coordinator.state else { return XCTFail("Expected finished") }
        XCTAssertFalse(fixture.camera.isCapturing)
    }

    func testExplicitDiscardDeletesOnlyCurrentTake() async throws {
        let fixture = try Fixture()
        try await fixture.start()
        let saved = try await fixture.coordinator.stop()
        try await fixture.start(microphone: false, camera: false)
        let current = try XCTUnwrap(fixture.coordinator.currentSessionDirectory)
        await fixture.coordinator.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(saved.allURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(fixture.mic.discardCount + fixture.camera.discardCount, 0)
        XCTAssertEqual(fixture.coordinator.state, .idle)
    }
}

@MainActor
private final class UsageLog { var events: [RecorderFeature] = [] }

private enum TestFailure: LocalizedError {
    case encoder
    var errorDescription: String? { "Synthetic encoder failure" }
}

@MainActor
private final class Fixture {
    let screen = FakeScreen()
    let mic = FakeMic()
    let camera = FakeCamera()
    let coordinator: RecordingCoordinator
    let usage = UsageLog()
    let directory: URL
    let microphone: Bool
    let includeCamera: Bool

    init(microphone: Bool = true, camera: Bool = true) throws {
        self.microphone = microphone
        self.includeCamera = camera
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmoothyRecLifecycle-\(UUID())")
        coordinator = RecordingCoordinator(screenRecorder: screen, micRecorder: mic, cameraRecorder: self.camera, outputDirectory: directory, trackUsage: { [usage] in usage.events.append($0) })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func start(microphone: Bool? = nil, camera: Bool? = nil) async throws {
        try await coordinator.start(configuration: RecordingSessionConfiguration(
            videoName: "Test Take", recordTarget: .fullScreen(Display(id: 1, name: "Test", width: 320, height: 180, isMain: true)),
            includeSystemAudio: false,
            selectedMicrophone: (microphone ?? self.microphone) ? Microphone(id: "test", name: "Test", uniqueID: "test", isBuiltIn: false, supportedSampleRates: [48000], inputChannels: 1) : nil,
            selectedCamera: (camera ?? includeCamera) ? Camera(id: "test", name: "Test", uniqueID: "test", isBuiltIn: false, position: .unspecified, formats: []) : nil,
            quality: .low, frameRate: .fps30))
    }
}

@MainActor
private final class FakeScreen: ScreenRecording {
    @Published var state: RecordingState = .idle
    var statePublisher: AnyPublisher<RecordingState, Never> { $state.eraseToAnyPublisher() }
    var captureAnchor: CMTime?
    var supportsPause = true
    var url: URL!
    var startError: Error?
    var stopError: Error?
    var stopCount = 0
    var discardCount = 0
    var onStop: (() async -> Void)?
    var onPause: (() async -> Void)?
    var onResume: (() async -> Void)?
    func startRecording(configuration: RecordingConfiguration) async throws {
        if let startError { throw startError }
        url = configuration.outputDirectory.appendingPathComponent("screen.mp4")
        try Data("screen".utf8).write(to: url)
        captureAnchor = CMClockGetTime(CMClockGetHostTimeClock())
        state = .recording(startTime: Date())
    }
    func stopRecording() async throws -> URL {
        stopCount += 1
        await onStop?()
        captureAnchor = nil
        if let stopError { throw stopError }
        state = .finished(url)
        return url
    }
    func discardRecording() async { discardCount += 1; try? FileManager.default.removeItem(at: url); state = .idle }
    func pauseRecording() async { state = .paused; await onPause?() }
    func resumeRecording() async { await onResume?(); state = .recording(startTime: Date()) }
}

@MainActor
private final class FakeMic: MicrophoneRecording {
    @Published var state: MicRecorderState = .idle
    var statePublisher: AnyPublisher<MicRecorderState, Never> { $state.eraseToAnyPublisher() }
    var url: URL!
    var startError: Error?
    var stopError: Error?
    var stopCount = 0
    var discardCount = 0
    var isCapturing = false
    var onStart: ((CMTime) -> Void)?
    func startRecording(configuration: MicrophoneConfiguration, syncTime: CMTime) async throws {
        if let startError { state = .failed(startError); throw startError }
        url = configuration.outputDirectory.appendingPathComponent("mic.m4a")
        try Data("mic".utf8).write(to: url)
        onStart?(syncTime)
        isCapturing = true
        state = .recording(startTime: Date())
    }
    func stopRecording() async throws -> URL {
        stopCount += 1; isCapturing = false
        if let stopError { throw stopError }
        state = .finished(url)
        return url
    }
    func discardRecording() async { discardCount += 1; isCapturing = false; try? FileManager.default.removeItem(at: url); state = .idle }
    func pauseRecording() {}
    func resumeRecording() {}
}

@MainActor
private final class FakeCamera: CameraRecording {
    @Published var state: CameraRecorderState = .idle
    var statePublisher: AnyPublisher<CameraRecorderState, Never> { $state.eraseToAnyPublisher() }
    var currentFrame: CGImage? { nil }
    var url: URL!
    var discardCount = 0
    var isCapturing = false
    func startRecording(configuration: CameraConfiguration, syncTime: CMTime) async throws {
        url = configuration.outputDirectory.appendingPathComponent("camera.mov")
        try Data("camera".utf8).write(to: url)
        isCapturing = true; state = .recording(startTime: Date())
    }
    func stopRecording() async throws -> URL { isCapturing = false; state = .finished(url); return url }
    func discardRecording() async { discardCount += 1; isCapturing = false; try? FileManager.default.removeItem(at: url); state = .idle }
    func pauseRecording() {}
    func resumeRecording() {}
}
