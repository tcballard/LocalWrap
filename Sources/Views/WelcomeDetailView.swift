import AppKit
import SwiftUI

struct WelcomeDetailView: View {
    @Environment(AppModel.self) private var appModel
    let didCreateSample: (Project) -> Void

    init(didCreateSample: @escaping (Project) -> Void = { _ in }) {
        self.didCreateSample = didCreateSample
    }
    var body: some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .accessibilityHidden(true)
                Text("Welcome to LocalWrapMac")
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("welcomeTitle")
        } description: {
            Text("Add or select a project to configure, start, and monitor your local app.")
                .multilineTextAlignment(.center)
        } actions: {
            VStack(spacing: 16) {
                Button("Try Sample Project") {
                    if let project = appModel.trySampleProject() { didCreateSample(project) }
                }
                .buttonStyle(.borderedProminent)
                .help("Copy and configure the bundled sample without starting it")
                .accessibilityIdentifier("trySampleProjectButton")
                HStack(spacing: 16) {
                Label("Secure native execution", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Label("macOS 15+", systemImage: "apple.logo")
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
        .padding(48)
        .accessibilityIdentifier("welcomeDetail")
    }
}
