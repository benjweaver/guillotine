// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import SwiftUI
import ServiceManagement

@MainActor final class PreferencesModel: ObservableObject {
    @Published private(set) var shortcut = Shortcut.load()
    @Published var shortcutError: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var loginError: String?
    var applyShortcut: ((Shortcut) throws -> Void)?

    func changeShortcut(_ candidate: Shortcut) {
        guard candidate != shortcut else { return }
        do {
            guard let applyShortcut else { return }
            try applyShortcut(candidate)
            shortcut = candidate
            shortcut.save()
            shortcutError = nil
        } catch { shortcutError = error.localizedDescription }
    }
    func refreshLoginStatus() {
        loginEnabled = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch { loginError = "Could not update launch at login: \(error.localizedDescription). Keep the app in Applications and try again." }
        refreshLoginStatus()
    }
}

struct SettingsView: View {
    @ObservedObject var session: SessionController
    @ObservedObject var preferences: PreferencesModel
    @State private var key: UInt32 = Shortcut.standard.key
    @State private var modifiers: UInt32 = Shortcut.standard.modifiers
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: GuillotineGlyph.menuImage(active: session.enabled))
                    .resizable().frame(width: 34, height: 34).foregroundStyle(.primary)
                VStack(alignment: .leading) {
                    Text("Guillotine").font(.title2.bold())
                    Text("Off with the head.").foregroundStyle(.secondary)
                }
                Spacer()
                Text(session.enabled ? "ON" : "OFF").font(.caption.bold()).padding(8)
                    .background(session.enabled ? Color.green.opacity(0.15) : Color.secondary.opacity(0.1), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(session.power.label, systemImage: session.power == .external ? "powerplug.fill" : "battery.50")
                Text(DisplayStatus.summary).font(.caption).foregroundStyle(.secondary)
                Text(session.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(session.enabled ? "Disable Headless Mode" : "Enable Headless Mode") {
                    if session.enabled { session.disable() } else { session.enable() }
                }
                if let error = session.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Global disable shortcut").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), alignment: .leading)], alignment: .leading) {
                    ForEach(Shortcut.modifierChoices, id: \.1) { entry in
                        Toggle(entry.0, isOn: Binding(get: { modifiers & entry.1 != 0 }, set: { if $0 { modifiers |= entry.1 } else { modifiers &= ~entry.1 } }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Picker("Key", selection: $key) {
                        ForEach(Shortcut.keys, id: \.1) { Text($0.0).tag($0.1) }
                    }.frame(width: 135)
                    Spacer()
                    Text(preferences.shortcut.label).monospaced().foregroundStyle(.secondary)
                    Button("Apply") { preferences.changeShortcut(Shortcut(key: key, modifiers: modifiers)) }
                        .disabled(!Shortcut(key: key, modifiers: modifiers).valid)
                }
                Text("Choose at least two modifiers, including Control or Command. Key positions use the US layout. Fn requires a keyboard with that key. Works while another app has focus; Secure Input or a locked screen may block hotkeys.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = preferences.shortcutError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
            Divider()
            Toggle("Launch Guillotine at login (always starts disabled)", isOn: Binding(get: { preferences.loginEnabled || preferences.loginNeedsApproval }, set: preferences.setLogin))
            if preferences.loginNeedsApproval {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = preferences.loginError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Lid-open and desktop operation use a temporary IOKit assertion. Closing a MacBook needs macOS clamshell setup; no software-only lid override is installed. A capturable desktop is a separate streaming requirement. See Headless Setup & Limitations in the menu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 500)
        .onAppear { key = preferences.shortcut.key; modifiers = preferences.shortcut.modifiers; session.refreshPower() }
        .onChange(of: scenePhase) { _ in preferences.refreshLoginStatus() }
    }
}
