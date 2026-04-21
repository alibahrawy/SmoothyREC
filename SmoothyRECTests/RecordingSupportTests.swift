//
//  RecordingSupportTests.swift
//  SmoothyRECTests
//
//  Created by SmoothyREC
//

import XCTest
@testable import SmoothyREC

final class RecordingSupportTests: XCTestCase {
    func testSanitizedBaseNameReplacesInvalidCharactersAndTrimsLength() {
        let longName = String(repeating: "A", count: 120)

        XCTAssertEqual(
            RecordingOutputFileResolver.sanitizedBaseName(" Demo / Clip? "),
            "Demo _ Clip_"
        )
        XCTAssertEqual(RecordingOutputFileResolver.sanitizedBaseName("   "), "Untitled")
        XCTAssertEqual(RecordingOutputFileResolver.sanitizedBaseName(longName).count, 100)
    }

    func testOutputURLUsesComponentTimestampAndExtension() throws {
        let outputDirectory = temporaryDirectory()
        let date = Date(timeIntervalSince1970: 0)

        let url = try RecordingOutputFileResolver.preparedOutputURL(
            videoName: "Launch Demo",
            component: .screen,
            fileExtension: "mov",
            outputDirectory: outputDirectory,
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(url.deletingLastPathComponent(), outputDirectory)
        XCTAssertEqual(url.lastPathComponent, "Launch Demo_screen_1970-01-01_00-00-00.mov")
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    func testOutputURLRemovesExistingFileBeforeReusingName() throws {
        let outputDirectory = temporaryDirectory()
        let date = Date(timeIntervalSince1970: 0)

        let firstURL = try RecordingOutputFileResolver.preparedOutputURL(
            videoName: "Collision",
            component: .microphone,
            fileExtension: "m4a",
            outputDirectory: outputDirectory,
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        try Data("old".utf8).write(to: firstURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstURL.path))

        let secondURL = try RecordingOutputFileResolver.preparedOutputURL(
            videoName: "Collision",
            component: .microphone,
            fileExtension: "m4a",
            outputDirectory: outputDirectory,
            date: date,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )

        XCTAssertEqual(secondURL, firstURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func testSettingsDefaultsRepresentCurrentRecordingDefaults() {
        XCTAssertEqual(SettingsKey.defaultQuality.defaultValue as? String, RecordingQuality.high.rawValue)
        XCTAssertEqual(SettingsKey.defaultFrameRate.defaultValue as? Int, FrameRate.fps30.rawValue)
        XCTAssertEqual(SettingsKey.includeSystemAudio.defaultValue as? Bool, true)
        XCTAssertEqual(SettingsKey.countdownEnabled.defaultValue as? Bool, true)
        XCTAssertEqual(SettingsKey.countdownSeconds.defaultValue as? Int, 3)
    }

    func testPermissionRequirementClassification() {
        XCTAssertTrue(SmoothyPermission.screenRecording.isRequiredForLaunch)
        XCTAssertFalse(SmoothyPermission.camera.isRequiredForLaunch)
        XCTAssertFalse(SmoothyPermission.microphone.isRequiredForLaunch)
        XCTAssertEqual(SmoothyPermission.camera.missingBannerLabel, "Camera (optional)")
    }

    func testScreenCapturePermissionClassifierRecognizesTCCDenialText() {
        let error = NSError(
            domain: "ScreenCaptureKit.SCStreamErrorDomain",
            code: -3801,
            userInfo: [
                NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"
            ]
        )

        XCTAssertTrue(ScreenCapturePermissionClassifier.isPermissionDenied(error))
    }

    func testScreenCapturePermissionClassifierIgnoresUnrelatedErrors() {
        let error = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            userInfo: [
                NSLocalizedDescriptionKey: "The operation timed out."
            ]
        )

        XCTAssertFalse(ScreenCapturePermissionClassifier.isPermissionDenied(error))
    }

    func testRecordingResultWarningSummaryFormatsOptionalFailures() {
        let result = RecordingResult(
            videoName: "Demo",
            screenRecordingURL: URL(fileURLWithPath: "/tmp/demo.mov"),
            microphoneRecordingURL: nil,
            cameraRecordingURL: nil,
            duration: 5,
            startTime: Date(timeIntervalSince1970: 0),
            endTime: Date(timeIntervalSince1970: 5),
            warnings: [
                RecordingWarning(component: .microphone, message: "Permission denied"),
                RecordingWarning(component: .camera, message: "Device unavailable")
            ]
        )

        XCTAssertEqual(
            result.warningSummary,
            "Microphone: Permission denied\nCamera: Device unavailable"
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SmoothyRECTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
