//
//  HotKeyManager.swift
//  SmoothyREC
//

import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut expressed in Carbon terms (virtual key code + Carbon
/// modifier mask), which is what `RegisterEventHotKey` expects.
struct HotKeyCombo: Equatable {
    var keyCode: Int
    var modifiers: Int

    var isValid: Bool { keyCode >= 0 && modifiers != 0 }
}

/// Registers system-wide hotkeys via Carbon. Carbon hotkeys are used instead of
/// an NSEvent global monitor because they work without Accessibility/Input
/// Monitoring permission and fire even when SmoothyREC is in the background.
@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private struct Entry {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var entries: [UInt32: Entry] = [:]
    private var handlerInstalled = false
    private var idCounter: UInt32 = 0

    private init() {}

    @discardableResult
    func register(_ combo: HotKeyCombo, action: @escaping () -> Void) -> UInt32? {
        guard combo.isValid else { return nil }
        installHandlerIfNeeded()

        idCounter += 1
        let id = idCounter
        let hotKeyID = EventHotKeyID(signature: OSType(0x53524543), id: id) // 'SREC'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            UInt32(combo.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return nil }
        entries[id] = Entry(ref: ref, action: action)
        return id
    }

    func unregisterAll() {
        for entry in entries.values {
            UnregisterEventHotKey(entry.ref)
        }
        entries.removeAll()
    }

    fileprivate func fire(id: UInt32) {
        entries[id]?.action()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let firedID = hotKeyID.id
                Task { @MainActor in
                    HotKeyManager.shared.fire(id: firedID)
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )
    }
}

// MARK: - Modifier / Key display helpers

enum HotKeyFormatter {
    /// Converts AppKit modifier flags to the Carbon mask used by RegisterEventHotKey.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var carbon = 0
        if flags.contains(.command) { carbon |= cmdKey }
        if flags.contains(.shift) { carbon |= shiftKey }
        if flags.contains(.option) { carbon |= optionKey }
        if flags.contains(.control) { carbon |= controlKey }
        return carbon
    }

    static func modifierSymbols(_ carbon: Int) -> String {
        var symbols = ""
        if carbon & controlKey != 0 { symbols += "⌃" }
        if carbon & optionKey != 0 { symbols += "⌥" }
        if carbon & shiftKey != 0 { symbols += "⇧" }
        if carbon & cmdKey != 0 { symbols += "⌘" }
        return symbols
    }

    static func displayString(keyCode: Int, modifiers: Int) -> String {
        modifierSymbols(modifiers) + keyName(for: keyCode)
    }

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Escape: return "⎋"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key \(keyCode)"
        }
    }
}
