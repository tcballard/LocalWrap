import Darwin
import Foundation

protocol ManagedProjectProcess: Sendable {
    var pid: Int32 { get }
    var processGroupID: Int32 { get }
    var logURL: URL? { get }
    var isRunning: Bool { get }
    /// Commits a prepared launch after its ownership record is durable.
    func resume() throws
    /// Abandons a prepared launch without signalling an unverified group.
    func abandonPreparedLaunch()
    func signalProcessGroup(_ signal: Int32) throws
}

enum ProcessSignalError: Error, Equatable, LocalizedError {
    case processGroupExited
    case permissionDenied
    case systemFailure(Int32)

    var errorDescription: String? {
        switch self {
        case .processGroupExited:
            "The process group exited before it could be signalled."
        case .permissionDenied:
            "macOS denied permission to signal the verified process group."
        case .systemFailure(let code):
            "The process group signal failed with system error \(code)."
        }
    }
}

extension ManagedProjectProcess {
    var processGroupID: Int32 { pid }
    var logURL: URL? { nil }
    func resume() throws {}
    func abandonPreparedLaunch() {}
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

protocol RecoverableProjectProcessLaunching: ProjectProcessLaunching {
    func prepareLaunch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess

    func monitorExisting(
        pid: Int32,
        processGroupID: Int32,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess
}

struct PosixProcessLauncher: RecoverableProjectProcessLaunching {
    func launch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalWrapProcessLogs", isDirectory: true)
        let logURL = directory.appendingPathComponent("\(UUID().uuidString).log")
        let process = try spawnSupervisor(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            logURL: logURL,
            removesLogOnExit: true,
            onOutput: onOutput,
            onExit: onExit
        )
        do {
            try process.resume()
            return process
        } catch {
            process.abandonPreparedLaunch()
            throw error
        }
    }

    func prepareLaunch(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        try spawnSupervisor(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            logURL: logURL,
            removesLogOnExit: false,
            onOutput: onOutput,
            onExit: onExit
        )
    }

    func monitorExisting(
        pid: Int32,
        processGroupID: Int32,
        logURL: URL,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        errno = 0
        guard Darwin.kill(pid, 0) == 0 || errno == EPERM else {
            throw RuntimeError.launchFailed("Previously launched process is no longer running.")
        }
        try ensurePrivateLogExists(at: logURL)
        return try PosixManagedProcess(
            pid: pid,
            processGroupID: processGroupID,
            logURL: logURL,
            ownsChild: false,
            removesLogOnExit: false,
            tailFromRecentOutput: true,
            commitDescriptor: nil,
            onOutput: onOutput,
            onExit: onExit
        )
    }

    private func spawnSupervisor(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        logURL: URL,
        removesLogOnExit: Bool,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws -> any ManagedProjectProcess {
        let logDirectory = logURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: logDirectory)
        let logDescriptor = open(
            logURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        guard logDescriptor >= 0 else {
            throw RuntimeError.launchFailed(String(cString: strerror(errno)))
        }
        var shouldRemoveLog = true
        defer {
            close(logDescriptor)
            if shouldRemoveLog { try? FileManager.default.removeItem(at: logURL) }
        }
        var logMetadata = stat()
        guard fstat(logDescriptor, &logMetadata) == 0,
              (logMetadata.st_mode & S_IFMT) == S_IFREG,
              logMetadata.st_uid == geteuid(),
              logMetadata.st_nlink == 1,
              fchmod(logDescriptor, 0o600) == 0 else {
            throw RuntimeError.launchFailed("Runtime log is not a private regular file.")
        }

        var commitPipe: [Int32] = [-1, -1]
        guard pipe(&commitPipe) == 0 else {
            throw RuntimeError.launchFailed("Could not create the private launch commit pipe.")
        }
        let commitReadDescriptor = commitPipe[0]
        let commitWriteDescriptor = commitPipe[1]
        var commitReadOpen = true
        var commitWriteTransferred = false
        defer {
            if commitReadOpen { _ = close(commitReadDescriptor) }
            if !commitWriteTransferred { _ = close(commitWriteDescriptor) }
        }
        guard fcntl(commitReadDescriptor, F_SETFD, 0) == 0,
              fcntl(commitWriteDescriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(commitWriteDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw RuntimeError.launchFailed("Could not secure the private launch commit pipe.")
        }

        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw RuntimeError.launchFailed("Could not initialise process file actions.")
        }
        var attributesInitialised = false
        defer {
            posix_spawn_file_actions_destroy(&actions)
            if attributesInitialised { posix_spawnattr_destroy(&attributes) }
        }

        guard posix_spawnattr_init(&attributes) == 0 else {
            throw RuntimeError.launchFailed("Could not initialise process attributes.")
        }
        attributesInitialised = true

        guard posix_spawn_file_actions_adddup2(&actions, logDescriptor, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, logDescriptor, STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, commitWriteDescriptor) == 0,
              posix_spawn_file_actions_addclose(&actions, logDescriptor) == 0,
              posix_spawn_file_actions_addchdir_np(&actions, workingDirectory.path) == 0 else {
            throw RuntimeError.launchFailed("Could not configure process file actions.")
        }
        let flags = Int16(POSIX_SPAWN_SETSID)
        var emptySignalMask = sigset_t()
        sigemptyset(&emptySignalMask)
        guard posix_spawnattr_setsigmask(&attributes, &emptySignalMask) == 0,
              posix_spawnattr_setflags(
                  &attributes,
                  flags | Int16(POSIX_SPAWN_SETSIGMASK)
              ) == 0 else {
            throw RuntimeError.launchFailed("Could not prepare an isolated process session.")
        }

        guard let supervisorExecutable = Bundle.main.executableURL else {
            throw RuntimeError.launchFailed("Could not locate the LocalWrap runtime supervisor.")
        }
        let supervisorArguments = [
            supervisorExecutable.path,
            RuntimeSupervisorCommand.launchMarker,
            String(commitReadDescriptor),
            executable.path
        ] + arguments
        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            supervisorArguments.map { strdup($0) }
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
            supervisorExecutable.path,
            &actions,
            &attributes,
            &argumentPointers,
            &environmentPointers
        )
        guard result == 0 else {
            throw RuntimeError.launchFailed(String(cString: strerror(result)))
        }
        _ = close(commitReadDescriptor)
        commitReadOpen = false

        do {
            let process = try PosixManagedProcess(
                pid: processID,
                processGroupID: processID,
                logURL: logURL,
                ownsChild: true,
                removesLogOnExit: removesLogOnExit,
                tailFromRecentOutput: false,
                commitDescriptor: commitWriteDescriptor,
                onOutput: onOutput,
                onExit: onExit
            )
            commitWriteTransferred = true
            shouldRemoveLog = false
            return process
        } catch {
            _ = close(commitWriteDescriptor)
            commitWriteTransferred = true
            var status: Int32 = 0
            while waitpid(processID, &status, 0) < 0, errno == EINTR {}
            throw error
        }
    }

