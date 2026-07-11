import SwiftUI

struct WorkspaceCommandActions {
    let canStart: Bool
    let canStop: Bool
    let startReady: () -> Void
    let startAll: () -> Void
    let stopAll: () -> Void
}

private struct WorkspaceCommandActionsKey: FocusedValueKey {
    typealias Value = WorkspaceCommandActions
}

extension FocusedValues {
    var workspaceCommandActions: WorkspaceCommandActions? {
        get { self[WorkspaceCommandActionsKey.self] }
        set { self[WorkspaceCommandActionsKey.self] = newValue }
    }
}

struct WorkspaceMenuCommands: Commands {
    @FocusedValue(\.workspaceCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Start Ready", action: { actions?.startReady() })
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(actions?.canStart != true)
            Button("Start All", action: { actions?.startAll() })
                .disabled(actions?.canStart != true)
            Divider()
            Button("Stop All", action: { actions?.stopAll() })
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(actions?.canStop != true)
        }
    }
}
