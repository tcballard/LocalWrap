import Darwin
import Foundation

protocol ManagedProjectProcess: Sendable {
    var pid: Int32 { get }
    var isRunning: Bool { get }
    func signalProcessGroup(_ signal: Int32)
}

protocol ProjectProcessLaunching: Sendable {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess
}

struct PosixProcessLauncher: ProjectProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        var outputPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&outputPipe) == 0 else {
            throw RuntimeError.launchFailed(String(cString: strerror(errno)))
        }
        let descriptorFlags = fcntl(outputPipe[0], F_GETFL)
        guard descriptorFlags >= 0,
              fcntl(outputPipe[0], F_SETFL, descriptorFlags | O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            close(outputPipe[0])
            close(outputPipe[1])
            throw RuntimeError.launchFailed(message)
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, outputPipe[0])
        posix_spawn_file_actions_addclose(&actions, outputPipe[1])
        posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            ([executable.path] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }.sorted()
        var environmentPointers: [UnsafeMutablePointer<CChar>?] =
            environmentStrings.map { strdup($0) }
        environmentPointers.append(nil)
        defer {
            for pointer in argumentPointers where pointer != nil { free(pointer) }
            for pointer in environmentPointers where pointer != nil { free(pointer) }
        }

        var processID: pid_t = 0
        let result = posix_spawn(
            &processID,
            executable.path,
            &actions,
            &attributes,
            &argumentPointers,
            &environmentPointers
        )
        close(outputPipe[1])
        guard result == 0 else {
            close(outputPipe[0])
            throw RuntimeError.launchFailed(String(cString: strerror(result)))
        }

        return PosixManagedProcess(
            pid: processID,
            outputDescriptor: outputPipe[0],
            onOutput: onOutput,
            onExit: onExit
        )
    }
}

private final class PosixManagedProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32

    private let lock = NSLock()
    private var running = true
    private let outputSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess
    private let collector: LineCollector

    var isRunning: Bool {
        lock.withLock { running }
    }

    init(
        pid: Int32,
        outputDescriptor: Int32,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.pid = pid
        collector = LineCollector(onLine: onOutput)
        let queue = DispatchQueue(label: "com.localwrap.native.process.\(pid)")
        outputSource = DispatchSource.makeReadSource(fileDescriptor: outputDescriptor, queue: queue)
        exitSource = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: queue
        )
        outputSource.setEventHandler { [collector] in
            Self.readAvailableOutput(from: outputDescriptor, collector: collector)
        }
        outputSource.setCancelHandler {
            close(outputDescriptor)
        }
        exitSource.setEventHandler { [weak self, collector] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            let code = Self.exitCode(from: status)
            lock.withLock { running = false }
            Self.readAvailableOutput(from: outputDescriptor, collector: collector)
            collector.flush()
            outputSource.cancel()
            exitSource.cancel()
            onExit(code)
        }
        outputSource.resume()
        exitSource.resume()
    }

    func signalProcessGroup(_ signal: Int32) {
        if Darwin.kill(-pid, signal) != 0 {
            _ = Darwin.kill(pid, signal)
        }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    private static func readAvailableOutput(
        from descriptor: Int32,
        collector: LineCollector
    ) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                collector.consume(Data(buffer.prefix(count)))
            } else {
                return
            }
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var result: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                let text = String(decoding: line, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                if !text.isEmpty { result.append(text) }
            }
            return result
        }
        lines.forEach(onLine)
    }

    func flush() {
        let line: String? = lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if let line, !line.isEmpty { onLine(line) }
    }
}
