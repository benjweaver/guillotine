// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import Foundation
import IOKit.ps

@MainActor final class PowerMonitor {
    private var source: CFRunLoopSource?
    var onChange: ((PowerState) -> Void)?

    static func current() -> PowerState {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let provider = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else {
            return .unknown
        }
        // This API reports AC for desktop Macs with no battery. Do not inspect IsCharging:
        // optimized charging and a full battery must still qualify as external power.
        switch provider as String {
        case kIOPSACPowerValue: return .external
        case kIOPSBatteryPowerValue: return .battery
        case kIOPMUPSPowerKey: return .ups
        default: return .unknown
        }
    }

    static var hasInternalBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            // Unknown hardware must not be advertised as a desktop with no lid.
            return true
        }
        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    func start() -> Bool {
        guard source == nil else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // Registered ONLY on the main run loop. Read each event immediately so an
            // unplug followed by a replug cannot be coalesced by an async Task we create.
            MainActor.assumeIsolated {
                let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
                monitor.onChange?(PowerMonitor.current())
            }
        }, context)?.takeRetainedValue() else { return false }
        source = created
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        onChange?(Self.current())
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        source = nil
        onChange = nil
    }
}
