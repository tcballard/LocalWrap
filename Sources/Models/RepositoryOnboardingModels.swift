import Foundation

enum RepositoryValueSource: String, Equatable, Sendable {
    case packageJSON
    case directoryName
    case packageScript
    case selectedDirectory
    case freePortSuggestion
    case reviewRequired
    case notDetected

    var label: String {
        switch self {
        case .packageJSON: "Detected from package.json"
        case .directoryName: "Detected from the folder name"
        case .packageScript: "Detected from package.json scripts"
        case .selectedDirectory: "Selected repository folder"
        case .freePortSuggestion: "Suggested available local port"
        case .reviewRequired: "Choose or enter a command"
        case .notDetected: "Not detected from this repository"
        }
    }
}

struct RepositoryProposal: Equatable, Identifiable, Sendable {
    let rootURL: URL
    let scripts: [PackageScript]
    let warnings: [InspectionWarning]
    let nameSource: RepositoryValueSource
    let commandSource: RepositoryValueSource
    var draft: ProjectDraft

    var id: String { rootURL.path }

    func source(for field: ProjectField, currentDraft: ProjectDraft) -> String {
        if field == .command,
           scripts.contains(where: { $0.command == currentDraft.command }) {
            return RepositoryValueSource.packageScript.label
        }
        if value(for: field, in: draft) != value(for: field, in: currentDraft) {
            return "Edited by you"
        }

        switch field {
        case .name: return nameSource.label
        case .cwd: return RepositoryValueSource.selectedDirectory.label
        case .command: return commandSource.label
        case .port, .url: return RepositoryValueSource.freePortSuggestion.label
        case .dependencies: return RepositoryValueSource.notDetected.label
        }
    }

    private func value(for field: ProjectField, in draft: ProjectDraft) -> String {
        switch field {
        case .name: draft.name ?? ""
        case .cwd: draft.cwd
        case .command: draft.command
        case .port: String(draft.port)
        case .url: draft.url
        case .dependencies: (draft.dependsOn ?? []).joined(separator: "\u{1F}")
        }
    }
}
