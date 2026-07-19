import Foundation

enum WorkspaceDoctorAnchor: Equatable, Sendable {
    case surface
    case check(WorkspaceCheckID)
    case project(String)

    var id: String {
        switch self {
        case .surface:
            "workspaceDoctorSurface"
        case .check(let check):
            "workspaceAttentionCheck-\(check.rawValue)"
        case .project(let projectID):
            "workspaceAttentionProject-\(projectID)"
        }
    }
}

struct WorkspaceDoctorNavigationRequest: Identifiable, Equatable, Sendable {
    let id: UUID
    let anchor: WorkspaceDoctorAnchor
}

struct WorkspaceDoctorMountedAnchor: Equatable, Sendable {
    let requestID: UUID
    let anchor: WorkspaceDoctorAnchor
}

/// Coordinates attention navigation without assuming how many render passes a
/// disclosure needs. A request can complete only after its exact destination
/// reports that it is mounted in the SwiftUI hierarchy.
struct WorkspaceDoctorNavigationState: Equatable, Sendable {
    private(set) var pendingRequest: WorkspaceDoctorNavigationRequest?
    private(set) var mountedAnchor: WorkspaceDoctorMountedAnchor?

    mutating func begin(requestID: UUID, anchor: WorkspaceDoctorAnchor) {
        pendingRequest = WorkspaceDoctorNavigationRequest(id: requestID, anchor: anchor)
        mountedAnchor = nil
    }

    mutating func acknowledgeMounted(_ acknowledgement: WorkspaceDoctorMountedAnchor) -> Bool {
        guard let pendingRequest,
              acknowledgement.requestID == pendingRequest.id,
              acknowledgement.anchor == pendingRequest.anchor,
              mountedAnchor == nil else {
            return false
        }

        mountedAnchor = acknowledgement
        return true
    }

    mutating func complete(_ acknowledgement: WorkspaceDoctorMountedAnchor) -> Bool {
        guard mountedAnchor == acknowledgement else { return false }
        pendingRequest = nil
        mountedAnchor = nil
        return true
    }

    mutating func cancel() {
        pendingRequest = nil
        mountedAnchor = nil
    }
}
