import AppKit
import UserNotifications

@MainActor
enum AppModelRegistry {
    static var current: AppModel?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var appModel: AppModel?
    private var isTerminating = false
    // LocalWrap intentionally remains alive after its only main window closes.
    // Retain that window for the app lifetime so menu-bar, Dock, notification,
    // and failure-recovery actions can present the same window again.
    private var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.lifecycle.info("Application finished launching")
        UNUserNotificationCenter.current().delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.lifecycle.info("Application will terminate")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        (appModel ?? AppModelRegistry.current)?.refreshAmbientServices()
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
    }

    func showMainWindow() {
        guard let window = mainWindow ?? NSApp.windows.first(where: { $0.canBecomeMain }) else {
            return
        }
        AppLog.windowing.info("Showing and activating main window")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showAboutPanel() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateLater
        }
        guard let appModel = appModel ?? AppModelRegistry.current else {
            return .terminateNow
        }
        isTerminating = true
        AppLog.lifecycle.info("Stopping project process groups before termination")
        Task {
            let report = await appModel.shutdown()
            if report.canTerminate {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            showMainWindow()
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Some local apps could not be stopped safely"
            let names = report.failures.prefix(4).map { failure in
                appModel.project(id: failure.projectID)?.name ?? failure.projectID
            }
            let suffix = report.failures.count > names.count
                ? " and \(report.failures.count - names.count) more"
                : ""
            alert.informativeText = "LocalWrap did not signal processes it could not verify. Review \(names.joined(separator: ", "))\(suffix), or quit and leave those processes running."
            alert.addButton(withTitle: "Keep LocalWrap Open")
            let quitButton = alert.addButton(withTitle: "Quit Without Stopping")
            quitButton.hasDestructiveAction = true
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                isTerminating = false
                appModel.errorMessage = report.failures.first?.message
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let identifier = response.notification.request.identifier
        await MainActor.run { [weak self] in
            guard let self else { return }
            let model = appModel ?? AppModelRegistry.current
            model?.handleNotificationResponse(identifier: identifier)
            showMainWindow()
        }
    }
}
