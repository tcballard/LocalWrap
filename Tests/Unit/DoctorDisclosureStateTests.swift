import XCTest
@testable import LocalWrapMac

final class DoctorDisclosureStateTests: XCTestCase {
    func testStartsCollapsedAndInitialDiagnosisEstablishesCollapsedBaseline() {
        var state = DoctorDisclosureState()

        XCTAssertFalse(state.isExpanded)
        state.observe(observation("check:port"))

        XCTAssertFalse(state.isExpanded)
    }

    func testManualExpansionPersistsAcrossDiagnosisRefreshes() {
        var state = DoctorDisclosureState()
        state.observe(observation())
        state.setExpanded(true)

        state.observe(observation())
        state.observe(observation("check:port"))

        XCTAssertTrue(state.isExpanded)
    }

    func testNewFailureExpandsOnceAndManualCollapseWinsOverRepeatedFailure() {
        var state = DoctorDisclosureState()
        state.observe(observation())

        state.observe(observation("check:port"))
        XCTAssertTrue(state.isExpanded)

        state.setExpanded(false)
        state.observe(observation("check:port"))
        XCTAssertFalse(state.isExpanded)
    }

    func testNewFailureAfterRecoveryExpandsAgain() {
        var state = DoctorDisclosureState()
        state.observe(observation())
        state.observe(observation("check:port"))
        state.setExpanded(false)

        state.observe(observation())
        state.observe(observation("check:command"))

        XCTAssertTrue(state.isExpanded)
    }

    func testAdditionalFailureDuringExistingEpisodeExpandsOnce() {
        var state = DoctorDisclosureState()
        state.observe(observation("check:port"))
        state.setExpanded(false)

        state.observe(observation("check:port", "check:url"))
        XCTAssertTrue(state.isExpanded)

        state.setExpanded(false)
        state.observe(observation("check:port", "check:url"))
        XCTAssertFalse(state.isExpanded)
    }

    func testUnsettledObservationsDoNotEstablishBaseline() {
        var state = DoctorDisclosureState()
        state.observe(DoctorDisclosureObservation(
            isSettled: false,
            failureIDs: ["check:port"]
        ))

        state.observe(observation("check:port"))

        XCTAssertFalse(state.isExpanded)
    }

    private func observation(_ failures: String...) -> DoctorDisclosureObservation {
        DoctorDisclosureObservation(isSettled: true, failureIDs: Set(failures))
    }
}
