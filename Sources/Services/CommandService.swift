import Foundation

struct CommandParser: Sendable {
    static let allowedExecutables = Set([
        "npm", "npx", "yarn", "pnpm", "node", "bun", "python", "python3", "deno",
    ])

    func parse(_ input: String) throws -> ParsedCommand {
        let command = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            throw RuntimeError.emptyCommand
        }
        let forbidden = CharacterSet(charactersIn: ";&|$`><(){}[]!#*?~%^\"'\n\r")
        guard command.rangeOfCharacter(from: forbidden) == nil else {
            throw RuntimeError.disallowedCharacters
        }
        let tokens = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = tokens.first else {
            throw RuntimeError.emptyCommand
        }
        guard Self.allowedExecutables.contains(executable) else {
            throw RuntimeError.executableNotAllowed(executable)
        }
        return ParsedCommand(executable: executable, arguments: Array(tokens.dropFirst()))
    }
}

struct ResolvedEnvironment: Equatable, Sendable {
    let executableURL: URL
    let values: [String: String]
}

struct EnvironmentResolver: Sendable {
    private let environment: @Sendable () -> [String: String]
    private let isExecutable: @Sendable (String) -> Bool

    init(
        environment: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        },
        isExecutable: @escaping @Sendable (String) -> Bool = {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    ) {
        self.environment = environment
        self.isExecutable = isExecutable
    }

    func resolve(executable: String, port: Int) throws -> ResolvedEnvironment {
        var values = environment()
        let standardDirectories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let inheritedDirectories = (values["PATH"] ?? "").split(separator: ":").map(String.init)
        var seen = Set<String>()
        let directories = (inheritedDirectories + standardDirectories).filter {
            !$0.isEmpty && seen.insert($0).inserted
        }
        let path = directories.joined(separator: ":")
        values["PATH"] = path
        values["PORT"] = String(port)
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent(executable)
            if isExecutable(candidate.path) {
                return ResolvedEnvironment(executableURL: candidate, values: values)
            }
        }
        throw RuntimeError.executableNotFound(executable)
    }
}
