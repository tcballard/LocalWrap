import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?
    private var isTerminating = false
    private weak var mainWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.lifecycle.info("Application finished launching")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.lifecycle.info("Application will terminate")
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating, let mainWindow, !mainWindow.isVisible else { return }
        AppLog.windowing.info("Restoring hidden main window after application activation")
        mainWindow.makeKeyAndOrderFront(nil)
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

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateLater
        }
        guard let appModel else {
            return .terminateNow
        }
        isTerminating = true
        AppLog.lifecycle.info("Stopping project process groups before termination")
        Task {
            await appModel.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
