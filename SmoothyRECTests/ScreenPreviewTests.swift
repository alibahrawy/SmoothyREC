import XCTest
import CoreGraphics
@testable import SmoothyREC

@MainActor
final class ScreenPreviewTests: XCTestCase {
    private let target = ScreenPreviewManager.Target.display(Display(id: 1, name: "One", width: 320, height: 180, isMain: true))

    func testDisabledPreviewDoesNotCaptureOrStartStream() async {
        var snapshots = 0
        var streams = 0
        let manager = ScreenPreviewManager(makeLiveStream: { streams += 1; return FakePreviewStream() }, snapshotProvider: { _ in
            snapshots += 1
            return Self.image()
        })
        await manager.startLive(for: target)
        await manager.capturePreview(for: target)
        XCTAssertEqual(snapshots, 0)
        XCTAssertEqual(streams, 0)
        XCTAssertFalse(manager.isLive)
    }

    func testDisableDuringSnapshotPreventsLateStreamStartup() async {
        let entered = expectation(description: "Snapshot entered")
        var release: CheckedContinuation<CGImage, Never>?
        var streams = 0
        let manager = ScreenPreviewManager(makeLiveStream: { streams += 1; return FakePreviewStream() }, snapshotProvider: { _ in
            await withCheckedContinuation { release = $0; entered.fulfill() }
        })
        manager.setEnabled(true)
        let start = Task { await manager.startLive(for: target) }
        await fulfillment(of: [entered], timeout: 2)
        manager.setEnabled(false)
        release?.resume(returning: Self.image())
        await start.value
        XCTAssertEqual(streams, 0)
        XCTAssertNil(manager.image)
        XCTAssertFalse(manager.isLive)
    }

    func testDisableDuringStreamStartupStopsLateCaptureAndFrames() async {
        let stream = FakePreviewStream()
        let entered = expectation(description: "Stream entered")
        var release: CheckedContinuation<Void, Never>?
        stream.onStart = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        let manager = ScreenPreviewManager(makeLiveStream: { stream }, snapshotProvider: { _ in Self.image() })
        manager.setEnabled(true)
        let start = Task { await manager.startLive(for: target) }
        await fulfillment(of: [entered], timeout: 2)
        manager.setEnabled(false)
        release?.resume()
        await start.value
        await Task.yield()
        XCTAssertFalse(stream.isRunning)
        XCTAssertNil(manager.image)
        XCTAssertFalse(manager.isLive)
    }

    func testOlderSourceCannotReplaceOrStopNewerPreview() async {
        let first = FakePreviewStream()
        let second = FakePreviewStream()
        let entered = expectation(description: "First stream entered")
        var release: CheckedContinuation<Void, Never>?
        first.onStart = { await withCheckedContinuation { release = $0; entered.fulfill() } }
        var created = 0
        let manager = ScreenPreviewManager(makeLiveStream: {
            created += 1
            return created == 1 ? first : second
        }, snapshotProvider: { _ in Self.image() })
        manager.setEnabled(true)
        let oldStart = Task { await manager.startLive(for: target) }
        await fulfillment(of: [entered], timeout: 2)
        let newTarget = ScreenPreviewManager.Target.display(Display(id: 2, name: "Two", width: 320, height: 180, isMain: false))
        await manager.startLive(for: newTarget)
        release?.resume()
        await oldStart.value
        await Task.yield()
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(second.isRunning)
        XCTAssertEqual(manager.previewedSourceName, "Two")
        manager.setEnabled(false)
        await manager.stopLive()
    }

    func testQueuedCloseCleanupDoesNotStopReopenedPreview() async {
        let first = FakePreviewStream()
        let second = FakePreviewStream()
        var created = 0
        let manager = ScreenPreviewManager(makeLiveStream: {
            created += 1
            return created == 1 ? first : second
        }, snapshotProvider: { _ in Self.image() })
        manager.setEnabled(true)
        await manager.startLive(for: target)
        manager.setEnabled(false)
        manager.setEnabled(true)
        await manager.startLive(for: target)
        await Task.yield()
        XCTAssertTrue(second.isRunning)
        XCTAssertFalse(first.isRunning)
        await manager.stopLive()
    }

    static func image() -> CGImage {
        CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

@MainActor
private final class FakePreviewStream: ScreenPreviewStreaming {
    var isRunning = false
    var onStart: (() async -> Void)?
    func start(target: ScreenPreviewManager.Target, onFrame: @escaping (CGImage) -> Void) async throws {
        await onStart?()
        isRunning = true
        onFrame(ScreenPreviewTests.image())
    }
    func stop() async { isRunning = false }
}
