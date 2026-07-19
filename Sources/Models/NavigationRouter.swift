import Foundation
import Observation

struct AttentionNavigationRequest: Identifiable, Equatable {
    let id: UUID
    let target: AttentionNavigationTarget

    init(id: UUID = UUID(), target: AttentionNavigationTarget) {
        self.id = id
        self.target = target
    }
}

@MainActor
@Observable
final class NavigationRouter {
    var selection: AppSelection? {
        didSet {
            guard selection != oldValue else { return }
            try? store?.save(selection)
        }
    }

    private(set) var attentionRequest: AttentionNavigationRequest?

    private let store: SessionStateStore?

    init(
        selection: AppSelection? = AppSelection.initial,
        store: SessionStateStore? = nil,
        projects: [Project] = [],
        workspace: WorkspaceState = .empty
    ) {
        self.store = store
        if let store {
            self.selection = store.restoredSelection(projects: projects, workspace: workspace)
        } else {
            self.selection = selection
        }
        attentionRequest = nil
    }

    func show(_ destination: AppSelection) {
        select(destination)
    }

    func select(_ destination: AppSelection?) {
        attentionRequest = nil
        selection = destination
    }

    func showAttentionTarget(_ target: AttentionNavigationTarget) {
        switch target {
        case .attention:
            selection = .attention
        case .project(let projectID, _):
            selection = .project(projectID)
        case .workspace(let target, _):
            selection = .workspace(target)
        }
        attentionRequest = AttentionNavigationRequest(target: target)
    }

    func consumeAttentionRequest(id: UUID) {
        guard attentionRequest?.id == id else { return }
        attentionRequest = nil
    }

    func revalidate(projects: [Project], workspace: WorkspaceState) {
        selection = SessionStateStore.validated(
            selection ?? .welcome,
            projects: projects,
            workspace: workspace
        )
        guard let request = attentionRequest else { return }
        switch request.target {
        case .attention:
            break
        case .project(let projectID, _):
            if !projects.contains(where: { $0.id == projectID }) {
                attentionRequest = nil
            }
        case .workspace(let target, let projectID):
            let targetSelection = AppSelection.workspace(target)
            let validated = SessionStateStore.validated(
                targetSelection,
                projects: projects,
                workspace: workspace
            )
            if validated != targetSelection
                || projectID.map({ id in !projects.contains(where: { $0.id == id }) }) == true {
                attentionRequest = nil
            }
        }
    }
}