    private func ensurePrivateLogExists(at logURL: URL) throws {
        let directory = logURL.deletingLastPathComponent()
        try ensurePrivateDirectory(at: directory)
        let descriptor = open(logURL.path, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeError.launchFailed("Could not open the private runtime log.")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            throw RuntimeError.launchFailed("Runtime log is not a private regular file.")
        }
    }

    private func ensurePrivateDirectory(at directory: URL) throws {
        var metadata = stat()
        if lstat(directory.path, &metadata) != 0 {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 else {
                throw RuntimeError.launchFailed(
                    "Could not create the private runtime log directory."
                )
            }
            guard lstat(directory.path, &metadata) == 0 else {
                throw RuntimeError.launchFailed(
                    "Could not inspect the private runtime log directory."
                )
            }
        }
        guard (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid(),
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o700) else {
            throw RuntimeError.launchFailed(
                "Runtime log directory is not a private directory owned by this user."
            )
        }
    }
}

private final class PosixManagedProcess: ManagedProjectProcess, @unchecked Sendable {
    let pid: Int32
    let processGroupID: Int32
    let logURL: URL?

    private let lock = NSLock()
    private var running = true
    private var hasResumed = false
    private var commitDescriptor: Int32?
    private let exitSource: DispatchSourceProcess
    private let tailer: FileLogTailer
    private let ownsChild: Bool
    private let removesLogOnExit: Bool

    var isRunning: Bool { lock.withLock { running } }

    init(
        pid: Int32,
        processGroupID: Int32,
        logURL: URL,
        ownsChild: Bool,
        removesLogOnExit: Bool,
        tailFromRecentOutput: Bool,
        commitDescriptor: Int32?,
        onOutput: @escaping @Sendable (String) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) throws {
        self.pid = pid
        self.processGroupID = processGroupID
        self.logURL = logURL
        self.ownsChild = ownsChild
        self.removesLogOnExit = removesLogOnExit
        self.commitDescriptor = commitDescriptor
        tailer = try FileLogTailer(
            logURL: logURL,
            tailFromRecentOutput: tailFromRecentOutput,
            onOutput: onOutput
        )
        let queue = DispatchQueue(label: "com.localwrap.native.process.\(pid)")
        exitSource = DispatchSource.makeProcessSource(
            identifier: pid,
            eventMask: .exit,
            queue: queue
        )
        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var code: Int32 = -1
            if ownsChild {
                var status: Int32 = 0
                if waitpid(pid, &status, 0) == pid {
                    code = Self.exitCode(from: status)
                }
            }
            lock.withLock { running = false }
            tailer.finish()
            exitSource.cancel()
            if removesLogOnExit, let logURL = self.logURL {
                try? FileManager.default.removeItem(at: logURL)
            }
            onExit(code)
        }
        exitSource.resume()
    }

