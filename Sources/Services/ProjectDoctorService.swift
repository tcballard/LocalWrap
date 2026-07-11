import Foundation

protocol DoctorFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
}

struct LocalDoctorFileSystem: DoctorFileSystem {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
            && directory.boolValue
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

final class ProjectDoctorService: @unchecked Sendable {
    private let fileSystem: any DoctorFileSystem
    private let validationService: ProjectValidationService
    private let portSuggester: PortSuggestionService
    private let now: @Sendable () -> String

    init(
        fileSystem: any DoctorFileSystem = LocalDoctorFileSystem(),
        validationService: ProjectValidationService = ProjectValidationService(),
        portSuggester: PortSuggestionService = PortSuggestionService(),
        now: @escaping @Sendable () -> String = { ISO8601DateFormatter().string(from: Date()) }
    ) {
        self.fileSystem = fileSystem
        self.validationService = validationService
        self.portSuggester = portSuggester
        self.now = now
    }

    func diagnose(_ draft: ProjectDraft, checkPortAvailability: Bool = true) -> ProjectDiagnosis {
        let timestamp = now()
        let directory = URL(fileURLWithPath: draft.cwd, isDirectory: true)
        let validation = validationService.validate(
            draft,
            isDirectory: { [fileSystem] path in
                fileSystem.isDirectory(at: URL(fileURLWithPath: path, isDirectory: true))
            },
            isPortAvailable: checkPortAvailability ? { [portSuggester] port in
                portSuggester.isAvailable(port)
            } : nil
        )
        var diagnosis = ProjectDiagnosis.notChecked(now: timestamp)
        diagnosis.status = .checking
        var combinedValidation = validation
        diagnosis.addTimeline("Checked project configuration.", status: .info, at: timestamp)

        let packageInspection = inspectPackage(at: directory)
        if let warning = packageInspection.warning,
           !validation.errors.contains(where: { $0.field == .cwd }) {
            combinedValidation.messages.append(warning)
        }
        if !packageInspection.hasScripts,
           !validation.errors.contains(where: { $0.field == .command }) {
            combinedValidation.messages.append(message(
                .command,
                "scripts-missing",
                "No package scripts found. Enter the command you use to start this project.",
                .warning
            ))
        }
        if packageInspection.hasDependencies, let install = packageInspection.installCommand {
            combinedValidation.messages.append(message(
                .dependencies,
                "node-modules-missing",
                "Dependencies may be missing. Next: run \(install) in this folder if start fails.",
                .warning
            ))
        }
        diagnosis.validation = combinedValidation
        configureDirectoryCheck(&diagnosis, validation: combinedValidation, package: packageInspection)
        configureCommandCheck(&diagnosis, validation: combinedValidation, package: packageInspection)
        configureDependencyCheck(&diagnosis, validation: combinedValidation, package: packageInspection)
        mapField(
            &diagnosis,
            check: .port,
            field: .port,
            validation: combinedValidation,
            passMessage: "Port is valid.",
            warningActions: [.findFreePort]
        )
        mapField(
            &diagnosis,
            check: .url,
            field: .url,
            validation: combinedValidation,
            passMessage: "URL is local.",
            warningActions: [.syncURL]
        )
        diagnosis.setCheck(.process, status: .pending, message: "Process has not started yet.")
        diagnosis.setCheck(.readiness, status: .pending, message: "Readiness check has not started yet.")

        if !validation.errors.isEmpty {
            diagnosis.status = .failed
            diagnosis.summary = "Start is blocked. Next: fix the failed Doctor check."
            diagnosis.addTimeline("Preflight found errors that block start.", status: .fail, at: now())
        } else if diagnosis.checks.contains(where: { $0.status == .warn }) {
            diagnosis.status = .attention
            diagnosis.summary = "Project can start, but Doctor found warnings. Next: review the highlighted checks."
            diagnosis.addTimeline("Preflight found warnings.", status: .warn, at: now())
        } else {
            diagnosis.status = .idle
            diagnosis.summary = "Project looks ready to start. Next: Save & Start."
            diagnosis.addTimeline("Preflight checks passed.", status: .pass, at: now())
        }
        diagnosis.updatedAt = now()
        return diagnosis
    }

    func actionPatch(
        for draft: ProjectDraft,
        actionID: String
    ) throws -> ProjectDraft {
        guard let action = DoctorActionID(rawValue: actionID) else {
            throw DoctorError.unknownAction(actionID)
        }
        return try actionPatch(for: draft, action: action)
    }

    func actionPatch(
        for draft: ProjectDraft,
        action: DoctorActionID
    ) throws -> ProjectDraft {
        var next = draft
        switch action {
        case .syncURL:
            guard (1_000...65_535).contains(draft.port) else {
                throw DoctorError.invalidAvailablePort
            }
            next.url = "http://localhost:\(draft.port)"
        case .findFreePort:
            let available = try portSuggester.suggest(preferred: draft.port)
            next.port = available
            if draft.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || validationService.urlValidator.isAutomaticallyGenerated(
                    draft.url,
                    configuredPort: draft.port
                ) {
                next.url = "http://localhost:\(available)"
            }
        case .revealFolder, .copyReport, .revealCommand:
            break
        }
        return next
    }

