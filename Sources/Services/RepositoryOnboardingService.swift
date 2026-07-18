import Foundation

final class RepositoryOnboardingService {
    private let inspector: ProjectInspectionService
    private let workspacePacks: WorkspacePackService

    init(
        inspector: ProjectInspectionService = ProjectInspectionService(),
        workspacePacks: WorkspacePackService = WorkspacePackService()
    ) {
        self.inspector = inspector
        self.workspacePacks = workspacePacks
    }

    func openProposal(
        directory: URL,
        projects: [Project],
        workspace: WorkspaceState
    ) throws -> RepositoryOpenProposal {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        if let packURL = try workspacePacks.discover(in: root) {
            return .workspace(try workspacePacks.inspect(
                rootURL: root,
                packURL: packURL,
                projects: projects,
                workspace: workspace
            ))
        }
        return .project(try propose(directory: root))
    }

    func propose(directory: URL) throws -> RepositoryProposal {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let inspection = try inspector.inspect(directory: root)
        let preferredScripts = inspection.scripts.filter(\.preferred)
        let requiresChoice = preferredScripts.count != 1
        var warnings = inspection.warnings
        if requiresChoice {
            warnings.append(InspectionWarning(
                field: ProjectField.command.rawValue,
                code: "command-choice-required",
                message: inspection.scripts.isEmpty
                    ? "Enter the command you use to run this repository."
                    : "Choose the script that runs the local application."
            ))
        }
        return RepositoryProposal(
            rootURL: root,
            scripts: inspection.scripts,
            warnings: warnings,
            nameSource: inspection.nameSource,
            commandSource: requiresChoice ? .reviewRequired : .packageScript,
            draft: ProjectDraft(
                name: inspection.name,
                cwd: inspection.cwd,
                command: requiresChoice ? "" : preferredScripts[0].command,
                port: inspection.suggestedPort,
                url: inspection.suggestedURL,
                autostart: false,
                openOnReady: false
            )
        )
    }
}
