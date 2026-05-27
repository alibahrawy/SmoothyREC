//
//  ScreenPreviewManager.swift
//  SmoothyREC
//
//  Snapshot preview for the selected screen recording source.
//

import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI
import CoreGraphics
import CoreVideo
import CoreImage

@MainActor
final class ScreenPreviewManager: ObservableObject {
    enum Target: Hashable {
        case display(Display)
        case window(CaptureWindow)

        var name: String {
            switch self {
            case .display(let display):
                return display.name
            case .window(let window):
                return window.description
            }
        }
    }

    @Published private(set) var image: NSImage?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var previewedSourceName: String?
    @Published private(set) var isLive = false

    private var requestID = 0
    private var liveStream: LiveScreenPreviewStream?
    private var liveTarget: Target?

    var hasPreview: Bool {
        image != nil
    }

    func clear() {
        requestID += 1
        Task { await stopLive() }
        image = nil
        isLoading = false
        errorMessage = nil
        previewedSourceName = nil
    }

    /// Starts a continuous live preview for the given target. Frames arrive at
    /// ~24fps from an SCStream sized for thumbnail use (max 720p), which keeps
    /// CPU and battery in check while still looking truly live.
    /// Call `stopLive()` when the preview view disappears or when recording
    /// begins — the recorder needs the screen capture pipeline for itself.
    func startLive(for target: Target?) async {
        // Tear down any existing live stream first.
        await stopLive()

        guard let target else {
            image = nil
            errorMessage = "Select a display or window before previewing."
            previewedSourceName = nil
            return
        }

        // Show a snapshot immediately so the UI isn't blank during stream startup.
        await capturePreview(for: target)

        do {
            let stream = LiveScreenPreviewStream()
            try await stream.start(target: target) { [weak self] cgImage in
                guard let self else { return }
                Task { @MainActor in
                    // Discard frames that arrive after we've moved on to another
                    // source — prevents the preview from briefly flashing the
                    // previous display when the user switches.
                    guard self.liveTarget == target else { return }
                    self.image = NSImage(
                        cgImage: cgImage,
                        size: NSSize(width: cgImage.width, height: cgImage.height)
                    )
                    self.previewedSourceName = target.name
                    self.errorMessage = nil
                    self.isLive = true
                }
            }
            liveStream = stream
            liveTarget = target
        } catch {
            // Fall back to the snapshot path — if SCStream won't start (most
            // commonly: permission missing), the snapshot already shown above
            // is the best we can do, and capturePreview surfaced any error.
            errorMessage = userFacingMessage(for: error)
            isLive = false
        }
    }

    func stopLive() async {
        isLive = false
        liveTarget = nil
        if let stream = liveStream {
            liveStream = nil
            await stream.stop()
        }
    }

    func capturePreview(for target: Target?) async {
        requestID += 1
        let currentRequestID = requestID

        guard let target else {
            image = nil
            errorMessage = "Select a display or window before previewing."
            previewedSourceName = nil
            return
        }

        isLoading = true
        errorMessage = nil

        defer {
            if currentRequestID == requestID {
                isLoading = false
            }
        }

        do {
            let cgImage = try await captureSnapshot(for: target)
            guard currentRequestID == requestID else { return }

            image = NSImage(
                cgImage: cgImage,
                size: NSSize(width: cgImage.width, height: cgImage.height)
            )
            previewedSourceName = target.name
        } catch {
            guard currentRequestID == requestID else { return }

            image = nil
            errorMessage = userFacingMessage(for: error)
            previewedSourceName = nil
        }
    }

    private func captureSnapshot(for target: Target) async throws -> CGImage {
        if let image = captureCoreGraphicsSnapshot(for: target) {
            return image
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let filter: SCContentFilter
        let sourceSize: CGSize

        switch target {
        case .display(let display):
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                throw ScreenPreviewError.sourceUnavailable("Selected display is no longer available.")
            }

            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            sourceSize = CGSize(width: scDisplay.width, height: scDisplay.height)

        case .window(let window):
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                throw ScreenPreviewError.sourceUnavailable("Selected window is no longer available. Load windows again and pick it.")
            }

            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            sourceSize = scWindow.frame.size
        }

        let previewSize = scaledSize(sourceSize, fittingWithin: CGSize(width: 1280, height: 720))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(previewSize.width)
        configuration.height = Int(previewSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 5)
        configuration.queueDepth = 3

