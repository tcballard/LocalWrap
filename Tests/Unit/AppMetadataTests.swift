import Foundation
import XCTest
@testable import LocalWrapMac

final class AppMetadataTests: XCTestCase {
    func testNativeBundleContainsVersionIconAndAboutCredits() throws {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            "3.3.0"
        )
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            "1"
        )
        XCTAssertNotNil(Bundle.main.url(forResource: "icon", withExtension: "icns"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Credits", withExtension: "rtf"))
    }
}
