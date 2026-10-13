import Foundation

public struct OfficialAppFacts: Codable, Equatable, Sendable {
    public let path: String
    public let bundleIdentifier: String
    public let shortVersion: String
    public let buildVersion: String
    public let executableName: String
    public let assetsSHA256: String
}

public enum OfficialAppInspector {
    public static let supportedPath = "/Applications/KakaoTalk.app"
    public static let expectedBundleIdentifier = "com.kakao.KakaoTalkMac"
    public static let expectedTeamIdentifier = "L75WVXX68A"

    /// The oldest official release this installer has been exercised against.  Anything newer is
    /// accepted without a code change: what we verify is identity — bundle identifier, Kakao Team
    /// ID and a valid signature — not a pinned version string.  Pinning an exact version made every
    /// KakaoTalk update require a new installer release before the dual app could be rebuilt.
    public static let minimumShortVersion = "26.6.1"

    public static func inspect(path: String = supportedPath) throws -> OfficialAppFacts {
        let appURL = URL(fileURLWithPath: path, isDirectory: true)
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: plistURL.path) else {
            throw InspectionError.appNotFound(path)
        }

        let appValues = try appURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard appValues.isDirectory == true, appValues.isSymbolicLink != true else {
            throw InspectionError.untrustedSource("Official app path must be a real directory, not a symbolic link")
        }
        let plistData = try Data(contentsOf: plistURL)
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              let shortVersion = plist["CFBundleShortVersionString"] as? String,
              let buildVersion = plist["CFBundleVersion"] as? String,
              let executableName = plist["CFBundleExecutable"] as? String
        else {
            throw InspectionError.invalidInfoPlist
        }
        guard bundleIdentifier == expectedBundleIdentifier else {
            throw InspectionError.unexpectedBundleIdentifier(bundleIdentifier)
        }
        guard isVersion(shortVersion, atLeast: minimumShortVersion) else {
            throw InspectionError.versionTooOld(shortVersion, minimumShortVersion)
        }

        let executableURL = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw InspectionError.missingExecutable(executableURL.path)
        }

        let assetsURL = appURL.appendingPathComponent("Contents/Resources/Assets.car")
        guard FileManager.default.fileExists(atPath: assetsURL.path) else {
            throw InspectionError.missingAssetsCatalog(assetsURL.path)
        }
        try verifySignature(appURL)

        return OfficialAppFacts(
            path: appURL.path,
            bundleIdentifier: bundleIdentifier,
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            executableName: executableName,
            assetsSHA256: try SHA256.file(at: assetsURL)
        )
    }

    /// Dotted numeric comparison.  A version string we cannot parse is accepted rather than
    /// rejected: the bundle identifier and the Kakao signature are the real gate, and a future
    /// change to Kakao's version format must not brick the installer.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        guard let left = numericComponents(version), let right = numericComponents(minimum) else {
            return true
        }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var components: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            components.append(value)
        }
        return components
    }

    private static func verifySignature(_ appURL: URL) throws {
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", appURL.path]
        try verify.run()
        verify.waitUntilExit()
        guard verify.terminationStatus == 0 else {
            throw InspectionError.untrustedSource("The official app signature is invalid")
        }

        let details = Process()
        let pipe = Pipe()
        details.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        details.arguments = ["-dv", "--verbose=4", appURL.path]
        details.standardError = pipe
        try details.run()
        details.waitUntilExit()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard details.terminationStatus == 0,
              output.contains("TeamIdentifier=\(expectedTeamIdentifier)") else {
            throw InspectionError.untrustedSource("The app is not signed by the expected Kakao Team ID")
        }
    }
}

public enum InspectionError: LocalizedError {
    case appNotFound(String)
    case invalidInfoPlist
    case unexpectedBundleIdentifier(String)
    case missingExecutable(String)
    case missingAssetsCatalog(String)
    case untrustedSource(String)
    case versionTooOld(String, String)

    public var errorDescription: String? {
        switch self {
        case .appNotFound(let path): "Official KakaoTalk was not found at \(path)"
        case .invalidInfoPlist: "KakaoTalk Info.plist is invalid"
        case .unexpectedBundleIdentifier(let value): "Unexpected bundle identifier: \(value)"
        case .missingExecutable(let path): "KakaoTalk executable is missing: \(path)"
        case .missingAssetsCatalog(let path): "KakaoTalk Assets.car is missing: \(path)"
        case .untrustedSource(let reason): "Untrusted KakaoTalk source: \(reason)"
        case .versionTooOld(let version, let minimum): "KakaoTalk \(version) is older than the minimum supported \(minimum). Update KakaoTalk and run the installer again."
        }
    }
}
