import Darwin
import SwiftUI

@main
enum LocalWrapEntryPoint {
    @MainActor
    static func main() {
        if let status = RuntimeSupervisorCommand().run(arguments: CommandLine.arguments) {
            Darwin.exit(status)
        }
        if let status = WorkspaceManifestCommand().run(arguments: CommandLine.arguments) {
            Darwin.exit(status)
        }
        LocalWrapMacApp.main()
    }
}

struct LocalWrapMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    @MainActor
    init() {
        let model = AppModel.forCurrentLaunch()
        _appModel = State(initialValue: model)
        AppModelRegistry.current = model
    }

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
