import SwiftUI

struct RepositoryReviewView: View {
    @Environment(AppModel.self) private var appModel
    let proposal: RepositoryProposal
    let didSave: (Project) -> Void

    @State private var draft: ProjectDraft
    @State private var diagnosis = ProjectDiagnosis.notChecked()
    @State private var isSubmitting = false
    @FocusState private var focusedField: ProjectField?

    init(proposal: RepositoryProposal, didSave: @escaping (Project) -> Void) {
        self.proposal = proposal
        self.didSave = didSave
        _draft = State(initialValue: proposal.draft)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Form {
                Section("Project") {
                    reviewField("Name", field: .name) {
                        TextField("Project name", text: nameBinding)
                            .focused($focusedField, equals: .name)
                            .accessibilityIdentifier("repositoryNameField")
                    }
                    reviewField("Folder", field: .cwd) {
                        Text(draft.cwd)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    reviewField("Command", field: .command) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !proposal.scripts.isEmpty {
                                Picker("Detected Script", selection: $draft.command) {
                                    Text("Choose a script…").tag("")
                                    ForEach(proposal.scripts, id: \.name) { script in
                                        Text(script.name).tag(script.command)
                                    }
                                }
                                .labelsHidden()
                                .accessibilityIdentifier("repositoryScriptPicker")
                            }
                            TextField("Run command", text: $draft.command)
                                .focused($focusedField, equals: .command)
                                .accessibilityIdentifier("repositoryCommandField")
                        }
                    }
                    reviewField("Port", field: .port) {
                        TextField("Port", value: $draft.port, format: .number.grouping(.never))
                            .focused($focusedField, equals: .port)
                            .accessibilityIdentifier("repositoryPortField")
                    }
                    reviewField("URL", field: .url) {
                        TextField("Local URL", text: $draft.url)
                            .focused($focusedField, equals: .url)
                            .accessibilityIdentifier("repositoryURLField")
                    }
                }

                if !proposal.warnings.isEmpty {
                    Section("Review Notes") {
                        ForEach(Array(proposal.warnings.enumerated()), id: \.offset) { _, warning in
                            Label(warning.message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("repositoryWarning-\(warning.code)")
                        }
                    }
                }

                Section("After Adding") {
                    HStack(spacing: 24) {
                        Toggle("Start automatically", isOn: $draft.autostart)
                        Toggle("Open in browser when ready", isOn: $draft.openOnReady)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            actions
        }
        .frame(width: 640)
        .frame(minHeight: 560)
        .task(id: validationKey) {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            diagnosis = appModel.diagnose(draft)
        }
        .onAppear {
            if draft.command.isEmpty {
                focusedField = .command
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Review Repository")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier("repositoryReviewSheet")
                Text("Nothing runs until you explicitly choose Add & Start.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var actions: some View {
        HStack {
            Button("Cancel") { appModel.dismissRepositoryProposal() }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)
                .accessibilityIdentifier("cancelRepositoryReviewButton")
            Spacer()
            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Adding repository")
            }
            Button("Add & Start") { save(start: true) }
                .disabled(!canSave || isSubmitting)
                .accessibilityIdentifier("addAndStartRepositoryButton")
            Button("Add Project") { save(start: false) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave || isSubmitting)
                .accessibilityIdentifier("addRepositoryButton")
        }
        .padding(16)
    }

    @ViewBuilder
    private func reviewField<Content: View>(
        _ label: String,
        field: ProjectField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: 3) {
                content()
                Text(proposal.source(for: field, currentDraft: draft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let validation = diagnosis.validation.message(for: field) {
                    Text(validation.message)
                        .font(.caption)
                        .foregroundStyle(validation.severity == .error ? .red : .orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var nameBinding: Binding<String> {
        Binding(
            get: { draft.name ?? "" },
            set: { draft.name = $0 }
        )
    }

    private var canSave: Bool {
        diagnosis.hasConfigurationCheck && diagnosis.validation.isValid
    }

    private var validationKey: RepositoryValidationKey {
        RepositoryValidationKey(draft)
    }

    private func save(start: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true
        let current = draft
        Task {
            if let project = await appModel.saveProject(
                draft: current,
                existingID: nil,
                startAfterSave: start
            ) {
                appModel.dismissRepositoryProposal()
                didSave(project)
            } else {
                isSubmitting = false
            }
        }
    }
}

private struct RepositoryValidationKey: Hashable {
    let name: String
    let cwd: String
    let command: String
    let port: Int
    let url: String
    let autostart: Bool
    let openOnReady: Bool

    init(_ draft: ProjectDraft) {
        name = draft.name ?? ""
        cwd = draft.cwd
        command = draft.command
        port = draft.port
        url = draft.url
        autostart = draft.autostart
        openOnReady = draft.openOnReady
    }
}
