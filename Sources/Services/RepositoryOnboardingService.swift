import Foundation

final class RepositoryOnboardingService {
    private let inspector: ProjectInspectionService

    init(inspector: ProjectInspectionService = ProjectInspectionService()) {
        self.inspector = inspector
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
