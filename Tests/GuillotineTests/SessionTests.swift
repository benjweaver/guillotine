// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import XCTest
import Carbon
@testable import Guillotine

@MainActor final class SessionTests: XCTestCase {
    final class Assertion: HardwareControl {
        var acquisitions = 0
        var releases = 0
        var owned = false
        var failAcquire = false
        var failRelease = false
        func acquire() throws {
            if failAcquire { throw NSError(domain: "test", code: 1) }
            acquisitions += 1
            owned = true
        }
        func release() throws {
            if failRelease { throw NSError(domain: "test", code: 2) }
            releases += 1
            owned = false
        }
    }
    private func make(_ assertion: Assertion, read: @escaping () -> PowerState = { .external }) -> SessionController {
        let controller = SessionController(controls: assertion, readPower: read)
        controller.monitoringAvailable = true
        controller.shortcutAvailable = true
        return controller
    }
    func testAlwaysStartsDisabledEvenOnAC() {
        let assertion = Assertion()
        let controller = make(assertion)
        controller.refreshPower()
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(assertion.acquisitions, 0)
    }
    func testBatteryUPSAndUnknownCanActivate() {
        for power in [PowerState.battery, .ups, .unknown] {
            let assertion = Assertion()
            let controller = make(assertion, read: { power })
            controller.enable()
            XCTAssertTrue(controller.enabled)
            XCTAssertNil(controller.error)
            XCTAssertEqual(assertion.acquisitions, 1)
        }
    }
    func testUnplugAndReplugPreserveActiveSession() {
        let assertion = Assertion()
        let controller = make(assertion)
        controller.enable()
        controller.powerChanged(.battery)
        XCTAssertTrue(controller.enabled)
        XCTAssertTrue(assertion.owned)
        XCTAssertEqual(assertion.releases, 0)
        controller.powerChanged(.external)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(assertion.acquisitions, 1)
    }
    func testUnknownAndUPSPreserveSession() {
        for power in [PowerState.unknown, .ups] {
            let assertion = Assertion()
            let controller = make(assertion)
            controller.enable()
            controller.powerChanged(power)
            XCTAssertTrue(assertion.owned)
        }
    }
    func testPowerChangingDuringActivationIsInformational() {
        let assertion = Assertion()
        var reads = 0
        let controller = make(assertion) {
            reads += 1
            return reads == 1 ? .external : .battery
        }
        controller.enable()
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(controller.power, .battery)
        XCTAssertEqual(assertion.acquisitions, 1)
        XCTAssertEqual(assertion.releases, 0)
    }
    func testBatteryActivationRefreshesPowerStatus() {
        let assertion = Assertion()
        let controller = make(assertion, read: { .battery })
        controller.powerChanged(.external)
        controller.enable()
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(controller.power, .battery)
        XCTAssertEqual(assertion.acquisitions, 1)
    }
    func testRepeatedTogglesAreBalancedAndIdempotent() {
        let assertion = Assertion()
        let controller = make(assertion)
        for _ in 0..<100 {
            controller.enable()
            controller.enable()
            controller.disable()
            controller.disable()
        }
        XCTAssertEqual(assertion.acquisitions, 100)
        XCTAssertEqual(assertion.releases, 100)
        XCTAssertFalse(assertion.owned)
    }
    func testNotificationsAreOptionalButShortcutIsRequired() {
        let assertion = Assertion()
        let controller = make(assertion)
        controller.monitoringAvailable = false
        controller.enable()
        XCTAssertTrue(controller.enabled)
        controller.disable()
        controller.monitoringAvailable = true
        controller.shortcutAvailable = false
        controller.enable()
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(assertion.acquisitions, 1)
    }
    func testAcquireFailureLeavesNoEnabledState() {
        let assertion = Assertion()
        assertion.failAcquire = true
        let controller = make(assertion)
        controller.enable()
        XCTAssertFalse(controller.enabled)
        XCTAssertNotNil(controller.error)
    }
    func testReleaseFailurePreservesOwnershipForRetry() {
        let assertion = Assertion()
        let controller = make(assertion)
        controller.enable()
        assertion.failRelease = true
        controller.disable()
        XCTAssertTrue(controller.enabled)
        XCTAssertNotNil(controller.error)
        assertion.failRelease = false
        controller.disable()
        XCTAssertFalse(controller.enabled)
        XCTAssertNil(controller.error)
        XCTAssertEqual(assertion.releases, 1)
    }
    func testRelaunchDoesNotRestoreActiveSession() {
        let assertion = Assertion()
        let first = make(assertion)
        first.enable()
        first.disable() // termination path
        let next = make(Assertion())
        next.refreshPower()
        XCTAssertFalse(next.enabled)
    }
    func testShortcutValidationAndPersistence() {
        XCTAssertTrue(Shortcut.standard.valid)
        XCTAssertEqual(Shortcut.standard.key, UInt32(kVK_Space))
        XCTAssertEqual(Shortcut.standard.modifiers, UInt32(cmdKey | optionKey | controlKey))
        XCTAssertEqual(Shortcut.standard.label, "⌃⌥⌘Space")
        XCTAssertFalse(Shortcut(key: 4, modifiers: 0).valid)
        XCTAssertFalse(Shortcut(key: 999, modifiers: Shortcut.standard.modifiers).valid)
        let suite = "GuillotineTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let changed = Shortcut(key: 0, modifiers: Shortcut.standard.modifiers)
        changed.save(to: defaults)
        XCTAssertEqual(Shortcut.load(from: defaults), changed)
        defaults.set(-100, forKey: "shortcutKey")
        defaults.set(-100, forKey: "shortcutModifiers")
        XCTAssertEqual(Shortcut.load(from: defaults), .standard)
    }
    func testRealGlobalShortcutReplacementAndConflict() throws {
        let first = GlobalShortcut(action: {})
        let second = GlobalShortcut(action: {})
        defer { first.stop(); second.stop() }
        let one = Shortcut(key: 97, modifiers: Shortcut.standard.modifiers | UInt32(shiftKey))
        let two = Shortcut(key: 98, modifiers: one.modifiers)
        try first.register(one)
        XCTAssertThrowsError(try second.register(one))
        try first.register(two)
        // The old key is now available, while the replacement is still reserved.
        try second.register(one)
        XCTAssertThrowsError(try second.register(two))
    }
    func testFnSpaceShortcutCanBeReservedExclusively() throws {
        let first = GlobalShortcut(action: {})
        let second = GlobalShortcut(action: {})
        defer { first.stop(); second.stop() }
        // The test host itself reserves the default. Add Shift for an independent
        // Fn+Space reservation so this test does not conflict with its own app.
        let candidate = Shortcut(key: Shortcut.standard.key, modifiers: Shortcut.standard.modifiers | UInt32(shiftKey) | UInt32(kEventKeyModifierFnMask))
        try first.register(candidate)
        XCTAssertThrowsError(try second.register(candidate))
        first.stop()
        try second.register(candidate)
    }
    func testCarbonHotkeyEventDisablesSession() throws {
        let assertion = Assertion()
        let controller = make(assertion)
        controller.enable()
        let shortcut = GlobalShortcut { controller.disable() }
        defer { shortcut.stop() }
        try shortcut.register(Shortcut(key: 97, modifiers: Shortcut.standard.modifiers | UInt32(shiftKey)))
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), GetCurrentEventTime(), EventAttributes(kEventAttributeUserEvent), &event), noErr)
        let created = try XCTUnwrap(event)
        defer { ReleaseEvent(created) }
        var identifier = EventHotKeyID(signature: 0x4755494C, id: 1)
        XCTAssertEqual(SetEventParameter(created, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier), noErr)
        XCTAssertEqual(SendEventToEventTarget(created, GetApplicationEventTarget()), noErr)
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(assertion.releases, 1)
    }
}
