import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @Environment(AppModel.self) private var appModel
    let showMainWindow: @MainActor () -> Void
    let showAboutPanel: @MainActor () -> Void

    private var snapshot: MenuCommandCenterSnapshot {
        appModel.menuCommandCenterSnapshot
    }

    var body: some View {
        Button("Show LocalWrap") {
            AppLog.windowing.info("Show main window requested from menu bar")
            showMainWindow()
        }
        .accessibilityIdentifier("menuShowLocalWrap")

        if let primaryAction = snapshot.primaryAction {
            Divider()

            Button {
                appModel.executeMenuPrimaryAction(primaryAction)
                if primaryAction.kind == .reviewFailure {
                    showMainWindow()
                }
            } label: {
                Label(primaryAction.label, systemImage: primaryActionSymbol(primaryAction.kind))
            }
            .accessibilityIdentifier("menuPrimaryAction")
        }

        Divider()

        Text(snapshot.statusLabel)
            .accessibilityLabel("LocalWrap status")
            .accessibilityValue(snapshot.statusLabel)

        if let emptyState = snapshot.emptyState {
            Text(emptyState.title)
                .help(emptyState.detail)
                .accessibilityLabel("\(emptyState.title). \(emptyState.detail)")
        }

        ForEach(snapshot.visibleGroups) { group in
            commandGroup(group)
        }

        workspaceMenu(snapshot.workspaceQuickActions)

        if snapshot.hasOverflow {
            Button("Show All in LocalWrap…") {
                appModel.showMenuOverflow()
                showMainWindow()
            }
            .accessibilityIdentifier("menuShowAll")
        }

        Divider()

        SettingsLink {
            Label("Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",", modifiers: .command)

        Button(appModel.isCheckingForUpdates ? "Checking for Updates…" : "Check for Updates…") {
            showMainWindow()
            Task { await appModel.checkForUpdates() }
        }
        .disabled(appModel.isCheckingForUpdates)

        Button("About LocalWrap") {
            showAboutPanel()
        }

        Divider()

        Button("Quit LocalWrap") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    @ViewBuilder
    private func commandGroup(_ group: MenuCommandCenterGroup) -> some View {
        Menu {
            ForEach(group.items) { item in
                commandItem(item, in: group.kind)
            }

            if group.hasOverflow {
                Divider()
                Button("Show \(group.totalCount - group.visibleCount) More in LocalWrap…") {
                    appModel.showMenuOverflow()
                    showMainWindow()
                }
            }
        } label: {
            Label(groupMenuTitle(group), systemImage: groupSymbol(group.kind))
        }
        .accessibilityIdentifier("menuGroup.\(group.kind.rawValue)")
    }

    @ViewBuilder
    private func commandItem(
        _ item: MenuCommandCenterItem,
        in group: MenuCommandCenterGroupKind
    ) -> some View {
        if let projectID = item.projectID,
           let actions = snapshot.quickActions(for: projectID) {
            Menu {
                if group == .attention || item.kind != .project {
                    Button {
                        appModel.openMenuAttentionItem(item)
                        showMainWindow()
                    } label: {
                        Label("Review in LocalWrap", systemImage: "arrow.up.forward.app")
                    }
                    Divider()
                }

                projectActionButtons(projectID: projectID, actions: actions)
            } label: {
                Label(item.title, systemImage: itemSymbol(item, group: group))
            }
            .help(itemHelp(item))
            .accessibilityLabel(itemAccessibilityLabel(item))
        } else {
            Button {
                appModel.openMenuAttentionItem(item)
                showMainWindow()
            } label: {
                Label(item.title, systemImage: itemSymbol(item, group: group))
            }
            .help(itemHelp(item))
            .accessibilityLabel(itemAccessibilityLabel(item))
        }
    }

    @ViewBuilder
    private func projectActionButtons(
        projectID: String,
        actions: MenuProjectQuickActions
    ) -> some View {
        capabilityButton(
            "Open",
            systemImage: "safari",
            capability: actions.open
        ) {
            appModel.executeMenuProjectAction(projectID: projectID, action: .open)
        }

        capabilityButton(
            "Start",
            systemImage: "play",
            capability: actions.start
        ) {
            appModel.executeMenuProjectAction(projectID: projectID, action: .start)
        }

        capabilityButton(
            "Stop",
            systemImage: "stop",
            capability: actions.stop
        ) {
            appModel.executeMenuProjectAction(projectID: projectID, action: .stop)
        }

        capabilityButton(
            "Restart",
            systemImage: "arrow.clockwise",
            capability: actions.restart
        ) {
            appModel.executeMenuProjectAction(projectID: projectID, action: .restart)
        }

        Divider()

        capabilityButton(
            "Review",
            systemImage: "arrow.up.forward.app",
            capability: actions.review
        ) {
            appModel.executeMenuProjectAction(projectID: projectID, action: .review)
            showMainWindow()
        }
    }

    private func workspaceMenu(_ actions: MenuWorkspaceQuickActions) -> some View {
        Menu {
            capabilityButton(
                "Open All Ready Apps",
                systemImage: "safari",
                capability: actions.openReadyApps
            ) {
                appModel.executeMenuWorkspaceAction(.openReadyApps)
            }

            capabilityButton(
                "Resume Previous Workspace",
                systemImage: "play",
                capability: actions.resume
            ) {
                appModel.executeMenuWorkspaceAction(.resume)
            }

            capabilityButton(
                "Start All Projects",
                systemImage: "play.circle",
                capability: actions.startAll
            ) {
                appModel.executeMenuWorkspaceAction(.startAll)
            }

            capabilityButton(
                "Stop All Running Projects",
                systemImage: "stop.circle",
                capability: actions.stopAll
            ) {
                appModel.executeMenuWorkspaceAction(.stopAll)
            }

            if !actions.savedWorkspaces.isEmpty {
                Divider()

                Menu("Saved Workspaces") {
                    ForEach(actions.savedWorkspaces) { workspace in
                        capabilityButton(
                            workspace.name,
                            systemImage: "rectangle.stack",
                            capability: workspace.start
                        ) {
                            appModel.executeMenuWorkspaceAction(
                                .startSavedProfile(workspace.profileID)
                            )
                        }
                    }

                    if actions.savedWorkspaceTotalCount > actions.savedWorkspaces.count {
                        Divider()
                        Button("Show All Workspaces in LocalWrap…") {
                            appModel.showMenuOverflow()
                            showMainWindow()
                        }
                    }
                }
            }
        } label: {
            Label("Workspace", systemImage: "rectangle.3.group")
        }
        .accessibilityIdentifier("menuWorkspaceActions")
    }

    private func capabilityButton(
        _ title: String,
        systemImage: String,
        capability: MenuActionCapability,
        action: @escaping @MainActor () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .disabled(!capability.isEnabled)
        .help(capability.disabledReason ?? title)
        .accessibilityHint(capability.disabledReason ?? "")
    }

    private func groupMenuTitle(_ group: MenuCommandCenterGroup) -> String {
        group.totalCount == 1 ? group.title : "\(group.title) (\(group.totalCount))"
    }

    private func groupSymbol(_ group: MenuCommandCenterGroupKind) -> String {
        switch group {
        case .attention: "exclamationmark.triangle"
        case .running: "bolt"
        case .ready: "checkmark.circle"
        case .readyToStart: "play.circle"
        }
    }

    private func itemSymbol(
        _ item: MenuCommandCenterItem,
        group: MenuCommandCenterGroupKind
    ) -> String {
        switch item.kind {
        case .attentionIssue, .runtimeFailure, .configurationIssue:
            "exclamationmark.triangle"
        case .project:
            groupSymbol(group)
        }
    }

    private func primaryActionSymbol(_ action: MenuCommandCenterPrimaryActionKind) -> String {
        switch action {
        case .resume: "play"
        case .openReadyApps: "safari"
        case .reviewFailure: "exclamationmark.triangle"
        }
    }

    private func itemHelp(_ item: MenuCommandCenterItem) -> String {
        [item.contextLabel, item.statusLabel, item.detailLabel]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func itemAccessibilityLabel(_ item: MenuCommandCenterItem) -> String {
        [item.title, item.contextLabel, item.statusLabel, item.detailLabel]
            .compactMap { $0 }
            .joined(separator: ". ")
    }
}
