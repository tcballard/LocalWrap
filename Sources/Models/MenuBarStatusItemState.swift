import Foundation

enum MenuBarStatusItemState: String, Equatable, Sendable {
    case idle
    case running
    case ready
    case attention

    var accessibilityLabel: String {
        switch self {
        case .idle: "LocalWrap is idle"
        case .running: "LocalWrap has projects starting or running"
        case .ready: "LocalWrap has ready projects"
        case .attention: "LocalWrap needs attention"
        }
    }

    static func resolve(
        attentionCount: Int,
        readyCount: Int,
        runningCount: Int
    ) -> MenuBarStatusItemState {
        if attentionCount > 0 { return .attention }
        if readyCount > 0 { return .ready }
        if runningCount > 0 { return .running }
        return .idle
    }
}

extension MenuCommandCenterSnapshot {
    var statusItemState: MenuBarStatusItemState {
        MenuBarStatusItemState.resolve(
            attentionCount: group(.attention).totalCount,
            readyCount: group(.ready).totalCount,
            runningCount: group(.running).totalCount
        )
    }
}
