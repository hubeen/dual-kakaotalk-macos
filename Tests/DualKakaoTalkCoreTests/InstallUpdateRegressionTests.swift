import AppKit
import XCTest
@testable import DualKakaoTalkCore

final class InstallUpdateRegressionTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func fixture(_ name: String, version: String, icon: String = "AppIcon", build: String = "2000", executable: String = "same executable") throws -> URL {
        let app = root.appendingPathComponent(name + ".app")
        for directory in ["Contents/Resources", "Contents/MacOS"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        let plist: [String: Any] = [
            "CFBundleIdentifier": KakaoTalkWorkInstaller.bundleIdentifier,
            "CFBundleExecutable": KakaoTalkWorkInstaller.executableName,
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
            "CFBundleIconFile": icon
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try Data("same catalog".utf8).write(to: app.appendingPathComponent("Contents/Resources/Assets.car"))
        try Data(executable.utf8).write(to: app.appendingPathComponent("Contents/MacOS/" + KakaoTalkWorkInstaller.executableName))
        for language in localizedDualAppNames.keys {
            let directory = app.appendingPathComponent("Contents/Resources/" + language + ".lproj")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .binary, options: 0)
                .write(to: directory.appendingPathComponent("InfoPlist.strings"))
        }
        try applyLocalizedDualAppNames(to: app)
        return app
    }

    func yellowIcon(in app: URL, name: String = "AppIcon") throws {
        let icon = NSImage(size: NSSize(width: 128, height: 128))
        icon.lockFocus()
        NSColor(calibratedRed: 250.0 / 255, green: 225.0 / 255, blue: 0, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 128, height: 128)).fill()
        icon.unlockFocus()
        let iconset = root.appendingPathComponent(UUID().uuidString + ".iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(icon.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: iconset.appendingPathComponent("icon_128x128.png"))
        try ProcessInstallCommandRunner().run("/usr/bin/iconutil", ["--convert", "icns", "--output", app.appendingPathComponent("Contents/Resources/" + name + ".icns").path, iconset.path])
    }

    func request(for staged: URL, destination: URL) throws -> PrivilegedInstallRequest {
        let digest = try SHA256.file(at: staged.appendingPathComponent("Contents/Resources/Assets.car"))
        return PrivilegedInstallRequest(version: "1", nonce: UUID().uuidString, sourcePath: "/Applications/KakaoTalk.app", destinationPath: destination.path, stagedPath: staged.path, sourceCatalogSHA256: digest, destinationCatalogSHA256: digest)
    }

    func testChangedVersionBuildOrExecutableMustNotBeSkipped() throws {
        let old = try fixture("old", version: "26.8.0")
        try Data("same icon".utf8).write(to: old.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        let variants = [
            try fixture("version", version: "26.9.0"),
            try fixture("build", version: "26.8.0", build: "2001"),
            try fixture("executable", version: "26.8.0", executable: "new executable")
        ]
        for staged in variants {
            try Data("same icon".utf8).write(to: staged.appendingPathComponent("Contents/Resources/AppIcon.icns"))
            XCTAssertFalse(KakaoTalkWorkInstaller.destinationIsNoOp(old, request: try request(for: staged, destination: old)), staged.lastPathComponent)
        }
    }

    func testIdenticalInstallIsSkippedButMissingExecutableIsNot() throws {
        let old = try fixture("old", version: "26.8.0")
        let staged = try fixture("staged", version: "26.8.0")
        for app in [old, staged] {
            try Data("same icon".utf8).write(to: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        }
        let payload = try request(for: staged, destination: old)
        XCTAssertTrue(KakaoTalkWorkInstaller.destinationIsNoOp(old, request: payload))
        try FileManager.default.removeItem(at: old.appendingPathComponent("Contents/MacOS/" + KakaoTalkWorkInstaller.executableName))
        XCTAssertFalse(KakaoTalkWorkInstaller.destinationIsNoOp(old, request: payload))
    }

    func testDifferentIconDeclarationMustNotBeSkipped() throws {
        let old = try fixture("old", version: "26.8.0", icon: "MissingIcon")
        let staged = try fixture("staged", version: "26.8.0")
        for app in [old, staged] {
            try Data("same icon".utf8).write(to: app.appendingPathComponent("Contents/Resources/AppIcon.icns"))
        }
        XCTAssertFalse(KakaoTalkWorkInstaller.destinationIsNoOp(old, request: try request(for: staged, destination: old)))
    }

    func testDeclaredIconRoundTrip() throws {
        let app = try fixture("declared", version: "26.9.0")
        try yellowIcon(in: app)
        try AppIconRecolorer.installDualIcon(in: app)
        let path = app.appendingPathComponent("Contents/Resources/AppIcon.icns")
        XCTAssertNotNil(NSImage(contentsOf: path))
        XCTAssertEqual(AppIconRecolorer.declaredIconFileName(in: app), "AppIcon.icns")
    }

    func testFallbackIconMustUpdateDeclaration() throws {
        let app = try fixture("fallback", version: "26.9.0", icon: "MissingIcon")
        try yellowIcon(in: app, name: "OtherIcon")
        try AppIconRecolorer.installDualIcon(in: app)
        let declared = try XCTUnwrap(AppIconRecolorer.declaredIconFileName(in: app))
        XCTAssertEqual(declared, "OtherIcon.icns")
        XCTAssertNotNil(NSImage(contentsOf: app.appendingPathComponent("Contents/Resources/" + declared)), "The bundle must declare the rebuilt icon rather than the missing original")
    }
}
