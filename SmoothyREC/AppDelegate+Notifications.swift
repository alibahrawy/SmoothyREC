//
//  AppDelegate+Notifications.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import Foundation
import UserNotifications
import os.log

private let notificationLogger = Logger(subsystem: "com.smoothyrec.SmoothyREC", category: "Notifications")

extension AppDelegate {
    func setupNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            notificationLogger.info("Notification permission: \(granted)")
        }
    }

    func showRecordingStartedNotification() {
        let notification = UNMutableNotificationContent()
        notification.title = "Recording Started"
        notification.body = recordingCoordinator.canPause
            ? "Click the timer in your menu bar to pause or stop."
            : "Click the timer in your menu bar to stop the recording."
        notification.sound = nil

        let request = UNNotificationRequest(
            identifier: "recording-started",
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func showRecordingFinishedNotification(result: RecordingResult) {
        let notification = UNMutableNotificationContent()
        notification.title = result.warnings.isEmpty ? "Recording Saved" : "Recording Saved With Warnings"

        var bodyParts: [String] = []
        if result.screenRecordingURL != nil { bodyParts.append("Screen") }
        if result.microphoneRecordingURL != nil { bodyParts.append("Mic") }
        if result.cameraRecordingURL != nil { bodyParts.append("Camera") }

        let savedText = bodyParts.isEmpty ? "No files" : bodyParts.joined(separator: ", ")
        notification.body = "Saved: \(savedText) (\(formatDuration(result.duration)))"
        notification.sound = .default

        let request = UNNotificationRequest(
            identifier: "recording-finished-\(result.startTime)",
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }

    func showRecordingErrorNotification(error: Error) {
        let notification = UNMutableNotificationContent()

        if isScreenPermissionChangeRequiresRelaunch(error) {
            notification.title = "Relaunch Required"
            notification.body = "Relaunch SmoothyREC before starting screen capture again."
        } else if isScreenRecordingPermissionDenied(error) {
            notification.title = "Screen Recording Permission Required"
            notification.body = "Enable Screen Recording for SmoothyREC in System Settings."
        } else {
            notification.title = "Recording Error"
            notification.body = error.localizedDescription
        }

        notification.sound = .default

        let request = UNNotificationRequest(
            identifier: "recording-error-\(Date())",
            content: notification,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request)
    }
}
