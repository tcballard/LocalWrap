import CryptoKit
import Foundation

actor AttentionService {
    static let maximumHistoryEntries = 100
    static let maximumActiveIssues = 512
    static let maximumProjects = 128
    static let maximumWorkspaceDiagnoses = 32
    static let maximumWorkspaceOperations = 32
    static let maximumWorkspaceOperationResults = 128
    static let maximumRuntimeInputs = 256
    static let maximumPreviewInputs = 128
    static let maximumReconciliationItems = 128
    static let maximumDiagnosisMessages = 64
    static let maximumWorkspaceProjects = 128
    static let maximumWorkspaceIssuesPerProject = 64

    private let historyLimit: Int
    private let now: @Sendable () -> String
    private var activeByID: [String: AttentionIssue] = [:]
    private var historyEntries: [AttentionHistoryEntry] = []
    private var historySequence = 0
    private var lastGeneratedAt = ""
    private var latestRevision: UInt64?

    init(
        maximumHistoryEntries: Int = AttentionService.maximumHistoryEntries,
        now: @escaping @Sendable () -> String = {
            ISO8601DateFormatter().string(from: Date())
        }
    ) {
        historyLimit = min(max(1, maximumHistoryEntries), Self.maximumHistoryEntries)
        self.now = now
    }

    @discardableResult
    func update(_ input: AttentionInput, revision: UInt64? = nil) -> AttentionSnapshot {
        if let revision {
            if let latestRevision, revision <= latestRevision {
                return makeSnapshot()
            }
            latestRevision = revision
        }
        let generatedAt = safeTimestamp(now())
        let issues = aggregate(input)
        let nextByID = Dictionary(uniqueKeysWithValues: issues.map { ($0.id, $0) })

        for issue in issues {
            guard let previous = activeByID[issue.id] else {
                appendHistory(.opened, issue: issue, at: generatedAt)
                continue
            }
            if historyRelevantChange(from: previous, to: issue) {
                appendHistory(.updated, issue: issue, at: generatedAt)
            }
        }
        for issue in sortedIssues(Array(activeByID.values)) where nextByID[issue.id] == nil {
            appendHistory(.resolved, issue: issue, at: generatedAt)
        }

        activeByID = nextByID
        lastGeneratedAt = generatedAt
        return makeSnapshot()
    }

    func currentSnapshot() -> AttentionSnapshot {
        makeSnapshot()
    }

    func clearHistory() -> AttentionSnapshot {
        historyEntries = []
        historySequence = 0
        return makeSnapshot()
    }

    private func makeSnapshot() -> AttentionSnapshot {
        AttentionSnapshot(
            generatedAt: lastGeneratedAt,
            issues: sortedIssues(Array(activeByID.values)),
            history: Array(historyEntries.reversed())
        )
    }

    private func aggregate(_ input: AttentionInput) -> [AttentionIssue] {
        var projectNames: [String: String] = [:]
        let orderedProjects = input.projects.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return $0.name < $1.name
        }
        for project in orderedProjects.prefix(Self.maximumProjects)
            where projectNames[project.id] == nil {
            projectNames[project.id] = safeDisplayName(project.name, fallback: "Saved project")
        }
        var candidates: [String: AttentionCandidate] = [:]

        let knownProjectIDs = Set(projectNames.keys)
        let diagnosisIDs = Set(input.projectDiagnoses.keys)
            .union(input.runtimes.keys)
            .intersection(knownProjectIDs)
        for projectID in diagnosisIDs.sorted() {
            let diagnosis = input.projectDiagnoses[projectID]
                ?? input.runtimes[projectID]?.diagnosis
                ?? .notChecked()
            addProjectDiagnosis(
                diagnosis,
                projectID: projectID,
                projectName: projectNames[projectID] ?? "Saved project",
                to: &candidates
            )
        }

        let workspaceDiagnoses = latestWorkspaceDiagnoses(input.workspaceDiagnoses)
        for diagnosis in workspaceDiagnoses {
            addWorkspaceDiagnosis(diagnosis, projectNames: projectNames, to: &candidates)
        }
        addRuntimeIssues(
            input.runtimes,
            reconciliation: input.runtimeReconciliation,
            projectNames: projectNames,
            to: &candidates
        )
        for operation in input.workspaceOperations
            .sorted(by: workspaceOperationSort)
            .prefix(Self.maximumWorkspaceOperations) {
            addWorkspaceOperation(
                operation,
                projectNames: projectNames,
                to: &candidates
            )
        }
        addPreviewIssues(input.previews, projectNames: projectNames, to: &candidates)

        return Array(sortedIssues(candidates.values.map(\.issue))
            .prefix(Self.maximumActiveIssues))
    }

    private func addProjectDiagnosis(
        _ diagnosis: ProjectDiagnosis,
        projectID: String,
        projectName: String,
        to candidates: inout [String: AttentionCandidate]
    ) {
        struct AreaState {
            var severity: AttentionSeverity
            var field: ProjectField?
            var check: DoctorCheckID?
            var actions: Set<DoctorActionID>
        }
        var areas: [String: AreaState] = [:]

        for validation in diagnosis.validation.messages
            .sorted(by: projectValidationSort)
            .prefix(Self.maximumDiagnosisMessages) {
            let area = projectArea(for: validation.field)
            let severity: AttentionSeverity = validation.severity == .error ? .blocker : .warning
            var state = areas[area] ?? AreaState(
                severity: severity,
                field: validation.field,
                check: doctorCheck(for: validation.field),
                actions: []
            )
            state.severity = maxSeverity(state.severity, severity)
            areas[area] = state
        }
        for check in diagnosis.checks where check.status == .warn || check.status == .fail {
            let area = check.id.rawValue
            let severity: AttentionSeverity = check.status == .fail ? .blocker : .warning
            var state = areas[area] ?? AreaState(
                severity: severity,
                field: projectField(for: check.id),
                check: check.id,
                actions: []
            )
            state.severity = maxSeverity(state.severity, severity)
            state.actions.formUnion(check.actions)
            areas[area] = state
        }

        if areas.isEmpty, diagnosis.status == .attention || diagnosis.status == .failed {
            areas["general"] = AreaState(
                severity: diagnosis.status == .failed ? .blocker : .warning,
                field: nil,
                check: nil,
                actions: []
            )
        }

        for area in areas.keys.sorted() {
            guard let state = areas[area] else { continue }
            let action = preferredDoctorAction(state.actions)
            let navigation: AttentionNavigationTarget
            if let check = state.check, action != nil {
                navigation = .project(
                    projectID: projectID,
                    surface: .doctor(check: check, suggestedAction: action)
                )
            } else if let field = state.field {
                navigation = .project(projectID: projectID, surface: .field(field))
            } else if let check = state.check {
                navigation = .project(
                    projectID: projectID,
                    surface: .doctor(check: check, suggestedAction: nil)
                )
            } else {
                navigation = .project(projectID: projectID, surface: .runtime)
            }
            let nextAction = projectNextAction(
                field: state.field,
                check: state.check,
                action: action
            )
            add(
                AttentionCandidate(
                    semanticParts: ["project", projectID, "diagnostic", area],
                    severity: state.severity,
                    sources: [.projectDoctor],
                    scope: .project(id: projectID, name: projectName),
                    title: projectTitle(field: state.field, check: state.check),
                    consequence: projectConsequence(area: area),
                    nextAction: nextAction,
                    navigationTarget: navigation,
                    priority: 30
                ),
                to: &candidates
            )
        }
    }

    private func addWorkspaceDiagnosis(
        _ diagnosis: WorkspaceDiagnosis,
        projectNames: [String: String],
        to candidates: inout [String: AttentionCandidate]
    ) {
        guard diagnosis.status != .empty else { return }
        let workspaceKey = workspaceKey(for: diagnosis.target)
        let workspaceTarget = workspaceTarget(for: diagnosis.target)
        var representedChecks = Set<WorkspaceCheckID>()

        for project in diagnosis.projects
            .sorted(by: { $0.id < $1.id })
            .prefix(Self.maximumWorkspaceProjects) {
            guard projectNames[project.id] != nil else { continue }
            var byCheck: [WorkspaceCheckID: AttentionSeverity] = [:]
            for issue in project.issues
                .sorted(by: workspaceIssueSort)
                .prefix(Self.maximumWorkspaceIssuesPerProject) {
                let severity: AttentionSeverity = issue.severity == .blocker ? .blocker : .warning
                byCheck[issue.check] = maxSeverity(byCheck[issue.check] ?? severity, severity)
            }
            for check in byCheck.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let severity = byCheck[check] else { continue }
                representedChecks.insert(check)
                let mappedArea = projectArea(for: check)
                let semanticParts: [String]
                if let mappedArea {
                    semanticParts = ["project", project.id, "diagnostic", mappedArea]
                } else {
                    semanticParts = ["project", project.id, "workspace", check.rawValue]
                }
                let navigation = workspaceNavigation(
                    check: check,
                    projectID: project.id,
                    workspaceTarget: workspaceTarget
                )
                add(
                    AttentionCandidate(
                        semanticParts: semanticParts,
                        severity: severity,
                        sources: [.workspaceDoctor],
                        scope: .project(
                            id: project.id,
                            name: projectNames[project.id] ?? project.name
                        ),
                        title: workspaceProjectTitle(check),
                        consequence: workspaceConsequence(check),
                        nextAction: AttentionNextAction(
                            label: workspaceNextAction(check),
                            kind: .navigate,
                            requiresConfirmation: false
                        ),
                        navigationTarget: navigation,
                        priority: 20
                    ),
                    to: &candidates
                )
            }
        }

        for check in diagnosis.checks
            .sorted(by: { $0.id.rawValue < $1.id.rawValue })
            where (check.status == .warn || check.status == .fail)
            && !representedChecks.contains(check.id) {
            add(
                AttentionCandidate(
                    semanticParts: ["workspace", workspaceKey, "diagnostic", check.id.rawValue],
                    severity: check.status == .fail ? .blocker : .warning,
                    sources: [.workspaceDoctor],
                    scope: .workspace(id: workspaceKey, name: diagnosis.target.name),
                    title: "\(check.id.label) needs attention in this workspace",
                    consequence: workspaceConsequence(check.id),
                    nextAction: AttentionNextAction(
                        label: workspaceNextAction(check.id),
                        kind: .navigate,
                        requiresConfirmation: false
                    ),
                    navigationTarget: .workspace(target: workspaceTarget, projectID: nil),
                    priority: 20
                ),
                to: &candidates
            )
        }
    }

    private func addRuntimeIssues(
        _ runtimes: [String: RuntimeSnapshot],
        reconciliation: RuntimeReconciliationReport,
        projectNames: [String: String],
        to candidates: inout [String: AttentionCandidate]
    ) {
        for projectID in runtimes.keys.sorted().prefix(Self.maximumRuntimeInputs) {
            guard let runtime = runtimes[projectID] else { continue }
            let projectName = projectNames[projectID]

            switch runtime.ownership {
            case .unverifiable:
                addRuntimeOwnership(
                    projectID: projectID,
                    projectName: projectName,
                    conflicting: false,
                    to: &candidates
                )
            case .conflicting:
                addRuntimeOwnership(
                    projectID: projectID,
                    projectName: projectName,
                    conflicting: true,
                    to: &candidates
                )
            case .none, .reconciling, .verified:
                break
            }

            guard let projectName else { continue }

            switch runtime.terminalReason {
            case .unexpectedExit:
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "process",
                    title: "Project exited unexpectedly",
                    consequence: "The local app is no longer running and dependent projects may be blocked.",
                    next: "Review the final runtime output, then start the project again.",
                    to: &candidates
                )
            case .readinessTimeout:
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "readiness",
                    title: "Project did not become ready",
                    consequence: "The process is active, but LocalWrap cannot confirm that the local app is usable.",
                    next: "Review readiness and the local URL before retrying.",
                    to: &candidates
                )
            case .cleanupFailure:
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "cleanup",
                    title: "Process cleanup failed",
                    consequence: "A process may still be running, so another start could create a duplicate service.",
                    next: "Review runtime ownership before starting or signalling this project.",
                    to: &candidates
                )
            case .launchFailure:
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "process",
                    title: "Project could not start",
                    consequence: "The local app is unavailable and dependent projects may remain blocked.",
                    next: "Review the command and runtime output before trying again.",
                    to: &candidates
                )
            case .doctorBlocked:
                if let causal = preferredDoctorCause(for: projectID, in: candidates) {
                    add(
                        AttentionCandidate(
                            semanticParts: causal,
                            severity: .blocker,
                            sources: [.runtime],
                            scope: .project(id: projectID, name: projectName),
                            title: "Project Doctor blocked start",
                            consequence: "LocalWrap will not launch the project until its configuration is safe.",
                            nextAction: AttentionNextAction(
                                label: "Review Project Doctor and resolve its blocking check.",
                                kind: .navigate,
                                requiresConfirmation: false
                            ),
                            navigationTarget: .project(
                                projectID: projectID,
                                surface: .runtime
                            ),
                            priority: 5
                        ),
                        to: &candidates
                    )
                } else {
                    addRuntimeSymptom(
                        projectID: projectID,
                        projectName: projectName,
                        area: "configuration",
                        title: "Project Doctor blocked start",
                        consequence: "LocalWrap will not launch the project until its configuration is safe.",
                        next: "Review Project Doctor and resolve its blocking check.",
                        to: &candidates
                    )
                }
            case .ownershipConflict, .ownershipUnverifiable, .intentionalStop, .none:
                break
            }

            if runtime.status == .runningUnresponsive,
               runtime.terminalReason == nil,
               !runtime.ownership.requiresOwnershipReview {
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "readiness",
                    title: "Project is not responding",
                    consequence: "The process is active, but the local app is not confirmed ready.",
                    next: "Review readiness and the local URL.",
                    to: &candidates
                )
            } else if runtime.status == .failed, runtime.terminalReason == nil {
                addRuntimeSymptom(
                    projectID: projectID,
                    projectName: projectName,
                    area: "process",
                    title: "Project runtime failed",
                    consequence: "The local app is unavailable until the runtime problem is resolved.",
                    next: "Review runtime output and Project Doctor.",
                    to: &candidates
                )
            }
        }

        if reconciliation.ledgerError != nil {
            add(
                AttentionCandidate(
                    semanticParts: ["application", "runtime-ledger"],
                    severity: .blocker,
                    sources: [.runtime],
                    scope: .application,
                    title: "Runtime records could not be reconciled",
                    consequence: "Autostart and process control remain blocked because ownership cannot be proven.",
                    nextAction: AttentionNextAction(
                        label: "Review runtime reconciliation before starting projects.",
                        kind: .reconcileRuntime,
                        requiresConfirmation: false
                    ),
                    navigationTarget: .attention,
                    priority: 60
                ),
                to: &candidates
            )
        }
        for item in reconciliation.unresolvedItems
            .sorted(by: reconciliationItemSort)
            .prefix(Self.maximumReconciliationItems) {
            addRuntimeOwnership(
                projectID: item.projectID,
                projectName: projectNames[item.projectID],
                conflicting: item.classification == .conflicting,
                to: &candidates
            )
        }
    }

    private func addRuntimeOwnership(
        projectID: String,
        projectName: String?,
        conflicting: Bool,
        to candidates: inout [String: AttentionCandidate]
    ) {
        let scope: AttentionScope = projectName.map {
            .project(id: projectID, name: $0)
        } ?? .application
        let navigationTarget: AttentionNavigationTarget = projectName == nil
            ? .attention
            : .project(projectID: projectID, surface: .runtime)
        let title: String
        if projectName == nil {
            title = "An unlinked runtime needs ownership review"
        } else if conflicting {
            title = "Runtime identity conflicts with the saved record"
        } else {
            title = "Runtime ownership could not be verified"
        }
        add(
            AttentionCandidate(
                semanticParts: ["project", projectID, "runtime", "ownership"],
                severity: .blocker,
                sources: [.runtime],
                scope: scope,
                title: title,
                consequence: "LocalWrap will not signal this process because ownership is uncertain.",
                nextAction: AttentionNextAction(
                    label: "Review runtime reconciliation before controlling this project.",
                    kind: .reconcileRuntime,
                    requiresConfirmation: false
                ),
                navigationTarget: navigationTarget,
                priority: conflicting ? 61 : 60
            ),
            to: &candidates
        )
    }

    private func addRuntimeSymptom(
        projectID: String,
        projectName: String,
        area: String,
        title: String,
        consequence: String,
        next: String,
        to candidates: inout [String: AttentionCandidate]
    ) {
        let semanticArea = area == "cleanup" ? ["runtime", area] : ["diagnostic", area]
        add(
            AttentionCandidate(
                semanticParts: ["project", projectID] + semanticArea,
                severity: .blocker,
                sources: [.runtime],
                scope: .project(id: projectID, name: projectName),
                title: title,
                consequence: consequence,
                nextAction: AttentionNextAction(
                    label: next,
                    kind: .navigate,
                    requiresConfirmation: false
                ),
                navigationTarget: .project(projectID: projectID, surface: .runtime),
                priority: 50
            ),
            to: &candidates
        )
    }

    private func addWorkspaceOperation(
        _ operation: WorkspaceOperationSummary,
        projectNames: [String: String],
        to candidates: inout [String: AttentionCandidate]
    ) {
        let target = operation.target ?? .allProjects
        for result in operation.unresolvedResults
            .sorted(by: workspaceOperationResultSort)
            .prefix(Self.maximumWorkspaceOperationResults) {
            guard let projectName = projectNames[result.projectID] else { continue }
            let area: String
            let severity: AttentionSeverity
            switch (result.status, result.reason) {
            case (.failed, "not-ready"):
                area = "readiness"
                severity = .blocker
            case (.failed, "start-failed"):
                area = "process"
                severity = .blocker
            case (.failed, _), (.blocked, _):
                area = "workspace-operation"
                severity = .blocker
            case (.skipped, "dependency-not-ready"):
                area = "workspace-startup"
                severity = .warning
            case (.started, _), (.skipped, _):
                continue
            }
            let semanticParts: [String]
            if result.reason == "runtime-ownership-unresolved" {
                semanticParts = ["project", result.projectID, "runtime", "ownership"]
            } else if result.reason == "workspace-doctor-blocked",
                      let causal = preferredDoctorCause(
                        for: result.projectID,
                        in: candidates
                      ) {
                semanticParts = causal
            } else if area == "readiness" || area == "process" {
                semanticParts = ["project", result.projectID, "diagnostic", area]
            } else if area == "workspace-startup" {
                semanticParts = ["project", result.projectID, "workspace", "startup"]
            } else {
                semanticParts = ["project", result.projectID, "workspace", "operation"]
            }
            add(
                AttentionCandidate(
                    semanticParts: semanticParts,
                    severity: severity,
                    sources: [.workspaceOperation],
                    scope: .project(
                        id: result.projectID,
                        name: projectName
                    ),
                    title: operationTitle(status: result.status, reason: result.reason),
                    consequence: operationConsequence(status: result.status, reason: result.reason),
                    nextAction: AttentionNextAction(
                        label: "Review the affected project and its workspace dependencies.",
                        kind: .navigate,
                        requiresConfirmation: false
                    ),
                    navigationTarget: .workspace(target: target, projectID: result.projectID),
                    priority: result.reason == "workspace-doctor-blocked" ? 5 : 40
                ),
                to: &candidates
            )
        }
    }

    private func addPreviewIssues(
        _ previews: [String: PreviewState],
        projectNames: [String: String],
        to candidates: inout [String: AttentionCandidate]
    ) {
        for projectID in previews.keys.sorted().prefix(Self.maximumPreviewInputs) {
            guard let projectName = projectNames[projectID],
                  previews[projectID]?.status == .failed else { continue }
            add(
                AttentionCandidate(
                    semanticParts: ["project", projectID, "preview"],
                    severity: .warning,
                    sources: [.preview],
                    scope: .project(
                        id: projectID,
                        name: projectName
                    ),
                    title: "Live Preview could not load",
                    consequence: "The in-app preview is unavailable, but LocalWrap has not changed the running app.",
                    nextAction: AttentionNextAction(
                        label: "Retry Live Preview or open the validated local URL in your browser.",
                        kind: .retryPreview,
                        requiresConfirmation: false
                    ),
                    navigationTarget: .project(projectID: projectID, surface: .preview),
                    priority: 10
                ),
                to: &candidates
            )
        }
    }

    private func add(
        _ rawCandidate: AttentionCandidate,
        to candidates: inout [String: AttentionCandidate]
    ) {
        let candidate = sanitizedCandidate(rawCandidate)
        let id = stableID(parts: candidate.semanticParts)
        guard let existing = candidates[id] else {
            candidates[id] = candidate.withID(id)
            return
        }
        let candidateWins = candidateOutranks(candidate, existing)
        var winner = candidateWins ? candidate : existing
        winner.id = id
        winner.severity = maxSeverity(candidate.severity, existing.severity)
        winner.sources.formUnion(existing.sources)
        winner.sources.formUnion(candidate.sources)
        candidates[id] = winner
    }

    private func appendHistory(
        _ event: AttentionHistoryEvent,
        issue: AttentionIssue,
        at timestamp: String
    ) {
        historySequence &+= 1
        historyEntries.append(AttentionHistoryEntry(
            id: stableID(parts: [
                "history", String(historySequence), event.rawValue, issue.id,
            ]),
            issueID: issue.id,
            event: event,
            recordedAt: timestamp,
            severity: issue.severity,
            sources: issue.sources,
            scopeKind: issue.scope.kind
        ))
        if historyEntries.count > historyLimit {
            historyEntries.removeFirst(historyEntries.count - historyLimit)
        }
    }

    private func historyRelevantChange(
        from previous: AttentionIssue,
        to current: AttentionIssue
    ) -> Bool {
        previous.severity != current.severity
            || previous.sources != current.sources
            || previous.scope.kind != current.scope.kind
            || previous.navigationTarget != current.navigationTarget
            || previous.nextAction != current.nextAction
    }

    private func stableID(parts: [String]) -> String {
        var data = Data("localwrap.attention.v1".utf8)
        for part in parts {
            let bytes = Data(part.utf8)
            var count = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "attention:\(digest)"
    }

    private func candidateOutranks(
        _ candidate: AttentionCandidate,
        _ existing: AttentionCandidate
    ) -> Bool {
        let candidateSeverity = severityRank(candidate.severity)
        let existingSeverity = severityRank(existing.severity)
        if candidateSeverity != existingSeverity {
            return candidateSeverity > existingSeverity
        }
        if candidate.priority != existing.priority {
            return candidate.priority > existing.priority
        }
        return candidate.presentationKey < existing.presentationKey
    }

    private func sanitizedCandidate(_ candidate: AttentionCandidate) -> AttentionCandidate {
        let scope: AttentionScope
        switch candidate.scope {
        case .application:
            scope = .application
        case .workspace(let id, let name):
            scope = .workspace(
                id: id,
                name: safeDisplayName(name, fallback: "Saved workspace")
            )
        case .project(let id, let name):
            scope = .project(
                id: id,
                name: safeDisplayName(name, fallback: "Saved project")
            )
        }
        return AttentionCandidate(
            semanticParts: candidate.semanticParts,
            severity: candidate.severity,
            sources: candidate.sources,
            scope: scope,
            title: boundedText(
                candidate.title,
                maximumBytes: AttentionIssue.maximumTitleBytes,
                fallback: "Needs attention"
            ),
            consequence: boundedText(
                candidate.consequence,
                maximumBytes: AttentionIssue.maximumConsequenceBytes,
                fallback: "This item needs review before normal work can continue."
            ),
            nextAction: AttentionNextAction(
                label: boundedText(
                    candidate.nextAction.label,
                    maximumBytes: AttentionIssue.maximumActionLabelBytes,
                    fallback: "Review this item."
                ),
                kind: candidate.nextAction.kind,
                requiresConfirmation: candidate.nextAction.requiresConfirmation
            ),
            navigationTarget: candidate.navigationTarget,
            priority: candidate.priority
        )
    }

    private func safeDisplayName(_ value: String, fallback: String) -> String {
        let sanitized = boundedText(
            value,
            maximumBytes: AttentionIssue.maximumScopeNameBytes,
            fallback: fallback
        )
        let lowercased = sanitized.lowercased()
        let sensitiveMarkers = [
            "secret", "password", "authorization", "bearer ", "token=", "api_key", "apikey",
        ]
        if sensitiveMarkers.contains(where: lowercased.contains) {
            return fallback
        }
        return sanitized
    }

    private func boundedText(
        _ value: String,
        maximumBytes: Int,
        fallback: String
    ) -> String {
        var output = ""
        output.reserveCapacity(maximumBytes)
        var previousWasWhitespace = true

        for scalar in value.unicodeScalars {
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
            let fragment = isWhitespace ? " " : String(scalar)
            if isWhitespace, previousWasWhitespace { continue }
            guard output.utf8.count + fragment.utf8.count <= maximumBytes else { break }
            output.append(fragment)
            previousWasWhitespace = isWhitespace
        }

        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? fallback : result
    }

    private func safeTimestamp(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789TtZz:+-.")
        guard !value.isEmpty, value.utf8.count <= 64,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return ""
        }
        return value
    }

    private func sortedIssues(_ issues: [AttentionIssue]) -> [AttentionIssue] {
        issues.sorted { lhs, rhs in
            let leftRank = severityRank(lhs.severity)
            let rightRank = severityRank(rhs.severity)
            if leftRank != rightRank { return leftRank > rightRank }
            let leftScope = lhs.scope.displayName.localizedCaseInsensitiveCompare(rhs.scope.displayName)
            if leftScope != .orderedSame { return leftScope == .orderedAscending }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    private func severityRank(_ severity: AttentionSeverity) -> Int {
        severity == .blocker ? 2 : 1
    }

    private func maxSeverity(
        _ lhs: AttentionSeverity,
        _ rhs: AttentionSeverity
    ) -> AttentionSeverity {
        severityRank(lhs) >= severityRank(rhs) ? lhs : rhs
    }

    private func latestWorkspaceDiagnoses(
        _ diagnoses: [WorkspaceDiagnosis]
    ) -> [WorkspaceDiagnosis] {
        var byTarget: [String: WorkspaceDiagnosis] = [:]
        for diagnosis in diagnoses {
            let key = workspaceKey(for: diagnosis.target)
            guard let current = byTarget[key] else {
                byTarget[key] = diagnosis
                continue
            }
            if diagnosis.updatedAt > current.updatedAt
                || (diagnosis.updatedAt == current.updatedAt
                    && workspaceDiagnosisTieKey(diagnosis) < workspaceDiagnosisTieKey(current)) {
                byTarget[key] = diagnosis
            }
        }
        return Array(byTarget.values
            .sorted {
                let left = workspaceKey(for: $0.target)
                let right = workspaceKey(for: $1.target)
                if left != right { return left < right }
                return workspaceDiagnosisTieKey($0) < workspaceDiagnosisTieKey($1)
            }
            .prefix(Self.maximumWorkspaceDiagnoses))
    }

    private func workspaceDiagnosisTieKey(_ diagnosis: WorkspaceDiagnosis) -> String {
        let checks = diagnosis.checks
            .map { "\($0.id.rawValue):\($0.status.rawValue)" }
            .sorted()
            .joined(separator: ",")
        let projects = diagnosis.projects
            .map { project in
                let issues = project.issues
                    .map { "\($0.check.rawValue):\($0.severity.rawValue):\($0.code)" }
                    .sorted()
                    .joined(separator: ",")
                return "\(project.id):\(project.status.rawValue):\(issues)"
            }
            .sorted()
            .joined(separator: ";")
        return "\(diagnosis.status.rawValue)|\(checks)|\(projects)"
    }

    private func workspaceOperationSort(
        _ lhs: WorkspaceOperationSummary,
        _ rhs: WorkspaceOperationSummary
    ) -> Bool {
        workspaceOperationSortKey(lhs) < workspaceOperationSortKey(rhs)
    }

    private func workspaceOperationSortKey(_ operation: WorkspaceOperationSummary) -> String {
        let target: String
        switch operation.target ?? .allProjects {
        case .allProjects: target = "all-projects"
        case .lastRunning: target = "last-running"
        case .profile(let id): target = "profile:\(id)"
        }
        let results = operation.unresolvedResults
            .map { "\($0.projectID):\($0.status.rawValue):\($0.reason ?? "")" }
            .sorted()
            .joined(separator: ";")
        return "\(target)|\(results)"
    }

    private func workspaceOperationResultSort(
        _ lhs: WorkspaceOperationResult,
        _ rhs: WorkspaceOperationResult
    ) -> Bool {
        let left = "\(lhs.projectID)|\(lhs.status.rawValue)|\(lhs.reason ?? "")"
        let right = "\(rhs.projectID)|\(rhs.status.rawValue)|\(rhs.reason ?? "")"
        return left < right
    }

    private func reconciliationItemSort(
        _ lhs: RuntimeReconciliationItem,
        _ rhs: RuntimeReconciliationItem
    ) -> Bool {
        let left = "\(lhs.projectID)|\(lhs.classification.rawValue)|\(lhs.runID)"
        let right = "\(rhs.projectID)|\(rhs.classification.rawValue)|\(rhs.runID)"
        return left < right
    }

    private func projectValidationSort(
        _ lhs: ProjectFieldValidation,
        _ rhs: ProjectFieldValidation
    ) -> Bool {
        let left = "\(lhs.field.rawValue)|\(lhs.severity.rawValue)|\(lhs.code)"
        let right = "\(rhs.field.rawValue)|\(rhs.severity.rawValue)|\(rhs.code)"
        return left < right
    }

    private func workspaceIssueSort(_ lhs: WorkspaceIssue, _ rhs: WorkspaceIssue) -> Bool {
        let left = "\(lhs.check.rawValue)|\(lhs.severity.rawValue)|\(lhs.code)"
        let right = "\(rhs.check.rawValue)|\(rhs.severity.rawValue)|\(rhs.code)"
        return left < right
    }

    private func projectArea(for field: ProjectField) -> String {
        switch field {
        case .name: "name"
        case .cwd: DoctorCheckID.directory.rawValue
        case .command: DoctorCheckID.command.rawValue
        case .dependencies: DoctorCheckID.dependencies.rawValue
        case .port: DoctorCheckID.port.rawValue
        case .url: DoctorCheckID.url.rawValue
        }
    }

    private func doctorCheck(for field: ProjectField) -> DoctorCheckID? {
        switch field {
        case .name: nil
        case .cwd: .directory
        case .command: .command
        case .dependencies: .dependencies
        case .port: .port
        case .url: .url
        }
    }

    private func projectField(for check: DoctorCheckID) -> ProjectField? {
        switch check {
        case .directory: .cwd
        case .command: .command
        case .dependencies: nil
        case .port: .port
        case .url: .url
        case .process, .readiness: nil
        }
    }

    private func projectArea(for check: WorkspaceCheckID) -> String? {
        switch check {
        case .directories: DoctorCheckID.directory.rawValue
        case .commands: DoctorCheckID.command.rawValue
        case .dependencies: DoctorCheckID.dependencies.rawValue
        case .ports: DoctorCheckID.port.rawValue
        case .urls: DoctorCheckID.url.rawValue
        case .projects, .startup, .environment: nil
        }
    }

    private func preferredDoctorAction(_ actions: Set<DoctorActionID>) -> DoctorActionID? {
        let order: [DoctorActionID] = [
            .findFreePort, .syncURL, .revealFolder, .revealCommand,
        ]
        return order.first { actions.contains($0) }
    }

    private func projectNextAction(
        field: ProjectField?,
        check: DoctorCheckID?,
        action: DoctorActionID?
    ) -> AttentionNextAction {
        if let action {
            return AttentionNextAction(
                label: action.mutatesProject
                    ? "Review and confirm \(action.label)."
                    : action.label,
                kind: .doctor(action),
                requiresConfirmation: action.mutatesProject
            )
        }
        if let field {
            return AttentionNextAction(
                label: "Review the \(fieldLabel(field)) field.",
                kind: .navigate,
                requiresConfirmation: false
            )
        }
        return AttentionNextAction(
            label: check.map { "Review the \($0.label) check in Project Doctor." }
                ?? "Review Project Doctor.",
            kind: .navigate,
            requiresConfirmation: false
        )
    }

    private func projectTitle(field: ProjectField?, check: DoctorCheckID?) -> String {
        if let check { return "\(check.label) needs attention" }
        if let field { return "\(fieldLabel(field)) needs attention" }
        return "Project needs attention"
    }

    private func projectConsequence(area: String) -> String {
        switch area {
        case "name": "The saved project cannot be identified clearly until its name is valid."
        case DoctorCheckID.directory.rawValue:
            "LocalWrap cannot reliably access the project files."
        case DoctorCheckID.command.rawValue:
            "The project cannot start safely with the current command."
        case DoctorCheckID.dependencies.rawValue:
            "This project or its dependants may start in the wrong order."
        case DoctorCheckID.port.rawValue:
            "The local service may fail to bind or may conflict with another project."
        case DoctorCheckID.url.rawValue:
            "Readiness, browser opening, and Live Preview may target the wrong address."
        case DoctorCheckID.process.rawValue:
            "The local app is unavailable until the process problem is resolved."
        case DoctorCheckID.readiness.rawValue:
            "LocalWrap cannot confirm that the running app is usable."
        default: "The project cannot complete its normal LocalWrap workflow."
        }
    }

    private func fieldLabel(_ field: ProjectField) -> String {
        switch field {
        case .name: "Name"
        case .cwd: "Folder"
        case .command: "Command"
        case .port: "Port"
        case .url: "URL"
        case .dependencies: "Dependencies"
        }
    }

    private func workspaceKey(for target: ResolvedWorkspaceTarget) -> String {
        switch target.kind {
        case .profile: "profile:\(target.profileID ?? "missing")"
        case .lastRunning: "last-running"
        case .allProjects: "all-projects"
        }
    }

    private func workspaceTarget(for target: ResolvedWorkspaceTarget) -> WorkspaceTarget {
        switch target.kind {
        case .profile:
            target.profileID.map(WorkspaceTarget.profile) ?? .allProjects
        case .lastRunning: .lastRunning
        case .allProjects: .allProjects
        }
    }

    private func workspaceNavigation(
        check: WorkspaceCheckID,
        projectID: String,
        workspaceTarget: WorkspaceTarget
    ) -> AttentionNavigationTarget {
        let field: ProjectField?
        switch check {
        case .directories: field = .cwd
        case .commands: field = .command
        case .dependencies:
            return .project(
                projectID: projectID,
                surface: .doctor(check: .dependencies, suggestedAction: nil)
            )
        case .ports: field = .port
        case .urls: field = .url
        case .projects, .startup, .environment: field = nil
        }
        if let field {
            return .project(projectID: projectID, surface: .field(field))
        }
        return .workspace(target: workspaceTarget, projectID: projectID)
    }

    private func workspaceProjectTitle(_ check: WorkspaceCheckID) -> String {
        switch check {
        case .startup: "Workspace startup is blocked"
        case .environment: "Local environment needs attention"
        default: "\(check.label) needs attention in this workspace"
        }
    }

    private func workspaceConsequence(_ check: WorkspaceCheckID) -> String {
        switch check {
        case .projects: "The workspace does not contain a complete, usable project set."
        case .startup: "The workspace cannot reach a reliable dependency-ordered start."
        case .directories: "One or more project folders cannot be used."
        case .commands: "One or more projects cannot start with their saved commands."
        case .dependencies: "Projects may start out of order or remain blocked."
        case .environment: "A project may start without values its local setup expects."
        case .ports: "Projects may compete for the same local port or fail to bind."
        case .urls: "Readiness and browser actions may target an invalid local address."
        }
    }

    private func workspaceNextAction(_ check: WorkspaceCheckID) -> String {
        switch check {
        case .startup, .dependencies: "Review the workspace dependency plan."
        case .environment: "Review the affected project's local environment setup."
        default: "Review Workspace Doctor's \(check.label) check."
        }
    }

    private func operationTitle(
        status: WorkspaceOperationItemStatus,
        reason: String?
    ) -> String {
        switch (status, reason) {
        case (.failed, "not-ready"): "Project did not become ready"
        case (.failed, "start-failed"): "Project could not start"
        case (.blocked, _): "Workspace start blocked this project"
        case (.skipped, "dependency-not-ready"): "Project is waiting for a dependency"
        default: "Workspace operation failed"
        }
    }

    private func operationConsequence(
        status: WorkspaceOperationItemStatus,
        reason: String?
    ) -> String {
        switch (status, reason) {
        case (.failed, "not-ready"):
            "The process did not become usable, so dependent projects were not safely advanced."
        case (.failed, "start-failed"):
            "The project is unavailable and dependent projects may remain blocked."
        case (.blocked, _):
            "The workspace plan cannot start this project safely."
        case (.skipped, "dependency-not-ready"):
            "This project was not started because a required project is not ready."
        default:
            "The workspace did not complete its requested operation."
        }
    }

    private func preferredDoctorCause(
        for projectID: String,
        in candidates: [String: AttentionCandidate]
    ) -> [String]? {
        candidates.values
            .filter { candidate in
                candidate.semanticParts.starts(with: ["project", projectID])
                    && (candidate.sources.contains(.projectDoctor)
                        || candidate.sources.contains(.workspaceDoctor))
            }
            .sorted { lhs, rhs in
                let leftSeverity = severityRank(lhs.severity)
                let rightSeverity = severityRank(rhs.severity)
                if leftSeverity != rightSeverity { return leftSeverity > rightSeverity }
                if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
                return lhs.semanticParts.joined(separator: "|")
                    < rhs.semanticParts.joined(separator: "|")
            }
            .first?
            .semanticParts
    }
}

private struct AttentionCandidate {
    var id = ""
    let semanticParts: [String]
    var severity: AttentionSeverity
    var sources: Set<AttentionSource>
    let scope: AttentionScope
    let title: String
    let consequence: String
    let nextAction: AttentionNextAction
    let navigationTarget: AttentionNavigationTarget
    let priority: Int

    init(
        semanticParts: [String],
        severity: AttentionSeverity,
        sources: Set<AttentionSource>,
        scope: AttentionScope,
        title: String,
        consequence: String,
        nextAction: AttentionNextAction,
        navigationTarget: AttentionNavigationTarget,
        priority: Int
    ) {
        self.semanticParts = semanticParts
        self.severity = severity
        self.sources = sources
        self.scope = scope
        self.title = title
        self.consequence = consequence
        self.nextAction = nextAction
        self.navigationTarget = navigationTarget
        self.priority = priority
    }

    func withID(_ id: String) -> AttentionCandidate {
        var copy = self
        copy.id = id
        return copy
    }

    var presentationKey: String {
        [
            scope.kind.rawValue,
            scope.displayName,
            title,
            consequence,
            nextAction.label,
            String(reflecting: navigationTarget),
            sources.map(\.rawValue).sorted().joined(separator: ","),
        ].joined(separator: "|")
    }

    var issue: AttentionIssue {
        AttentionIssue(
            id: id,
            severity: severity,
            sources: sources.sorted { $0.rawValue < $1.rawValue },
            scope: scope,
            title: title,
            consequence: consequence,
            nextAction: nextAction,
            navigationTarget: navigationTarget
        )
    }
}
