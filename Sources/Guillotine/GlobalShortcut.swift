// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import AppKit
import Carbon

struct Shortcut: Equatable {
    var key: UInt32
    var modifiers: UInt32
    static let standard = Shortcut(key: UInt32(kVK_Space), modifiers: UInt32(cmdKey | optionKey | controlKey))
    static let keys: [(String, UInt32)] = [
        ("Space", UInt32(kVK_Space)), ("A", 0), ("B", 11), ("C", 8), ("D", 2), ("E", 14), ("F", 3),
        ("G", 5), ("H", 4), ("I", 34), ("J", 38), ("K", 40), ("L", 37),
        ("M", 46), ("N", 45), ("O", 31), ("P", 35), ("Q", 12), ("R", 15),
        ("S", 1), ("T", 17), ("U", 32), ("V", 9), ("W", 13), ("X", 7),
        ("Y", 16), ("Z", 6), ("F1", 122), ("F2", 120), ("F3", 99), ("F4", 118),
        ("F5", 96), ("F6", 97), ("F7", 98), ("F8", 100), ("F9", 101), ("F10", 109),
        ("F11", 103), ("F12", 111)
    ]
    static let modifierChoices: [(String, UInt32)] = [
        ("Fn 🌐", UInt32(kEventKeyModifierFnMask)), ("Control ⌃", UInt32(controlKey)), ("Option ⌥", UInt32(optionKey)),
        ("Command ⌘", UInt32(cmdKey)), ("Shift ⇧", UInt32(shiftKey))
    ]
    var valid: Bool {
        let permitted = UInt32(controlKey | optionKey | shiftKey | cmdKey) | UInt32(kEventKeyModifierFnMask)
        return Self.keys.contains { $0.1 == key } && modifiers & ~permitted == 0
            && modifiers.nonzeroBitCount >= 2 && modifiers & UInt32(controlKey | cmdKey) != 0
    }
    var label: String {
        let symbols: [(UInt32, String)] = [(UInt32(kEventKeyModifierFnMask), "Fn"), (UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined()
            + (Self.keys.first { $0.1 == key }?.0 ?? "?")
    }
    static func load(from defaults: UserDefaults = .standard) -> Shortcut {
        guard defaults.object(forKey: "shortcutKey") != nil else { return .standard }
        let stored = Shortcut(key: UInt32(clamping: defaults.integer(forKey: "shortcutKey")), modifiers: UInt32(clamping: defaults.integer(forKey: "shortcutModifiers")))
        return stored.valid ? stored : .standard
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(Int(key), forKey: "shortcutKey")
        defaults.set(Int(modifiers), forKey: "shortcutModifiers")
    }
}

@MainActor final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static let signature: OSType = 0x4755494C // GUIL

    init(action: @escaping () -> Void) { self.action = action }

    func register(_ shortcut: Shortcut) throws {
        guard shortcut.valid else {
            throw NSError(domain: "Guillotine.Shortcut", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use at least two modifiers, including Control or Command."])
        }
        if handler == nil {
            var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                      identifier.signature == GlobalShortcut.signature, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
                MainActor.assumeIsolated {
                    Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().action()
                }
                return noErr
            }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { throw failure(result) }
        }
        // Reserve the replacement before releasing the current key. Failed changes leave
        // the existing emergency shortcut intact.
        var replacement: EventHotKeyRef?
        let result = RegisterEventHotKey(shortcut.key, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: 1), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &replacement)
        guard result == noErr else { throw failure(result) }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = replacement
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }
    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: "Guillotine.Shortcut", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "macOS could not register this shortcut (\(status)). Choose a different combination; it may be in use by another app."])
    }
}
