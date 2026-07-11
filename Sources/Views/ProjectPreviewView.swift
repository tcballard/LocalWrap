import SwiftUI

struct ProjectPreviewView: View {
    let project: Project
    @Binding var state: PreviewState
    let openExternal: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label("Preview", systemImage: "macwindow")
                    .font(.headline)
                Text(state.currentURL?.absoluteString ?? project.url)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("previewURL")
                Spacer()
                Button("Reload") { state.reload() }
                    .accessibilityIdentifier("reloadPreviewButton")
                Button("Open in Browser") { openProjectURL() }
                    .accessibilityIdentifier("openPreviewExternalButton")
                Button("Close") { state.close() }
                    .accessibilityIdentifier("closePreviewButton")
            }

            ZStack {
                if let url = LocalURLValidator().url(from: project.url) {
                    PreviewWebView(
                        initialURL: url,
                        state: $state,
                        openExternal: openExternal
                    )
                } else {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text("The saved project URL is invalid.")
                    )
                }

                if state.status == .loading {
                    ProgressView("Loading preview…")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityIdentifier("previewLoading")
                } else if state.status == .failed {
                    ContentUnavailableView(
                        "Preview failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(state.errorMessage ?? "Unable to load the local URL.")
                    )
                    .background(.regularMaterial)
                    .accessibilityIdentifier("previewFailure")
                }
            }
            .frame(minHeight: 340)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.separator, lineWidth: 1)
            }
            .accessibilityIdentifier("projectPreview")
        }
    }

    private func openProjectURL() {
        guard let url = LocalURLValidator().url(from: project.url) else { return }
        openExternal(url)
    }
}
