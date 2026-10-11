// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import Foundation
import Combine

enum PowerState: String, Equatable {
    case external, battery, ups, unknown

    var label: String {
        switch self {
        case .external: return "External power connected"
        case .battery: return "Running on battery"
        case .ups: return "Running on UPS battery"
        case .unknown: return "Power source unavailable"
        }
    }
}

@MainActor protocol HardwareControl: AnyObject {
    func acquire() throws
    func release() throws
}

/// Every event and both activation power checks run synchronously on the main actor.
/// Enabled is deliberately never persisted. Only physical panel power and keyboard backlight are owned.
@MainActor final class SessionController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var power: PowerState = .unknown
    @Published private(set) var message = "Physical controls start restored."
    @Published private(set) var error: String?
    var allowBattery = false { didSet { refreshPower() } }
    var monitoringAvailable = false
    var shortcutAvailable = false
    var onChange: (() -> Void)?

    private let controls: HardwareControl
    private let readPower: () -> PowerState

    init(controls: HardwareControl, readPower: @escaping () -> PowerState) {
        self.controls = controls
        self.readPower = readPower
    }

    func refreshPower() { powerChanged(readPower()) }

    func powerChanged(_ value: PowerState) {
        power = value
        if enabled && !allowBattery && value != .external { disable(reason: "Restored: battery operation is disabled.") }
        onChange?()
    }

    func enable() {
        guard !enabled else { return }
        error = nil
        guard shortcutAvailable else {
            fail("The disable shortcut is unavailable. Choose an unused shortcut in Settings.")
            return
        }
        power = readPower()
        guard monitoringAvailable else { fail("Power notifications unavailable. Reopen Guillotine."); return }
        guard allowBattery || power == .external else { fail("Connect power or enable Allow on battery in Settings."); return }
        do {
            try controls.acquire()
            enabled = true
            power = readPower()
            if !allowBattery && power != .external { disable(reason: "Restored: power disconnected during activation."); return }
            message = "Built-in panel power and keyboard backlight off requested."
            onChange?()
        } catch {
            fail("Could not cut screen and keyboard power: \(error.localizedDescription)")
        }
    }

    func disable(reason: String = "Physical panel and keyboard backlight restored.") {
        guard enabled else { return }
        do {
            try controls.release()
            enabled = false
            error = nil
            message = reason
            onChange?()
        } catch {
            // Do not pretend release succeeded. Keep ownership so another disable can retry.
            fail("Could not restore physical controls: \(error.localizedDescription). Retry Restore or quit Guillotine; the independent guard restores on disconnect or lease expiry.")
        }
    }

    func reportRestoration(_ text: String) {
        guard !enabled else { return }
        error = nil
        message = text
        onChange?()
    }

    func reportError(_ text: String) { fail(text) }

    private func fail(_ description: String) {
        error = description
        onChange?()
    }
}
