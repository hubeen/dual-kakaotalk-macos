import Foundation
import Darwin

public struct InstallRequest: Sendable {
    public let sourceApp: URL
    public let destinationApp: URL
    public let allowedAssetsSHA256: Set<String>
    public init(sourceApp: URL, destinationApp: URL, allowedAssetsSHA256: Set<String>) {
        self.sourceApp = sourceApp
        self.destinationApp = destinationApp
        self.allowedAssetsSHA256 = allowedAssetsSHA256
    }
}

public enum InstallerError: LocalizedError {
    case identicalPaths, unsupportedSourcePath(String), missingResource(String), commandFailed(String), invalidRequest(String)
    public var errorDescription: String? {
        switch self {
        case .identicalPaths: return "Source and destination paths must differ."
        case .unsupportedSourcePath(let path): return "Install the official KakaoTalk app at /Applications/KakaoTalk.app (received: \(path))."
        case .missingResource(let path): return "Required app resource is missing: \(path)"
        case .commandFailed(let message), .invalidRequest(let message): return message
        }
    }
}

public protocol InstallCommandRunning { func run(_ executable: String, _ arguments: [String]) throws }
public struct ProcessInstallCommandRunner: InstallCommandRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let pipe = Pipe(); process.standardError = pipe; try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallerError.commandFailed(detail.isEmpty ? "Command failed: \(executable)" : detail)
        }
    }
}

/// The only serialized input accepted by the privileged installer.  The property-list keys are
/// deliberately fixed: accepting arbitrary JSON or command-line paths would expand root authority.
public struct PrivilegedInstallRequest: Codable, Sendable {
    public static let schemaVersion = 1
    public let schema: Int
    public let version: String
    public let nonce: String
    public let sourcePath: String
    public let destinationPath: String
    public let stagedPath: String
    public let sourceCatalogSHA256: String
    public let destinationCatalogSHA256: String

    public init(version: String, nonce: String, sourcePath: String, destinationPath: String, stagedPath: String, sourceCatalogSHA256: String, destinationCatalogSHA256: String) {
        self.schema = Self.schemaVersion; self.version = version; self.nonce = nonce; self.sourcePath = sourcePath
        self.destinationPath = destinationPath; self.stagedPath = stagedPath
        self.sourceCatalogSHA256 = sourceCatalogSHA256; self.destinationCatalogSHA256 = destinationCatalogSHA256
    }
}

let localizedDualAppNames = [
    "ko": "듀얼 카카오톡",
    "en": "Dual KakaoTalk",
    "ja": "Dual KakaoTalk"
]

func applyLocalizedDualAppNames(to app: URL) throws {
    for (language, name) in localizedDualAppNames {
        let url = app.appendingPathComponent("Contents/Resources/\(language).lproj/InfoPlist.strings")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InstallerError.missingResource(url.path)
        }
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw InspectionError.invalidInfoPlist
        }
        plist["CFBundleName"] = name
        plist["CFBundleDisplayName"] = name
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url, options: .atomic)
    }
}

func hasLocalizedDualAppNames(in app: URL) -> Bool {
    localizedDualAppNames.allSatisfy { language, name in
        let url = app.appendingPathComponent("Contents/Resources/\(language).lproj/InfoPlist.strings")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return false }
        return plist["CFBundleName"] as? String == name &&
            plist["CFBundleDisplayName"] as? String == name
    }
}

enum RecoveryOperation: Equatable {
    case removeDestination, restoreBackup, removeBackup, removeStaged, removeJournal
}

func recoveryOperations(phase: String, destinationExists: Bool, backupExists: Bool, stagedExists: Bool) throws -> [RecoveryOperation] {
    switch phase {
    case "prepared":
        return (destinationExists && backupExists ? [.removeDestination] : []) +
            (backupExists ? [.restoreBackup] : []) +
            (stagedExists ? [.removeStaged] : []) + [.removeJournal]
    case "predecessor-backed-up":
        return (destinationExists ? [.removeDestination] : []) +
            (backupExists ? [.restoreBackup] : []) +
            (stagedExists ? [.removeStaged] : []) + [.removeJournal]
    case "installed":
        return (destinationExists ? [.removeDestination] : []) +
            (backupExists ? [.restoreBackup] : []) +
            (stagedExists ? [.removeStaged] : []) + [.removeJournal]
    case "verified":
        guard destinationExists || backupExists else {
            throw InstallerError.commandFailed("Verified install and backup are both missing.")
        }
        return (!destinationExists && backupExists ? [.restoreBackup] : []) +
            (destinationExists && backupExists ? [.removeBackup] : []) +
            (stagedExists ? [.removeStaged] : []) + [.removeJournal]
    default:
        throw InstallerError.commandFailed("Unknown recovery phase.")
    }
}

