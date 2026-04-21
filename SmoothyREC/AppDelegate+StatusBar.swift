//
//  AppDelegate+StatusBar.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import AppKit
import SwiftUI

extension AppDelegate {
    // MARK: - Main Menu Bar

    func setupMainMenuBar() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 400)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ContentView().environmentObject(self))
        mainPopover = popover

        mainStatusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = mainStatusItem?.button {
            updateMainStatusButton()
            button.action = #selector(toggleMainPopover)
            button.target = self
        }
    }

    @objc func toggleMainPopover() {
        guard let button = mainStatusItem?.button else { return }

        let activePopover = isRecording ? recordingStatusPopover : mainPopover
        let inactivePopover = isRecording ? mainPopover : recordingStatusPopover

        guard let popover = activePopover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            inactivePopover?.performClose(nil)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func updateMainStatusButton() {
        guard let button = mainStatusItem?.button else { return }

        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        if isRecording {
            let symbolName = isPaused ? "pause.circle.fill" : "record.circle.fill"
            let symbolColor = isPaused ? NSColor.systemOrange : NSColor.systemRed
            button.image = configuredStatusImage(symbolName: symbolName, color: symbolColor)
            button.attributedTitle = statusButtonTitle(" \(recordingCoordinator.formattedDuration)")
            button.contentTintColor = nil
        } else {
            button.image = configuredStatusImage(symbolName: "record.circle", color: .labelColor)
            button.attributedTitle = statusButtonTitle("")
            button.contentTintColor = nil
        }
    }

    // MARK: - Recording Status Popover

    func setupRecordingStatusMenuBar() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 200)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: RecordingStatusView().environmentObject(self))
        recordingStatusPopover = popover
    }

    func updateRecordingStatusButton() {
        guard isRecording else { return }
        updateMainStatusButton()
    }

    private func configuredStatusImage(symbolName: String, color: NSColor) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SmoothyREC")
        let image = baseImage?.withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }

    private func statusButtonTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
    }
}
