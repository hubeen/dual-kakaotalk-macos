import Foundation
import XCTest
@testable import DualKakaoTalkCore

final class OfficialAppInspectorTests: XCTestCase {
    private var temporaryDirectory: URL!

    func testAcceptsTheMinimumAndAnythingNewer() {
        XCTAssertTrue(OfficialAppInspector.isVersion("26.6.1", atLeast: "26.6.1"))
        XCTAssertTrue(OfficialAppInspector.isVersion("26.6.2", atLeast: "26.6.1"))
        XCTAssertTrue(OfficialAppInspector.isVersion("26.8.0", atLeast: "26.6.1"))
        XCTAssertTrue(OfficialAppInspector.isVersion("27.0", atLeast: "26.6.1"))
        XCTAssertTrue(OfficialAppInspector.isVersion("26.10.0", atLeast: "26.9.0"))
    }

    func testRejectsOlderVersions() {
        XCTAssertFalse(OfficialAppInspector.isVersion("26.6.0", atLeast: "26.6.1"))
        XCTAssertFalse(OfficialAppInspector.isVersion("25.9.9", atLeast: "26.6.1"))
        XCTAssertFalse(OfficialAppInspector.isVersion("26.6", atLeast: "26.6.1"))
    }

    func testAcceptsVersionStringsItCannotParse() {
        // Identity and signature are the real gate; a future version format must not brick us.
        XCTAssertTrue(OfficialAppInspector.isVersion("26.8.0-beta", atLeast: "26.6.1"))
        XCTAssertTrue(OfficialAppInspector.isVersion("", atLeast: "26.6.1"))
    }

    func testRejectsVersionsOlderThanTheSupportedMinimum() throws {
        let app = try makeFixture(bundleIdentifier: OfficialAppInspector.expectedBundleIdentifier)
        XCTAssertThrowsError(try OfficialAppInspector.inspect(path: app.path)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("older than the minimum supported"),
                error.localizedDescription
            )
        }
    }

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRejectsUnexpectedBundleIdentifier() throws {
        let app = try makeFixture(bundleIdentifier: "example.invalid")
        XCTAssertThrowsError(try OfficialAppInspector.inspect(path: app.path)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "Unexpected bundle identifier: example.invalid"
            )
        }
    }

    func testRejectsMissingOfficialApp() {
        let missing = temporaryDirectory.appendingPathComponent("Missing.app")
        XCTAssertThrowsError(try OfficialAppInspector.inspect(path: missing.path))
    }

    private func makeFixture(bundleIdentifier: String) throws -> URL {
        let app = temporaryDirectory.appendingPathComponent("KakaoTalk.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executableDirectory = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundleExecutable": "KakaoTalk"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = executableDirectory.appendingPathComponent("KakaoTalk")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data("catalog-fixture".utf8).write(to: resources.appendingPathComponent("Assets.car"))
        return app
    }
}
