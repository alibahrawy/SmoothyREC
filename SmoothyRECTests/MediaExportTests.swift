import XCTest
import AVFoundation
import CoreVideo
@testable import SmoothyREC

@MainActor
final class MediaExportTests: XCTestCase {
    func testCompressionUsageRequiresFinalReplacementAndPreservesOriginalOnFailure() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let input = try await media.video(seconds: 1)
        var events: [RecorderFeature] = []
        let record: (RecorderFeature) -> Void = { events.append($0) }
        let compressor = VideoCompressor()
        try await compressor.compressAndReplace(inputURL: input, preset: .mediumQuality, trackUsage: record)
        XCTAssertEqual(events, [.fileCompress])
        let tracks = try await AVURLAsset(url: input).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let original = try Data(contentsOf: input)
        // A nonempty backup directory prevents the replacement; no success.
        let backup = input.deletingPathExtension().appendingPathExtension("backup.mp4")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: backup.appendingPathComponent("keep"))
        do { try await compressor.compressAndReplace(inputURL: input, preset: .mediumQuality, trackUsage: record); XCTFail("Expected replacement failure") } catch {}
        XCTAssertEqual(events, [.fileCompress])
        XCTAssertEqual(try Data(contentsOf: input), original)
        let canceled = Task { try await compressor.compressAndReplace(inputURL: input, preset: .mediumQuality, trackUsage: record) }
        canceled.cancel()
        do { try await canceled.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(events, [.fileCompress])
    }

    func testPiPUsageCountsSuccessfulExportButNotMissingOrCorruptInputs() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let screen = try await media.video(seconds: 1)
        var events: [RecorderFeature] = []
        func model(_ camera: URL) -> CompletionViewModel {
            CompletionViewModel(result: RecordingResult(videoName: "Synthetic", screenRecordingURL: screen,
                microphoneRecordingURL: nil, cameraRecordingURL: camera, duration: 1,
                startTime: Date(), endTime: Date()), trackUsage: { events.append($0) })
        }
        let valid = model(screen)
        await valid.exportPiP()
        XCTAssertEqual(events, [.pipExport])
        guard case .done(let output) = valid.pipState else { return XCTFail("Expected successful output") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        await model(media.directory.appendingPathComponent("missing.mov")).exportPiP()
        let corrupt = media.directory.appendingPathComponent("corrupt.mov")
        try Data("not video".utf8).write(to: corrupt)
        await model(corrupt).exportPiP()
        XCTAssertEqual(events, [.pipExport])
    }

    func testMicrophoneCompressionProducesPlayableM4A() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let input = try await media.audio(seconds: 2)
        let original = try Data(contentsOf: input)
        let compressor = VideoCompressor()
        let output = try await compressor.compress(inputURL: input, preset: .mediumQuality)
        defer { try? FileManager.default.removeItem(at: output) }
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.1)
        XCTAssertEqual(output.pathExtension, "m4a")
        XCTAssertEqual(try Data(contentsOf: input), original)
        XCTAssertFalse(compressor.isCompressing)
    }

    func testMP4CompressionKeepsMP4ContainerAndOriginal() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let input = try await media.video(seconds: 2)
        let original = try Data(contentsOf: input)
        let output = try await VideoCompressor().compress(inputURL: input, preset: .mediumQuality)
        defer { try? FileManager.default.removeItem(at: output) }
        let data = try Data(contentsOf: output)
        XCTAssertEqual(String(data: data[4..<8], encoding: .ascii), "ftyp")
        XCTAssertNotEqual(String(data: data[8..<12], encoding: .ascii), "qt  ")
        XCTAssertEqual(output.pathExtension, "mp4")
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(try Data(contentsOf: input), original)
    }

    func testPiPClampsLongMicrophoneToVideoDuration() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let video = try await media.video(seconds: 2)
        let mic = try await media.audio(seconds: 3)
        let output = try await PiPCompositor.compose(screenURL: video, cameraURL: video, microphoneURL: mic,
            outputURL: media.directory.appendingPathComponent("pip.mov"), corner: .bottomRight)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
    }

    func testPiPWithOffsetAndShortCameraStillExportsFullScreen() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let screen = try await media.video(seconds: 2)
        let camera = try await media.video(seconds: 1, name: "camera")
        let mic = try await media.audio(seconds: 3)
        let output = try await PiPCompositor.compose(screenURL: screen, cameraURL: camera, microphoneURL: mic,
            outputURL: media.directory.appendingPathComponent("pip.mov"), corner: .bottomRight, sourceStartOffset: 0.5)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
    }

    func testPiPHandlesOffsetBeyondOptionalTracks() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let screen = try await media.video(seconds: 2)
        let mic = try await media.audio(seconds: 1)
        let output = try await PiPCompositor.compose(screenURL: screen, cameraURL: screen, microphoneURL: mic,
            outputURL: media.directory.appendingPathComponent("pip.mov"), corner: .bottomRight, sourceStartOffset: 4)
        let duration = try await AVURLAsset(url: output).load(.duration)
        XCTAssertEqual(duration.seconds, 2, accuracy: 0.05)
    }

    func testCompressionFailureKeepsOriginalAndResetsProgress() async throws {
        let media = try TestMedia()
        defer { media.remove() }
        let input = media.directory.appendingPathComponent("corrupt.mp4")
        let contents = Data("not a media file".utf8)
        try contents.write(to: input)
        let compressor = VideoCompressor()
        do {
            _ = try await compressor.compress(inputURL: input, preset: .mediumQuality)
            XCTFail("Expected unsupported/corrupt input to fail")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: input), contents)
        XCTAssertFalse(compressor.isCompressing)
        XCTAssertLessThan(compressor.progress, 1)
    }
}

private struct TestMedia {
    let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SmoothyRecMedia-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }

    func audio(seconds: Int) async throws -> URL {
        let sampleRate = 48000
        let samples = sampleRate * seconds
        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + samples * 2), to: &wav)
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt16(1), to: &wav)
        append(UInt32(sampleRate), to: &wav)
        append(UInt32(sampleRate * 2), to: &wav)
        append(UInt16(2), to: &wav)
        append(UInt16(16), to: &wav)
        wav.append(contentsOf: "data".utf8)
        append(UInt32(samples * 2), to: &wav)
        for sample in 0..<samples {
            append(Int16(sin(Double(sample) * 440 * 2 * .pi / Double(sampleRate)) * 8000), to: &wav)
        }
        let input = directory.appendingPathComponent("mic.wav")
        let output = directory.appendingPathComponent("mic.m4a")
        try wav.write(to: input)
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A))
        export.outputURL = output
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else { throw export.error ?? CocoaError(.fileWriteUnknown) }
        return output
    }

    func video(seconds: Int, name: String = "screen") async throws -> URL {
        let url = directory.appendingPathComponent("\(name).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA, nil, &pixel)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        let data = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt32.self)
        for index in 0..<(CVPixelBufferGetBytesPerRow(buffer) * 120 / 4) { data[index] = 0xff336699 }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<(seconds * 30) {
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && writer.status == .writing && Date() < deadline {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            guard input.isReadyForMoreMediaData,
                  adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
        }
        writer.endSession(atSourceTime: CMTime(seconds: Double(seconds), preferredTimescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    private func append<T: FixedWidthInteger>(_ number: T, to data: inout Data) {
        var value = number.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
}
