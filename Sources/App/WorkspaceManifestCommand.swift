import Foundation

struct WorkspaceManifestCommand {
    typealias Reviewer = (URL, URL?) throws -> ReviewedWorkspacePack
    typealias Output = (String) -> Void

    private let reviewer: Reviewer
    private let output: Output
    private let errorOutput: Output
    private let fileManager: FileManager

    init(
        workspacePacks: WorkspacePackService = WorkspacePackService(),
        output: @escaping Output = WorkspaceManifestCommand.standardOutput,
        errorOutput: @escaping Output = WorkspaceManifestCommand.standardError,
        fileManager: FileManager = .default
    ) {
        reviewer = { rootURL, packURL in
            try workspacePacks.review(rootURL: rootURL, packURL: packURL)
        }
        self.output = output
        self.errorOutput = errorOutput
        self.fileManager = fileManager
    }

    init(
        reviewer: @escaping Reviewer,
        output: @escaping Output,
        errorOutput: @escaping Output,
        fileManager: FileManager = .default
    ) {
        self.reviewer = reviewer
        self.output = output
        self.errorOutput = errorOutput
        self.fileManager = fileManager
    }

    /// Returns `nil` when this is a normal app launch rather than a manifest command.
    func run(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == "validate-manifest" else { return nil }
        guard arguments.count == 3 else {
            errorOutput("Usage: LocalWrap validate-manifest <repository-or-manifest>")
            return 2
        }

        let inputURL = resolvedURL(for: arguments[2])
        let location = validationLocation(for: inputURL)

        do {
            let pack = try reviewer(location.rootURL, location.packURL)
            output("Valid LocalWrap workspace manifest")
            output("Manifest: \(pack.packURL.path)")
            output("Workspace: \(pack.name)")
            output("Projects: \(pack.projects.count)")
            output("Workspaces: \(pack.profiles.count)")
            return 0
        } catch {
            errorOutput("Invalid LocalWrap workspace manifest: \(error.localizedDescription)")
            return 1
        }
    }

    private func resolvedURL(for argument: String) -> URL {
        let path = (argument as NSString).expandingTildeInPath
        let isLikelyDirectory = (path as NSString).pathExtension.lowercased() != "json"
        if (path as NSString).isAbsolutePath {
            return URL(fileURLWithPath: path, isDirectory: isLikelyDirectory).standardizedFileURL
        }
        return URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent(path, isDirectory: isLikelyDirectory)
            .standardizedFileURL
    }

    private func validationLocation(for inputURL: URL) -> (rootURL: URL, packURL: URL?) {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: inputURL.path, isDirectory: &isDirectory)
        if exists, isDirectory.boolValue {
            return (inputURL, nil)
        }

        let parent = inputURL.deletingLastPathComponent()
        if !exists, inputURL.pathExtension.lowercased() != "json", parent.lastPathComponent != ".localwrap" {
            return (inputURL, nil)
        }
        if inputURL.lastPathComponent == "workspace.json", parent.lastPathComponent == ".localwrap" {
            return (parent.deletingLastPathComponent(), inputURL)
        }
        return (parent, inputURL)
    }

    static func standardOutput(_ message: String) {
        write(message, to: .standardOutput)
    }

    static func standardError(_ message: String) {
        write(message, to: .standardError)
    }

    private static func write(_ message: String, to handle: FileHandle) {
        guard let data = "\(message)\n".data(using: .utf8) else { return }
        handle.write(data)
    }
}
