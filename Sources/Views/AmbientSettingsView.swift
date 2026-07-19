import SwiftUI

struct AmbientSettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section("App launch") {
                Toggle("Launch LocalWrap at login", isOn: launchAtLoginBinding)
                    .disabled(
                        appModel.launchAtLoginService.isChanging
                            || appModel.launchAtLoginService.status == .notFound
                    )
                    .help(launchAtLoginHelp)
                    .accessibilityHint(launchAtLoginHelp)
                    .accessibilityIdentifier("launchAtLoginToggle")

                settingStatus(
                    title: "System status",
                    value: appModel.launchAtLoginService.status.label,
                    symbol: launchAtLoginStatusSymbol
                )

                if appModel.launchAtLoginService.status == .requiresApproval {
                    Button("Open Login Items Settings…") {
                        appModel.openLaunchAtLoginSettings()
                    }
                }

                if let error = appModel.launchAtLoginService.lastError {
                    settingsError(error.localizedDescription)
                }

                Text("Launch at Login starts LocalWrap itself. It never starts a project; each project's Autostart setting controls that separately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Runtime notifications") {
                Toggle("Ready, failed, and unexpected-exit alerts", isOn: notificationsBinding)
                    .disabled(appModel.runtimeNotificationService.preferenceStatus.isBusy)
                    .help("Notification text contains only the project name and coarse runtime state.")
                    .accessibilityHint("Notifications are off until you enable them and macOS grants permission.")
                    .accessibilityIdentifier("runtimeNotificationsToggle")

                settingStatus(
                    title: "Permission",
                    value: appModel.runtimeNotificationService.preferenceStatus.label,
                    symbol: notificationStatusSymbol
                )

                if appModel.runtimeNotificationService.preferenceStatus == .requiresSystemApproval {
                    Button("Open Notification Settings…") {
                        appModel.openRuntimeNotificationSettings()
                    }
                }

                if let error = appModel.runtimeNotificationService.lastError {
                    settingsError(error.localizedDescription)
                }

                Text("Notifications are off by default, omit runtime output, and do not repeat an unchanged failure.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Project behavior") {
                LabeledContent("Autostart") {
                    Text("Set per project")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Ready destination") {
                    Text("Set per project")
                        .foregroundStyle(.secondary)
                }
                Text("Open a project in LocalWrap to choose whether it starts automatically and whether its local page opens after readiness is confirmed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Window and background behavior") {
                LabeledContent("Close main window") {
                    Text("Keep LocalWrap running")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Quit LocalWrap") {
                    Text("Stop verified-owned projects")
                        .foregroundStyle(.secondary)
                }
                Text("Closing leaves the menu-bar command center available. LocalWrap never signals a process whose ownership it cannot verify.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 480)
        .task { appModel.refreshAmbientServices() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { appModel.launchAtLoginService.isRequested },
            set: { appModel.setLaunchAtLoginEnabled($0) }
        )
    }

    private var notificationsBinding: Binding<Bool> {
        Binding(
            get: { appModel.runtimeNotificationService.isOptedIn },
            set: { enabled in
                Task { await appModel.setRuntimeNotificationsEnabled(enabled) }
            }
        )
    }

    private var launchAtLoginHelp: String {
        switch appModel.launchAtLoginService.status {
        case .notFound:
            "Launch at Login is unavailable for this copy of LocalWrap."
        case .requiresApproval:
            "Approve LocalWrap in System Settings to finish enabling Launch at Login."
        case .notRegistered, .enabled:
            "Open LocalWrap automatically after you sign in to this Mac."
        }
    }

    private var launchAtLoginStatusSymbol: String {
        switch appModel.launchAtLoginService.status {
        case .enabled: "checkmark.circle"
        case .requiresApproval: "exclamationmark.circle"
        case .notFound: "xmark.circle"
        case .notRegistered: "circle"
        }
    }

    private var notificationStatusSymbol: String {
        switch appModel.runtimeNotificationService.preferenceStatus {
        case .enabled: "checkmark.circle"
        case .requiresSystemApproval: "exclamationmark.circle"
        case .checkingAuthorization, .requestingAuthorization: "ellipsis.circle"
        case .disabled: "circle"
        }
    }

    private func settingStatus(
        title: String,
        value: String,
        symbol: String
    ) -> some View {
        LabeledContent(title) {
            Label(value, systemImage: symbol)
                .foregroundStyle(.secondary)
        }
    }

    private func settingsError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ambientSettingsError")
    }
}
