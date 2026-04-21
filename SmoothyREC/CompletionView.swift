//
//  CompletionView.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import SwiftUI
import AVFoundation
import os.log

private let completionLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "Completion")

struct CompletionView: View {
    @EnvironmentObject var appDelegate: AppDelegate
    @StateObject private var viewModel: CompletionViewModel

    let recordingResult: RecordingResult

    init(recordingResult: RecordingResult) {
        self.recordingResult = recordingResult
        _viewModel = StateObject(wrappedValue: CompletionViewModel(result: recordingResult))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Content
            ScrollView {
                VStack(spacing: 20) {
                    // Recording summary
                    summarySection

                    if !recordingResult.warnings.isEmpty {
                        Divider()
                            .padding(.horizontal, -20)

                        warningSection
                    }

                    Divider()
                        .padding(.horizontal, -20)

                    // Files list
                    filesSection
                }
                .padding(24)
            }

            Divider()

            // Footer buttons
            footerView
        }
        .frame(minWidth: 500, idealWidth: 550, maxWidth: 600,
               minHeight: 450, idealHeight: 500, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
    }

    // MARK: - Header
    private var headerView: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recording Complete")
                    .font(.system(size: 18, weight: .semibold))

                Text(viewModel.formattedTotalDuration)
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

    // MARK: - Summary Section
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Recording Summary")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "info.circle.fill")
                    .foregroundColor(.blue)
            }

            HStack(spacing: 20) {
                SummaryItem(
                    icon: "clock",
                    label: "Duration",
                    value: viewModel.formattedTotalDuration
                )

                SummaryItem(
                    icon: "folder",
                    label: "Total Size",
                    value: viewModel.formattedTotalSize
                )

                SummaryItem(
                    icon: "doc.fill",
                    label: "Files",
                    value: "\(viewModel.fileItems.count)"
                )
            }
        }
    }

    // MARK: - Files Section
    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Output Files")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundColor(.blue)
            }

            VStack(spacing: 12) {
                ForEach($viewModel.fileItems) { $item in
                    FileItemView(item: $item)
                }
            }
        }
    }

    // MARK: - Warning Section
    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label {
                Text("Saved With Warnings")
                    .font(.system(size: 13, weight: .medium))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(recordingResult.warnings) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundColor(.orange)
                            .font(.system(size: 12))
                            .padding(.top, 1)

                        Text(warning.displayText)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(8)
        }
    }

    // MARK: - Footer
    private var footerView: some View {
        HStack(spacing: 12) {
            Button(action: {
                viewModel.openOutputFolder()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                    Text("Open Output Folder")
                }
            }
            .buttonStyle(.bordered)

            Spacer()

            Button(action: {
                NSApp.keyWindow?.close()
                appDelegate.showMainWindow()
            }) {
                Text("New Recording")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
    }
}

// MARK: - Summary Item

struct SummaryItem: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.secondary)

            Text(value)
                .font(.system(size: 14, weight: .semibold))

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - File Item View

struct FileItemView: View {
    @Binding var item: FileItem
    @StateObject private var compressor = VideoCompressor()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // File info row
            HStack(spacing: 12) {
                // File type icon
                Image(systemName: item.iconName)
                    .font(.system(size: 24))
                    .foregroundColor(item.iconColor)
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)

                    Text(item.formattedSize)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Compression progress or actions
                if compressor.isCompressing {
                    VStack(alignment: .trailing, spacing: 4) {
                        ProgressView(value: compressor.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 80)

                        Text("\(Int(compressor.progress * 100))%")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        // Compress button
                        Button(action: {
                            compressFile()
                        }) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.borderless)
                        .help("Compress file")
                        .disabled(item.isCompressed || !item.isCompressible)

                        // Reveal in Finder button
                        Button(action: {
                            item.revealInFinder()
                        }) {
                            Image(systemName: "arrow.right.circle")
                                .font(.system(size: 16))
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                }
            }

