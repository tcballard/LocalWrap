enum AppSelection: Hashable {
    case welcome
    case workspaces
    case workspace(WorkspaceTarget)
    case projects
    case project(String)
    case newProject

    static let initial: AppSelection = .welcome
}
