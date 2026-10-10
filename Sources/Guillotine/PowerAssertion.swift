// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors

import Foundation
import IOKit.pwr_mgt

struct PowerManagementError: LocalizedError {
    let operation: String
    let code: IOReturn
    var errorDescription: String? {
        "\(operation) returned \(String(format: "0x%08x", UInt32(bitPattern: code)))."
    }
}

@MainActor final class IdleSleepAssertion: SleepAssertion {
    private var identifier: IOPMAssertionID?

    func acquire() throws {
        guard identifier == nil else { return }
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Guillotine: headless remote access on external power" as CFString,
            &created
        )
        guard result == kIOReturnSuccess else {
            throw PowerManagementError(operation: "IOPMAssertionCreateWithName", code: result)
        }
        identifier = created
    }

    func release() throws {
        guard let identifier else { return }
        let result = IOPMAssertionRelease(identifier)
        guard result == kIOReturnSuccess else {
            throw PowerManagementError(operation: "IOPMAssertionRelease", code: result)
        }
        self.identifier = nil
    }
    // IOKit assertions are process-scoped. The kernel also cleans up after SIGKILL/crash.
}