/// Outcome of the unprivileged preparation step.  `menuBarIconsRecolored` is false when this
/// KakaoTalk build's asset catalog is not one we have verified the private CoreUI writer against.
public struct PreparedInstall: Sendable {
    public let requestURL: URL
    public let menuBarIconsRecolored: Bool
}

public enum KakaoTalkWorkInstaller {
    public static let destinationPath = "/Applications/KakaoTalkWork.app"
    public static let bundleIdentifier = "com.kakao.KakaoTalkWorkMac"
    public static let executableName = "KakaoTalkWork"
    private static let journalURL = URL(fileURLWithPath: "/var/db/com.dualkakaotalk.install.journal.plist")
    private static let lockURL = URL(fileURLWithPath: "/var/run/com.dualkakaotalk.install.lock")

    /// Unprivileged work only: copy, mutate, and ad-hoc sign under a user-owned 0700 staging root.
    public static func prepare(_ request: InstallRequest, version: String) throws -> PreparedInstall {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13 else {
            throw InstallerError.invalidRequest("macOS Ventura 13 or newer is required.")
        }
        let source = try canonical(request.sourceApp, mustBe: OfficialAppInspector.supportedPath)
        guard try canonical(request.destinationApp).path == destinationPath else { throw InstallerError.invalidRequest("Destination is fixed.") }
        let facts = try OfficialAppInspector.inspect(path: source.path)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("DualKakaoTalk-\(getuid())-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let staged = root.appendingPathComponent("KakaoTalkWork.app")
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            let menuBarIconsRecolored = try mutateAndSign(staged, facts: facts, request: request)
            let stagedDigest = try SHA256.file(at: staged.appendingPathComponent("Contents/Resources/Assets.car"))
            let payload = PrivilegedInstallRequest(version: version, nonce: UUID().uuidString, sourcePath: source.path, destinationPath: destinationPath, stagedPath: staged.path, sourceCatalogSHA256: facts.assetsSHA256, destinationCatalogSHA256: stagedDigest)
            let requestURL = root.appendingPathComponent("request.plist")
            try writeRequest(payload, to: requestURL)
            return PreparedInstall(requestURL: requestURL, menuBarIconsRecolored: menuBarIconsRecolored)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    /// Root entry point. It has no path arguments other than a grammar-checked request file.
    public static func installReleaseRequest(at requestURL: URL) throws -> Bool {
        var noOp = false
        try withExclusiveLock {
            try recoverIfNeeded()
            let request = try readAndValidateRequest(requestURL)
            // Recheck source, process and staged output immediately before import.
            let facts = try OfficialAppInspector.inspect(path: request.sourcePath)
            guard facts.assetsSHA256 == request.sourceCatalogSHA256 else { throw InstallerError.invalidRequest("Source catalog changed after preparation.") }
            try validateStaged(request)
            let destination = URL(fileURLWithPath: destinationPath)
            if destinationIsNoOp(destination, request: request) { noOp = true; return }
            let backup = URL(fileURLWithPath: "/Applications/.KakaoTalkWork.backup-\(request.nonce).app")
            try writeJournal(phase: "prepared", request: request, backup: backup)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.moveItem(at: destination, to: backup)
            }
            try writeJournal(phase: "predecessor-backed-up", request: request, backup: backup)
            try FileManager.default.moveItem(at: URL(fileURLWithPath: request.stagedPath), to: destination)
            try writeJournal(phase: "installed", request: request, backup: backup)
            try ProcessInstallCommandRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", destination.path])
            guard try SHA256.file(at: destination.appendingPathComponent("Contents/Resources/Assets.car")) == request.destinationCatalogSHA256 else { throw InstallerError.commandFailed("Installed catalog digest mismatch.") }
            try writeJournal(phase: "verified", request: request, backup: backup)
            try? FileManager.default.removeItem(at: backup); try? FileManager.default.removeItem(at: requestURL.deletingLastPathComponent()); try? FileManager.default.removeItem(at: journalURL)
        }
        return noOp
    }

    // Retained for library clients; it never performs an unbounded privileged import.
    public static func install(_ request: InstallRequest, fileManager: FileManager = .default, runner: InstallCommandRunning = ProcessInstallCommandRunner()) throws {
        _ = fileManager; _ = runner
        throw InstallerError.commandFailed("Use prepare followed by install-release-request; direct installation is disabled.")
    }

    private static func mutateAndSign(_ staged: URL, facts: OfficialAppFacts, request: InstallRequest) throws -> Bool {
        let fm = FileManager.default, contents = staged.appendingPathComponent("Contents"), plist = staged.appendingPathComponent("Contents/Info.plist")
        let old = contents.appendingPathComponent("MacOS/\(facts.executableName)"), new = contents.appendingPathComponent("MacOS/\(executableName)")
        guard fm.fileExists(atPath: old.path) else { throw InstallerError.missingResource(old.path) }
        if old != new { try fm.moveItem(at: old, to: new) }
        try updatePlist(at: plist)
        try applyLocalizedDualAppNames(to: staged)
        guard fm.fileExists(atPath: contents.appendingPathComponent("Resources/Assets.car").path) else {
            throw InstallerError.missingResource(contents.appendingPathComponent("Resources/Assets.car").path)
        }
        // The Dock and app-switcher icon is derived through public AppKit only, so it does not
        // depend on a fingerprinted catalog and keeps working after a KakaoTalk update.
        try AppIconRecolorer.installDualIcon(in: staged)
        let menuBarIconsRecolored = recolorMenuBarIcons(in: staged, facts: facts, request: request)
        try ProcessInstallCommandRunner().run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", staged.path]); try ProcessInstallCommandRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        return menuBarIconsRecolored
    }

    /// Green menu-bar icons go through the private CoreUI writer, which is only trusted against
    /// catalogs we have verified.  On any other build the step is skipped instead of failing the
    /// install: the dual app is still identified by its green Dock icon and its display name.
    private static func recolorMenuBarIcons(in staged: URL, facts: OfficialAppFacts, request: InstallRequest) -> Bool {
        guard request.allowedAssetsSHA256.contains(facts.assetsSHA256),
              AssetCatalogPatcher.supportedCatalogSHA256.contains(facts.assetsSHA256) else { return false }
        let fm = FileManager.default
        let assets = staged.appendingPathComponent("Contents/Resources/Assets.car")
        let patched = staged.appendingPathComponent("Contents/Resources/.Assets.green.car")
        do {
            try AssetCatalogPatcher.patch(.init(sourceCatalog: assets, destinationCatalog: patched, allowedSourceSHA256: request.allowedAssetsSHA256))
            _ = try fm.replaceItemAt(assets, withItemAt: patched)
            return true
        } catch {
            try? fm.removeItem(at: patched)
            return false
        }
    }

    private static func canonical(_ url: URL, mustBe expected: String? = nil) throws -> URL {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let expected, path != expected { throw InstallerError.unsupportedSourcePath(path) }
        return URL(fileURLWithPath: path)
    }
    private static func attributes(_ url: URL) throws -> [FileAttributeKey: Any] { try FileManager.default.attributesOfItem(atPath: url.path) }
    private static func rejectLinkAndInsecure(_ url: URL, owner: uid_t? = nil, mode: Int? = nil) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey]); guard values.isSymbolicLink != true else { throw InstallerError.invalidRequest("Symlink rejected: \(url.path)") }
        let a = try attributes(url)
        if let owner, (a[.ownerAccountID] as? NSNumber)?.uint32Value != owner { throw InstallerError.invalidRequest("Unexpected owner.") }
        if let mode, ((a[.posixPermissions] as? NSNumber)?.intValue ?? 0) != mode { throw InstallerError.invalidRequest("Unsafe permissions.") }
    }
    private static func writeRequest(_ request: PrivilegedInstallRequest, to url: URL) throws {
        let data = try PropertyListEncoder().encode(request); try data.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func readAndValidateRequest(_ url: URL) throws -> PrivilegedInstallRequest {
        try rejectLinkAndInsecure(url, mode: 0o600)
        let requestAttributes = try attributes(url)
        guard let requestOwner = (requestAttributes[.ownerAccountID] as? NSNumber)?.uint32Value, requestOwner != 0 else {
            throw InstallerError.invalidRequest("Request must be owned by the preparing user.")
        }
        let root = url.deletingLastPathComponent()
        try rejectLinkAndInsecure(root, owner: requestOwner, mode: 0o700)
        guard root.path.hasPrefix("/private/tmp/DualKakaoTalk-") || root.path.hasPrefix("/tmp/DualKakaoTalk-") else { throw InstallerError.invalidRequest("Request is outside the staging root.") }
        let object = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), options: [], format: nil)
        guard let keys = object as? [String: Any], Set(keys.keys) == Set(["schema", "version", "nonce", "sourcePath", "destinationPath", "stagedPath", "sourceCatalogSHA256", "destinationCatalogSHA256"]) else { throw InstallerError.invalidRequest("Request grammar rejected.") }
        let request = try PropertyListDecoder().decode(PrivilegedInstallRequest.self, from: Data(contentsOf: url))
        guard request.schema == PrivilegedInstallRequest.schemaVersion, request.version.range(of: "^[0-9]+(\\.[0-9]+)*$", options: .regularExpression) != nil, request.nonce.range(of: "^[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil, try canonical(URL(fileURLWithPath: request.sourcePath), mustBe: OfficialAppInspector.supportedPath).path == request.sourcePath, request.destinationPath == destinationPath, URL(fileURLWithPath: request.stagedPath).deletingLastPathComponent().path == root.path, request.stagedPath == root.appendingPathComponent("KakaoTalkWork.app").path, request.sourceCatalogSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, request.destinationCatalogSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw InstallerError.invalidRequest("Invalid fixed request values.") }
        return request
    }
    private static func validateStaged(_ request: PrivilegedInstallRequest) throws {
        let staged = URL(fileURLWithPath: request.stagedPath); try rejectLinkAndInsecure(staged)
        guard FileManager.default.fileExists(atPath: staged.appendingPathComponent("Contents/Info.plist").path), try SHA256.file(at: staged.appendingPathComponent("Contents/Resources/Assets.car")) == request.destinationCatalogSHA256, hasLocalizedDualAppNames(in: staged) else { throw InstallerError.invalidRequest("Staged app changed after preparation.") }
    }
    static func destinationIsNoOp(_ destination: URL, request: PrivilegedInstallRequest) -> Bool {
        guard FileManager.default.fileExists(atPath: destination.path), let plist = try? Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")), let dictionary = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil) as? [String: Any], dictionary["CFBundleIdentifier"] as? String == bundleIdentifier, dictionary["CFBundleExecutable"] as? String == executableName, hasLocalizedDualAppNames(in: destination) else { return false }
        guard (try? SHA256.file(at: destination.appendingPathComponent("Contents/Resources/Assets.car"))) == request.destinationCatalogSHA256 else { return false }
        let staged = URL(fileURLWithPath: request.stagedPath)
        guard let stagedPlist = try? Data(contentsOf: staged.appendingPathComponent("Contents/Info.plist")),
              let stagedDictionary = try? PropertyListSerialization.propertyList(from: stagedPlist, options: [], format: nil) as? [String: Any] else { return false }
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let installed = dictionary[key] as? String,
                  let prepared = stagedDictionary[key] as? String,
                  installed == prepared else { return false }
        }
        let executable = "Contents/MacOS/\(executableName)"
        guard let installedDigest = try? SHA256.file(at: destination.appendingPathComponent(executable)),
              let preparedDigest = try? SHA256.file(at: staged.appendingPathComponent(executable)),
              installedDigest == preparedDigest else { return false }
        return installedIconMatchesStaged(destination: destination, staged: staged)
    }

    /// The recoloured app icon is not covered by the catalog digest, so without this a rebuilt
    /// icon -- after tuning the green, say -- would be mistaken for an install that is already
    /// current and silently skipped.  An icon we cannot read on either side counts as a mismatch,
    /// so the install proceeds rather than being wrongly skipped.
    private static func installedIconMatchesStaged(destination: URL, staged: URL) -> Bool {
        guard let fileName = AppIconRecolorer.declaredIconFileName(in: staged),
              AppIconRecolorer.declaredIconFileName(in: destination) == fileName,
              let installed = try? SHA256.file(at: destination.appendingPathComponent("Contents/Resources/\(fileName)")),
              let prepared = try? SHA256.file(at: staged.appendingPathComponent("Contents/Resources/\(fileName)"))
        else { return false }
        return installed == prepared
    }
    private static func withExclusiveLock(_ body: () throws -> Void) throws {
        let fd = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600)) }; guard fd >= 0 else { throw InstallerError.commandFailed("Cannot open installer lock.") }; defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw InstallerError.commandFailed("Another installation is in progress.") }; defer { flock(fd, LOCK_UN) }; try body()
    }
    private static func writeJournal(phase: String, request: PrivilegedInstallRequest, backup: URL) throws {
        let journal: [String: String] = ["phase": phase, "source": request.sourcePath, "destination": request.destinationPath, "staged": request.stagedPath, "backup": backup.path, "nonce": request.nonce]
        try durableWrite(try PropertyListSerialization.data(fromPropertyList: journal, format: .binary, options: 0), to: journalURL, mode: 0o600)
    }
    private static func recoverIfNeeded() throws {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        try rejectLinkAndInsecure(journalURL, owner: 0, mode: 0o600)
        guard let journal = try PropertyListSerialization.propertyList(from: Data(contentsOf: journalURL), options: [], format: nil) as? [String: String],
              let destinationPath = journal["destination"], let backupPath = journal["backup"],
              let stagedPath = journal["staged"], let phase = journal["phase"] else {
            throw InstallerError.commandFailed("Unsafe recovery journal retained for manual recovery.")
        }
        guard destinationPath == Self.destinationPath,
              backupPath.hasPrefix("/Applications/.KakaoTalkWork.backup-"),
              stagedPath.hasPrefix("/private/tmp/DualKakaoTalk-") else {
            throw InstallerError.commandFailed("Recovery journal paths are outside the fixed grammar.")
        }
        let destination = URL(fileURLWithPath: destinationPath)
        let backup = URL(fileURLWithPath: backupPath)
        let staged = URL(fileURLWithPath: stagedPath)
        let fm = FileManager.default
        let operations = try recoveryOperations(
            phase: phase,
            destinationExists: fm.fileExists(atPath: destination.path),
            backupExists: fm.fileExists(atPath: backup.path),
            stagedExists: fm.fileExists(atPath: staged.path)
        )
        for operation in operations {
            switch operation {
            case .removeDestination: try fm.removeItem(at: destination)
            case .restoreBackup: try fm.moveItem(at: backup, to: destination)
            case .removeBackup: try fm.removeItem(at: backup)
            case .removeStaged: try fm.removeItem(at: staged)
            case .removeJournal: try fm.removeItem(at: journalURL)
            }
        }
    }
    private static func durableWrite(_ data: Data, to url: URL, mode: Int) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = temporary.path.withCString { Darwin.open($0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, mode_t(mode)) }; guard fd >= 0 else { throw InstallerError.commandFailed("Cannot create durable journal.") }; defer { close(fd) }
        try data.withUnsafeBytes { bytes in guard write(fd, bytes.baseAddress, bytes.count) == bytes.count else { throw InstallerError.commandFailed("Cannot write durable journal.") } }; guard fsync(fd) == 0 else { throw InstallerError.commandFailed("Cannot sync journal.") }; guard rename(temporary.path, url.path) == 0 else { throw InstallerError.commandFailed("Cannot atomically replace journal.") }
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY); if directory >= 0 { _ = fsync(directory); close(directory) }
    }
    private static func updatePlist(at url: URL) throws { let data = try Data(contentsOf: url); guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw InspectionError.invalidInfoPlist }; plist["CFBundleExecutable"] = executableName; plist["CFBundleIdentifier"] = bundleIdentifier; plist["CFBundleName"] = executableName; plist["CFBundleDisplayName"] = executableName; plist.removeValue(forKey: "CFBundleIconName"); try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url, options: .atomic) }
}
