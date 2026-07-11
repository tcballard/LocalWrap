import SwiftUI

@main
struct LocalWrapMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel.forCurrentLaunch()

    var body: some Scene {
        WindowGroup("LocalWrapMac", id: "main") {
            ContentView(registerMainWindow: appDelegate.registerMainWindow)
                .environment(appModel)
                .onAppear {
                    appDelegate.appModel = appModel
                }
        }
        .defaultSize(width: 1_080, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            ApplicationCommands(
                appModel: appModel,
                showMainWindow: appDelegate.showMainWindow
            )
            ProjectMenuCommands()
            WorkspaceMenuCommands()
        }

        MenuBarExtra("LocalWrapMac", image: "MenuBarIcon") {
            MenuBarContentView(
                showMainWindow: appDelegate.showMainWindow,
                showAboutPanel: appDelegate.showAboutPanel
            )
                .environment(appModel)
        }
    }
}
