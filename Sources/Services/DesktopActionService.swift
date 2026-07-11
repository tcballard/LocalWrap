import AppKit
import Foundation

struct DesktopActionService: @unchecked Sendable {
    var revealFolder: (URL) -> Void
    var copyText: (String) -> Void
    var openURL: (URL) -> Void

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
