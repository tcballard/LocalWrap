import SwiftUI

struct ProjectEditorView: View {
    @Environment(AppModel.self) private var appModel
    let project: Project?
    let runtime: RuntimeSnapshot
    let attentionRequest: AttentionNavigationRequest?
    @Binding var selection: AppSelection?
    @Binding private var externalDirty: Bool

    @State private var baseline: ProjectDraft
    @State private var name: String
    @State private var cwd: String
    @State private var command: String
    @State private var port: Int
    @State private var url: String
    @State private var autostart: Bool
    @State private var openOnReady: Bool
    @State private var diagnosis = ProjectDiagnosis.notChecked()
    @State private var doctorExpansionRequestID: UUID?
    @State private var highlightedDoctorCheck: DoctorCheckID?
    @FocusState private var focusedField: ProjectField?
    @AccessibilityFocusState private var accessibilityFocusedField: ProjectField?

    init(
        project: Project?,
        runtime: RuntimeSnapshot = RuntimeSnapshot(),
        attentionRequest: AttentionNavigationRequest? = nil,
        selection: Binding<AppSelection?>,
        isDirty: Binding<Bool> = .constant(false)
    ) {
        self.project = project
        self.runtime = runtime
        self.attentionRequest = attentionRequest
        _selection = selection
        _externalDirty = isDirty
        let initial = project.map(ProjectDraft.init(project:)) ?? ProjectDraft(
            name: "",
            cwd: "",
            command: "npm run dev",
            port: 3_000,
            url: "http://localhost:3000"
        )
        _baseline = State(initialValue: initial)
        _name = State(initialValue: initial.name ?? "")
        _cwd = State(initialValue: initial.cwd)
        _command = State(initialValue: initial.command)
        _port = State(initialValue: initial.port)
        _url = State(initialValue: initial.url)
        _autostart = State(initialValue: initial.autostart)
        _openOnReady = State(initialValue: initial.openOnReady)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if project == nil {
                HStack {
                    Text("Add Project")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("Open Repository…") {
                        appModel.chooseRepository()
                    }
                    .help("Detect configuration from a repository folder")
                    .accessibilityIdentifier("chooseRepositoryFromAddButton")
                }
            } else {
                Text("Configuration")
                    .font(.title2.bold())
            }

            Form {
                fieldRow(.name) {
                    TextField("Name", text: $name)
                        .focused($focusedField, equals: .name)
                        .accessibilityFocused($accessibilityFocusedField, equals: .name)
                        .accessibilityIdentifier("projectNameField")
                }
                fieldRow(.cwd) {
                    TextField("Working Directory", text: $cwd)
                        .focused($focusedField, equals: .cwd)
                        .accessibilityFocused($accessibilityFocusedField, equals: .cwd)
                        .accessibilityIdentifier("projectDirectoryField")
                }
                fieldRow(.command) {
                    TextField("Command", text: $command)
                        .focused($focusedField, equals: .command)
                        .accessibilityFocused($accessibilityFocusedField, equals: .command)
                        .accessibilityIdentifier("projectCommandField")
                }
                fieldRow(.port) {
                    TextField("Port", value: $port, format: .number.grouping(.never))
                        .focused($focusedField, equals: .port)
                        .accessibilityFocused($accessibilityFocusedField, equals: .port)
                        .accessibilityIdentifier("projectPortField")
                }
                fieldRow(.url) {
                    TextField("URL", text: $url)
                        .focused($focusedField, equals: .url)
                        .accessibilityFocused($accessibilityFocusedField, equals: .url)
                        .accessibilityIdentifier("projectURLField")
                }
                Toggle("Start automatically", isOn: $autostart)
                Toggle("Open when ready", isOn: $openOnReady)
            }
            .formStyle(.grouped)

            HStack {
                Button("Save") { save(start: false) }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(
                        !canSave
                            || (project != nil && !appModel.runtimeControlsAvailable)
                    )
                    .accessibilityIdentifier("saveProjectButton")
                Button("Save & Start") { save(start: true) }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !appModel.runtimeControlsAvailable
                            || !canSave
                            || runtime.status.isActive
                            || runtime.ownership.hasUnresolvedRun
                    )
                    .accessibilityIdentifier("saveAndStartButton")
            }

