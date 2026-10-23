//
//  PiPCompositor.swift
//  SmoothyREC
//

import AVFoundation
import CoreGraphics

enum PiPCorner: String, CaseIterable, Identifiable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

enum PiPCompositorError: LocalizedError {
    case missingScreenTrack
    case missingCameraTrack
    case exportSessionCreationFailed
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingScreenTrack: return "The screen recording has no video track to use as the base layer."
        case .missingCameraTrack: return "The camera recording has no video track to overlay."
        case .exportSessionCreationFailed: return "Could not create the export session for the combined video."
        case .exportFailed(let detail): return "Combining the video failed: \(detail)"
        }
    }
}

/// Overlays a camera recording onto a screen recording as a picture-in-picture
/// layer and exports a single combined file. Screen system audio and the
/// optional separate microphone track are mixed in so the result is ready to
/// share without an editor.
enum PiPCompositor {
    static func compose(
        screenURL: URL,
        cameraURL: URL,
        microphoneURL: URL?,
        outputURL: URL,
        corner: PiPCorner,
        sourceStartOffset: TimeInterval = 0,
        cameraWidthFraction: CGFloat = 0.26,
        marginFraction: CGFloat = 0.025
    ) async throws -> URL {
        let composition = AVMutableComposition()

        let screenAsset = AVURLAsset(url: screenURL)
        let cameraAsset = AVURLAsset(url: cameraURL)

        guard let screenVideo = try await screenAsset.loadTracks(withMediaType: .video).first else {
            throw PiPCompositorError.missingScreenTrack
        }
        guard let cameraVideo = try await cameraAsset.loadTracks(withMediaType: .video).first else {
            throw PiPCompositorError.missingCameraTrack
        }

        let screenDuration = try await screenAsset.load(.duration)
        let cameraDuration = try await cameraAsset.load(.duration)
        let screenRange = CMTimeRange(start: .zero, duration: screenDuration)

        // The camera/mic stems start at the session sync clock; the screen
        // file starts a beat later (stream startup latency). Skip that lead-in
        // on the camera/mic so all tracks depict the same instant at t=0.
        let headOffset = CMTime(seconds: max(0, sourceStartOffset), preferredTimescale: 600)
        let cameraStart = CMTimeMinimum(headOffset, cameraDuration)
        let availableCamera = CMTimeSubtract(cameraDuration, cameraStart)
        let overlayDuration = CMTimeMinimum(screenDuration, availableCamera)

        // Render canvas is the upright screen size.
        let screenNaturalSize = try await screenVideo.load(.naturalSize)
        let screenTransform = try await screenVideo.load(.preferredTransform)
        let renderSize = screenNaturalSize.applying(screenTransform)
        let canvas = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))

        // Base screen layer.
        guard let screenComp = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PiPCompositorError.exportSessionCreationFailed
        }
        try screenComp.insertTimeRange(screenRange, of: screenVideo, at: .zero)
        screenComp.preferredTransform = screenTransform

        // Camera overlay layer.
        var cameraComp: AVMutableCompositionTrack?
        if overlayDuration > .zero {
            guard let track = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { throw PiPCompositorError.exportSessionCreationFailed }
            cameraComp = track
            try track.insertTimeRange(
                CMTimeRange(start: cameraStart, duration: overlayDuration),
                of: cameraVideo, at: .zero
            )
        }

        // Audio: screen (system) audio, then microphone if separate.
        if let screenAudio = try await screenAsset.loadTracks(withMediaType: .audio).first,
           let audioComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audioComp.insertTimeRange(screenRange, of: screenAudio, at: .zero)
        }
        if let microphoneURL {
            let micAsset = AVURLAsset(url: microphoneURL)
            if let micAudio = try await micAsset.loadTracks(withMediaType: .audio).first {
                let micDuration = try await micAsset.load(.duration)
                let micStart = CMTimeMinimum(headOffset, micDuration)
                let micLength = CMTimeMinimum(screenDuration, CMTimeSubtract(micDuration, micStart))
                if micLength > .zero,
                   let micComp = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    let micRange = CMTimeRange(start: micStart, duration: micLength)
                    try micComp.insertTimeRange(micRange, of: micAudio, at: .zero)
                }
            }
        }

        // Layer instructions: camera on top, screen beneath.
        let screenLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: screenComp)
        screenLayer.setTransform(screenTransform, at: .zero)

        let cameraNaturalSize = try await cameraVideo.load(.naturalSize)
        let cameraTransform = try await cameraVideo.load(.preferredTransform)
        let cameraOriented = cameraNaturalSize.applying(cameraTransform)
        let cameraSize = CGSize(width: abs(cameraOriented.width), height: abs(cameraOriented.height))

        let targetWidth = canvas.width * cameraWidthFraction
        let scale = targetWidth / cameraSize.width
        let scaledHeight = cameraSize.height * scale
        let margin = canvas.width * marginFraction

        let tx: CGFloat
        let ty: CGFloat
        switch corner {
        case .topLeft:
            tx = margin; ty = margin
        case .topRight:
            tx = canvas.width - targetWidth - margin; ty = margin
        case .bottomLeft:
            tx = margin; ty = canvas.height - scaledHeight - margin
        case .bottomRight:
            tx = canvas.width - targetWidth - margin; ty = canvas.height - scaledHeight - margin
        }

        let cameraLayer = cameraComp.map { AVMutableVideoCompositionLayerInstruction(assetTrack: $0) }
        let scaleAndPlace = cameraTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
        cameraLayer?.setTransform(scaleAndPlace, at: .zero)
        if overlayDuration < screenDuration {
            cameraLayer?.setOpacity(0, at: overlayDuration)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = screenRange
        instruction.layerInstructions = cameraLayer.map { [$0, screenLayer] } ?? [screenLayer]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = [instruction]
        videoComposition.renderSize = canvas
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        try? FileManager.default.removeItem(at: outputURL)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw PiPCompositorError.exportSessionCreationFailed
        }
        export.outputURL = outputURL
        // .mov is the safe container here: the camera is always HEVC and the
        // screen may be HEVC too — exporting those to .mp4 fails on many Macs.
        export.outputFileType = .mov
        export.videoComposition = videoComposition
        export.shouldOptimizeForNetworkUse = true

        await export.export()

        if export.status == .completed {
            return outputURL
        }
        throw PiPCompositorError.exportFailed(export.error?.localizedDescription ?? "Unknown error")
    }
}
