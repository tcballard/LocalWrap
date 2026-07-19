import Foundation
import XCTest
@testable import LocalWrapMac

@MainActor
final class AttentionIntegrationTests: XCTestCase {
    func testAppModelPublishesRuntimeIssueAndDeepLinksToProjectSurface() async throws {
        let project = makeProject()
        let model = AppModel(
            projects: [project],
            initialRuntimes: [
                project.id: RuntimeSnapshot(
                    status: .failed,
                    terminalReason: .unexpectedExit(code: 2)
                ),
            ],
            attentionService: AttentionService(now: { "2026-07-19T00:00:00Z" })
        )

        try await waitForAttention(model)
        let issue = try XCTUnwrap(model.attentionSnapshot.issues.first {
            $0.sources.contains(.runtime)
        })

        XCTAssertEqual(issue.title, "Project exited unexpectedly")
        model.openAttentionIssue(issue)
        XCTAssertEqual(model.navigationRouter.selection, .project(project.id))
        XCTAssertEqual(model.navigationRouter.attentionRequest?.target, issue.navigationTarget)
    }

    func testPreviewFailureAppearsThenResolvesWhenPreviewRetries() async throws {
        let project = makeProject()
        let model = AppModel(
            projects: [project],
            attentionService: AttentionService(now: { "2026-07-19T00:00:00Z" })
        )
        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: project.url)))
        preview.markFailed("Failure containing SECRET_VALUE")

        model.reportPreviewState(projectID: project.id, state: preview)
        try await waitForAttention(model, source: .preview)
        let issue = try XCTUnwrap(model.attentionSnapshot.issues.first {
            $0.sources.contains(.preview)
        })
        XCTAssertFalse(String(reflecting: issue).contains("SECRET_VALUE"))

        preview.markLoading()
        model.reportPreviewState(projectID: project.id, state: preview)
        for _ in 0..<100 {
            if !model.attentionSnapshot.issues.contains(where: { $0.sources.contains(.preview) }) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.attentionSnapshot.issues.contains { $0.sources.contains(.preview) })
        XCTAssertTrue(model.attentionSnapshot.history.contains { $0.event == .resolved })
    }

    func testPreviewNoiseRefreshesAttentionOnlyWhenFailureEvidenceChanges() async throws {
        let project = makeProject()
        let now = AttentionNowRecorder()
        let model = AppModel(
            projects: [project],
            attentionService: AttentionService(now: now.next)
        )
        try await waitForUpdateCount(now, atLeast: 1)
        let initialUpdateCount = now.count

        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: project.url)))
        preview.estimatedProgress = 0.35
        preview.pageTitle = "Loading"
        model.reportPreviewState(projectID: project.id, state: preview)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(now.count, initialUpdateCount)

        preview.markFailed("Connection refused")
        model.reportPreviewState(projectID: project.id, state: preview)
        try await waitForUpdateCount(now, atLeast: initialUpdateCount + 1)
        let firstFailureUpdateCount = now.count

        preview.estimatedProgress = 0.82
        preview.pageTitle = "Unrelated WebKit title update"
        preview.canGoBack = true
        preview.reload()
        model.reportPreviewState(projectID: project.id, state: preview)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(now.count, firstFailureUpdateCount)

        preview.markFailed("The connection closed during the response")
        model.reportPreviewState(projectID: project.id, state: preview)
        try await waitForUpdateCount(now, atLeast: firstFailureUpdateCount + 1)
        let changedFailureUpdateCount = now.count

        preview.markLoading()
        model.reportPreviewState(projectID: project.id, state: preview)
        try await waitForUpdateCount(now, atLeast: changedFailureUpdateCount + 1)
        try await waitForPreviewResolution(model)
        XCTAssertFalse(model.attentionSnapshot.issues.contains { $0.sources.contains(.preview) })
    }

    func testRapidAttentionRefreshesCancelAndSerializeDetachedDiagnosisBatches() async throws {
        let project = makeProject()
        let now = AttentionNowRecorder()
        let fileSystem = SlowAttentionDoctorFileSystem(delay: 0.08)
        let doctor = ProjectDoctorService(
            fileSystem: fileSystem,
            portSuggester: PortSuggestionService(isAvailable: { _ in true })
        )
        let model = AppModel(
            projects: [project],
            doctorService: doctor,
            workspaceDoctor: WorkspaceDoctorService(
                projectDoctor: doctor,
                fileSystem: fileSystem,
                portSuggester: PortSuggestionService(isAvailable: { _ in true })
            ),
            attentionService: AttentionService(now: now.next)
        )
        try await waitForUpdateCount(now, atLeast: 1, attempts: 600)
        let initialUpdateCount = now.count
        fileSystem.resetMeasurements()

        var preview = PreviewState()
        preview.open(try XCTUnwrap(URL(string: project.url)))
        preview.markFailed("First failure")
        model.reportPreviewState(projectID: project.id, state: preview)
        try await waitForDiagnosisToStart(fileSystem)

        preview.markFailed("Second failure")
        model.reportPreviewState(projectID: project.id, state: preview)
        preview.markFailed("Final failure")
        model.reportPreviewState(projectID: project.id, state: preview)

        try await waitForAttention(model, source: .preview, attempts: 600)

        XCTAssertEqual(fileSystem.maximumConcurrentCalls, 1)
        XCTAssertEqual(now.count, initialUpdateCount + 1)
    }

    private func waitForAttention(
        _ model: AppModel,
        source: AttentionSource = .runtime,
        attempts: Int = 100
    ) async throws {
        for _ in 0..<attempts {
            if model.attentionSnapshot.issues.contains(where: { $0.sources.contains(source) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for \(source.rawValue) attention issue")
    }

    private func waitForUpdateCount(
        _ recorder: AttentionNowRecorder,
        atLeast expected: Int,
        attempts: Int = 200
    ) async throws {
        for _ in 0..<attempts {
            if recorder.count >= expected { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for attention update \(expected); saw \(recorder.count)")
    }

    private func waitForDiagnosisToStart(
        _ fileSystem: SlowAttentionDoctorFileSystem
    ) async throws {
        for _ in 0..<200 {
            if fileSystem.activeCalls > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for detached attention diagnosis")
    }

    private func waitForPreviewResolution(_ model: AppModel) async throws {
        for _ in 0..<200 {
            if !model.attentionSnapshot.issues.contains(where: { $0.sources.contains(.preview) }) {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for preview attention resolution")
    }

    private func makeProject() -> Project {
        Project(
            id: "attention-project",
            name: "Web",
            cwd: "/tmp",
            command: "npm start",
            port: 4_321,
            url: "http://localhost:4321",
            createdAt: "2026-07-19T00:00:00Z",
            updatedAt: "2026-07-19T00:00:00Z"
        )
    }
}

private final class AttentionNowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func next() -> String {
        lock.withLock {
            storedCount += 1
            return "2026-07-19T00:00:00.\(storedCount)Z"
        }
    }
}

private final class SlowAttentionDoctorFileSystem: @unchecked Sendable, DoctorFileSystem {
    private let lock = NSLock()
    private let delay: TimeInterval
    private var storedActiveCalls = 0
    private var storedMaximumConcurrentCalls = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var activeCalls: Int { lock.withLock { storedActiveCalls } }
    var maximumConcurrentCalls: Int { lock.withLock { storedMaximumConcurrentCalls } }

    func resetMeasurements() {
        lock.withLock {
            precondition(storedActiveCalls == 0)
            storedMaximumConcurrentCalls = 0
        }
    }

    func fileExists(at url: URL) -> Bool {
        measure { false }
    }

    func isDirectory(at url: URL) -> Bool {
        measure { true }
    }

    func readData(at url: URL) throws -> Data {
        measure { Data() }
    }

    private func measure<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.withLock {
            storedActiveCalls += 1
            storedMaximumConcurrentCalls = max(
                storedMaximumConcurrentCalls,
                storedActiveCalls
            )
        }
        defer { lock.withLock { storedActiveCalls -= 1 } }
        Thread.sleep(forTimeInterval: delay)
        return try body()
    }
}
