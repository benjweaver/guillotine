// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum LowPowerPolicy: Int, CaseIterable, Identifiable {
    case off, onBattery, belowPercentage
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .onBattery: return "Whenever on battery"
        case .belowPercentage: return "At a battery percentage"
        }
    }
}

enum BatteryPolicy {
    static let defaultSleepPercentage = 10
    static let defaultLowPowerPercentage = 20
    static func percentage(_ value: Int) -> Int { min(100, max(1, value)) }
}
