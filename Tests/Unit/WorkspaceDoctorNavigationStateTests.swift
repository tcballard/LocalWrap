import Foundation
import XCTest
@testable import LocalWrapMac

final class WorkspaceDoctorNavigationStateTests: XCTestCase {
    func testRequestCannotCompleteUntilItsExactAnchorIsMounted() {
        let requestID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let expected = WorkspaceDoctorMountedAnchor(
            requestID: requestID,
            anchor: .project("api")
        )
        var state = WorkspaceDoctorNavigationState()

        state.begin(requestID: requestID, anchor: .project("api"))

        XCTAssertFalse(state.complete(expected))
        XCTAssertFalse(state.acknowledgeMounted(WorkspaceDoctorMountedAnchor(
            requestID: requestID,
            anchor: .surface
        )))
        XCTAssertFalse(state.acknowledgeMounted(WorkspaceDoctorMountedAnchor(
            requestID: UUID(),
            anchor: .project("api")
        )))
        XCTAssertEqual(state.pendingRequest?.anchor, .project("api"))

        XCTAssertTrue(state.acknowledgeMounted(expected))
        XCTAssertFalse(state.acknowledgeMounted(expected))
        XCTAssertEqual(state.pendingRequest?.id, requestID)

        XCTAssertTrue(state.complete(expected))
        XCTAssertNil(state.pendingRequest)
        XCTAssertNil(state.mountedAnchor)
    }

    func testNewRequestInvalidatesAnAcknowledgementFromThePreviousRequest() {
        let firstID = UUID()
        let secondID = UUID()
        let first = WorkspaceDoctorMountedAnchor(
            requestID: firstID,
            anchor: .check(.ports)
        )
        let second = WorkspaceDoctorMountedAnchor(
            requestID: secondID,
            anchor: .project("web")
        )
        var state = WorkspaceDoctorNavigationState()

        state.begin(requestID: firstID, anchor: first.anchor)
        XCTAssertTrue(state.acknowledgeMounted(first))

        state.begin(requestID: secondID, anchor: second.anchor)

        XCTAssertFalse(state.complete(first))
        XCTAssertFalse(state.acknowledgeMounted(first))
        XCTAssertTrue(state.acknowledgeMounted(second))
        XCTAssertTrue(state.complete(second))
    }

    func testCancellationClearsBothAwaitingAndMountedPhases() {
        let requestID = UUID()
        let acknowledgement = WorkspaceDoctorMountedAnchor(
            requestID: requestID,
            anchor: .surface
        )
        var state = WorkspaceDoctorNavigationState()

        state.begin(requestID: requestID, anchor: .surface)
        XCTAssertTrue(state.acknowledgeMounted(acknowledgement))

        state.cancel()

        XCTAssertNil(state.pendingRequest)
        XCTAssertNil(state.mountedAnchor)
        XCTAssertFalse(state.complete(acknowledgement))
    }

    func testAnchorIdentifiersRemainStableForScrollAndAccessibilityFocus() {
        XCTAssertEqual(WorkspaceDoctorAnchor.surface.id, "workspaceDoctorSurface")
        XCTAssertEqual(
            WorkspaceDoctorAnchor.check(.dependencies).id,
            "workspaceAttentionCheck-dependencies"
        )
        XCTAssertEqual(
            WorkspaceDoctorAnchor.project("frontend").id,
            "workspaceAttentionProject-frontend"
        )
    }
}