        if #available(macOS 14.0, *) {
            do {
                return try await captureImage(contentFilter: filter, configuration: configuration)
            } catch {
                return try await ScreenPreviewFrameGrabber.capture(
                    contentFilter: filter,
                    configuration: configuration
                )
            }
        }

        return try await ScreenPreviewFrameGrabber.capture(
            contentFilter: filter,
            configuration: configuration
        )
    }

    @available(macOS 14.0, *)
    private func captureImage(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(
                contentFilter: contentFilter,
                configuration: configuration
            ) { image, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: ScreenPreviewError.captureFailed("No preview image was returned."))
                }
            }
        }
    }

    private func scaledSize(_ sourceSize: CGSize, fittingWithin maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return maxSize
        }

        let widthScale = maxSize.width / sourceSize.width
        let heightScale = maxSize.height / sourceSize.height
        let scale = min(1.0, min(widthScale, heightScale))

        let width = max(2, Int((sourceSize.width * scale).rounded(.down)))
        let height = max(2, Int((sourceSize.height * scale).rounded(.down)))

        return CGSize(
            width: max(2, width - (width % 2)),
            height: max(2, height - (height % 2))
        )
    }

    private func captureCoreGraphicsSnapshot(for target: Target) -> CGImage? {
        let image: CGImage?

        switch target {
        case .display(let display):
            image = CGDisplayCreateImage(display.id)

        case .window(let window):
            image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                window.id,
                [.bestResolution, .boundsIgnoreFraming]
            )
        }

        guard let image, image.width > 1, image.height > 1 else {
            return nil
        }

        return image
    }

    private func userFacingMessage(for error: Error) -> String {
        if let previewError = error as? ScreenPreviewError {
            return previewError.localizedDescription
        }

        let nsError = error as NSError
        let isPermissionError = (nsError.domain == "com.apple.ScreenCaptureKit"
            && (nsError.code == 3 || nsError.code == -3801))
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == 4)

        if isPermissionError {
            return "Screen Recording permission is not available yet. Open Permissions, confirm SmoothyREC is enabled, then relaunch if macOS asks."
        }

        let detail = nsError.localizedDescription
        if detail.isEmpty {
            return "Screen preview failed. Try refreshing the source or reopening SmoothyREC."
        }
        return "Screen preview failed: \(detail)"
    }
}

private enum ScreenPreviewError: LocalizedError {
    case sourceUnavailable(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceUnavailable(let message), .captureFailed(let message):
            return message
        }
    }
}

private final class ScreenPreviewFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.smoothyrec.screenpreview.frame", qos: .userInitiated)
    private let context = CIContext()
    private let lock = NSLock()

    private var stream: SCStream?
    private var continuation: CheckedContinuation<CGImage, Error>?

    static func capture(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        let grabber = ScreenPreviewFrameGrabber()
        return try await grabber.capture(contentFilter: contentFilter, configuration: configuration)
    }

    private func capture(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()

            let stream = SCStream(filter: contentFilter, configuration: configuration, delegate: self)
            self.stream = stream

            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            } catch {
                resume(with: .failure(error))
                return
            }

            Task {
                do {
                    try await stream.startCapture()
                } catch {
                    self.resume(with: .failure(error))
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.resume(with: .failure(ScreenPreviewError.captureFailed("Timed out waiting for a screen preview frame.")))
            }
        }
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else {
            resume(with: .failure(ScreenPreviewError.captureFailed("Could not convert the preview frame.")))
            return
        }

        resume(with: .success(image))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        resume(with: .failure(error))
    }

    private nonisolated static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let firstAttachment = attachments.first,
              let rawStatus = firstAttachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }

        return status == .complete || status == .started
    }

    private func resume(with result: Result<CGImage, Error>) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let stream = stream
        self.stream = nil
        lock.unlock()

        guard let continuation else { return }

        Task {
            try? await stream?.stopCapture()
            continuation.resume(with: result)
        }
    }
}

struct ScreenPreviewView: View {
    @ObservedObject var previewManager: ScreenPreviewManager
    let height: CGFloat

