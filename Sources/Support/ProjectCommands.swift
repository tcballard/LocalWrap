import SwiftUI

struct ProjectCommandActions {
    let canStart: Bool
    let canStop: Bool
    let canRestart: Bool
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void
}

private struct ProjectCommandActionsKey: FocusedValueKey {
    typealias Value = ProjectCommandActions
}

extension FocusedValues {
    var projectCommandActions: ProjectCommandActions? {
        get { self[ProjectCommandActionsKey.self] }
        set { self[ProjectCommandActionsKey.self] = newValue }
    }
}

struct ProjectMenuCommands: Commands {
    @FocusedValue(\.projectCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Project") {
            Button("Start", action: { actions?.start() })
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(actions?.canStart != true)

            Button("Stop", action: { actions?.stop() })
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(actions?.canStop != true)

            Button("Restart", action: { actions?.restart() })
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(actions?.canRestart != true)
        }
    }
}
