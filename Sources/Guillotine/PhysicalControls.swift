// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 Ben Weaver and Guillotine contributors
import Foundation
import Darwin

@MainActor final class PhysicalControls: HardwareControl {
    private var process: Process?
    private var lease: FileHandle?
    private var heartbeat: Timer?
    var allowBattery = false
    var closedLid = false
    var restoreOnSleep = false
    var restoreOnWake = false
    var onStopped: ((String) -> Void)?
    private var stopReason: String {
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Guillotine/last-stop.txt")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "Physical controls restored by hardware guard."
    }

    private var executable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GuillotineGuard")
    }
    func recover() throws {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["--recover"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        guard wait(child, seconds: 3), child.terminationStatus == 0 else {
            throw failure("Previous-session recovery failed. Reopen Guillotine or restart macOS.")
        }
    }
    func acquire() throws {
        guard process == nil else { return }
        signal(SIGPIPE, SIG_IGN)
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = executable
        child.arguments = (allowBattery ? ["--allow-battery"] : []) + (closedLid ? ["--closed-lid"] : []) + (restoreOnSleep ? ["--restore-on-sleep"] : []) + (restoreOnWake ? ["--restore-on-wake"] : [])
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let available = poll(&descriptor, 1, 10000)
        let response = available > 0 ? String(data: output.fileHandleForReading.availableData, encoding: .utf8) ?? "" : ""
        guard response.hasPrefix("READY") else {
            input.fileHandleForWriting.closeFile()
            _ = wait(child, seconds: 2)
            throw failure(response.replacingOccurrences(of: "ERROR ", with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Hardware guard did not become ready. Reopen Guillotine." : response)
        }
        process = child
        lease = input.fileHandleForWriting
        child.terminationHandler = { [weak self] stopped in
            Task { @MainActor in
                guard let self, self.process === stopped else { return }
                self.onStopped?(self.stopReason)
            }
        }
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                do { try self.lease?.write(contentsOf: Data("renew battery=\(self.allowBattery ? 1 : 0)\n".utf8)) }
                catch { self.onStopped?(self.stopReason) }
            }
        }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }
    func release() throws {
        heartbeat?.invalidate(); heartbeat = nil
        try? lease?.close(); lease = nil
        guard let child = process else { return }
        child.terminationHandler = nil
        guard wait(child, seconds: 3) else {
            child.terminate()
            throw failure("Hardware restoration is still pending. Retry Restore or reopen Guillotine.")
        }
        if child.terminationStatus != 0 {
            // A killed guard cannot run its cleanup; recover its durable journal now.
            try recover()
        }
        process = nil
    }
    private func wait(_ child: Process, seconds: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        return !child.isRunning
    }
    private func failure(_ text: String) -> NSError {
        NSError(domain: "Guillotine.Hardware", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
