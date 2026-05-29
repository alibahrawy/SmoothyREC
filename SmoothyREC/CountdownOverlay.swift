//
//  CountdownOverlay.swift
//  SmoothyREC
//
//  Created by SmoothyREC
//

import AppKit
import SwiftUI

/// Holds the current countdown number so the SwiftUI overlay updates reactively.
@MainActor
final class CountdownValue: ObservableObject {
    @Published var number: Int = 3
}

/// Manages a borderless, click-through overlay window on every screen that shows
/// a large countdown (3 → 2 → 1) before recording starts. The overlay is torn
/// down before capture begins, so it never appears in the recording itself.
@MainActor
final class CountdownOverlayController {
    private var windows: [NSWindow] = []
    private let value = CountdownValue()

    func show(startingAt seconds: Int) {
        value.number = seconds
        guard windows.isEmpty else { return }

        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .screenSaver
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)
            window.contentView = NSHostingView(rootView: CountdownOverlayView(value: value))
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func update(_ number: Int) {
        value.number = number
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }
}

private struct CountdownOverlayView: View {
    @ObservedObject var value: CountdownValue

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)

            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 320, height: 320)

                Text("\(value.number)")
                    .font(.system(size: 200, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
            }
            .id(value.number)
            .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: value.number)
    }
}
