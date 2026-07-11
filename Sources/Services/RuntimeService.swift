import Darwin
import Foundation

actor RuntimeService {
    typealias EventSink = @Sendable (String, RuntimeSnapshot) -> Void

    private struct RunContext {
        let id: UUID
        let process: any ManagedProjectProcess
        var readinessTask: Task<Void, Never>?
    }

    private let parser: CommandParser
    private let environmentResolver: EnvironmentResolver
    private let launcher: any ProjectProcessLaunching
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

    init(
        parser: CommandParser = CommandParser(),
        environmentResolver: EnvironmentResolver = EnvironmentResolver(),
        launcher: any ProjectProcessLaunching = PosixProcessLauncher(),
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

    @discardableResult
    func start(_ project: Project) async throws -> RuntimeSnapshot {
        if states[project.id]?.status.isActive == true {
            throw RuntimeError.alreadyRunning
        }
        var diagnosis = doctor.diagnose(ProjectDraft(project: project))
        if diagnosis.status == .failed {
            let message = diagnosis.summary
            var failed = states[project.id] ?? RuntimeSnapshot()
            failed.status = .failed
            failed.error = message
            failed.readinessMessage = "Doctor preflight blocked start."
            failed.diagnosis = diagnosis
            failed.appendLog("[doctor] \(message)")
            states[project.id] = failed
            publish(project.id)
            throw RuntimeError.doctorBlocked(message)
        }
        let runID = UUID()
        diagnosis.status = .starting
        diagnosis.summary = "Starting project. Next: wait for the process to launch."
        diagnosis.setCheck(.process, status: .running, message: "Starting process.")
        diagnosis.setCheck(.readiness, status: .pending, message: "Waiting for the process to launch.")
        diagnosis.addTimeline("Starting project.", status: .info, at: now())
        var state = RuntimeSnapshot(
            status: .starting,
            logs: [],
            startedAt: now(),
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
            let process = try launcher.launch(
                executable: resolved.executableURL,
                arguments: command.arguments,
                environment: resolved.values,
                workingDirectory: URL(fileURLWithPath: project.cwd, isDirectory: true),
                onOutput: { [weak self] line in
                    Task { await self?.received(line: line, projectID: project.id, runID: runID) }
                },
                onExit: { [weak self] code in
                    Task { await self?.exited(code: code, projectID: project.id, runID: runID) }
                }
            )
            state.pid = process.pid
            state.appendLog("[started] PID \(process.pid)")
            state.diagnosis.status = .waiting
            state.diagnosis.summary = "Process is running. Next: wait for readiness."
            state.diagnosis.setCheck(.process, status: .pass, message: "Process started with PID \(process.pid).")
            state.diagnosis.setCheck(.readiness, status: .running, message: "Waiting for the local URL to respond.")
            state.diagnosis.addTimeline("Process started with PID \(process.pid).", status: .pass, at: now())
            state.diagnosis.addTimeline("Readiness polling started.", status: .info, at: now())
            states[project.id] = state
            let task = Task { [weak self, readiness] in
                let ready = await readiness.waitUntilReady(
                    url: readinessURL,
                    timeout: .seconds(30),
                    interval: .milliseconds(500)
                )
                await self?.readinessFinished(
                    ready: ready,
                    url: readinessURL,
                    projectID: project.id,
                    runID: runID
                )
            }
            runs[project.id] = RunContext(id: runID, process: process, readinessTask: task)
            publish(project.id)
            return state
        } catch {
            state.status = .failed
            state.error = error.localizedDescription
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
            state.diagnosis.addTimeline("Process launch failed: \(error.localizedDescription)", status: .fail, at: now())
            states[project.id] = state
            publish(project.id)
            throw error
        }
    }

    @discardableResult
    func stop(projectID: String) async -> RuntimeSnapshot {
        guard let run = runs[projectID] else {
            return states[projectID] ?? RuntimeSnapshot()
        }
        run.readinessTask?.cancel()
        if var state = states[projectID] {
            state.status = .stopping
            state.readinessMessage = "Stopping project."
            state.diagnosis.status = .stopped
            state.diagnosis.summary = "Stopping project. Next: wait for process cleanup."
            state.diagnosis.setCheck(.process, status: .running, message: "Stopping process group.")
            state.diagnosis.addTimeline("Stopping project.", status: .info, at: now())
            states[projectID] = state
            publish(projectID)
        }
        run.process.signalProcessGroup(SIGTERM)
        if !(await waitForExit(run.process, attempts: terminationWaitAttempts)) {
            run.process.signalProcessGroup(SIGKILL)
            _ = await waitForExit(run.process, attempts: killWaitAttempts)
        }
        if runs[projectID]?.id == run.id, !run.process.isRunning {
            runs[projectID] = nil
            var state = states[projectID] ?? RuntimeSnapshot()
            state.status = .stopped
            state.pid = nil
            state.stoppedAt = now()
            state.readinessMessage = "Project stopped."
            state.diagnosis.status = .stopped
            state.diagnosis.summary = "Project stopped. Next: Start when you are ready."
            state.diagnosis.setCheck(.process, status: .pending, message: "Process is stopped.")
            state.diagnosis.setCheck(.readiness, status: .pending, message: "Readiness is stopped.")
            state.diagnosis.addTimeline("Project stopped and process group exited.", status: .pass, at: now())
            states[projectID] = state
            publish(projectID)
        } else if runs[projectID]?.id == run.id, run.process.isRunning {
            var state = states[projectID] ?? RuntimeSnapshot()
            state.status = .runningUnresponsive
            state.readinessMessage = "Process did not exit after SIGTERM and SIGKILL."
            state.appendLog("[stop] Process group did not exit.")
            state.diagnosis.status = .failed
            state.diagnosis.summary = "Cleanup failed. Next: inspect the surviving process group."
            state.diagnosis.setCheck(.process, status: .fail, message: state.readinessMessage ?? "Cleanup failed.")
            state.diagnosis.addTimeline("Process cleanup failed.", status: .fail, at: now())
            states[projectID] = state
            publish(projectID)
        }
        return states[projectID] ?? RuntimeSnapshot()
    }

    func restart(_ project: Project) async throws -> RuntimeSnapshot {
        _ = await stop(projectID: project.id)
        var state = try await start(project)
        state.diagnosis.addTimeline("Restarted project.", status: .info, at: now())
        states[project.id] = state
        publish(project.id)
        return state
    }

    func stopAll() async {
        for projectID in Array(runs.keys) {
            _ = await stop(projectID: projectID)
        }
    }

    func clearLogs(projectID: String) {
        guard var state = states[projectID] else { return }
        state.logs = []
        states[projectID] = state
        publish(projectID)
    }

    private func received(line: String, projectID: String, runID: UUID) {
        guard runs[projectID]?.id == runID, var state = states[projectID] else { return }
        state.appendLog(line)
        states[projectID] = state
        publish(projectID)
    }

    private func exited(code: Int32, projectID: String, runID: UUID) {
        guard runs[projectID]?.id == runID, var state = states[projectID] else { return }
        runs[projectID]?.readinessTask?.cancel()
        runs[projectID] = nil
        let wasStopping = state.status == .stopping
        state.status = wasStopping || code == 0 ? .stopped : .failed
        state.pid = nil
        state.exitCode = code
        state.stoppedAt = now()
        state.readinessMessage = wasStopping || code == 0
            ? "Project stopped."
            : "Process exited with code \(code)."
        state.error = wasStopping || code == 0 ? nil : state.readinessMessage
        state.appendLog("[process exited with code \(code)]")
        if wasStopping || code == 0 {
            state.diagnosis.status = .stopped
            state.diagnosis.summary = "Project stopped. Next: Start when you are ready."
            state.diagnosis.setCheck(.process, status: .pending, message: "Process exited with code \(code).")
            state.diagnosis.setCheck(.readiness, status: .pending, message: "Readiness is stopped.")
            state.diagnosis.addTimeline("Process exited with code \(code).", status: .pass, at: now())
        } else {
            state.diagnosis.status = .failed
            state.diagnosis.summary = "Process exited unexpectedly. Next: review the final log lines."
            state.diagnosis.setCheck(.process, status: .fail, message: "Process exited with code \(code).")
            state.diagnosis.addTimeline("Process exited unexpectedly with code \(code).", status: .fail, at: now())
        }
        states[projectID] = state
        publish(projectID)
    }

    private func readinessFinished(
        ready: Bool,
        url: URL,
        projectID: String,
        runID: UUID
    ) {
        guard runs[projectID]?.id == runID,
              runs[projectID]?.process.isRunning == true,
              var state = states[projectID] else { return }
        if ready {
            state.status = .ready
            state.readyAt = now()
            state.readinessMessage = "Project is ready."
            state.appendLog("[ready] \(url.absoluteString)")
            state.diagnosis.status = .ready
            state.diagnosis.summary = "Project is ready."
            state.diagnosis.setCheck(.process, status: .pass, message: "Process is running.")
            state.diagnosis.setCheck(.readiness, status: .pass, message: "Local URL responded.")
            state.diagnosis.addTimeline("Project became ready.", status: .pass, at: now())
        } else {
            state.status = .runningUnresponsive
            state.readinessMessage = "\(url.absoluteString) did not respond before timeout."
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

    private func readinessURL(for project: Project) throws -> URL {
        let resolution = healthChecks.resolve(project)
        guard let url = resolution.url else {
            throw RuntimeError.launchFailed(resolution.error ?? "Invalid readiness URL.")
        }
        return url
    }

    private func waitForExit(_ process: any ManagedProjectProcess, attempts: Int) async -> Bool {
        for _ in 0..<attempts {
            if !process.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return !process.isRunning
    }

    private func publish(_ projectID: String) {
        guard let state = states[projectID] else { return }
        eventSink?(projectID, state)
    }
}