            // Compression result info
            if item.isCompressed, let saved = item.spaceSaved {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 10))

                    Text("Compressed: saved \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                }
                .padding(.leading, 44)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(8)
        .onChange(of: compressor.progress) { newProgress in
            if newProgress >= 1.0, compressor.isCompressing == false {
                // Compression completed
                item.updateAfterCompression()
            }
        }
    }

    private func compressFile() {
        guard item.isCompressible else { return }

        Task {
            do {
                let compressedURL = try await compressor.compress(
                    inputURL: item.fileURL,
                    preset: .mediumQuality
                )

                // Replace original with compressed
                let fileManager = FileManager.default
                try? fileManager.removeItem(at: item.fileURL)
                try? fileManager.moveItem(at: compressedURL, to: item.fileURL)

                await MainActor.run {
                    item.markAsCompressed()
                }
            } catch {
                completionLogger.error("Compression failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Video Compressor

@MainActor
class VideoCompressor: ObservableObject {
    @Published var isCompressing = false
    @Published var progress: Double = 0.0

    func compress(inputURL: URL, preset: AVAssetExportPreset) async throws -> URL {
        isCompressing = true
        progress = 0.0

        defer {
            isCompressing = false
        }

        let asset = AVAsset(url: inputURL)

        // Determine output file type based on input
        let outputFileType: AVFileType
        if inputURL.pathExtension.lowercased() == "m4a" {
            outputFileType = .m4a
        } else {
            outputFileType = .mov
        }

        // Create temporary output URL
        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent("compressed_\(UUID().uuidString).\(inputURL.pathExtension)")

        // Check if export is possible
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: preset.exportPreset
        ) else {
            throw CompressionError.exportSessionCreationFailed
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = outputFileType
        exportSession.shouldOptimizeForNetworkUse = true

        // Monitor progress
        let progressTask = Task {
            while exportSession.status == .waiting || exportSession.status == .exporting {
                await MainActor.run {
                    self.progress = Double(exportSession.progress)
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        // Perform export
        await exportSession.export()

        // Cancel progress monitoring
        progressTask.cancel()

        // Update final progress
        progress = 1.0

        // Check result
        if let error = exportSession.error {
            throw CompressionError.exportFailed(error)
        }

        guard exportSession.status == .completed else {
            throw CompressionError.exportFailed(nil)
        }

        return outputURL
    }
}

enum AVAssetExportPreset {
    case lowQuality
    case mediumQuality
    case highQuality

    var exportPreset: String {
        switch self {
        case .lowQuality:
            return AVAssetExportPresetLowQuality
        case .mediumQuality:
            return AVAssetExportPresetMediumQuality
        case .highQuality:
            return AVAssetExportPresetHighestQuality
        }
    }
}

enum CompressionError: Error {
    case exportSessionCreationFailed
    case exportFailed(Error?)
}

// MARK: - File Item

struct FileItem: Identifiable {
    let id = UUID()
    let fileURL: URL
    let type: FileType
    var fileSize: Int64
    var isCompressed: Bool = false
    var spaceSaved: Int64? = nil

    enum FileType {
        case screen
        case camera
        case microphone

        var displayName: String {
            switch self {
            case .screen: return "Screen Recording"
            case .camera: return "Camera Recording"
            case .microphone: return "Microphone Audio"
            }
        }

        var iconName: String {
            switch self {
            case .screen: return "display.fill"
            case .camera: return "video.fill"
            case .microphone: return "mic.fill"
            }
        }

        var iconColor: Color {
            switch self {
            case .screen: return .blue
            case .camera: return .purple
            case .microphone: return .orange
            }
        }

        var isCompressible: Bool {
            switch self {
            case .screen, .camera: return true
            case .microphone: return true // AAC can be re-encoded
            }
        }
    }

    var displayName: String {
        type.displayName
    }

    var iconName: String {
        type.iconName
    }

    var iconColor: Color {
        type.iconColor
    }

    var isCompressible: Bool {
        type.isCompressible && !isCompressed
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    mutating func markAsCompressed() {
        let originalSize = fileSize
        updateFileSize()
        let newSize = fileSize
        spaceSaved = originalSize - newSize
        isCompressed = true
    }

    mutating func updateFileSize() {
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) {
            fileSize = attributes[.size] as? Int64 ?? 0
        }
    }

    mutating func updateAfterCompression() {
        updateFileSize()
    }

    func revealInFinder() {
        NSWorkspace.shared.selectFile(fileURL.path, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Completion View Model

@MainActor
class CompletionViewModel: ObservableObject {
    @Published var fileItems: [FileItem] = []

    let result: RecordingResult

    init(result: RecordingResult) {
        self.result = result
        loadFileItems()
    }

    private func loadFileItems() {
        var items: [FileItem] = []

        if let screenURL = result.screenRecordingURL {
            if let size = fileSize(at: screenURL) {
                items.append(FileItem(fileURL: screenURL, type: .screen, fileSize: size))
            }
        }

        if let cameraURL = result.cameraRecordingURL {
            if let size = fileSize(at: cameraURL) {
                items.append(FileItem(fileURL: cameraURL, type: .camera, fileSize: size))
            }
        }

        if let micURL = result.microphoneRecordingURL {
            if let size = fileSize(at: micURL) {
                items.append(FileItem(fileURL: micURL, type: .microphone, fileSize: size))
            }
        }

        fileItems = items
    }

    private func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.size] as? Int64
    }

    var formattedTotalDuration: String {
        let hours = Int(result.duration) / 3600
        let minutes = Int(result.duration) / 60 % 60
        let seconds = Int(result.duration) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var totalSize: Int64 {
        fileItems.reduce(0) { $0 + $1.fileSize }
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    func openOutputFolder() {
        guard let firstURL = fileItems.first?.fileURL else { return }
        let folderURL = firstURL.deletingLastPathComponent()
        NSWorkspace.shared.open(folderURL)
    }
}

// MARK: - Preview

#Preview {
    let sampleResult = RecordingResult(
        videoName: "Test Recording",
        screenRecordingURL: URL(fileURLWithPath: "/Users/test/Movies/SmoothyREC/Test_screen_2024-01-15_14-30-22.mov"),
        microphoneRecordingURL: URL(fileURLWithPath: "/Users/test/Movies/SmoothyREC/Test_mic_2024-01-15_14-30-22.m4a"),
        cameraRecordingURL: URL(fileURLWithPath: "/Users/test/Movies/SmoothyREC/Test_camera_2024-01-15_14-30-22.mov"),
        duration: 184.5,
        startTime: Date(),
        endTime: Date()
    )

    CompletionView(recordingResult: sampleResult)
        .environmentObject(AppDelegate())
}
