import Foundation

struct DoctorDisclosureObservation: Equatable, Sendable {
    let isSettled: Bool
    let failureIDs: Set<String>
}

struct DoctorDisclosureState: Equatable, Sendable {
    private(set) var isExpanded = false
    private var hasEstablishedBaseline = false
    private var observedFailureIDs = Set<String>()

    mutating func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    mutating func expand() {
        isExpanded = true
    }

    mutating func observe(_ observation: DoctorDisclosureObservation) {
        guard observation.isSettled else { return }

        guard hasEstablishedBaseline else {
            hasEstablishedBaseline = true
            observedFailureIDs = observation.failureIDs
            return
        }

        let newFailures = observation.failureIDs.subtracting(observedFailureIDs)
        observedFailureIDs = observation.failureIDs

        if !newFailures.isEmpty {
            isExpanded = true
        }
    }
}
