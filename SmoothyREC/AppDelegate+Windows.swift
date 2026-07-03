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
        // ARC owns this window; letting AppKit release it on close would
        // over-release and crash when the user closes the completion window.
        completionWindow.isReleasedWhenClosed = false
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
        // Build the window AND its content once. Replacing the content view
        // controller on every show wiped the user's video name and selections,
        // spun up duplicate capture pipelines, and let a hotkey pressed during
        // the countdown start a second recording from a fresh view.
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
            window.contentViewController = NSHostingController(rootView: MainWindowView().environmentObject(self))
            mainWindow = window
        }

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
            window.delegate = self
            window.contentViewController = NSHostingController(
                rootView: OnboardingView(onComplete: { [weak self] in
                    if self?.hasCompletedOnboarding == true {
                        self?.onboardingWindow?.close()
                    } else {
                        self?.completeOnboarding()
                    }
                }).environmentObject(self)
            )
            onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        hasShownInitialPermissionPanel = true
        onboardingWindow?.close()
        showMainWindow()

        // If the user granted Screen Recording during onboarding, macOS still
        // needs the app to relaunch before SCStream becomes usable. The
        // settings-return path doesn't fire because onboarding opens Settings
        // directly via NSWorkspace, so we explicitly probe here.
        Task { @MainActor in
            await self.detectScreenPermissionFlipSinceLaunch()
        }
    }

    func reopenOnboarding() {
        showOnboardingWindow()
    }

    // MARK: - NSWindowDelegate

    /// Closing the permission panel — by the Continue button or the window's
    /// close control — permanently suppresses auto-opening it on future launches.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === onboardingWindow else { return }

        hasDismissedPermissionPanel = true
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
            window.contentViewController = NSHostingController(rootView: SettingsView().environmentObject(self))
            settingsWindow = window
        }

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

    // MARK: - Updates

    static let githubRepo = "alibahrawy/SmoothyREC"
    static let releasesURL = "https://github.com/alibahrawy/SmoothyREC/releases/latest"

    /// Manual check from the menu — always reports a result.
    func checkForUpdates() {
        Task { await self.checkForUpdates(interactive: true) }
    }

    /// Compares the newest GitHub release against the running version. The
    /// app is unsigned for now, so instead of an in-app updater we send users
    /// to the release page to download.
    func checkForUpdates(interactive: Bool) async {
        struct Release: Decodable {
            let tag_name: String
            let html_url: String
        }

        guard let url = URL(string: "https://api.github.com/repos/\(Self.githubRepo)/releases/latest") else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let release = try JSONDecoder().decode(Release.self, from: data)

            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

            if Self.isVersion(latest, newerThan: current) {
                let alert = NSAlert()
                alert.messageText = "SmoothyREC \(latest) is available"
                alert.informativeText = "You're on \(current). Download the new version from GitHub."
                alert.addButton(withTitle: "Download")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn, let page = URL(string: release.html_url) {
                    NSWorkspace.shared.open(page)
                }
            } else if interactive {
                let alert = NSAlert()
                alert.messageText = "You're up to date"
                alert.informativeText = "SmoothyREC \(current) is the latest version."
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        } catch {
            guard interactive else { return }
            let alert = NSAlert()
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = "Check your internet connection, or visit the releases page directly."
            alert.addButton(withTitle: "Open Releases Page")
            alert.addButton(withTitle: "OK")
            if alert.runModal() == .alertFirstButtonReturn, let page = URL(string: Self.releasesURL) {
                NSWorkspace.shared.open(page)
            }
        }
    }

    /// Numeric dotted-version comparison ("1.10.0" > "1.9.1").
    static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }
}
