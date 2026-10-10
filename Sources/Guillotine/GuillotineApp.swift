// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import SwiftUI
import AppKit

@main struct GuillotineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene { Settings { EmptyView() } }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let session = SessionController(assertion: IdleSleepAssertion(), readPower: PowerMonitor.current)
    private let monitor = PowerMonitor()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var observations: [NSObjectProtocol] = []
    private lazy var preferences = PreferencesModel()
    private lazy var shortcut = GlobalShortcut { [weak self] in
        self?.session.disable(reason: "Headless Mode turned off with the global shortcut.")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        session.onChange = { [weak self] in self?.updateIcon() }
        monitor.onChange = { [weak self] value in self?.session.powerChanged(value) }
        session.monitoringAvailable = monitor.start()
        session.refreshPower()
        preferences.applyShortcut = { [weak self] candidate in
            guard let self else { return }
            try self.shortcut.register(candidate)
            self.session.shortcutAvailable = true
        }
        do {
            try shortcut.register(preferences.shortcut)
            session.shortcutAvailable = true
        } catch { preferences.shortcutError = error.localizedDescription }
        let center = NSWorkspace.shared.notificationCenter
        observations.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.disable(reason: "System sleep requested. Enable again when needed.") }
        })
        observations.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.refreshPower() }
        })
        observations.append(center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.disable() }
        })
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        button.image = GuillotineGlyph.menuImage(active: session.enabled)
        button.toolTip = "Guillotine — Headless Mode \(session.enabled ? "On" : "Off") • \(session.power.label)"
        button.setAccessibilityLabel(button.toolTip)
    }

    func menuWillOpen(_ menu: NSMenu) {
        session.refreshPower()
        preferences.refreshLoginStatus()
        menu.removeAllItems()
        add("Guillotine · Off with the head", to: menu)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: session.enabled ? "Disable Headless Mode" : "Enable Headless Mode", action: #selector(toggleMode), keyEquivalent: "")
        toggle.target = self
        toggle.state = session.enabled ? .on : .off
        menu.addItem(toggle)
        add(session.power.label, to: menu)
        add(DisplayStatus.summary, to: menu)
        add(session.enabled ? "Display sleep and backlight timeout allowed" : "Normal sleep policies apply", to: menu)
        if let error = session.error {
            let item = NSMenuItem()
            item.view = NSHostingView(rootView: Text(error).font(.caption).foregroundStyle(.red).frame(width: 290, alignment: .leading).padding(10))
            menu.addItem(item)
        }
        if !session.monitoringAvailable { add("Power notifications unavailable — reopen app", to: menu) }
        add("Disable shortcut: \(preferences.shortcut.label)\(session.shortcutAvailable ? "" : " (unavailable)")", to: menu)
        menu.addItem(.separator())
        action("Settings…", #selector(showSettings), to: menu)
        action("Headless Setup & Limitations…", #selector(showGuide), to: menu)
        menu.addItem(.separator())
        action("Quit Guillotine", #selector(quit), to: menu, key: "q")
    }

    private func add(_ title: String, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.addItem(item)
    }
    private func action(_ title: String, _ selector: Selector, to menu: NSMenu, key: String = "") {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
    @objc private func toggleMode() {
        if session.enabled { session.disable() } else { session.enable() }
        if session.error != nil { showSettings() }
    }
    @objc private func showSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: SettingsView(session: session, preferences: preferences))
            let window = NSWindow(contentViewController: controller)
            window.title = "Guillotine Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        preferences.refreshLoginStatus()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc private func showGuide() {
        guard let url = Bundle.main.url(forResource: "HeadlessGuide", withExtension: "txt") else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func quit() {
        session.disable()
        NSApp.terminate(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        session.disable()
        monitor.stop()
        shortcut.stop()
        observations.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }
}

enum DisplayStatus {
    @MainActor static var summary: String {
        guard PowerMonitor.hasInternalBattery else { return "Closed lid: not applicable to desktop Macs" }
        let external = NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) == 0
        }
        return external
            ? "Closed lid: display detected; setup must be verified"
            : "Closed lid: unavailable without clamshell setup"
    }
}