            DoctorPanelView(
                diagnosis: effectiveDiagnosis,
                actionsDisabled: project != nil && (
                    !appModel.runtimeControlsAvailable
                        || isDirty
                        || runtime.status.isActive
                        || runtime.ownership.hasUnresolvedRun
                ),
                expansionRequestID: doctorExpansionRequestID,
                highlightedCheck: highlightedDoctorCheck,
                perform: performDoctorAction,
                buildReport: {
                    appModel.buildDoctorReport(
                        draft: draft,
                        existingID: project?.id,
                        diagnosis: effectiveDiagnosis
                    )
                },
                copyReport: appModel.copyDoctorReport
            )
        }
        .frame(maxWidth: 760, alignment: .leading)
        .task(id: diagnosisKey) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            diagnosis = appModel.diagnose(draft)
        }
        .onChange(of: isDirty, initial: true) { _, dirty in
            externalDirty = dirty
        }
        .task(id: attentionRequest?.id) {
            handleAttentionRequest()
        }
        .navigationTitle(project?.name ?? "Add Project")
    }

    private var draft: ProjectDraft {
        ProjectDraft(
            id: project?.id,
            name: name,
            cwd: cwd,
            command: command,
            port: port,
            url: url,
            autostart: autostart,
            openOnReady: openOnReady,
            isSample: project?.isSample ?? false,
            dependsOn: project?.dependsOn,
            healthCheck: project?.healthCheck,
            source: project?.source
        )
    }

    private var diagnosisKey: DiagnosisKey { DiagnosisKey(draft) }
    private var isDirty: Bool { draft != baseline }
    private var canSave: Bool {
        diagnosis.hasConfigurationCheck && diagnosis.validation.isValid
    }

    private var effectiveDiagnosis: ProjectDiagnosis {
        if project != nil, !isDirty, runtime.diagnosis.hasConfigurationCheck {
            return runtime.diagnosis
        }
        return diagnosis
    }

    @ViewBuilder
    private func fieldRow<Content: View>(
        _ field: ProjectField,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            if let validation = diagnosis.validation.message(for: field) {
                Text(validation.message)
                    .font(.caption)
                    .foregroundStyle(validation.severity == .error ? .red : .orange)
                    .accessibilityIdentifier("\(field.rawValue)ValidationMessage")
            }
        }
        .id("projectField-\(field.rawValue)")
    }

    private func save(start: Bool) {
        let current = draft
        Task {
            if let saved = await appModel.saveProject(
                draft: current,
                existingID: project?.id,
                startAfterSave: start
            ) {
                baseline = ProjectDraft(project: saved)
                selection = .project(saved.id)
            }
        }
    }

    private func performDoctorAction(_ action: DoctorActionID) {
        if action == .revealCommand {
            focusedField = .command
            return
        }
        let current = draft
        Task {
            guard let patched = await appModel.performDoctorAction(
                action,
                draft: current,
                existingID: project?.id,
                isDirty: isDirty,
                diagnosis: effectiveDiagnosis
            ) else { return }
            guard action.mutatesProject else { return }
            apply(patched)
            if project != nil {
                baseline = patched
            }
            diagnosis = appModel.diagnose(patched)
        }
    }

    private func handleAttentionRequest() {
        guard let project,
              let request = attentionRequest,
              case .project(let requestedProjectID, let surface) = request.target,
              requestedProjectID == project.id else { return }

        switch surface {
        case .field(let field):
            if field == .dependencies {
                highlightedDoctorCheck = .dependencies
                doctorExpansionRequestID = request.id
                return
            }
            focusedField = field
            accessibilityFocusedField = field
        case .doctor(let check, let suggestedAction):
            highlightedDoctorCheck = check
            doctorExpansionRequestID = request.id
            if suggestedAction == .revealCommand {
                focusedField = .command
                accessibilityFocusedField = .command
            }
        case .runtime, .preview:
            break
        }
    }

    private func apply(_ draft: ProjectDraft) {
        name = draft.name ?? ""
        cwd = draft.cwd
        command = draft.command
        port = draft.port
        url = draft.url
        autostart = draft.autostart
        openOnReady = draft.openOnReady
    }
}

private struct DiagnosisKey: Hashable {
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
