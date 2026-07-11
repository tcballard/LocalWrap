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

        CommandGroup(replacing: .newItem) {}
    }
}