    private struct PackageInspection {
        var warning: ProjectFieldValidation?
        var hasScripts = false
        var hasDependencies = false
        var installCommand: String?
    }

    private func inspectPackage(at directory: URL) -> PackageInspection {
        guard fileSystem.isDirectory(at: directory) else { return PackageInspection() }
        let packageURL = directory.appendingPathComponent("package.json")
        guard fileSystem.fileExists(at: packageURL) else {
            return PackageInspection(warning: message(
                .cwd,
                "package-json-missing",
                "No package.json found. You can still enter a command manually.",
                .warning
            ))
        }
        do {
            let object = try JSONSerialization.jsonObject(with: fileSystem.readData(at: packageURL))
            guard let package = object as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            let scripts = package["scripts"] as? [String: Any] ?? [:]
            let dependencies = package["dependencies"] as? [String: Any] ?? [:]
            let devDependencies = package["devDependencies"] as? [String: Any] ?? [:]
            let hasDependencies = !dependencies.isEmpty || !devDependencies.isEmpty
            let modules = directory.appendingPathComponent("node_modules", isDirectory: true)
            return PackageInspection(
                warning: nil,
                hasScripts: scripts.values.contains { $0 is String },
                hasDependencies: hasDependencies && !fileSystem.isDirectory(at: modules),
                installCommand: hasDependencies ? inferInstallCommand(in: directory) : nil
            )
        } catch {
            return PackageInspection(warning: message(
                .cwd,
                "package-json-invalid",
                "package.json could not be read. Enter a command manually.",
                .warning
            ))
        }
    }

    private func inferInstallCommand(in directory: URL) -> String {
        if fileSystem.fileExists(at: directory.appendingPathComponent("pnpm-lock.yaml")) {
            return "pnpm install"
        }
        if fileSystem.fileExists(at: directory.appendingPathComponent("yarn.lock")) {
            return "yarn install"
        }
        if fileSystem.fileExists(at: directory.appendingPathComponent("bun.lock"))
            || fileSystem.fileExists(at: directory.appendingPathComponent("bun.lockb")) {
            return "bun install"
        }
        return "npm install"
    }

    private func configureDirectoryCheck(
        _ diagnosis: inout ProjectDiagnosis,
        validation: ProjectValidation,
        package: PackageInspection
    ) {
        if let error = validation.errors.first(where: { $0.field == .cwd }) {
            diagnosis.setCheck(.directory, status: .fail, message: error.message)
        } else if let warning = package.warning {
            diagnosis.setCheck(.directory, status: .warn, message: warning.message, actions: [.revealFolder])
        } else {
            diagnosis.setCheck(.directory, status: .pass, message: "Directory exists.", actions: [.revealFolder])
        }
    }

    private func configureCommandCheck(
        _ diagnosis: inout ProjectDiagnosis,
        validation: ProjectValidation,
        package: PackageInspection
    ) {
        if let error = validation.errors.first(where: { $0.field == .command }) {
            diagnosis.setCheck(.command, status: .fail, message: error.message, actions: [.revealCommand])
        } else if !package.hasScripts {
            diagnosis.setCheck(
                .command,
                status: .warn,
                message: "No package scripts found. Enter the command you use to start this project.",
                actions: [.revealCommand]
            )
        } else {
            diagnosis.setCheck(.command, status: .pass, message: "Command is allowed.", actions: [.revealCommand])
        }
    }

    private func configureDependencyCheck(
        _ diagnosis: inout ProjectDiagnosis,
        validation: ProjectValidation,
        package: PackageInspection
    ) {
        if validation.errors.contains(where: { $0.field == .cwd }) {
            diagnosis.setCheck(.dependencies, status: .pending, message: "Choose an existing directory first.")
        } else if package.hasDependencies, let install = package.installCommand {
            diagnosis.setCheck(
                .dependencies,
                status: .warn,
                message: "Dependencies may be missing. Next: run \(install) in this folder if start fails."
            )
        } else {
            diagnosis.setCheck(.dependencies, status: .pass, message: "No dependency warning detected.")
        }
    }

    private func mapField(
        _ diagnosis: inout ProjectDiagnosis,
        check: DoctorCheckID,
        field: ProjectField,
        validation: ProjectValidation,
        passMessage: String,
        warningActions: [DoctorActionID]
    ) {
        if let error = validation.errors.first(where: { $0.field == field }) {
            diagnosis.setCheck(check, status: .fail, message: error.message)
        } else if let warning = validation.warnings.first(where: { $0.field == field }) {
            diagnosis.setCheck(check, status: .warn, message: warning.message, actions: warningActions)
        } else {
            diagnosis.setCheck(check, status: .pass, message: passMessage)
        }
    }

    private func message(
        _ field: ProjectField,
        _ code: String,
        _ message: String,
        _ severity: ProjectValidationSeverity
    ) -> ProjectFieldValidation {
        ProjectFieldValidation(field: field, code: code, message: message, severity: severity)
    }
}
