import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: AppSelection? = AppSelection.initial
    let registerMainWindow: @MainActor (NSWindow) -> Void

    init(registerMainWindow: @escaping @MainActor (NSWindow) -> Void) {
        self.registerMainWindow = registerMainWindow
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-preview") {
            _selection = State(initialValue: .project("ui-preview"))
        }
        #endif
    }

    var body: some View {
        Group {
            if case .recoveryRequired(let message, let backupAvailable) = appModel.persistenceStatus {
                RecoveryView(message: message, backupAvailable: backupAvailable)
            } else {
                mainContent
            }
        }
        .frame(minWidth: 860, minHeight: 620)
        .background(MainWindowBridge(register: registerMainWindow))
    }

    private var mainContent: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            detail
        }
        .navigationTitle("LocalWrapMac")
        .accessibilityIdentifier("mainContent")
        .background(MainWindowBridge(register: registerMainWindow))
        .onAppear {
            AppLog.windowing.info("Main window content appeared")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    selection = .newProject
                } label: {
                    Label("Add Project", systemImage: "plus")
                }
                .help("Add Project")
                .accessibilityIdentifier("addProjectButton")
            }
        }
        .alert(
            "LocalWrap",
            isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )
        ) {
            Button("OK") { appModel.errorMessage = nil }
        } message: {
            Text(appModel.errorMessage ?? "Unknown error")
        }
        .alert(item: releaseNoticeBinding) { notice in
            if let releaseURL = notice.releaseURL {
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    primaryButton: .default(Text("View Release")) {
                        appModel.openReleasePage(releaseURL)
                    },
                    secondaryButton: .cancel(Text("Later"))
                )
            } else {
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .welcome {
        case .welcome:
            WelcomeDetailView { project in selection = .project(project.id) }
        case .workspaces:
            WorkspaceDetailView(selection: $selection, initialTarget: nil)
        case .workspace(let target):
            WorkspaceDetailView(selection: $selection, initialTarget: target)
        case .projects:
            ProjectsOverviewView(selection: $selection)
        case .project(let id):
            ProjectCockpitView(projectID: id, selection: $selection)
                .id(id)
        case .newProject:
            ScrollView {
                ProjectEditorView(project: nil, selection: $selection)
                    .padding(32)
            }
        }
    }

    private var releaseNoticeBinding: Binding<ReleaseNotice?> {
        Binding(
            get: { appModel.releaseNotice },
            set: { appModel.releaseNotice = $0 }
        )
    }
}

private struct RecoveryView: View {
    @Environment(AppModel.self) private var appModel
    let message: String
    let backupAvailable: Bool
    @State private var confirmsStartFresh = false

    var body: some View {
        ContentUnavailableView {
            Label("Project Data Needs Recovery", systemImage: "exclamationmark.triangle")
        } description: {
            Text("LocalWrap preserved the unreadable store. \(message)")
        } actions: {
            HStack {
                if backupAvailable {
                    Button("Restore Backup") { _ = appModel.recover(.restoreBackup) }
                        .accessibilityIdentifier("restoreBackupButton")
                }
                Button("Start Fresh", role: .destructive) { confirmsStartFresh = true }
                    .accessibilityIdentifier("startFreshButton")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .accessibilityIdentifier("recoveryView")
        .confirmationDialog(
            "Start with an empty project list?",
            isPresented: $confirmsStartFresh,
            titleVisibility: .visible
        ) {
            Button("Start Fresh", role: .destructive) { _ = appModel.recover(.startFresh) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The corrupt file remains preserved for diagnosis, but its projects will not be loaded.")
        }
    }
}

#Preview {
    ContentView(registerMainWindow: { _ in })
        .environment(AppModel())
}
