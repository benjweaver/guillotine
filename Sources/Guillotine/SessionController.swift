// SPDX-License-Identifier: GPL-3.0-only
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

@MainActor protocol SleepAssertion: AnyObject {
    func acquire() throws
    func release() throws
}

/// Every event and both activation power checks run synchronously on the main actor.
/// Enabled is deliberately never persisted. The assertion is the only owned override.
@MainActor final class SessionController: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var power: PowerState = .unknown
    @Published private(set) var message = "Headless Mode starts off."
    @Published private(set) var error: String?
    var monitoringAvailable = false
    var shortcutAvailable = false
    var onChange: (() -> Void)?

    private let assertion: SleepAssertion
    private let readPower: () -> PowerState

    init(assertion: SleepAssertion, readPower: @escaping () -> PowerState) {
        self.assertion = assertion
        self.readPower = readPower
    }

    func refreshPower() { powerChanged(readPower()) }

    func powerChanged(_ value: PowerState) {
        power = value
        if value != .external && enabled {
            disable(reason: "Headless Mode turned off: \(value.label.lowercased()).")
        }
        onChange?()
    }

    func enable() {
        guard !enabled else { return }
        error = nil
        guard monitoringAvailable else {
            fail("Power notifications are unavailable. Quit and reopen Guillotine before enabling.")
            return
        }
        guard shortcutAvailable else {
            fail("The disable shortcut is unavailable. Choose an unused shortcut in Settings.")
            return
        }
        // Never trust the cached menu value when acquiring an assertion.
        power = readPower()
        guard power == .external else {
            fail("Connect external power before enabling Headless Mode. Charging is not required.")
            return
        }
        do {
            try assertion.acquire()
            enabled = true
            // Close the check/acquire window. The notification source handles later changes.
            power = readPower()
            if power != .external {
                disable(reason: "Power changed during activation; Headless Mode turned off.")
                return
            }
            message = "Idle system sleep prevented. Display sleep remains allowed."
            onChange?()
        } catch {
            fail("Could not prevent idle sleep: \(error.localizedDescription)")
        }
    }

    func disable(reason: String = "Headless Mode is off. Normal sleep policies apply.") {
        guard enabled else { return }
        do {
            try assertion.release()
            enabled = false
            error = nil
            message = reason
            onChange?()
        } catch {
            // Do not pretend release succeeded. Keep ownership so another disable can retry.
            fail("Could not release the sleep assertion: \(error.localizedDescription). Retry Disable or quit Guillotine; macOS releases it when the process exits.")
        }
    }

    private func fail(_ description: String) {
        error = description
        onChange?()
    }
}
