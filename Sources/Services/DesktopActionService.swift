import AppKit
import Foundation

struct DesktopActionService: @unchecked Sendable {
    var revealFolder: (URL) -> Void
    var copyText: (String) -> Void
    var openURL: (URL) -> Void
    var openNotificationSettings: () -> Void = {
        let notifications = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
        if let notifications, NSWorkspace.shared.open(notifications) {
            return
        }
        NSWorkspace.shared.open(
            URL(
                fileURLWithPath: "/System/Applications/System Settings.app",
                isDirectory: true
            )
        )
    }

    static let live = DesktopActionService(
        revealFolder: { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        copyText: { text in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        },
        openURL: { NSWorkspace.shared.open($0) }
    )
}
