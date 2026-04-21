//
//  AppDelegate+Windows.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import AppKit
import SwiftUI

extension AppDelegate {
    // MARK: - Completion Window

    func showCompletionWindow(result: RecordingResult) {
        let completionWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 550, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        completionWindow.title = "Recording Complete"
        completionWindow.center()
        completionWindow.contentViewController = NSHostingController(
            rootView: CompletionView(recordingResult: result).environmentObject(self)
        )
        completionWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Main Window

    func showMainWindow() {
        if mainWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 920),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SmoothyREC"
            window.center()
            window.isReleasedWhenClosed = false
            mainWindow = window
        }

        mainWindow?.contentViewController = NSHostingController(rootView: MainWindowView().environmentObject(self))
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Onboarding Window

    func showOnboardingWindow() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Welcome to SmoothyREC"
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }

        onboardingWindow?.contentViewController = NSHostingController(
            rootView: OnboardingView(onComplete: { [weak self] in
                if self?.hasCompletedOnboarding == true {
                    self?.onboardingWindow?.close()
                } else {
                    self?.completeOnboarding()
                }
            }).environmentObject(self)
        )

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        hasShownInitialPermissionPanel = true
        onboardingWindow?.close()
        showMainWindow()
    }

    func reopenOnboarding() {
        showOnboardingWindow()
    }

    // MARK: - Settings Window

    func openSettings() {
        openFullSettings()
    }

    func openFullSettings() {
        mainPopover?.performClose(nil)

        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 440),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "SmoothyREC Settings"
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }

        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(self))
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeMainPopover() {
        mainPopover?.performClose(nil)
        recordingStatusPopover?.performClose(nil)
    }

    func quitApp() {
        NSApp.terminate(nil)
    }
}