    var body: some View {
        ZStack {
            if let image = previewManager.image {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.black.opacity(0.9))

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(1)
                }
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if let sourceName = previewManager.previewedSourceName {
                        Text(sourceName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(10)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                )
            } else if previewManager.isLoading {
                placeholder(icon: "display", title: "Capturing preview...", subtitle: "macOS may ask for Screen Recording access here.")
                    .overlay {
                        ProgressView()
                            .controlSize(.small)
                            .offset(y: -28)
                    }
            } else if let errorMessage = previewManager.errorMessage {
                placeholder(
                    icon: "exclamationmark.triangle.fill",
                    title: "Screen preview unavailable",
                    subtitle: errorMessage,
                    iconColor: .orange
                )
            } else {
                placeholder(
                    icon: "display",
                    title: "No screen preview yet",
                    subtitle: "Click Preview Screen to capture a snapshot of the selected source."
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func placeholder(
        icon: String,
        title: String,
        subtitle: String,
        iconColor: Color = .secondary
    ) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.controlBackgroundColor))

            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                    .foregroundColor(iconColor)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 18)
            }
        }
        .frame(height: height)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
        )
    }
}

extension ScreenPreviewManager {
    static var preview: ScreenPreviewManager {
        ScreenPreviewManager()
    }
}

// MARK: - Live preview stream

/// A long-running SCStream tuned for thumbnail-quality live preview.
/// Frames flow through a single callback at ~24fps until `stop()` is called.
private final class LiveScreenPreviewStream: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.smoothyrec.screenpreview.live", qos: .userInitiated)
    private let context = CIContext()
    private let lock = NSLock()

    private var stream: SCStream?
    private var onFrame: ((CGImage) -> Void)?
    private var lastFrameAt: CFTimeInterval = 0
    // Floor between frames — caps preview to ~30fps even if the OS hands us more,
    // which keeps the SwiftUI redraw cost predictable on retina displays.
    private let minFrameInterval: CFTimeInterval = 1.0 / 30.0

    func start(target: ScreenPreviewManager.Target,
               onFrame: @escaping (CGImage) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )

        let filter: SCContentFilter
        let sourceSize: CGSize

        switch target {
        case .display(let display):
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                throw ScreenPreviewError.sourceUnavailable("Selected display is no longer available.")
            }
            let ownApplications = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: ownApplications,
                exceptingWindows: []
            )
            sourceSize = CGSize(width: scDisplay.width, height: scDisplay.height)

        case .window(let window):
            guard let scWindow = content.windows.first(where: { $0.windowID == window.id }) else {
                throw ScreenPreviewError.sourceUnavailable("Selected window is no longer available. Load windows again and pick it.")
            }
            filter = SCContentFilter(desktopIndependentWindow: scWindow)
            sourceSize = scWindow.frame.size
        }

        let previewSize = Self.scaledSize(sourceSize, fittingWithin: CGSize(width: 1280, height: 720))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(previewSize.width)
        configuration.height = Int(previewSize.height)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3

        let scStream = SCStream(filter: filter, configuration: configuration, delegate: self)

        lock.lock()
        self.onFrame = onFrame
        self.stream = scStream
        lock.unlock()

        try scStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await scStream.startCapture()
    }

    func stop() async {
        lock.lock()
        let scStream = stream
        stream = nil
        onFrame = nil
        lock.unlock()

        guard let scStream else { return }
        try? await scStream.stopCapture()
    }

    nonisolated func stream(_ stream: SCStream,
                            didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                            of outputType: SCStreamOutputType) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              Self.isCompleteFrame(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        // Frame-rate throttle on the producer side so we don't burn cycles
        // converting frames the UI would never see.
        let now = CACurrentMediaTime()
        lock.lock()
        let interval = now - lastFrameAt
        guard interval >= minFrameInterval else {
            lock.unlock()
            return
        }
        lastFrameAt = now
        let callback = onFrame
        lock.unlock()

        guard let callback else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }
        callback(cgImage)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Stop quietly — the manager already shows a snapshot if the stream
        // disappears, and reports an error via its own error path on next start.
    }

    private nonisolated static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let firstAttachment = attachments.first,
              let rawStatus = firstAttachment[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else {
            return true
        }
        return status == .complete || status == .started
    }

    private static func scaledSize(_ sourceSize: CGSize, fittingWithin maxSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return maxSize
        }
        let scale = min(1.0, min(maxSize.width / sourceSize.width, maxSize.height / sourceSize.height))
        let width = max(2, Int((sourceSize.width * scale).rounded(.down)))
        let height = max(2, Int((sourceSize.height * scale).rounded(.down)))
        return CGSize(width: max(2, width - (width % 2)),
                      height: max(2, height - (height % 2)))
    }
}