    func resume() throws {
        let descriptor = lock.withLock { () -> Int32? in
            guard !hasResumed, running else { return nil }
            hasResumed = true
            defer { commitDescriptor = nil }
            return commitDescriptor
        }
        guard let descriptor else { return }
        defer { _ = close(descriptor) }

        var byte: UInt8 = 0xA5
        while true {
            let count = Darwin.write(descriptor, &byte, 1)
            if count == 1 { return }
            if count < 0, errno == EINTR { continue }
            throw RuntimeError.launchFailed(
                "The runtime supervisor exited before launch could be committed."
            )
        }
    }

    func abandonPreparedLaunch() {
        let descriptor = lock.withLock { () -> Int32? in
            defer { commitDescriptor = nil }
            return commitDescriptor
        }
        if let descriptor {
            _ = close(descriptor)
        }
    }

    deinit {
        abandonPreparedLaunch()
    }

    func signalProcessGroup(_ signal: Int32) throws {
        guard processGroupID > 0, processGroupID == pid else {
            throw ProcessSignalError.systemFailure(EINVAL)
        }
        guard Darwin.kill(-processGroupID, signal) == 0 else {
            switch errno {
            case ESRCH: throw ProcessSignalError.processGroupExited
            case EPERM, EACCES: throw ProcessSignalError.permissionDenied
            default: throw ProcessSignalError.systemFailure(errno)
            }
        }
    }

    private static func exitCode(from status: Int32) -> Int32 {
        if status & 0x7F == 0 { return (status >> 8) & 0xFF }
        return 128 + (status & 0x7F)
    }
}

private final class FileLogTailer: @unchecked Sendable {
    private static let recentOutputBytes: off_t = 256 * 1_024
    private static let maximumLogBytes: off_t = 8 * 1_024 * 1_024
    private static let maximumReadBytesPerTick = 256 * 1_024

    private let descriptor: Int32
    private let timer: DispatchSourceTimer
    private let collector: LineCollector
    private let queue: DispatchQueue
    private var isFinished = false

    init(
        logURL: URL,
        tailFromRecentOutput: Bool,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws {
        descriptor = open(logURL.path, O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RuntimeError.launchFailed("Could not open the private runtime log: \(String(cString: strerror(errno))).")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & mode_t(0o777)) == mode_t(0o600) else {
            _ = close(descriptor)
            throw RuntimeError.launchFailed("Runtime log is not a private regular file.")
        }
        if tailFromRecentOutput {
            _ = lseek(descriptor, max(0, metadata.st_size - Self.recentOutputBytes), SEEK_SET)
        }
        collector = LineCollector(onLine: onOutput)
        let queue = DispatchQueue(label: "com.localwrap.native.log.\(UUID().uuidString)")
        self.queue = queue
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.readAvailableOutputOnQueue() }
        timer.setCancelHandler { [descriptor] in close(descriptor) }
        timer.resume()
    }

    func finish() {
        queue.sync {
            guard !isFinished else { return }
            isFinished = true
            readAvailableOutputOnQueue()
            collector.flush()
            timer.cancel()
        }
    }

    private func readAvailableOutputOnQueue() {
        guard !isFinished || !timer.isCancelled else { return }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var remainingBudget = Self.maximumReadBytesPerTick
        while remainingBudget > 0 {
            let count = read(descriptor, &buffer, min(buffer.count, remainingBudget))
            if count > 0 {
                collector.consume(Data(buffer.prefix(count)))
                remainingBudget -= count
            } else {
                break
            }
        }
        var metadata = stat()
        if fstat(descriptor, &metadata) == 0,
           metadata.st_size > Self.maximumLogBytes,
           ftruncate(descriptor, 0) == 0 {
            _ = lseek(descriptor, 0, SEEK_SET)
        }
    }
}

private final class LineCollector: @unchecked Sendable {
    private static let maximumPendingBytes = 64 * 1_024

    private let lock = NSLock()
    private var pending = Data()
    private var isDiscardingOverflow = false
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    func consume(_ data: Data) {
        let lines: [String] = lock.withLock {
            pending.append(data)
            var result: [String] = []

            while !pending.isEmpty {
                if isDiscardingOverflow {
                    guard let newline = pending.firstIndex(of: 0x0A) else {
                        pending.removeAll(keepingCapacity: true)
                        break
                    }
                    pending.removeSubrange(...newline)
                    isDiscardingOverflow = false
                    continue
                }

                if let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    let text = String(decoding: line, as: UTF8.self)
                        .trimmingCharacters(in: .newlines)
                    if !text.isEmpty { result.append(text) }
                    continue
                }

                guard pending.count > Self.maximumPendingBytes else { break }
                let prefix = pending.prefix(Self.maximumPendingBytes)
                let text = String(decoding: prefix, as: UTF8.self)
                    .trimmingCharacters(in: .newlines)
                pending.removeAll(keepingCapacity: true)
                isDiscardingOverflow = true
                result.append("\(text)… [output line truncated]")
            }
            return result
        }
        lines.forEach(onLine)
    }

    func flush() {
        let line: String? = lock.withLock {
            if isDiscardingOverflow {
                pending.removeAll()
                isDiscardingOverflow = false
                return nil
            }
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if let line, !line.isEmpty { onLine(line) }
    }
}
