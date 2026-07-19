import Darwin
import Foundation

actor RuntimeService {
    typealias EventSink = @Sendable (String, RuntimeSnapshot) -> Void

    private struct RunContext {
        let id: String
        let process: any ManagedProjectProcess
        let ledgerRecord: RuntimeLedgerRecord?
        var readinessTask: Task<Void, Never>?
        var isStopping: Bool
    }

    private struct ManagedComponents {
        let launcher: any RecoverableProjectProcessLaunching
        let ledger: any RuntimeLedgerStoring
        let inspector: any ProcessInspecting
    }

    private enum ManagedWaitResult {
        case exited
        case stillRunning
        case unsafe(String, RuntimeOwnershipReason)
    }

    private enum SignalReadiness {
        case verified(VerifiedProcessOwnership)
        case exited
        case unsafe(String, RuntimeOwnershipReason)
    }

    private let parser: CommandParser
    private let environmentResolver: EnvironmentResolver
    private let launcher: any ProjectProcessLaunching
    private let ledgerStore: (any RuntimeLedgerStoring)?
    private let processInspector: (any ProcessInspecting)?
    private let readiness: any ReadinessProbing
    private let doctor: ProjectDoctorService
    private let healthChecks: HealthCheckResolver
    private let now: @Sendable () -> String
    private let isDirectory: @Sendable (String) -> Bool
    private let terminationWaitAttempts: Int
    private let killWaitAttempts: Int
    private var states: [String: RuntimeSnapshot] = [:]
    private var runs: [String: RunContext] = [:]
    private var eventSink: EventSink?
    nonisolated let managesPersistentRuns: Bool

    static func live() -> RuntimeService {
        let paths = RuntimeLedgerPaths.production()
        return RuntimeService(
            launcher: PosixProcessLauncher(),
            ledgerStore: RuntimeLedgerStore(paths: paths),
            processInspector: DarwinProcessInspector()
        )
    }

    init(
        parser: CommandParser = CommandParser(),
        environmentResolver: EnvironmentResolver = EnvironmentResolver(),
        launcher: any ProjectProcessLaunching = PosixProcessLauncher(),
        ledgerStore: (any RuntimeLedgerStoring)? = nil,
        processInspector: (any ProcessInspecting)? = nil,
        readiness: any ReadinessProbing = ReadinessService(),
        doctor: ProjectDoctorService = ProjectDoctorService(),
        urlValidator: LocalURLValidator = LocalURLValidator(),
        healthChecks: HealthCheckResolver? = nil,
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) },
        terminationWaitAttempts: Int = 50,
        killWaitAttempts: Int = 20,
        isDirectory: @escaping @Sendable (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory)
                && directory.boolValue
        }
    ) {
        self.parser = parser
        self.environmentResolver = environmentResolver
        self.launcher = launcher
        self.ledgerStore = ledgerStore
        self.processInspector = processInspector
        managesPersistentRuns = ledgerStore != nil
            && processInspector != nil
            && launcher is any RecoverableProjectProcessLaunching
        self.readiness = readiness
        self.doctor = doctor
        self.healthChecks = healthChecks ?? HealthCheckResolver(urlValidator: urlValidator)
        self.now = now
        self.terminationWaitAttempts = max(0, terminationWaitAttempts)
        self.killWaitAttempts = max(0, killWaitAttempts)
        self.isDirectory = isDirectory
    }

    func setEventSink(_ sink: EventSink?) {
        eventSink = sink
    }

    func snapshot(for projectID: String) -> RuntimeSnapshot {
        states[projectID] ?? RuntimeSnapshot()
    }

    func allSnapshots() -> [String: RuntimeSnapshot] {
        states
    }

    func waitForReady(
        projectID: String,
        timeout: Duration = .seconds(35),
        pollInterval: Duration = .milliseconds(50)
    ) async -> RuntimeSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            let state = states[projectID] ?? RuntimeSnapshot()
            switch state.status {
            case .ready, .failed, .stopped, .runningUnresponsive:
                return state
            case .starting, .stopping:
                break
            }
            try? await Task.sleep(for: pollInterval)
        }
        return states[projectID] ?? RuntimeSnapshot()
    }

    @discardableResult
    func refreshDiagnosis(for project: Project) -> RuntimeSnapshot {
        var state = states[project.id] ?? RuntimeSnapshot()
        state.diagnosis = doctor.diagnose(ProjectDraft(project: project))
        states[project.id] = state
        publish(project.id)
        return state
    }

    /// Rebuilds runtime truth before any autostart decision. An unreadable
    /// ledger fails the whole operation closed; individual uncertain records
    /// remain persisted and non-signallable.
    func reconcile(projects: [Project]) -> RuntimeReconciliationReport {
        guard let managed = managedComponents else { return .empty }

        let exclusiveLock: any RuntimeLedgerLock
        do {
            exclusiveLock = try managed.ledger.acquireExclusiveLock()
        } catch {
            return RuntimeReconciliationReport(
                items: [],
                ledgerError: "Runtime reconciliation could not lock its ownership ledger: \(error.localizedDescription)"
            )
        }
        defer { exclusiveLock.unlock() }

        let document: RuntimeLedgerDocument
        do {
            document = try managed.ledger.load()
        } catch {
            return RuntimeReconciliationReport(
                items: [],
                ledgerError: "Runtime reconciliation is blocked: \(error.localizedDescription)"
            )
        }

        let projectsByID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        var items: [RuntimeReconciliationItem] = []
        var ledgerError: String?

        for record in document.records {
            let assessment = managed.inspector.inspect(ProcessOwnershipExpectation(record: record))
            switch assessment {
            case .exited:
                do {
                    _ = try managed.ledger.remove(runID: record.runID)
                    try? managed.ledger.removeLog(filename: record.logFilename)
                    markReconciledExit(record: record, project: projectsByID[record.projectID])
                    items.append(RuntimeReconciliationItem(
                        runID: record.runID,
                        projectID: record.projectID,
                        classification: .exited,
                        message: "The recorded process group has exited."
                    ))
                } catch {
                    ledgerError = ledgerError
                        ?? "An exited runtime record could not be removed: \(error.localizedDescription)"
                    items.append(RuntimeReconciliationItem(
                        runID: record.runID,
                        projectID: record.projectID,
                        classification: .unverifiable,
                        message: "The process exited, but its runtime record could not be cleaned up."
                    ))
                }

            case .unverifiable(let uncertainty):
                let message = uncertaintyMessage(uncertainty)
                setUnresolvedState(
                    record: record,
                    project: projectsByID[record.projectID],
                    classification: .unverifiable,
                    reason: ownershipReason(uncertainty),
                    message: message
                )
                items.append(RuntimeReconciliationItem(
                    runID: record.runID,
                    projectID: record.projectID,
                    classification: .unverifiable,
                    message: message
                ))

            case .conflicting(let conflict):
                let message = conflictMessage(conflict)
                setUnresolvedState(
                    record: record,
                    project: projectsByID[record.projectID],
                    classification: .conflicting,
                    reason: ownershipReason(conflict),
                    message: message
                )
                items.append(RuntimeReconciliationItem(
                    runID: record.runID,
                    projectID: record.projectID,
                    classification: .conflicting,
                    message: message
                ))

            case .verified:
                guard let project = projectsByID[record.projectID] else {
                    let message = "The saved project no longer exists, so this run cannot be controlled safely."
                    setUnresolvedState(
                        record: record,
                        project: nil,
                        classification: .conflicting,
                        reason: .projectConfigurationChanged,
                        message: message
                    )
                    items.append(RuntimeReconciliationItem(
                        runID: record.runID,
                        projectID: record.projectID,
                        classification: .conflicting,
                        message: message
                    ))
                    continue
                }

                do {
                    let contract = try launchContract(for: project)
                    guard contract.fingerprint == record.commandFingerprint,
                          project.port == record.port else {
                        throw RuntimeError.reconciliationRequired(
                            "The project configuration changed after this run started."
                        )
                    }

                    if let existing = runs[project.id] {
                        guard existing.id == record.runID else {
                            throw RuntimeError.reconciliationRequired(
                                "Another in-memory run is already associated with this project."
                            )
                        }
                        items.append(RuntimeReconciliationItem(
                            runID: record.runID,
                            projectID: record.projectID,
                            classification: .verifiedOwned,
                            message: "LocalWrap still owns and monitors this process group."
                        ))
                        continue
                    }

                    let logURL = try managed.ledger.logURL(for: record.logFilename)
                    let process = try managed.launcher.monitorExisting(
                        pid: record.pid,
                        processGroupID: record.processGroupID,
                        logURL: logURL,
                        onOutput: { [weak self] line in
                            Task {
                                await self?.received(
                                    line: line,
                                    projectID: project.id,
                                    runID: record.runID
                                )
                            }
                        },
                        onExit: { [weak self] code in
                            Task {
                                await self?.exited(
                                    code: code,
                                    projectID: project.id,
                                    runID: record.runID
                                )
                            }
                        }
                    )
                    guard process.pid == record.pid,
                          process.processGroupID == record.processGroupID else {
                        throw RuntimeError.ownershipNotVerified(
                            "Recovered process monitoring returned a different process identity."
                        )
                    }
                    guard case .verified = managed.inspector.inspect(
                        ProcessOwnershipExpectation(record: record)
                    ) else {
                        throw RuntimeError.ownershipNotVerified(
                            "The process identity changed while LocalWrap restored monitoring."
                        )
                    }
                    var effectiveRecord = record
                    if record.phase == .prepared {
                        effectiveRecord.phase = .running
                        do {
                            _ = try managed.ledger.upsert(effectiveRecord)
                        } catch {
                            effectiveRecord = record
                            ledgerError = ledgerError
                                ?? "A recovered run is active, but its runtime phase could not be saved: \(error.localizedDescription)"
                        }
                    }

                    var diagnosis = doctor.diagnose(ProjectDraft(project: project))
                    diagnosis.status = .waiting
                    diagnosis.summary = "Recovered the owned process. Next: verify readiness."
                    diagnosis.setCheck(
                        .process,
                        status: .pass,
                        message: "Verified owned process group \(record.processGroupID)."
                    )
                    diagnosis.setCheck(
                        .readiness,
                        status: .running,
                        message: "Rechecking the local URL."
                    )
                    diagnosis.addTimeline(
                        "Recovered an owned run after LocalWrap relaunched.",
                        status: .pass,
                        at: now()
                    )
                    var state = RuntimeSnapshot(
                        status: .starting,
                        runID: record.runID,
                        ownership: .verified(runID: record.runID),
                        recoveredAfterRelaunch: true,
                        pid: record.pid,
                        logs: ["[reconciled] Verified process group \(record.processGroupID)."],
                        startedAt: record.startedAt,
                        readinessMessage: "Rechecking project readiness.",
                        diagnosis: diagnosis
                    )
                    state.terminalReason = nil
                    states[project.id] = state
                    runs[project.id] = RunContext(
                        id: record.runID,
                        process: process,
                        ledgerRecord: effectiveRecord,
                        readinessTask: nil,
                        isStopping: false
                    )
                    beginReadiness(
                        project: project,
                        url: contract.readinessURL,
                        runID: record.runID
                    )
                    publish(project.id)
                    items.append(RuntimeReconciliationItem(
                        runID: record.runID,
                        projectID: record.projectID,
                        classification: .verifiedOwned,
                        message: "LocalWrap verified and restored monitoring for this process group."
                    ))
                } catch {
                    let message = error.localizedDescription
                    setUnresolvedState(
                        record: record,
                        project: project,
                        classification: .conflicting,
                        reason: .projectConfigurationChanged,
                        message: message
                    )
                    items.append(RuntimeReconciliationItem(
                        runID: record.runID,
                        projectID: record.projectID,
                        classification: .conflicting,
                        message: message
                    ))
                }
            }
        }

        return RuntimeReconciliationReport(items: items, ledgerError: ledgerError)
    }

    @discardableResult
    func start(_ project: Project) async throws -> RuntimeSnapshot {
        if states[project.id]?.status.isActive == true {
            throw RuntimeError.alreadyRunning
        }

        if let managed = managedComponents {
            do {
                let exclusiveLock = try managed.ledger.acquireExclusiveLock()
                defer { exclusiveLock.unlock() }
                try assertManagedStartAllowed(projectID: project.id, managed: managed)
            } catch {
                publishStartFailure(project: project, error: error, terminalReason: .ownershipUnverifiable)
                throw error
            }
        }

        var diagnosis = doctor.diagnose(ProjectDraft(project: project))
        if diagnosis.status == .failed {
            let message = diagnosis.summary
            var failed = states[project.id] ?? RuntimeSnapshot()
            failed.status = .failed
            failed.error = message
            failed.terminalReason = .doctorBlocked
            failed.readinessMessage = "Doctor preflight blocked start."
            failed.diagnosis = diagnosis
            failed.appendLog("[doctor] \(message)")
            states[project.id] = failed
            publish(project.id)
            throw RuntimeError.doctorBlocked(message)
        }

        let runID = UUID().uuidString.lowercased()
        let startedAt = now()
        diagnosis.status = .starting
        diagnosis.summary = "Starting project. Next: wait for the process to launch."
        diagnosis.setCheck(.process, status: .running, message: "Starting process.")
        diagnosis.setCheck(.readiness, status: .pending, message: "Waiting for the process to launch.")
        diagnosis.addTimeline("Starting project.", status: .info, at: startedAt)
        var state = RuntimeSnapshot(
            status: .starting,
            runID: runID,
            ownership: managedComponents == nil ? .none : .reconciling,
            logs: [],
            startedAt: startedAt,
            readinessMessage: "Waiting for the local app to respond.",
            diagnosis: diagnosis
        )
        states[project.id] = state
        publish(project.id)

        do {
            guard isDirectory(project.cwd) else {
                throw RuntimeError.workingDirectoryMissing(project.cwd)
            }
            let command = try parser.parse(project.command)
            let resolved = try environmentResolver.resolve(
                executable: command.executable,
                port: project.port
            )
            let readinessURL = try readinessURL(for: project)

            if let managed = managedComponents {
                state = try await launchManaged(
                    project: project,
                    runID: runID,
                    startedAt: startedAt,
                    state: state,
                    executable: resolved.executableURL,
                    arguments: command.arguments,
                    environment: resolved.values,
                    readinessURL: readinessURL,
                    managed: managed
                )
            } else {
                state = try launchLegacy(
                    project: project,
                    runID: runID,
                    state: state,
                    executable: resolved.executableURL,
                    arguments: command.arguments,
                    environment: resolved.values,
                    readinessURL: readinessURL
                )
            }
            return state
        } catch {
            state = states[project.id] ?? state
            state.status = .failed
            if case .reconciling = state.ownership {
                state.ownership = .none
            }
            state.error = error.localizedDescription
            state.terminalReason = .launchFailure
            state.readinessMessage = "Project failed to start."
            state.appendLog("[error] \(error.localizedDescription)")
            state.diagnosis.status = .failed
            state.diagnosis.summary = "Start failed. Next: review the process error and command."
            state.diagnosis.setCheck(
                .process,
                status: .fail,
                message: error.localizedDescription,
                actions: [.revealCommand]
            )
            state.diagnosis.setCheck(.readiness, status: .pending, message: "Readiness did not start.")
            state.diagnosis.addTimeline(
                "Process launch failed: \(error.localizedDescription)",
                status: .fail,
                at: now()
            )
            states[project.id] = state
            publish(project.id)
            throw error
        }
    }

    @discardableResult
    func stop(projectID: String) async -> RuntimeSnapshot {
        guard var run = runs[projectID] else {
            return states[projectID] ?? RuntimeSnapshot()
        }
        if run.isStopping {
            return states[projectID] ?? RuntimeSnapshot()
        }
        run.readinessTask?.cancel()
        run.isStopping = true
        runs[projectID] = run
        markStopping(projectID: projectID)

        if let record = run.ledgerRecord, let managed = managedComponents {
            return await stopManaged(
                projectID: projectID,
                run: run,
                record: record,
                managed: managed
            )
        }
        return await stopLegacy(projectID: projectID, run: run)
    }

    func restart(_ project: Project) async throws -> RuntimeSnapshot {
        let stopped = await stop(projectID: project.id)
        guard !stopped.status.isActive, !stopped.ownership.hasUnresolvedRun else {
            throw RuntimeError.ownershipNotVerified(
                stopped.error ?? "The existing run could not be stopped safely."
            )
        }
        var state = try await start(project)
        state.diagnosis.addTimeline("Restarted project.", status: .info, at: now())
        states[project.id] = state
        publish(project.id)
        return state
    }

    /// Workspace operations retain their existing fire-and-report behavior.
    /// App termination uses `stopAllWithReport()` so it can be cancelled.
    func stopAll() async {
        _ = await stopAllWithReport()
    }

    func stopAllWithReport() async -> RuntimeShutdownReport {
        var stopped: [String] = []
        var failures: [RuntimeShutdownFailure] = []
        let candidates = Set(runs.keys).union(
            states.compactMap { key, value in
                value.ownership.hasUnresolvedRun ? key : nil
            }
        )

        for projectID in candidates.sorted() {
            let state = await stop(projectID: projectID)
            if !state.status.isActive, !state.ownership.hasUnresolvedRun {
                stopped.append(projectID)
            } else {
                failures.append(RuntimeShutdownFailure(
                    projectID: projectID,
                    runID: state.runID,
                    message: state.error ?? state.readinessMessage
                        ?? "The process could not be stopped safely."
                ))
            }
        }

        if let managed = managedComponents {
            do {
                let exclusiveLock = try managed.ledger.acquireExclusiveLock()
                let remaining = try managed.ledger.load().records
                exclusiveLock.unlock()

                for record in remaining where runs[record.projectID] == nil {
                    failures.removeAll { $0.runID == record.runID }
                    switch managed.inspector.inspect(ProcessOwnershipExpectation(record: record)) {
                    case .exited:
                        let cleanupLock = try managed.ledger.acquireExclusiveLock()
                        _ = try managed.ledger.remove(runID: record.runID)
                        try? managed.ledger.removeLog(filename: record.logFilename)
                        cleanupLock.unlock()
                        stopped.append(record.projectID)
                    case .verified:
                        do {
                            try attachLedgerOnlyRun(record: record, managed: managed)
                            let state = await stop(projectID: record.projectID)
                            if !state.status.isActive, !state.ownership.hasUnresolvedRun {
                                stopped.append(record.projectID)
                            } else {
                                failures.append(RuntimeShutdownFailure(
                                    projectID: record.projectID,
                                    runID: record.runID,
                                    message: state.error ?? "The verified process group did not stop."
                                ))
                            }
                        } catch {
                            failures.append(RuntimeShutdownFailure(
                                projectID: record.projectID,
                                runID: record.runID,
                                message: error.localizedDescription
                            ))
                        }
                    case .unverifiable(let uncertainty):
                        failures.append(RuntimeShutdownFailure(
                            projectID: record.projectID,
                            runID: record.runID,
                            message: uncertaintyMessage(uncertainty)
                        ))
                    case .conflicting(let conflict):
                        failures.append(RuntimeShutdownFailure(
                            projectID: record.projectID,
                            runID: record.runID,
                            message: conflictMessage(conflict)
                        ))
                    }
                }
            } catch {
                failures.append(RuntimeShutdownFailure(
                    projectID: "runtime-ledger",
                    runID: nil,
                    message: "Runtime shutdown could not verify the ledger: \(error.localizedDescription)"
                ))
            }
        }

        return RuntimeShutdownReport(
            stoppedProjectIDs: Array(Set(stopped)).sorted(),
            failures: failures
        )
    }

    func clearLogs(projectID: String) {
        guard var state = states[projectID] else { return }
        state.logs = []
        states[projectID] = state
        publish(projectID)
    }

    private func attachLedgerOnlyRun(
        record: RuntimeLedgerRecord,
        managed: ManagedComponents
    ) throws {
        let logURL = try managed.ledger.logURL(for: record.logFilename)
        let process = try managed.launcher.monitorExisting(
            pid: record.pid,
            processGroupID: record.processGroupID,
            logURL: logURL,
            onOutput: { [weak self] line in
                Task {
                    await self?.received(
                        line: line,
                        projectID: record.projectID,
                        runID: record.runID
                    )
                }
            },
            onExit: { [weak self] code in
                Task {
                    await self?.exited(
                        code: code,
                        projectID: record.projectID,
                        runID: record.runID
                    )
                }
            }
        )
        guard process.pid == record.pid,
              process.processGroupID == record.processGroupID,
              case .verified = managed.inspector.inspect(
                ProcessOwnershipExpectation(record: record)
              ) else {
            throw RuntimeError.ownershipNotVerified(
                "The process identity changed while LocalWrap prepared shutdown."
            )
        }
        var state = states[record.projectID] ?? RuntimeSnapshot()
        state.status = .runningUnresponsive
        state.runID = record.runID
        state.ownership = .verified(runID: record.runID)
        state.pid = record.pid
        state.startedAt = record.startedAt
        state.error = nil
        state.readinessMessage = "Verified owned run recovered for shutdown."
        states[record.projectID] = state
        runs[record.projectID] = RunContext(
            id: record.runID,
            process: process,
            ledgerRecord: record,
            readinessTask: nil,
            isStopping: false
        )
        publish(record.projectID)
    }

    private var managedComponents: ManagedComponents? {
        guard let ledgerStore,
              let processInspector,
              let recoverableLauncher = launcher as? any RecoverableProjectProcessLaunching else {
            return nil
        }
        return ManagedComponents(
            launcher: recoverableLauncher,
            ledger: ledgerStore,
            inspector: processInspector
        )
    }

    private func launchManaged(
        project: Project,
        runID: String,
        startedAt: String,
        state: RuntimeSnapshot,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        readinessURL: URL,
        managed: ManagedComponents
    ) async throws -> RuntimeSnapshot {
        let exclusiveLock = try managed.ledger.acquireExclusiveLock()
        defer { exclusiveLock.unlock() }
        try assertManagedStartAllowed(projectID: project.id, managed: managed)
        let logFilename = "run-\(runID).log"
        let logURL = try managed.ledger.logURL(for: logFilename)
        let fingerprint = ProcessCommandFingerprint.makeLaunchContract(
            executablePath: executable.path,
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
            port: project.port,
            readinessURL: readinessURL
        )
        let process = try managed.launcher.prepareLaunch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
            logURL: logURL,
            onOutput: { [weak self] line in
                Task { await self?.received(line: line, projectID: project.id, runID: runID) }
            },
            onExit: { [weak self] code in
                Task { await self?.exited(code: code, projectID: project.id, runID: runID) }
            }
        )

        var candidateRecord: RuntimeLedgerRecord?
        do {
            let observation = try managed.inspector.capture(
                pid: process.pid,
                commandFingerprint: fingerprint
            )
            guard observation.pid == process.pid,
                  observation.processGroupID == process.processGroupID,
                  observation.pid == observation.processGroupID,
                  observation.pid == observation.sessionID,
                  process.logURL?.standardizedFileURL == logURL.standardizedFileURL else {
                throw RuntimeError.ownershipNotVerified(
                    "The launched process did not establish the expected isolated identity."
                )
            }
            let preparedRecord = RuntimeLedgerRecord(
                phase: .prepared,
                runID: runID,
                projectID: project.id,
                pid: observation.pid,
                processGroupID: observation.processGroupID,
                sessionID: observation.sessionID,
                effectiveUserID: observation.effectiveUserID,
                kernelStartTime: observation.kernelStartTime,
                commandFingerprint: observation.commandFingerprint,
                observedProcessFingerprint: observation.observedProcessFingerprint,
                port: project.port,
                startedAt: startedAt,
                logFilename: logFilename
            )
            candidateRecord = preparedRecord
            _ = try managed.ledger.upsert(preparedRecord)

            let verified: VerifiedProcessOwnership
            switch managed.inspector.inspect(ProcessOwnershipExpectation(record: preparedRecord)) {
            case .verified(let ownership):
                verified = ownership
            case .exited:
                throw RuntimeError.launchFailed(
                    "The runtime supervisor exited before launch could be committed."
                )
            case .unverifiable(let uncertainty):
                throw RuntimeError.ownershipNotVerified(uncertaintyMessage(uncertainty))
            case .conflicting(let conflict):
                throw RuntimeError.ownershipNotVerified(conflictMessage(conflict))
            }
            guard verified.pid == process.pid,
                  verified.processGroupID == process.processGroupID,
                  verified.sessionID == process.pid else {
                throw RuntimeError.ownershipNotVerified(
                    "The runtime supervisor identity changed before launch commit."
                )
            }

            var started = startedState(
                state,
                pid: process.pid,
                ownership: .verified(runID: runID)
            )
            states[project.id] = started
            runs[project.id] = RunContext(
                id: runID,
                process: process,
                ledgerRecord: preparedRecord,
                readinessTask: nil,
                isStopping: false
            )
            try process.resume()

            var runningRecord = preparedRecord
            runningRecord.phase = .running
            do {
                _ = try managed.ledger.upsert(runningRecord)
                if let running = runs[project.id], running.id == runID {
                    runs[project.id] = RunContext(
                        id: running.id,
                        process: running.process,
                        ledgerRecord: runningRecord,
                        readinessTask: running.readinessTask,
                        isStopping: running.isStopping
                    )
                }
            } catch {
                // The command is already running. Keep the durable prepared
                // record and reconcile it on the next launch; never signal an
                // owned group merely because a phase-only write failed.
                if var current = states[project.id] {
                    current.appendLog(
                        "[ledger] Runtime is active; launch phase will be reconciled later."
                    )
                    current.diagnosis.addTimeline(
                        "Runtime phase persistence needs reconciliation.",
                        status: .warn,
                        at: now()
                    )
                    states[project.id] = current
                }
            }
            exclusiveLock.unlock()
            beginReadiness(project: project, url: readinessURL, runID: runID)
            publish(project.id)
            started = states[project.id] ?? started
            return started
        } catch {
            process.abandonPreparedLaunch()
            exclusiveLock.unlock()
            var removeRunContext = candidateRecord == nil
            if let record = candidateRecord {
                let outcome = await waitForManagedExit(
                    record: record,
                    inspector: managed.inspector,
                    attempts: max(1, killWaitAttempts)
                )
                if case .exited = outcome {
                    do {
                        let cleanupLock = try managed.ledger.acquireExclusiveLock()
                        defer { cleanupLock.unlock() }
                        _ = try managed.ledger.remove(runID: record.runID)
                        try? managed.ledger.removeLog(filename: record.logFilename)
                        var cleaned = states[project.id] ?? state
                        cleaned.ownership = .none
                        cleaned.pid = nil
                        states[project.id] = cleaned
                        removeRunContext = true
                    } catch {
                        var unresolved = states[project.id] ?? state
                        unresolved.ownership = .unverifiable(
                            runID: record.runID,
                            reason: .ledgerUnavailable
                        )
                        unresolved.error = "The failed launch exited, but its runtime record could not be removed."
                        states[project.id] = unresolved
                    }
                } else {
                    var unresolved = states[project.id] ?? state
                    let reason: RuntimeOwnershipReason
                    let message: String
                    switch outcome {
                    case .unsafe(let detail, let unsafeReason):
                        reason = unsafeReason
                        message = detail
                    case .stillRunning:
                        reason = .inspectionUnavailable
                        message = "The failed launch left a process group that could not be confirmed exited."
                    case .exited:
                        reason = .ledgerUnavailable
                        message = "The failed launch could not be cleaned up."
                    }
                    unresolved.ownership = .unverifiable(runID: record.runID, reason: reason)
                    unresolved.error = message
                    states[project.id] = unresolved
                }
            } else {
                _ = await waitForExit(process, attempts: max(1, killWaitAttempts))
                try? managed.ledger.removeLog(filename: logFilename)
            }
            if removeRunContext, runs[project.id]?.id == runID {
                runs[project.id] = nil
            }
            throw error
        }
    }

    private func launchLegacy(
        project: Project,
        runID: String,
        state: RuntimeSnapshot,
        executable: URL,
        arguments: [String],
        environment: [String: String],
        readinessURL: URL
    ) throws -> RuntimeSnapshot {
        let process = try launcher.launch(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
            onOutput: { [weak self] line in
                Task { await self?.received(line: line, projectID: project.id, runID: runID) }
            },
            onExit: { [weak self] code in
                Task { await self?.exited(code: code, projectID: project.id, runID: runID) }
            }
        )
        let started = startedState(state, pid: process.pid, ownership: .none)
        states[project.id] = started
        runs[project.id] = RunContext(
            id: runID,
            process: process,
            ledgerRecord: nil,
            readinessTask: nil,
            isStopping: false
        )
        beginReadiness(project: project, url: readinessURL, runID: runID)
        publish(project.id)
        return started
    }

    private func startedState(
        _ initial: RuntimeSnapshot,
        pid: Int32,
        ownership: RuntimeOwnershipState
    ) -> RuntimeSnapshot {
        var state = initial
        state.pid = pid
        state.ownership = ownership
        state.terminalReason = nil
        state.appendLog("[started] PID \(pid)")
        state.diagnosis.status = .waiting
        state.diagnosis.summary = "Process is running. Next: wait for readiness."
        state.diagnosis.setCheck(.process, status: .pass, message: "Process started with PID \(pid).")
        state.diagnosis.setCheck(.readiness, status: .running, message: "Waiting for the local URL to respond.")
        state.diagnosis.addTimeline("Process started with PID \(pid).", status: .pass, at: now())
        state.diagnosis.addTimeline("Readiness polling started.", status: .info, at: now())
        return state
    }

    private func beginReadiness(project: Project, url: URL, runID: String) {
        let task = Task { [weak self, readiness] in
            let ready = await readiness.waitUntilReady(
                url: url,
                timeout: .seconds(30),
                interval: .milliseconds(500)
            )
            await self?.readinessFinished(
                ready: ready,
                url: url,
                projectID: project.id,
                runID: runID
            )
        }
        if var run = runs[project.id], run.id == runID {
            run.readinessTask = task
            runs[project.id] = run
        } else {
            task.cancel()
        }
    }

    private func stopManaged(
        projectID: String,
        run: RunContext,
        record: RuntimeLedgerRecord,
        managed: ManagedComponents
    ) async -> RuntimeSnapshot {
        switch signalReadiness(record: record, inspector: managed.inspector) {
        case .verified(let ownership):
            do {
                try signalVerifiedProcessGroup(
                    SIGTERM,
                    ownership: ownership,
                    process: run.process
                )
            } catch {
                return stateAfterSignalFailure(
                    error,
                    projectID: projectID,
                    run: run,
                    record: record,
                    inspector: managed.inspector
                )
            }
        case .exited:
            return finalizeExit(projectID: projectID, run: run, code: nil, intentional: true)
        case .unsafe(let message, let reason):
            return markOwnershipFailure(
                projectID: projectID,
                runID: record.runID,
                reason: reason,
                message: message
            )
        }

        let termResult = await waitForManagedExit(
            record: record,
            inspector: managed.inspector,
            attempts: terminationWaitAttempts
        )
        guard runs[projectID]?.id == run.id else {
            return states[projectID] ?? RuntimeSnapshot()
        }
        switch termResult {
        case .exited:
            return finalizeExit(projectID: projectID, run: run, code: nil, intentional: true)
        case .unsafe(let message, let reason):
            return markOwnershipFailure(
                projectID: projectID,
                runID: record.runID,
                reason: reason,
                message: message
            )
        case .stillRunning:
            break
        }

        // Identity is deliberately re-read immediately before escalation.
        switch signalReadiness(record: record, inspector: managed.inspector) {
        case .verified(let ownership):
            do {
                try signalVerifiedProcessGroup(
                    SIGKILL,
                    ownership: ownership,
                    process: run.process
                )
            } catch {
                return stateAfterSignalFailure(
                    error,
                    projectID: projectID,
                    run: run,
                    record: record,
                    inspector: managed.inspector
                )
            }
        case .exited:
            return finalizeExit(projectID: projectID, run: run, code: nil, intentional: true)
        case .unsafe(let message, let reason):
            return markOwnershipFailure(
                projectID: projectID,
                runID: record.runID,
                reason: reason,
                message: message
            )
        }

        let killResult = await waitForManagedExit(
            record: record,
            inspector: managed.inspector,
            attempts: killWaitAttempts
        )
        guard runs[projectID]?.id == run.id else {
            return states[projectID] ?? RuntimeSnapshot()
        }
        switch killResult {
        case .exited:
            return finalizeExit(projectID: projectID, run: run, code: nil, intentional: true)
        case .unsafe(let message, let reason):
            return markOwnershipFailure(
                projectID: projectID,
                runID: record.runID,
                reason: reason,
                message: message
            )
        case .stillRunning:
            return markCleanupFailure(
                projectID: projectID,
                message: "The verified process group did not exit after SIGTERM and SIGKILL."
            )
        }
    }

    private func stopLegacy(projectID: String, run: RunContext) async -> RuntimeSnapshot {
        if !run.process.isRunning {
            return finalizeExit(projectID: projectID, run: run, code: nil, intentional: true)
        }
        return markOwnershipFailure(
            projectID: projectID,
            runID: run.id,
            reason: .inspectionUnavailable,
            message: "LocalWrap cannot verify this legacy process identity, so it will not send a stop signal."
        )
    }

    private func markStopping(projectID: String) {
        guard var state = states[projectID] else { return }
        state.status = .stopping
        state.readinessMessage = "Stopping project."
        state.diagnosis.status = .stopped
        state.diagnosis.summary = "Stopping project. Next: wait for process cleanup."
        state.diagnosis.setCheck(.process, status: .running, message: "Stopping process group.")
        state.diagnosis.addTimeline("Stopping project.", status: .info, at: now())
        states[projectID] = state
        publish(projectID)
    }

    private func stateAfterSignalFailure(
        _ error: Error,
        projectID: String,
        run: RunContext,
        record: RuntimeLedgerRecord,
        inspector: any ProcessInspecting
    ) -> RuntimeSnapshot {
        if error as? ProcessSignalError == .processGroupExited {
            switch signalReadiness(record: record, inspector: inspector) {
            case .exited:
                return finalizeExit(
                    projectID: projectID,
                    run: run,
                    code: nil,
                    intentional: true
                )
            case .unsafe(let message, let reason):
                return markOwnershipFailure(
                    projectID: projectID,
                    runID: record.runID,
                    reason: reason,
                    message: message
                )
            case .verified:
                break
            }
        }
        return markOwnershipFailure(
            projectID: projectID,
            runID: record.runID,
            reason: error as? ProcessSignalError == .permissionDenied
                ? .permissionDenied
                : .inspectionUnavailable,
            message: error.localizedDescription
        )
    }

    private func markCleanupFailure(projectID: String, message: String) -> RuntimeSnapshot {
        if var run = runs[projectID] {
            run.isStopping = false
            runs[projectID] = run
        }
        var state = states[projectID] ?? RuntimeSnapshot()
        state.status = .runningUnresponsive
        state.terminalReason = .cleanupFailure
        state.readinessMessage = message
        state.error = message
        state.appendLog("[stop] \(message)")
        state.diagnosis.status = .failed
        state.diagnosis.summary = "Cleanup failed. Next: inspect the surviving process group."
        state.diagnosis.setCheck(.process, status: .fail, message: message)
        state.diagnosis.addTimeline("Process cleanup failed.", status: .fail, at: now())
        states[projectID] = state
        publish(projectID)
        return state
    }

    private func markOwnershipFailure(
        projectID: String,
        runID: String,
        reason: RuntimeOwnershipReason,
        message: String
    ) -> RuntimeSnapshot {
        if var run = runs[projectID] {
            run.isStopping = false
            runs[projectID] = run
        }
        var state = states[projectID] ?? RuntimeSnapshot()
        state.status = .runningUnresponsive
        state.ownership = reason == .identityMismatch || reason == .processGroupMismatch
            ? .conflicting(runID: runID, reason: reason)
            : .unverifiable(runID: runID, reason: reason)
        state.terminalReason = state.ownership.permitsSignalling
            ? .cleanupFailure
            : (reason == .identityMismatch || reason == .processGroupMismatch
                ? .ownershipConflict
                : .ownershipUnverifiable)
        state.error = message
        state.readinessMessage = message
        state.appendLog("[ownership] \(message)")
        state.diagnosis.status = .attention
        state.diagnosis.summary = "Process ownership needs review before LocalWrap can stop it."
        state.diagnosis.setCheck(.process, status: .warn, message: message)
        state.diagnosis.addTimeline(message, status: .warn, at: now())
        states[projectID] = state
        publish(projectID)
        return state
    }

    private func finalizeExit(
        projectID: String,
        run: RunContext,
        code: Int32?,
        intentional: Bool
    ) -> RuntimeSnapshot {
        guard runs[projectID]?.id == run.id else {
            return states[projectID] ?? RuntimeSnapshot()
        }
        run.readinessTask?.cancel()
        runs[projectID] = nil

        if let record = run.ledgerRecord, let ledgerStore {
            do {
                let exclusiveLock = try ledgerStore.acquireExclusiveLock()
                defer { exclusiveLock.unlock() }
                _ = try ledgerStore.remove(runID: record.runID)
                try? ledgerStore.removeLog(filename: record.logFilename)
            } catch {
                var failed = states[projectID] ?? RuntimeSnapshot()
                failed.status = .failed
                failed.pid = nil
                failed.ownership = .unverifiable(
                    runID: record.runID,
                    reason: .ledgerUnavailable
                )
                failed.terminalReason = .cleanupFailure
                failed.error = "The process exited, but its runtime record could not be removed: \(error.localizedDescription)"
                failed.readinessMessage = failed.error
                failed.stoppedAt = now()
                failed.diagnosis.status = .attention
                failed.diagnosis.summary = "Runtime cleanup needs attention before this project can start again."
                states[projectID] = failed
                publish(projectID)
                return failed
            }
        }

        var state = states[projectID] ?? RuntimeSnapshot()
        state.status = intentional ? .stopped : .failed
        state.pid = nil
        state.ownership = .none
        state.exitCode = code
        state.stoppedAt = now()
        state.terminalReason = intentional ? .intentionalStop : .unexpectedExit(code: code)
        if intentional {
            state.error = nil
            state.readinessMessage = "Project stopped."
            state.appendLog(code.map { "[process exited with code \($0)]" } ?? "[process group exited]")
            state.diagnosis.status = .stopped
            state.diagnosis.summary = "Project stopped. Next: Start when you are ready."
            state.diagnosis.setCheck(.process, status: .pending, message: "Process is stopped.")
            state.diagnosis.setCheck(.readiness, status: .pending, message: "Readiness is stopped.")
            state.diagnosis.addTimeline("Project stopped and process group exited.", status: .pass, at: now())
        } else {
            let detail = code.map { "Process exited unexpectedly with code \($0)." }
                ?? "Process exited unexpectedly."
            state.error = detail
            state.readinessMessage = detail
            state.appendLog(code.map { "[process exited with code \($0)]" } ?? "[process exited]")
            state.diagnosis.status = .failed
            state.diagnosis.summary = "Process exited unexpectedly. Next: review the final log lines."
            state.diagnosis.setCheck(.process, status: .fail, message: detail)
            state.diagnosis.addTimeline(detail, status: .fail, at: now())
        }
        states[projectID] = state
        publish(projectID)
        return state
    }

    private func received(line: String, projectID: String, runID: String) {
        guard runs[projectID]?.id == runID, var state = states[projectID] else { return }
        state.appendLog(line)
        states[projectID] = state
        publish(projectID)
    }

    private func exited(code: Int32, projectID: String, runID: String) {
        guard let run = runs[projectID], run.id == runID else { return }
        if let record = run.ledgerRecord, let processInspector {
            switch processInspector.inspect(ProcessOwnershipExpectation(record: record)) {
            case .exited:
                _ = finalizeExit(
                    projectID: projectID,
                    run: run,
                    code: code >= 0 ? code : nil,
                    intentional: run.isStopping
                )
            case .verified:
                _ = markCleanupFailure(
                    projectID: projectID,
                    message: "The process-group leader exited, but verified descendants remain."
                )
            case .unverifiable(let uncertainty):
                _ = markOwnershipFailure(
                    projectID: projectID,
                    runID: runID,
                    reason: ownershipReason(uncertainty),
                    message: uncertaintyMessage(uncertainty)
                )
            case .conflicting(let conflict):
                _ = markOwnershipFailure(
                    projectID: projectID,
                    runID: runID,
                    reason: ownershipReason(conflict),
                    message: conflictMessage(conflict)
                )
            }
        } else {
            _ = finalizeExit(
                projectID: projectID,
                run: run,
                code: code,
                intentional: run.isStopping
            )
        }
    }

    private func readinessFinished(
        ready: Bool,
        url: URL,
        projectID: String,
        runID: String
    ) {
        guard runs[projectID]?.id == runID,
              runs[projectID]?.process.isRunning == true,
              var state = states[projectID] else { return }
        if ready {
            state.status = .ready
            state.readyAt = now()
            state.readinessMessage = "Project is ready."
            state.appendLog("[ready] \(redactedURL(url))")
            state.diagnosis.status = .ready
            state.diagnosis.summary = "Project is ready."
            state.diagnosis.setCheck(.process, status: .pass, message: "Process is running.")
            state.diagnosis.setCheck(.readiness, status: .pass, message: "Local URL responded.")
            state.diagnosis.addTimeline("Project became ready.", status: .pass, at: now())
        } else {
            state.status = .runningUnresponsive
            state.terminalReason = .readinessTimeout
            state.readinessMessage = "\(redactedURL(url)) did not respond before timeout."
            state.appendLog("[running-unresponsive] \(state.readinessMessage ?? "")")
            state.diagnosis.status = .attention
            state.diagnosis.summary = "Process is running, but readiness timed out. Next: review the URL and output."
            state.diagnosis.setCheck(.process, status: .pass, message: "Process is still running.")
            state.diagnosis.setCheck(.readiness, status: .warn, message: state.readinessMessage ?? "Readiness timed out.")
            state.diagnosis.addTimeline("Readiness polling timed out.", status: .warn, at: now())
        }
        states[projectID] = state
        publish(projectID)
    }

    private func assertManagedStartAllowed(
        projectID: String,
        managed: ManagedComponents
    ) throws {
        let records = try managed.ledger.load().records.filter { $0.projectID == projectID }
        for record in records {
            switch managed.inspector.inspect(ProcessOwnershipExpectation(record: record)) {
            case .exited:
                _ = try managed.ledger.remove(runID: record.runID)
                try? managed.ledger.removeLog(filename: record.logFilename)
            case .verified:
                throw RuntimeError.reconciliationRequired(
                    "LocalWrap already owns a recorded run for this project."
                )
            case .unverifiable:
                throw RuntimeError.ownershipNotVerified(
                    "A recorded run cannot be verified, so LocalWrap will not start a duplicate."
                )
            case .conflicting:
                throw RuntimeError.ownershipNotVerified(
                    "A recorded run conflicts with the current process identity, so LocalWrap will not start a duplicate."
                )
            }
        }
    }

    private func launchContract(
        for project: Project
    ) throws -> (fingerprint: String, readinessURL: URL) {
        guard isDirectory(project.cwd) else {
            throw RuntimeError.workingDirectoryMissing(project.cwd)
        }
        let command = try parser.parse(project.command)
        let resolved = try environmentResolver.resolve(
            executable: command.executable,
            port: project.port
        )
        let readinessURL = try readinessURL(for: project)
        return (
            ProcessCommandFingerprint.makeLaunchContract(
                executablePath: resolved.executableURL.path,
                arguments: command.arguments,
                workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
                port: project.port,
                readinessURL: readinessURL
            ),
            readinessURL
        )
    }

    private func readinessURL(for project: Project) throws -> URL {
        let resolution = healthChecks.resolve(project)
        guard let url = resolution.url else {
            throw RuntimeError.launchFailed(resolution.error ?? "Invalid readiness URL.")
        }
        return url
    }

    private func signalReadiness(
        record: RuntimeLedgerRecord,
        inspector: any ProcessInspecting
    ) -> SignalReadiness {
        switch inspector.inspect(ProcessOwnershipExpectation(record: record)) {
        case .verified(let ownership):
            return .verified(ownership)
        case .exited:
            return .exited
        case .unverifiable(let uncertainty):
            return .unsafe(
                uncertaintyMessage(uncertainty),
                ownershipReason(uncertainty)
            )
        case .conflicting(let conflict):
            return .unsafe(conflictMessage(conflict), ownershipReason(conflict))
        }
    }

    private func signalVerifiedProcessGroup(
        _ signal: Int32,
        ownership: VerifiedProcessOwnership,
        process: any ManagedProjectProcess
    ) throws {
        guard ownership.pid == process.pid,
              ownership.processGroupID == process.processGroupID,
              ownership.pid == ownership.processGroupID,
              ownership.pid == ownership.sessionID else {
            throw RuntimeError.ownershipNotVerified(
                "The monitored process no longer matches the freshly verified process group."
            )
        }
        try process.signalProcessGroup(signal)
    }

    private func waitForManagedExit(
        record: RuntimeLedgerRecord,
        inspector: any ProcessInspecting,
        attempts: Int
    ) async -> ManagedWaitResult {
        for _ in 0..<attempts {
            switch inspector.inspect(ProcessOwnershipExpectation(record: record)) {
            case .exited:
                return .exited
            case .verified:
                try? await Task.sleep(for: .milliseconds(100))
            case .unverifiable(let uncertainty):
                return .unsafe(uncertaintyMessage(uncertainty), ownershipReason(uncertainty))
            case .conflicting(let conflict):
                return .unsafe(conflictMessage(conflict), ownershipReason(conflict))
            }
        }
        switch inspector.inspect(ProcessOwnershipExpectation(record: record)) {
        case .exited:
            return .exited
        case .verified:
            return .stillRunning
        case .unverifiable(let uncertainty):
            return .unsafe(uncertaintyMessage(uncertainty), ownershipReason(uncertainty))
        case .conflicting(let conflict):
            return .unsafe(conflictMessage(conflict), ownershipReason(conflict))
        }
    }

    private func waitForExit(_ process: any ManagedProjectProcess, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func markReconciledExit(record: RuntimeLedgerRecord, project: Project?) {
        guard project != nil, runs[record.projectID] == nil else { return }
        var state = states[record.projectID] ?? RuntimeSnapshot()
        state.status = .stopped
        state.runID = record.runID
        state.ownership = .none
        state.pid = nil
        state.stoppedAt = now()
        state.readinessMessage = "The previously recorded process group has exited."
        states[record.projectID] = state
        publish(record.projectID)
    }

    private func setUnresolvedState(
        record: RuntimeLedgerRecord,
        project: Project?,
        classification: RuntimeReconciliationClassification,
        reason: RuntimeOwnershipReason,
        message: String
    ) {
        guard let project else { return }
        var diagnosis = doctor.diagnose(ProjectDraft(project: project))
        diagnosis.status = .attention
        diagnosis.summary = "Runtime ownership needs review before LocalWrap can control this run."
        diagnosis.setCheck(.process, status: .warn, message: message)
        diagnosis.addTimeline("Runtime reconciliation needs attention.", status: .warn, at: now())
        let ownership: RuntimeOwnershipState = classification == .conflicting
            ? .conflicting(runID: record.runID, reason: reason)
            : .unverifiable(runID: record.runID, reason: reason)
        states[project.id] = RuntimeSnapshot(
            status: .runningUnresponsive,
            runID: record.runID,
            ownership: ownership,
            terminalReason: classification == .conflicting
                ? .ownershipConflict
                : .ownershipUnverifiable,
            pid: record.pid,
            logs: ["[reconciliation] \(message)"],
            startedAt: record.startedAt,
            readinessMessage: message,
            error: message,
            diagnosis: diagnosis
        )
        publish(project.id)
    }

    private func publishStartFailure(
        project: Project,
        error: Error,
        terminalReason: RuntimeTerminalReason
    ) {
        var diagnosis = doctor.diagnose(ProjectDraft(project: project))
        diagnosis.status = .attention
        diagnosis.summary = "Start is blocked until runtime ownership is reconciled."
        diagnosis.setCheck(.process, status: .warn, message: error.localizedDescription)
        var failed = states[project.id] ?? RuntimeSnapshot()
        failed.status = .failed
        failed.error = error.localizedDescription
        failed.readinessMessage = error.localizedDescription
        failed.terminalReason = terminalReason
        failed.diagnosis = diagnosis
        failed.appendLog("[reconciliation] \(error.localizedDescription)")
        states[project.id] = failed
        publish(project.id)
    }

    private func ownershipReason(
        _ uncertainty: ProcessInspectionUncertainty
    ) -> RuntimeOwnershipReason {
        switch uncertainty {
        case .permissionDenied:
            .permissionDenied
        case .systemFailure, .malformedArguments:
            .inspectionUnavailable
        }
    }

    private func ownershipReason(_ conflict: ProcessOwnershipConflict) -> RuntimeOwnershipReason {
        switch conflict {
        case .processGroup, .session, .leaderMissingFromProcessGroup,
             .groupMemberProcessGroup, .groupMemberSession:
            .processGroupMismatch
        default:
            .identityMismatch
        }
    }

    private func uncertaintyMessage(_ uncertainty: ProcessInspectionUncertainty) -> String {
        switch uncertainty {
        case .permissionDenied:
            "macOS did not permit LocalWrap to verify this process group. It was not signalled."
        case .systemFailure:
            "macOS could not provide enough process identity evidence. The process group was not signalled."
        case .malformedArguments:
            "The running process arguments could not be verified safely. The process group was not signalled."
        }
    }

    private func conflictMessage(_ conflict: ProcessOwnershipConflict) -> String {
        switch conflict {
        case .leaderMissingFromProcessGroup:
            "The recorded leader exited while processes remain in its group. LocalWrap will not signal them automatically."
        case .processGroup, .session, .groupMemberProcessGroup, .groupMemberSession:
            "The recorded process-group identity changed. LocalWrap will not signal it automatically."
        default:
            "The recorded process identity no longer matches. LocalWrap will not signal it automatically."
        }
    }

    private func redactedURL(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.string ?? "the local URL"
    }

    private func publish(_ projectID: String) {
        guard let state = states[projectID] else { return }
        eventSink?(projectID, state)
    }
}
