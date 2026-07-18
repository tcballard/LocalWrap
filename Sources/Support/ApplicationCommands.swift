import SwiftUI

struct ApplicationCommands: Commands {
    let appModel: AppModel
    let showMainWindow: @MainActor () -> Void

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(appModel.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
                showMainWindow()
                Task { await appModel.checkForUpdates() }
            }
            .disabled(appModel.isCheckingForUpdates)
        }

        CommandGroup(replacing: .newItem) {
            Button("Open Repository…") {
                showMainWindow()
                appModel.chooseRepository()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!canOpenRepository)
        }
    }

    private var canOpenRepository: Bool {
        if case .ready = appModel.persistenceStatus { return true }
        return false
    }
}
