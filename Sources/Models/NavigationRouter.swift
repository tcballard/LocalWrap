import Observation

@MainActor
@Observable
final class NavigationRouter {
    var selection: AppSelection? {
        didSet {
            guard selection != oldValue else { return }
            try? store?.save(selection)
        }
    }

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
    }

    func show(_ destination: AppSelection) {
        select(destination)
    }

    func select(_ destination: AppSelection?) {
        selection = destination
    }

    func revalidate(projects: [Project], workspace: WorkspaceState) {
        selection = SessionStateStore.validated(
            selection ?? .welcome,
            projects: projects,
            workspace: workspace
        )
    }
}
