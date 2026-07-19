import XCTest

@MainActor
final class LocalWrapMacUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testInitialWindowShowsNativeScaffold() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.windows["LocalWrapMac"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workspaces"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Projects"].exists)
        XCTAssertTrue(app.staticTexts["Welcome to LocalWrapMac"].exists)
    }

    func testAddProjectOpensAccessibleEditor() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        XCTAssertTrue(app.buttons["addProjectButton"].waitForExistence(timeout: 5))
        app.buttons["addProjectButton"].click()

        XCTAssertTrue(app.textFields["projectNameField"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["projectDirectoryField"].exists)
        XCTAssertTrue(app.textFields["projectCommandField"].exists)
        XCTAssertTrue(app.buttons["saveAndStartButton"].exists)
        XCTAssertFalse(app.buttons["saveProjectButton"].isEnabled)
        let doctorPanel = app.descendants(matching: .any)["projectDoctorPanel"]
        XCTAssertTrue(doctorPanel.waitForExistence(timeout: 2))
        app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: 500)
        XCTAssertFalse(app.descendants(matching: .any)["doctorSummary"].exists)
        doctorPanel.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["doctorSummary"].waitForExistence(timeout: 2)
        )
        for check in ["directory", "command", "dependencies", "port", "url", "process", "readiness"] {
            XCTAssertTrue(
                app.descendants(matching: .any)["doctorCheck-\(check)"].exists,
                "Missing ordered Doctor check \(check)"
            )
        }
    }

    func testWorkspaceDetailExposesEightChecksAndSafeActionStates() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let allProjects = app.descendants(matching: .any)["allProjectsWorkspaceRow"]
        XCTAssertTrue(allProjects.waitForExistence(timeout: 5))
        allProjects.click()

        let workspaceDoctor = app.descendants(matching: .any)["workspaceDoctorPanel"]
        XCTAssertTrue(workspaceDoctor.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["workspaceDoctorCheck-projects"].exists)
        workspaceDoctor.click()
        for check in [
            "projects", "startup", "directories", "commands",
            "dependencies", "environment", "ports", "urls",
        ] {
            XCTAssertTrue(
                app.descendants(matching: .any)["workspaceDoctorCheck-\(check)"].exists,
                "Missing Workspace Doctor check \(check)"
            )
        }
        XCTAssertTrue(app.buttons["importWorkspaceButton"].isEnabled)
        if app.staticTexts["No saved projects"].exists {
            XCTAssertFalse(app.buttons["startReadyWorkspaceButton"].isEnabled)
            XCTAssertFalse(app.buttons["startAllWorkspaceButton"].isEnabled)
            XCTAssertFalse(app.buttons["exportWorkspaceButton"].isEnabled)
        }
    }

    func testClosingMainWindowKeepsAppAvailableInTheMenuBar() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "--ui-test-preview",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["previewProjectButton"].waitForExistence(timeout: 5))
        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.exists)
        closeButton.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 2))

        app.activate()
        XCTAssertFalse(
            app.windows.firstMatch.waitForExistence(timeout: 1),
            "Ordinary application activation must not reopen a window the user closed."
        )
        XCTAssertTrue(app.menuBars.statusItems.firstMatch.waitForExistence(timeout: 3))
    }

    func testReadyProjectExposesPreviewControlsWithoutNativeBridge() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-test-preview"]
        app.launch()

        let previewButton = app.buttons["previewProjectButton"]
        XCTAssertTrue(previewButton.waitForExistence(timeout: 5))
        XCTAssertTrue(previewButton.isEnabled)
        XCTAssertTrue(app.buttons["openProjectButton"].isEnabled)
        previewButton.click()

        XCTAssertTrue(
            app.descendants(matching: .any)["projectPreview"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["previewBackButton"].exists)
        XCTAssertFalse(app.buttons["previewBackButton"].isEnabled)
        XCTAssertTrue(app.buttons["previewForwardButton"].exists)
        XCTAssertFalse(app.buttons["previewForwardButton"].isEnabled)
        let reloadButton = app.buttons["reloadPreviewButton"]
        let stopButton = app.buttons["stopPreviewButton"]
        let reloadOrStop = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in reloadButton.exists || stopButton.exists },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reloadOrStop], timeout: 2), .completed)
        // SwiftUI does not preserve the picker's accessibility label on every
        // hosted macOS runner. PreviewTests owns the exact viewport preset
        // contract; this test owns the visible preview surface and actions.
        XCTAssertTrue(
            app.descendants(matching: .any)["Current preview URL"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Open in Browser"].waitForExistence(timeout: 3))
        let closePreview = app.buttons["Close Preview"]
        XCTAssertTrue(closePreview.waitForExistence(timeout: 3))
        // The hosted runner's narrow desktop can place this trailing control
        // beyond its clickable bounds. The same Preview toggle is the visible,
        // already-hittable close action in that layout.
        previewButton.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["projectPreview"].waitForNonExistence(timeout: 2)
        )
    }

    func testOpenRepositoryReviewIsEditableAndExplicitlySafe() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "--ui-test-repository-review",
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["repositoryReviewSheet"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["Review Repository"].exists)
        XCTAssertTrue(app.staticTexts["Nothing runs until you explicitly choose Add & Start."].exists)
        XCTAssertTrue(app.textFields["repositoryNameField"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["repositoryScriptPicker"].exists)
        XCTAssertTrue(app.textFields["repositoryCommandField"].exists)
        XCTAssertTrue(app.textFields["repositoryPortField"].exists)
        XCTAssertTrue(app.textFields["repositoryURLField"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["repositoryWarning-review-fixture"].exists)
        XCTAssertTrue(app.buttons["cancelRepositoryReviewButton"].exists)
        XCTAssertTrue(app.buttons["addAndStartRepositoryButton"].exists)
        XCTAssertTrue(app.buttons["addRepositoryButton"].exists)
    }

    func testWorkspaceManifestReviewShowsFullStoppedImportContract() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES", "--ui-test-workspace-manifest-review",
        ]
        app.launch()

        let review = app.descendants(matching: .any)["workspacePackReview"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Review Workspace Manifest"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Manifest version 1"].exists)
        XCTAssertTrue(app.staticTexts["Fixture Stack"].exists)
        XCTAssertTrue(app.staticTexts["Ready with 1 warning"].exists)
        XCTAssertTrue(app.staticTexts["Import saves only the reviewed configuration. Projects remain stopped and no commands run."].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackMetric-projects"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackMetric-workspaces"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackMetric-warnings"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackMetric-blockers"].exists)
        XCTAssertTrue(app.buttons["Reveal Manifest"].exists)
        XCTAssertTrue(app.buttons["Copy Path"].exists)
        XCTAssertTrue(app.buttons["Review Again"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackIssue-warning-fixture-warning-project-web-url"].exists)
        let webProject = app.descendants(matching: .any)["workspacePackProject-web"]
        XCTAssertTrue(webProject.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["workspacePackProjectComparison-web"].exists)
        // Hosted AppKit flattens the sheet's ScrollView and its offscreen
        // GridRows out of XCUI. WorkspacePackServiceTests owns those exact
        // field values; this test verifies the review and safe import surface.
        XCTAssertTrue(app.buttons["Cancel"].exists)
        let importProjects = app.buttons["Import Projects"]
        XCTAssertTrue(importProjects.exists)
        XCTAssertTrue(importProjects.isEnabled)
        XCTAssertTrue(app.staticTexts["Projects remain stopped after import."].exists)
    }

    func testRuntimeConflictIsVisibleAndCannotBeStartedAgain() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES", "--ui-test-runtime-reconciliation",
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Recovered Runtime"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["running-unresponsive"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "The recorded process identity no longer matches. LocalWrap did not signal it."
            ].exists
        )
        XCTAssertFalse(app.buttons["startProjectButton"].isEnabled)

        let attentionRow = app.descendants(matching: .any)["attentionSidebarRow"]
        XCTAssertTrue(attentionRow.waitForExistence(timeout: 3))
        attentionRow.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["attentionDetail"].waitForExistence(timeout: 3)
        )
        let ownershipIssue = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'attentionIssue-' AND label CONTAINS %@",
            "Runtime identity conflicts with the saved record"
        )).firstMatch
        XCTAssertTrue(ownershipIssue.waitForExistence(timeout: 3))
        ownershipIssue.click()
        XCTAssertTrue(app.descendants(matching: .any)["projectStatus"].waitForExistence(timeout: 3))
    }

    func testStandardAboutPanelUsesNativePresentation() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let applicationMenu = app.menuBars.menuBarItems["LocalWrapMac"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 5))
        applicationMenu.click()
        let aboutItem = applicationMenu.menuItems["About LocalWrapMac"]
        XCTAssertTrue(aboutItem.waitForExistence(timeout: 2))
        aboutItem.click()

        XCTAssertTrue(app.staticTexts["LocalWrapMac"].waitForExistence(timeout: 3))
        // AppKit's standard About panel does not consistently expose its
        // version label to XCUI. AppMetadataTests verifies the exact bundle
        // version, build, icon, and credits; this test verifies presentation.
    }

    func testMenuBarActionsReflectReadyBackgroundProjectAndShowHiddenWindow() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "--ui-test-preview"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 2))

        let statusItem = app.menuBars.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 3))
        statusItem.click()

        XCTAssertTrue(statusItem.menuItems["Open Ready Apps"].waitForExistence(timeout: 3))
        XCTAssertTrue(statusItem.menuItems["Open Ready Apps"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["Ready"].exists)
        XCTAssertTrue(statusItem.menuItems["Workspace"].exists)
        XCTAssertTrue(statusItem.menuItems["Settings…"].exists)
        XCTAssertTrue(statusItem.menuItems["Check for Updates…"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["About LocalWrap"].exists)

        let showLocalWrap = app.menuItems["Show LocalWrap"]
        XCTAssertTrue(showLocalWrap.exists)
        showLocalWrap
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

}
