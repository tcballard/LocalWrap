import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var appModel
    let showMainWindow: @MainActor () -> Void
    let showAboutPanel: @MainActor () -> Void

    var body: some View {
        Button("Show LocalWrapMac") {
            AppLog.windowing.info("Show main window requested from menu bar")
            showMainWindow()
        }

        Divider()

        Button("Open Ready Projects") {
            appModel.openReadyProjectURLs()
        }
        .disabled(appModel.readyProjects.isEmpty)

        Button("Resume Workspace") {
            Task { await appModel.startWorkspace(target: .lastRunning, readyOnly: false) }
        }
        .disabled(
            appModel.runningProjectCount > 0
                || appModel.workspace.lastRunningProjectIds.isEmpty
                || appModel.isWorkspaceOperating
        )

        Button("Start All Projects") {
            Task { await appModel.startWorkspace(target: .allProjects, readyOnly: false) }
        }
        .disabled(appModel.projects.isEmpty || appModel.isWorkspaceOperating)

        Button("Stop All Running Projects") {
            Task { await appModel.stopAllProjects() }
        }
        .disabled(appModel.runningProjectCount == 0 || appModel.isWorkspaceOperating)

        Divider()

        Text(appModel.menuStatusSummary)
            .accessibilityLabel(appModel.menuStatusSummary)

        Menu("Running Projects") {
            ForEach(appModel.activeProjects) { project in
                Menu(shortTitle(project.name)) {
                    Button("Open") { appModel.openProjectURL(id: project.id) }
                        .disabled(appModel.runtime(for: project.id).status != .ready)
                    Button("Stop") {
                        Task { await appModel.stopProject(id: project.id) }
                    }
                    .disabled(appModel.runtime(for: project.id).status == .stopping)
                }
            }
        }
        .disabled(appModel.activeProjects.isEmpty)

        Divider()

        Button(appModel.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
            showMainWindow()
            Task { await appModel.checkForUpdates() }
        }
        .disabled(appModel.isCheckingForUpdates)

        Button("About LocalWrapMac") {
            showAboutPanel()
        }

        Button("Quit LocalWrapMac") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func shortTitle(_ value: String) -> String {
        value.count <= 30 ? value : String(value.prefix(27)) + "..."
    }
}
