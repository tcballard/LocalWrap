import XCTest
@testable import LocalWrapMac

final class CommandServiceTests: XCTestCase {
    func testParsesAllowlistedCommandWithoutAShell() throws {
        XCTAssertEqual(
            try CommandParser().parse("npm run dev -- --host 127.0.0.1"),
            ParsedCommand(
                executable: "npm",
                arguments: ["run", "dev", "--", "--host", "127.0.0.1"]
            )
        )
    }

    func testRejectsUnknownExecutablesAndEveryShellMetacharacterClass() {
        XCTAssertThrowsError(try CommandParser().parse("bash run.sh"))
        for command in ["npm start; whoami", "npm $(whoami)", "npm > output", "npm 'start'"] {
            XCTAssertThrowsError(try CommandParser().parse(command), command)
        }
    }

    func testResolvesExecutableAndInjectsPortWithoutDroppingEnvironment() throws {
        let resolver = EnvironmentResolver(
            environment: { ["PATH": "/tools:/usr/bin", "HOME": "/Users/test"] },
            isExecutable: { $0 == "/tools/npm" }
        )

        let resolved = try resolver.resolve(executable: "npm", port: 5_173)

        XCTAssertEqual(resolved.executableURL.path, "/tools/npm")
        XCTAssertEqual(resolved.values["PORT"], "5173")
        XCTAssertEqual(resolved.values["HOME"], "/Users/test")
    }
}
