import SwiftUI

struct ProjectPreviewView: View {
    let project: Project
    @Binding var state: PreviewState
    @Binding var viewport: PreviewViewportPreset
    let openExternal: (URL) -> Void

    var body: some View {
        VStack(spacing: 0) {
            browserControls
            Divider()
            locationBar
            loadingProgress
            Divider()
            previewCanvas
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("projectPreview")
    }

    private var browserControls: some View {
        HStack(spacing: 10) {
            ControlGroup {
                Button {
                    state.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                        .labelStyle(.iconOnly)
                }
                .disabled(!state.canGoBack)
                .help("Back")
                .accessibilityIdentifier("previewBackButton")

                Button {
                    state.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                        .labelStyle(.iconOnly)
                }
                .disabled(!state.canGoForward)
                .help("Forward")
                .accessibilityIdentifier("previewForwardButton")

                if state.status == .loading {
                    Button {
                        state.stopLoading()
                    } label: {
                        Label("Stop Loading", systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .help("Stop Loading")
                    .accessibilityIdentifier("stopPreviewButton")
                } else {
                    Button {
                        state.reload()
                    } label: {
                        Label("Reload Preview", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .help("Reload Preview")
                    .accessibilityIdentifier("reloadPreviewButton")
                }
            }

            Picker("Viewport Width", selection: $viewport) {
                ForEach(PreviewViewportPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .frame(width: 118)
            .help("Viewport Width")
            .accessibilityLabel("Viewport Width")
            .accessibilityValue(viewport.accessibilityValue)
            .accessibilityIdentifier("previewViewportPicker")

            Spacer(minLength: 8)

            ControlGroup {
                Button(action: openCurrentURL) {
                    Label("Open in Browser", systemImage: "safari")
                        .labelStyle(.iconOnly)
                }
                .help("Open Current Page in Browser")
                .accessibilityIdentifier("openPreviewExternalButton")

                Button {
                    state.close()
                } label: {
                    Label("Close Preview", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .help("Close Preview")
                .accessibilityIdentifier("closePreviewButton")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var locationBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(state.pageTitle ?? "Live Preview")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)

                Text(currentURLString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Current preview URL")
                    .accessibilityValue(currentURLString)
                    .accessibilityIdentifier("previewURL")
            }

            Spacer(minLength: 8)

            Text(viewport.accessibilityValue)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var loadingProgress: some View {
        if state.status == .loading {
            ProgressView(value: max(0.02, state.estimatedProgress), total: 1)
                .progressViewStyle(.linear)
                .accessibilityLabel("Loading preview")
                .accessibilityValue("\(Int(state.estimatedProgress * 100)) percent")
                .accessibilityIdentifier("previewLoadingProgress")
        }
    }

    private var previewCanvas: some View {
        GeometryReader { geometry in
            let availableWidth = max(geometry.size.width, 320)
            let viewportWidth = viewport.width ?? availableWidth

            ScrollView(.horizontal) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)

                    if let initialURL {
                        PreviewWebView(
                            initialURL: initialURL,
                            state: $state,
                            openExternal: openExternal
                        )
                        .id(initialURL)
                    } else {
                        unavailableContent
                    }

                    if state.status == .loading && !state.hasLoadedContent {
                        ProgressView("Loading preview…")
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("previewLoading")
                    } else if state.status == .failed && !state.hasLoadedContent {
                        failureContent
                    }

                    if state.status == .failed && state.hasLoadedContent {
                        failureBanner
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(10)
                    }
                }
                .frame(width: viewportWidth, height: max(geometry.size.height, 320))
                .frame(minWidth: availableWidth)
                .accessibilityLabel(
                    "Live preview of \(project.name), \(viewport.accessibilityValue)"
                )
                .accessibilityIdentifier("previewCanvas")
            }
        }
        .frame(minHeight: 340)
    }

    private var unavailableContent: some View {
        ContentUnavailableView(
            "Preview unavailable",
            systemImage: "exclamationmark.triangle",
            description: Text("The saved project URL is invalid.")
        )
    }

    private var failureContent: some View {
        ContentUnavailableView {
            Label("Preview failed", systemImage: "exclamationmark.triangle")
        } description: {
            Text(state.errorMessage ?? "Unable to load the local URL.")
        } actions: {
            Button("Retry") { state.reload() }
                .accessibilityIdentifier("retryPreviewButton")
            Button("Open in Browser", action: openCurrentURL)
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("previewFailure")
    }

    private var failureBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(state.errorMessage ?? "The preview could not finish loading.")
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Retry") { state.reload() }
                .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("previewFailureBanner")
    }

    private var initialURL: URL? {
        LocalURLValidator().url(from: project.url)
    }

    private var currentURLString: String {
        state.currentURL?.absoluteString ?? project.url
    }

    private func openCurrentURL() {
        let validator = LocalURLValidator()
        if let currentURL = state.currentURL,
           validator.validate(currentURL.absoluteString) {
            openExternal(currentURL)
        } else if let initialURL {
            openExternal(initialURL)
        }
    }
}
