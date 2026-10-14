import Foundation
import XCTest
@testable import Remux

final class HerdrSessionDiscoveryTests: XCTestCase {
    // `herdr session list --json` output from a real run; v0.9.3 serializes
    // the same `SessionInfo` fields.
    private let sessionListJSON = #"{"sessions":[{"default":true,"name":"default","running":false,"session_dir":"/private/tmp/rpp-herdr/h/.config/herdr","socket_path":"/private/tmp/rpp-herdr/h/.config/herdr/herdr.sock"},{"default":false,"name":"probe","running":true,"session_dir":"/private/tmp/rpp-herdr/h/.config/herdr/sessions/probe","socket_path":"/private/tmp/rpp-herdr/h/.config/herdr/sessions/probe/herdr.sock"}]}"#

    func testListCommandKeepsConfiguredExecutableOutOfLoginShellSyntax() {
        let executable = "/home/owner's tools/herdr; touch pwned"

        let command = HerdrSessionDiscovery.listSessionsCommand(herdrExecutable: executable)

        XCTAssertTrue(command.hasPrefix("exec /bin/sh -c '"))
        XCTAssertTrue(command.contains(#"exec "$resolved" session list --json"#))
        XCTAssertFalse(command.contains(executable))
        XCTAssertFalse(command.contains("touch pwned"))
    }

    func testListsRunningAndStoppedSessions() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(stdout: "herdr 0.9.3\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(sessions, [
            HerdrDiscoveredSession(name: "default", isRunning: false),
            HerdrDiscoveredSession(name: "probe", isRunning: true),
        ])
    }

    func testMissingHerdrHasNoSessions() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(
                exitStatus: 127,
                stderr: "\(HerdrRemoteCommand.notFoundMarker): herdr\n"
            )
        )

        XCTAssertEqual(sessions, [])
    }

    func testHerdrThatCannotRunIsAnError() {
        let stderr = "\(HerdrRemoteCommand.notExecutableMarker): /opt/herdr\n"

        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(exitStatus: 126, stderr: stderr))
        ) { error in
            XCTAssertEqual(
                error as? HerdrSessionDiscoveryError,
                .remoteExit(status: 126, stderr: stderr)
            )
        }
    }

    func testExit127WithoutTheMarkerIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(
                from: result(exitStatus: 127, stderr: "sh: something else failed\n")
            )
        )
    }

    func testHerdrOlderThanTheMinimumIsRefused() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(
                from: result(stdout: "herdr 0.9.0\n\(sessionListJSON)\n")
            )
        ) { error in
            XCTAssertEqual(
                error as? HerdrSessionDiscoveryError,
                .unsupportedVersion(HerdrVersion(major: 0, minor: 9, patch: 0))
            )
        }
    }

    func testNewerHerdrIsAccepted() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(stdout: "herdr 1.0.0\n\(sessionListJSON)\n")
        )

        XCTAssertEqual(sessions.map(\.name), ["default", "probe"])
    }

    func testUnreadableVersionIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(stdout: "herdr\n\(sessionListJSON)\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .unreadableVersion("herdr"))
        }
    }

    /// What the server's startup files print before the ready marker is not the command's output.
    func testStartupOutputBeforeTheReadyMarkerIsSkipped() throws {
        let sessions = try HerdrSessionDiscovery.sessions(
            from: result(stdout: "Welcome, last login yesterday\nherdr 0.1.0\n", readyThen: "herdr 0.9.3\n\(sessionListJSON)\n")
        )
        XCTAssertEqual(sessions.map(\.name), ["default", "probe"])
    }

    func testOutputWithoutTheReadyMarkerIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(
                from: RemuxSSHExecResult(exitStatus: 0, stdout: Data("herdr 0.9.3\n\(sessionListJSON)\n".utf8), stderr: Data())
            )
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .incompleteOutput)
        }
    }

    func testInvalidSessionListIsAnError() {
        XCTAssertThrowsError(
            try HerdrSessionDiscovery.sessions(from: result(stdout: "herdr 0.9.3\nnot json\n"))
        ) { error in
            XCTAssertEqual(error as? HerdrSessionDiscoveryError, .invalidSessionList)
        }
    }

    /// A run whose stdout is `stdout` (startup output), the ready marker line, then `readyThen`, or
    /// with `stdout` alone after the marker.
    private func result(
        exitStatus: Int = 0,
        stdout: String = "",
        readyThen: String? = nil,
        stderr: String = ""
    ) -> RemuxSSHExecResult {
        let output = readyThen.map { stdout + "\n\(HerdrRemoteCommand.readyMarker)\n" + $0 }
            ?? "\n\(HerdrRemoteCommand.readyMarker)\n" + stdout
        return RemuxSSHExecResult(
            exitStatus: exitStatus,
            stdout: Data(output.utf8),
            stderr: Data(stderr.utf8)
        )
    }
}
