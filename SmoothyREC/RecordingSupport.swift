//
//  RecordingSupport.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation

enum RecordingComponent: String, CaseIterable, Identifiable {
    case screen
    case microphone
    case camera

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .screen:
            return "Screen Recording"
        case .microphone:
            return "Microphone"
        case .camera:
            return "Camera"
        }
    }

    var fileNameComponent: String {
        switch self {
        case .screen:
            return "screen"
        case .microphone:
            return "mic"
        case .camera:
            return "camera"
        }
    }
}

struct RecordingWarning: Equatable, Identifiable {
    let component: RecordingComponent
    let message: String

    var id: String {
        "\(component.rawValue)-\(message)"
    }

    var displayText: String {
        "\(component.displayName): \(message)"
    }
}

enum SmoothyPermission: CaseIterable {
    case screenRecording
    case camera
    case microphone

    var displayName: String {
        switch self {
        case .screenRecording:
            return "Screen Recording"
        case .camera:
            return "Camera"
        case .microphone:
            return "Microphone"
        }
    }

    var isRequiredForLaunch: Bool {
        self == .screenRecording
    }

    var missingBannerLabel: String {
        "\(displayName) (\(isRequiredForLaunch ? "required" : "optional"))"
    }
}

enum ScreenCapturePermissionClassifier {
    static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError

        if nsError.domain == "com.apple.ScreenCaptureKit",
           nsError.code == 3 || nsError.code == -3801 {
            return true
        }

        if nsError.domain == "ScreenCaptureKit.SCStreamErrorDomain",
           nsError.code == 3 || nsError.code == -3801 {
            return true
        }

        if nsError.domain == NSCocoaErrorDomain, nsError.code == 4 {
            return true
        }

        let description = nsError.localizedDescription.lowercased()
        return description.contains("tcc")
            || description.contains("application, window, display capture")
            || description.contains("not authorized")
            || description.contains("not authorised")
            || (description.contains("declined") && description.contains("capture"))
            || (description.contains("permission") && description.contains("screen"))
    }
}

enum RecordingOutputError: LocalizedError, Equatable {
    case missingOutputFolder
    case directoryCreationFailed(String)
    case existingFileRemovalFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingOutputFolder:
            return "No output folder is available. Choose an output folder in Settings."
        case .directoryCreationFailed(let detail):
            return "Could not create the output folder: \(detail)"
        case .existingFileRemovalFailed(let detail):
            return "Could not replace an existing output file: \(detail)"
        }
    }
}

enum RecordingOutputFileResolver {
    static func sanitizedBaseName(_ name: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>")
        let sanitized = name
            .components(separatedBy: invalidCharacters)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !sanitized.isEmpty else {
            return "Untitled"
        }

        return String(sanitized.prefix(100))
    }

    static func timestampString(for date: Date = Date(), timeZone: TimeZone = .current) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        dateFormatter.timeZone = timeZone
        return dateFormatter.string(from: date)
    }

    static func preparedOutputURL(
        videoName: String,
        component: RecordingComponent,
        fileExtension: String,
        outputDirectory: URL,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        fileManager: FileManager = .default
    ) throws -> URL {
        do {
            try fileManager.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw RecordingOutputError.directoryCreationFailed(error.localizedDescription)
        }

        let filename = [
            sanitizedBaseName(videoName),
            component.fileNameComponent,
            timestampString(for: date, timeZone: timeZone)
        ].joined(separator: "_") + ".\(fileExtension)"

        let outputURL = outputDirectory.appendingPathComponent(filename)

        guard fileManager.fileExists(atPath: outputURL.path) else {
            return outputURL
        }

        do {
            try fileManager.removeItem(at: outputURL)
        } catch {
            throw RecordingOutputError.existingFileRemovalFailed(error.localizedDescription)
        }

        return outputURL
    }
}
