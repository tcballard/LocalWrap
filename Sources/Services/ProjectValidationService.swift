import Foundation

struct LocalURLValidator: Sendable {
    static let allowedHosts = Set(["localhost", "127.0.0.1", "::1"])

    func validate(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              Self.allowedHosts.contains(host),
              components.user == nil,
              components.password == nil,
              let port = components.port,
              (1_000...65_535).contains(port) else {
            return false
        }
        return true
    }

    func port(in value: String) -> Int? {
        guard validate(value) else { return nil }
        return URLComponents(string: value)?.port
    }

    func url(from value: String) -> URL? {
        guard validate(value) else { return nil }
        return URL(string: value)
    }

    func isAutomaticallyGenerated(_ value: String, configuredPort: Int) -> Bool {
        guard validate(value), port(in: value) == configuredPort,
              let components = URLComponents(string: value),
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return false
        }
        return true
    }
}

struct ProjectValidationService: Sendable {
    let commandParser: CommandParser
    let urlValidator: LocalURLValidator

    init(
        commandParser: CommandParser = CommandParser(),
        urlValidator: LocalURLValidator = LocalURLValidator()
    ) {
        self.commandParser = commandParser
        self.urlValidator = urlValidator
    }

    func validate(
        _ draft: ProjectDraft,
        isDirectory: (String) -> Bool,
        isPortAvailable: ((Int) -> Bool)? = nil
    ) -> ProjectValidation {
        var result = ProjectValidation()
        let name = draft.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let directory = draft.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)

        if name.isEmpty {
            add(&result, .name, "name-required", "Name is required.", .error)
        }
        if directory.isEmpty {
            add(&result, .cwd, "cwd-required", "Directory is required.", .error)
        } else if !isDirectory(directory) {
            add(&result, .cwd, "cwd-missing", "Directory does not exist.", .error)
        }
        if command.isEmpty {
            add(&result, .command, "command-required", "Command is required.", .error)
        } else {
            do {
                _ = try commandParser.parse(command)
            } catch {
                add(&result, .command, "command-invalid", error.localizedDescription, .error)
            }
        }
        if !(1_000...65_535).contains(draft.port) {
            add(&result, .port, "port-invalid", "Port must be between 1000 and 65535.", .error)
        } else if let isPortAvailable, !isPortAvailable(draft.port) {
            add(&result, .port, "port-busy", "Port appears to be in use.", .warning)
        }
        if url.isEmpty {
            add(&result, .url, "url-required", "App URL is required.", .error)
        } else if !urlValidator.validate(url) {
            add(&result, .url, "url-invalid", "URL must be local http(s) on an allowed port.", .error)
        } else if (1_000...65_535).contains(draft.port), urlValidator.port(in: url) != draft.port {
            add(&result, .url, "url-port-mismatch", "URL port does not match the project port.", .warning)
        }
        return result
    }

    private func add(
        _ result: inout ProjectValidation,
        _ field: ProjectField,
        _ code: String,
        _ message: String,
        _ severity: ProjectValidationSeverity
    ) {
        result.messages.append(ProjectFieldValidation(
            field: field,
            code: code,
            message: message,
            severity: severity
        ))
    }
}
