// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import SwiftUI
import ServiceManagement

@MainActor final class PreferencesModel: ObservableObject {
    @Published private(set) var shortcut = Shortcut.load()
    @Published var shortcutError: String?
    @Published private(set) var loginEnabled = false
    @Published private(set) var loginNeedsApproval = false
    @Published var loginError: String?
    @Published var restoreOnSleep = UserDefaults.standard.bool(forKey: "restoreOnSleep") {
        didSet { UserDefaults.standard.set(restoreOnSleep, forKey: "restoreOnSleep") }
    }
    @Published var restoreOnWake = UserDefaults.standard.bool(forKey: "restoreOnWake") {
        didSet { UserDefaults.standard.set(restoreOnWake, forKey: "restoreOnWake") }
    }
    private let lidService = SMAppService.daemon(plistName: "dev.guillotine.LidHelper.plist")
    @Published private(set) var lidHelperStatus = "Not installed"
    @Published private(set) var lidHelperState = SMAppService.Status.notRegistered
    @Published var lidHelperError: String?
    var lidHelperReady: Bool { lidService.status == .enabled }
    func refreshLidHelper() {
        lidHelperState = lidService.status
        switch lidHelperState {
        case .enabled: lidHelperStatus = "Approved"; lidHelperError = nil
        case .requiresApproval: lidHelperStatus = "Administrator approval required in Login Items"
        case .notRegistered: lidHelperStatus = "Not installed"
        default: lidHelperStatus = "Unavailable—keep Guillotine in Applications"
        }
    }
    func installLidHelper() {
        do { try lidService.register(); lidHelperError = nil }
        catch { lidHelperError = error.localizedDescription }
        refreshLidHelper()
        if lidHelperState == .requiresApproval { lidHelperError = nil }
    }
    func removeLidHelper() {
        do { try lidService.unregister(); lidHelperError = nil }
        catch { lidHelperError = error.localizedDescription }
        refreshLidHelper()
    }
    private let energyDefaults: UserDefaults
    var energyPolicyChanged: (() -> Void)?
    @Published var batterySleepEnabled: Bool {
        didSet { energyDefaults.set(batterySleepEnabled, forKey: "batterySleepEnabled"); energyPolicyChanged?() }
    }
    @Published var batterySleepPercentage: Int {
        didSet {
            let bounded = BatteryPolicy.percentage(batterySleepPercentage)
            if batterySleepPercentage != bounded { batterySleepPercentage = bounded; return }
            energyDefaults.set(batterySleepPercentage, forKey: "batterySleepPercentage")
            energyPolicyChanged?()
        }
    }
    @Published var lowPowerPolicy: LowPowerPolicy {
        didSet { energyDefaults.set(lowPowerPolicy.rawValue, forKey: "lowPowerPolicy"); energyPolicyChanged?() }
    }
    @Published var lowPowerPercentage: Int {
        didSet {
            let bounded = BatteryPolicy.percentage(lowPowerPercentage)
            if lowPowerPercentage != bounded { lowPowerPercentage = bounded; return }
            energyDefaults.set(lowPowerPercentage, forKey: "lowPowerPercentage")
            energyPolicyChanged?()
        }
    }
    init(defaults: UserDefaults = .standard) {
        energyDefaults = defaults
        // Preserve the earlier trial's one-time sleep-block reset, including upgrades
        // from before the trial. Later explicit sleep-block choices stay intact.
        if !defaults.bool(forKey: "sleepBlockMigrationApplied") {
            if defaults.object(forKey: "controlPanel") == nil {
                defaults.set(false, forKey: "closedLid")
            }
            defaults.set(true, forKey: "sleepBlockMigrationApplied")
        }
        closedLid = defaults.bool(forKey: "closedLid")
        batterySleepEnabled = defaults.object(forKey: "batterySleepEnabled") == nil ? true : defaults.bool(forKey: "batterySleepEnabled")
        batterySleepPercentage = BatteryPolicy.percentage(defaults.object(forKey: "batterySleepPercentage") as? Int ?? BatteryPolicy.defaultSleepPercentage)
        lowPowerPolicy = LowPowerPolicy(rawValue: defaults.integer(forKey: "lowPowerPolicy")) ?? .off
        lowPowerPercentage = BatteryPolicy.percentage(defaults.object(forKey: "lowPowerPercentage") as? Int ?? BatteryPolicy.defaultLowPowerPercentage)
    }
    var sleepThreshold: Int { batterySleepEnabled ? batterySleepPercentage : 0 }
    var lowPowerThreshold: Int {
        switch lowPowerPolicy {
        case .off: return 0
        case .onBattery: return 100
        case .belowPercentage: return lowPowerPercentage
        }
    }
    var speakerPolicyChanged: ((Bool) -> Void)?
    @Published var muteSpeakers = UserDefaults.standard.bool(forKey: "muteSpeakers") {
        didSet { UserDefaults.standard.set(muteSpeakers, forKey: "muteSpeakers"); speakerPolicyChanged?(muteSpeakers) }
    }
    var batteryPolicyChanged: ((Bool) -> Void)?
    @Published var allowBattery = UserDefaults.standard.bool(forKey: "allowBattery") {
        didSet { UserDefaults.standard.set(allowBattery, forKey: "allowBattery"); batteryPolicyChanged?(allowBattery) }
    }
    @Published var closedLid: Bool {
        didSet { energyDefaults.set(closedLid, forKey: "closedLid") }
    }
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
    let toggle: () -> Void
    @State private var key: UInt32 = Shortcut.standard.key
    @State private var modifiers: UInt32 = Shortcut.standard.modifiers
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
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
                Button(session.enabled ? "Restore Controls" : "Enable Guillotine") {
                    toggle()
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
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Allow on battery", isOn: $preferences.allowBattery)
                Text("Off by default. When off, unplugging restores immediately. Battery sessions restore and request sleep at serious or critical macOS thermal pressure.").font(.caption).foregroundStyle(.secondary)
                Toggle("Sleep at a battery percentage", isOn: $preferences.batterySleepEnabled)
                if preferences.batterySleepEnabled {
                    HStack {
                        Text("Sleep at or below")
                        TextField("Battery percentage", value: $preferences.batterySleepPercentage, format: .number).frame(width: 45)
                        Text("%")
                        Stepper("Battery sleep percentage", value: $preferences.batterySleepPercentage, in: 1...100).labelsHidden()
                    }
                }
                Text("Only while headless on battery. Restores controls before requesting sleep. Turn off to let macOS handle a depleted battery normally.").font(.caption).foregroundStyle(.secondary)
                Picker("Low Power Mode", selection: $preferences.lowPowerPolicy) {
                    ForEach(LowPowerPolicy.allCases) { Text($0.label).tag($0) }
                }
                if preferences.lowPowerPolicy == .belowPercentage {
                    HStack {
                        Text("Enable at or below")
                        TextField("Low Power Mode battery percentage", value: $preferences.lowPowerPercentage, format: .number).frame(width: 45)
                        Text("%")
                        Stepper("Low Power Mode percentage", value: $preferences.lowPowerPercentage, in: 1...100).labelsHidden()
                    }
                }
                Text("Low Power Mode can reduce heat while running on battery, which may help avoid thermal limits. Requires the approved power helper; restores the prior battery setting afterward. Battery options apply live while headless.").font(.caption).foregroundStyle(.secondary)
                Toggle("Prevent closed-lid sleep (experimental, WIP)", isOn: $preferences.closedLid)
                Text("Closed-lid operation is not yet reliable. Requires the approved power helper. Temporarily sets global SleepDisabled while active. This also blocks ordinary/manual sleep until restored. Original value is journaled by a privileged, leased helper. Capture may still need a virtual display/adapter; physical testing remains required.").font(.caption).foregroundStyle(.secondary)
                Text("Power helper: \(preferences.lidHelperStatus)").font(.caption)
                HStack {
                    switch preferences.lidHelperState {
                    case .enabled:
                        Button("Remove Helper") { session.disable(); if !session.enabled { preferences.removeLidHelper() } }
                    case .requiresApproval:
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    default:
                        Button("Install Helper…") { preferences.installLidHelper() }
                    }
                }
                if let error = preferences.lidHelperError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Stay headless across lock, sleep and wake by default.").font(.caption)
                Toggle("Restore physical controls when sleeping", isOn: $preferences.restoreOnSleep)
                Toggle("Restore physical controls when waking", isOn: $preferences.restoreOnWake)
                Text("Changes apply next activation. With closed-lid support off, sleep and Caffeine settings stay independent.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Launch Guillotine at login (always starts disabled)", isOn: Binding(get: { preferences.loginEnabled || preferences.loginNeedsApproval }, set: preferences.setLogin))
            if preferences.loginNeedsApproval {
                Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let error = preferences.loginError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text("Panel power and keyboard backlight controls use private macOS APIs. Panel-off is requested once when enabled; macOS may turn it back on after lid opening or wake. Caffeine can handle sleep prevention independently. Lock does not change the mode. Lock-screen hotkey delivery needs testing; Mac sleep still interrupts streaming normally.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        }.frame(width: 500, height: 660)
        .onAppear { key = preferences.shortcut.key; modifiers = preferences.shortcut.modifiers; session.refreshPower(); preferences.refreshLidHelper() }
        .onChange(of: scenePhase) { _ in preferences.refreshLoginStatus(); preferences.refreshLidHelper() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in preferences.refreshLoginStatus(); preferences.refreshLidHelper() }
    }
}
