import AppKit
import SwiftUI

struct MainWindowBridge: NSViewRepresentable {
    let register: @MainActor (NSWindow) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(register: register)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.attach(whenAvailableFrom: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(whenAvailableFrom: view)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let register: @MainActor (NSWindow) -> Void
        private weak var window: NSWindow?

        init(register: @escaping @MainActor (NSWindow) -> Void) {
            self.register = register
        }

        func attach(whenAvailableFrom view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                if self.window !== window {
                    self.window = window
                    self.register(window)
                }
                guard let closeButton = window.standardWindowButton(.closeButton) else { return }
                closeButton.target = self
                closeButton.action = #selector(self.hideWindow(_:))
            }
        }

        @objc private func hideWindow(_ sender: Any?) {
            AppLog.windowing.info("Hiding main window while background projects continue")
            window?.orderOut(sender)
            NSApp.hide(sender)
        }
    }
}
