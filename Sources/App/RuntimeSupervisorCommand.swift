import Darwin
import Foundation

/// Internal process-group leader used for recoverable launches.
///
/// The supervisor waits for a one-byte commit from the UI process before it
/// starts the requested command. An EOF means the ledger was not durably
/// committed, so the command is never launched. The supervisor remains the
/// stable session and process-group leader while wrappers such as npm or npx
/// exec into their eventual target.
struct RuntimeSupervisorCommand {
    static let launchMarker = "--localwrap-runtime-supervisor"

    private enum GroupMembership {
        case otherProcessesRemain
        case onlySupervisor
        case uncertain
    }

    func run(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == Self.launchMarker else { return nil }
        guard arguments.count >= 4,
              let commitDescriptor = Int32(arguments[2]),
              commitDescriptor >= 3 else { return 64 }

        let executablePath = arguments[3]
        let targetArguments = Array(arguments.dropFirst(4))
        guard waitForCommit(on: commitDescriptor) else { return 125 }

        installSupervisorSignalPolicy()

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return 126 }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return 126 }
        defer { posix_spawnattr_destroy(&attributes) }

        var defaultSignals = sigset_t()
        var emptySignalMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigemptyset(&emptySignalMask)
        [SIGTERM, SIGINT, SIGHUP, SIGQUIT].forEach {
            sigaddset(&defaultSignals, $0)
        }
        let flags = Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
              posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0 else {
            return 126
        }

        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            ([executablePath] + targetArguments).map { strdup($0) }
        argumentPointers.append(nil)
        let environmentStrings = ProcessInfo.processInfo.environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var environmentPointers: [UnsafeMutablePointer<CChar>?] =
            environmentStrings.map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }

        var childPID: pid_t = 0
        let result = posix_spawn(
            &childPID,
            executablePath,
            &actions,
            &attributes,
            &argumentPointers,
            &environmentPointers
        )
        guard result == 0 else {
            Self.writeDiagnostic("LocalWrap could not start the reviewed command (system error \(result)).")
            return 126
        }

        var status: Int32 = 0
        while waitpid(childPID, &status, 0) < 0 {
            if errno == EINTR { continue }
            return 127
        }

        // A wrapper can exit before one of its descendants. Keep the stable
        // leader alive until no other process remains in this group.
        var consecutiveEmptyObservations = 0
        while consecutiveEmptyObservations < 2 {
            switch processGroupMembership() {
            case .otherProcessesRemain, .uncertain:
                consecutiveEmptyObservations = 0
            case .onlySupervisor:
                consecutiveEmptyObservations += 1
            }
            if consecutiveEmptyObservations < 2 { usleep(100_000) }
        }
        return Self.exitCode(from: status)
    }

    private func waitForCommit(on descriptor: Int32) -> Bool {
        defer { _ = close(descriptor) }
        var byte: UInt8 = 0
        while true {
            let result = Darwin.read(descriptor, &byte, 1)
            if result == 1 { return byte == 0xA5 }
            if result == 0 { return false }
            if errno == EINTR { continue }
            return false
        }
    }

    private func installSupervisorSignalPolicy() {
        // Group signals already reach every target process. Keeping the
        // supervisor alive until they exit preserves the identity LocalWrap
        // verified. SIGKILL remains available for bounded escalation.
        _ = Darwin.signal(SIGTERM, SIG_IGN)
        _ = Darwin.signal(SIGINT, SIG_IGN)
        _ = Darwin.signal(SIGHUP, SIG_IGN)
        _ = Darwin.signal(SIGQUIT, SIG_IGN)
    }

    private func processGroupMembership() -> GroupMembership {
        let groupID = getpgrp()
        errno = 0
        let requiredBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(bitPattern: groupID),
            nil,
            0
        )
        guard requiredBytes > 0 else { return .uncertain }

        let capacity = (Int(requiredBytes) / MemoryLayout<Int32>.size) + 32
        var pids = [Int32](repeating: 0, count: capacity)
        errno = 0
        let returnedBytes = pids.withUnsafeMutableBytes { bytes in
            proc_listpids(
                UInt32(PROC_PGRP_ONLY),
                UInt32(bitPattern: groupID),
                bytes.baseAddress,
                Int32(bytes.count)
            )
        }
        guard returnedBytes > 0,
              returnedBytes < pids.count * MemoryLayout<Int32>.size else {
            return .uncertain
        }
        let count = min(Int(returnedBytes) / MemoryLayout<Int32>.size, pids.count)
        let ownPID = getpid()
        return pids.prefix(count).contains { $0 > 0 && $0 != ownPID }
            ? .otherProcessesRemain
            : .onlySupervisor
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }

    private static func writeDiagnostic(_ message: String) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        try? FileHandle.standardError.write(contentsOf: data)
    }
}
