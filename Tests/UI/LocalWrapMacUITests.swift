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

        XCTAssertTrue(
            app.descendants(matching: .any)["workspaceDoctorPanel"].waitForExistence(timeout: 3)
        )
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

    func testClosingMainWindowHidesAndApplicationActivationReopensIt() {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let closeButton = window.buttons[XCUIIdentifierCloseWindow]
        XCTAssertTrue(closeButton.exists)
        closeButton.click()
        XCTAssertTrue(window.waitForNonExistence(timeout: 2))

        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Welcome to LocalWrapMac"].exists)
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
        XCTAssertTrue(app.descendants(matching: .any)["projectLiveSplitView"].exists)
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
        XCTAssertTrue(app.descendants(matching: .any)["previewViewportPicker"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["previewURL"].exists)
        XCTAssertTrue(app.buttons["openPreviewExternalButton"].exists)
        let closePreview = app.buttons["closePreviewButton"]
        XCTAssertTrue(closePreview.exists)
        closePreview.click()
        XCTAssertTrue(
            app.descendants(matching: .any)["projectPreview"].waitForNonExistence(timeout: 2)
        )
    }

    func testStandardAboutPanelUsesNativeBundleMetadata() {
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
        XCTAssertTrue(app.staticTexts["Version 3.3.0 (1)"].exists)
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

        XCTAssertTrue(statusItem.menuItems["Open Ready Projects"].isEnabled)
        XCTAssertFalse(statusItem.menuItems["Resume Workspace"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["Start All Projects"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["Stop All Running Projects"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["Running Projects"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["Check for Updates…"].isEnabled)
        XCTAssertTrue(statusItem.menuItems["About LocalWrapMac"].exists)

        statusItem.menuItems["Show LocalWrapMac"].click()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
    }

}
