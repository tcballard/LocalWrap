import Foundation

struct PackageScript: Equatable, Sendable {
    let name: String
    let command: String
    let script: String
    let preferred: Bool
}

struct InspectionWarning: Equatable, Sendable {
    let field: String
    let code: String
    let message: String
}

struct ProjectInspection: Equatable, Sendable {
    let cwd: String
    let name: String
    let scripts: [PackageScript]
    let recommendedCommand: String
    let suggestedPort: Int
    let suggestedURL: String
    let warnings: [InspectionWarning]
}

protocol DirectoryInspectingFileSystem {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func readData(at url: URL) throws -> Data
}

struct LocalDirectoryInspectingFileSystem: DirectoryInspectingFileSystem {
    func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

final class ProjectInspectionService {
    private static let preferredOrder = ["dev", "start", "preview", "serve"]

    private let fileSystem: any DirectoryInspectingFileSystem
    private let portSuggester: PortSuggestionService

    init(
        fileSystem: any DirectoryInspectingFileSystem = LocalDirectoryInspectingFileSystem(),
        portSuggester: PortSuggestionService = PortSuggestionService()
    ) {
        self.fileSystem = fileSystem
        self.portSuggester = portSuggester
    }

    func inspect(directory: URL?, preferredPort: Int = 3_000) throws -> ProjectInspection {
        guard let directory else {
            return ProjectInspection(
                cwd: "",
                name: "Untitled Project",
                scripts: [],
                recommendedCommand: "npm run dev",
                suggestedPort: preferredPort,
                suggestedURL: "http://localhost:\(preferredPort)",
                warnings: [warning("cwd", "cwd-required", "Choose a project directory.")]
            )
        }

        let path = directory.standardizedFileURL.path
        guard fileSystem.isDirectory(at: directory) else {
            return ProjectInspection(
                cwd: path,
                name: directory.lastPathComponent.isEmpty ? "Untitled Project" : directory.lastPathComponent,
                scripts: [],
                recommendedCommand: "npm run dev",
                suggestedPort: preferredPort,
                suggestedURL: "http://localhost:\(preferredPort)",
                warnings: [warning("cwd", "cwd-missing", "Directory does not exist.")]
            )
        }

        let packageURL = directory.appendingPathComponent("package.json")
        var warnings: [InspectionWarning] = []
        var packageName: String?
        var scripts: [PackageScript] = []
        if !fileSystem.fileExists(at: packageURL) {
            warnings.append(warning(
                "cwd",
                "package-json-missing",
                "No package.json found. You can still enter a command manually."
            ))
        } else {
            do {
                let data = try fileSystem.readData(at: packageURL)
                let json = try JSONSerialization.jsonObject(with: data)
                guard let object = json as? [String: Any] else {
                    throw CocoaError(.propertyListReadCorrupt)
                }
                packageName = object["name"] as? String
                let rawScripts = object["scripts"] as? [String: Any] ?? [:]
                scripts = discoverScripts(rawScripts)
            } catch {
                warnings.append(warning(
                    "cwd",
                    "package-json-invalid",
                    "package.json could not be read. Enter a command manually."
                ))
            }
        }
        if scripts.isEmpty {
            warnings.append(warning(
                "command",
                "scripts-missing",
                "No package scripts found. Enter the command you use to start this project."
            ))
        }

        let port = try portSuggester.suggest(preferred: preferredPort)
        return ProjectInspection(
            cwd: path,
            name: packageName?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
                ?? directory.lastPathComponent,
            scripts: scripts,
            recommendedCommand: scripts.first?.command ?? "npm run dev",
            suggestedPort: port,
            suggestedURL: "http://localhost:\(port)",
            warnings: warnings
        )
    }

    private func discoverScripts(_ rawScripts: [String: Any]) -> [PackageScript] {
        let names = rawScripts.keys.filter { rawScripts[$0] is String }
        let preferred = Self.preferredOrder.filter(names.contains)
        let remaining = names.filter { !Self.preferredOrder.contains($0) }.sorted()
        return (preferred + remaining).compactMap { name in
            guard let script = rawScripts[name] as? String else {
                return nil
            }
            return PackageScript(
                name: name,
                command: name == "start" ? "npm start" : "npm run \(name)",
                script: script,
                preferred: Self.preferredOrder.contains(name)
            )
        }
    }

    private func warning(_ field: String, _ code: String, _ message: String) -> InspectionWarning {
        InspectionWarning(field: field, code: code, message: message)
    }
}

private extension String {
    var nonempty: String? {
        isEmpty ? nil : self
    }
}
