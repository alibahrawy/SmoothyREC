//
//  RegionSelectionOverlay.swift
//  SmoothyREC
//

import AppKit

/// A user-selected capture area on a specific display.
/// `rect` is in points with a top-left origin (what SCStreamConfiguration.sourceRect
/// expects); `scale` is the display's backing scale so callers can derive pixels.
struct SelectedRegion: Equatable {
    let displayID: CGDirectDisplayID
    let rect: CGRect
    let scale: CGFloat

    var pixelSize: CGSize {
        CGSize(width: rect.width * scale, height: rect.height * scale)
    }

    var displayString: String {
        "\(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }
}

/// Presents a dim full-screen overlay on the chosen display and lets the user
/// drag out a rectangle to capture. Escape cancels.
@MainActor
final class RegionSelectionController {
    private var window: NSWindow?

    func begin(on display: Display, completion: @escaping (SelectedRegion?) -> Void) {
        guard let screen = screen(for: display.id) else {
            completion(nil)
            return
        }

        let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
        let scale = screen.backingScaleFactor
        let viewHeight = screen.frame.height
        let displayID = display.id

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        self.window = window

        view.onComplete = { [weak self] viewRect in
            guard let self else { return }
            self.finish()

            guard let viewRect, viewRect.width >= 8, viewRect.height >= 8 else {
                completion(nil)
                return
            }

            // View coords are bottom-left; SCStream sourceRect is top-left.
            let topLeftRect = CGRect(
                x: viewRect.origin.x,
                y: viewHeight - (viewRect.origin.y + viewRect.height),
                width: viewRect.width,
                height: viewRect.height
            )
            completion(SelectedRegion(displayID: displayID, rect: topLeftRect, scale: scale))
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
    }

    private func finish() {
        window?.orderOut(nil)
        window = nil
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (screen.deviceDescription[key] as? NSNumber)?.uint32Value == displayID
        } ?? NSScreen.main
    }
}

private final class RegionSelectionView: NSView {
    /// Called with the selected rect in view coordinates (bottom-left origin),
    /// or nil if the user cancelled.
    var onComplete: ((CGRect?) -> Void)?

    private var startPoint: NSPoint?
    private var selection: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let current = convert(event.locationInWindow, from: nil)
        selection = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        onComplete?(selection)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onComplete?(nil)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard selection.width > 0, selection.height > 0 else {
            drawHint()
            return
        }

        // Punch the selection clear.
        NSColor.clear.setFill()
        selection.fill(using: .copy)

        // Outline.
        let border = NSBezierPath(rect: selection)
        border.lineWidth = 2
        NSColor.systemGreen.setStroke()
        border.stroke()

        // Size label.
        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = label.size(withAttributes: attrs)
        let point = NSPoint(x: selection.midX - size.width / 2,
                            y: selection.maxY + 6)
        label.draw(at: point, withAttributes: attrs)
    }

    private func drawHint() {
        let hint = "Drag to select an area to record  ·  Press Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9)
        ]
        let size = hint.size(withAttributes: attrs)
        let point = NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY)
        hint.draw(at: point, withAttributes: attrs)
    }
}
