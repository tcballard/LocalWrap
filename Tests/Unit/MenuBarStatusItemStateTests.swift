import XCTest
@testable import LocalWrapMac

final class MenuBarStatusItemStateTests: XCTestCase {
    func testIdleWhenNoCommandCenterGroupsContainItems() {
        XCTAssertEqual(
            MenuBarStatusItemState.resolve(
                attentionCount: 0,
                readyCount: 0,
                runningCount: 0
            ),
            .idle
        )
    }

    func testRunningWhenAProjectIsActiveButNotReady() {
        XCTAssertEqual(
            MenuBarStatusItemState.resolve(
                attentionCount: 0,
                readyCount: 0,
                runningCount: 1
            ),
            .running
        )
    }

    func testReadyTakesPrecedenceOverRunning() {
        XCTAssertEqual(
            MenuBarStatusItemState.resolve(
                attentionCount: 0,
                readyCount: 1,
                runningCount: 2
            ),
            .ready
        )
    }

    func testAttentionTakesPrecedenceOverReadyAndRunning() {
        XCTAssertEqual(
            MenuBarStatusItemState.resolve(
                attentionCount: 1,
                readyCount: 2,
                runningCount: 3
            ),
            .attention
        )
    }

    func testEveryStateHasAStatusSpecificAccessibilityLabel() {
        let labels = Set([
            MenuBarStatusItemState.idle.accessibilityLabel,
            MenuBarStatusItemState.running.accessibilityLabel,
            MenuBarStatusItemState.ready.accessibilityLabel,
            MenuBarStatusItemState.attention.accessibilityLabel,
        ])

        XCTAssertEqual(labels.count, 4)
        XCTAssertTrue(labels.allSatisfy { $0.hasPrefix("LocalWrap") })
    }
}
