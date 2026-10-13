import AppKit
import CoreUIBridge
import Foundation

public struct AssetCatalogRendition: Equatable, Sendable {
    public let name: String
    public let scale: Int
    public let width: Int
    public let height: Int
    public let hasInternalLink: Bool
    public let rgbaData: Data

    public init(name: String, scale: Int, width: Int, height: Int, hasInternalLink: Bool, rgbaData: Data = Data()) {
        self.name = name
        self.scale = scale
        self.width = width
        self.height = height
        self.hasInternalLink = hasInternalLink
        self.rgbaData = rgbaData
    }
}

public struct AssetCatalogMutationPlan: Equatable, Sendable {
    public let sourceCatalog: URL
    public let destinationCatalog: URL
    public let allowedSourceSHA256: Set<String>

    public init(sourceCatalog: URL, destinationCatalog: URL, allowedSourceSHA256: Set<String>) {
        self.sourceCatalog = sourceCatalog
        self.destinationCatalog = destinationCatalog
        self.allowedSourceSHA256 = allowedSourceSHA256
    }
}

public enum AssetCatalogPatcherError: LocalizedError, Equatable {
    case sourceNotAllowlisted
    case destinationMustDiffer
    case invalidRenditionMetadata
    case unexpectedRenditionCount(Int)
    case unexpectedRendition(AssetCatalogRendition)
    case missingTarget(String, Int)
    case bridge(String)
    case assetutil(String)
    case nonTargetMetadataChanged
    case postWriteValidationFailed

    public var errorDescription: String? {
        switch self {
        case .sourceNotAllowlisted: "The source asset catalog fingerprint is not allowlisted."
        case .destinationMustDiffer: "The output catalog must be a separate temporary copy."
        case .invalidRenditionMetadata: "CoreUI returned invalid rendition metadata."
        case .unexpectedRenditionCount(let count): "Expected exactly 16 target renditions, found \(count)."
        case .unexpectedRendition(let rendition): "Unexpected target rendition \(rendition.name) at \(rendition.scale)x (\(rendition.width)x\(rendition.height))."
        case .missingTarget(let name, let scale): "Missing target rendition \(name) at \(scale)x."
        case .bridge(let message), .assetutil(let message): message
        case .nonTargetMetadataChanged: "Non-target rendition metadata changed after patching."
        case .postWriteValidationFailed: "Patched target renditions did not validate as RGB."
        }
    }
}

public enum AssetCatalogPatcher {
    public static let allowedNames: Set<String> = [
        "MenuIcon", "MenuIconWithNew", "DarkMenuIcon", "DarkMenuIconWithNew",
        "LoggedoutMenuIcon", "LoggedoutDarkMenuIcon", "AlternateMenuIcon", "AlternateDarkMenuIcon",
    ]

    public static let supportedCatalogSHA256: Set<String> = [
        "2d47e3d6cf38e3b91e32e13b4125054075a13a15f27916b2a77531ebe0a92036"
    ]
    public static func validate(plan: AssetCatalogMutationPlan) throws {
        guard plan.sourceCatalog.standardizedFileURL != plan.destinationCatalog.standardizedFileURL else {
            throw AssetCatalogPatcherError.destinationMustDiffer
        }
        let sourceDigest = try SHA256.file(at: plan.sourceCatalog)
        guard plan.allowedSourceSHA256.contains(sourceDigest),
              supportedCatalogSHA256.contains(sourceDigest) else {
            throw AssetCatalogPatcherError.sourceNotAllowlisted
        }
    }

    public static func validateTargetRenditions(
        _ renditions: [AssetCatalogRendition],
        requireInternalLinks: Bool = true
    ) throws {
        guard renditions.count == allowedNames.count * 2 else {
            throw AssetCatalogPatcherError.unexpectedRenditionCount(renditions.count)
        }
        var seen = Set<String>()
        for rendition in renditions {
            guard allowedNames.contains(rendition.name),
                  !requireInternalLinks || rendition.hasInternalLink else {
                throw AssetCatalogPatcherError.unexpectedRendition(rendition)
            }
            let expectedDimension = rendition.scale == 1 ? 20 : rendition.scale == 2 ? 40 : 0
            guard expectedDimension != 0, rendition.width == expectedDimension, rendition.height == expectedDimension else {
                throw AssetCatalogPatcherError.unexpectedRendition(rendition)
            }
            guard seen.insert("\(rendition.name)/\(rendition.scale)").inserted else {
                throw AssetCatalogPatcherError.unexpectedRendition(rendition)
            }
        }
        for name in allowedNames {
            for scale in 1...2 where !seen.contains("\(name)/\(scale)") {
                throw AssetCatalogPatcherError.missingTarget(name, scale)
            }
        }
    }

    /// Creates and patches only destinationCatalog, leaving sourceCatalog untouched.
    public static func patch(_ plan: AssetCatalogMutationPlan) throws {
        try validate(plan: plan)
        guard !FileManager.default.fileExists(atPath: plan.destinationCatalog.path) else {
            throw AssetCatalogPatcherError.destinationMustDiffer
        }
        try FileManager.default.copyItem(at: plan.sourceCatalog, to: plan.destinationCatalog)
        let before = try renditions(in: plan.destinationCatalog)
        let targets = before.filter { allowedNames.contains($0.name) }
        try validateTargetRenditions(targets)
        var expectedPixels: [String: Data] = [:]
        for rendition in targets {
            guard rendition.rgbaData.count == rendition.width * rendition.height * 4 else {
                throw AssetCatalogPatcherError.invalidRenditionMetadata
            }
            var pixels = rendition.rgbaData
            pixels.withUnsafeMutableBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    let alpha = bytes[offset + 3]
                    let straight = RGBA(
                        red: unpremultiply(bytes[offset], alpha: alpha),
                        green: unpremultiply(bytes[offset + 1], alpha: alpha),
                        blue: unpremultiply(bytes[offset + 2], alpha: alpha),
                        alpha: alpha
                    )
                    let output = ColorTransformer.transform(straight, variant: .menuBar)
                    bytes[offset] = premultiply(output.red, alpha: output.alpha)
                    bytes[offset + 1] = premultiply(output.green, alpha: output.alpha)
                    bytes[offset + 2] = premultiply(output.blue, alpha: output.alpha)
                    bytes[offset + 3] = output.alpha
                }
            }
            expectedPixels["\(rendition.name)/\(rendition.scale)"] = pixels
            var error: NSError?
            guard CoreUIBridgeReplaceNamedImageRendition(plan.destinationCatalog, rendition.name, rendition.scale, rendition.width, rendition.height, pixels, &error) else {
                throw AssetCatalogPatcherError.bridge(error?.localizedDescription ?? "CoreUI replacement failed.")
            }
        }
        let after = try renditions(in: plan.destinationCatalog)
        let patched = after.filter { allowedNames.contains($0.name) }
        try validateTargetRenditions(patched, requireInternalLinks: false)
        for rendition in patched {
            guard let expected = expectedPixels["\(rendition.name)/\(rendition.scale)"],
                  validatesTransformedPixels(rendition.rgbaData, expected: expected) else {
                throw AssetCatalogPatcherError.postWriteValidationFailed
            }
        }
        guard nonTargetMetadata(before) == nonTargetMetadata(after) else {
            throw AssetCatalogPatcherError.nonTargetMetadataChanged
        }
        guard try SHA256.file(at: plan.destinationCatalog) != SHA256.file(at: plan.sourceCatalog) else {
            throw AssetCatalogPatcherError.postWriteValidationFailed
        }
    }

    public static func renditions(in catalog: URL) throws -> [AssetCatalogRendition] {
        var error: NSError?
        var values: NSArray?
        guard CoreUIBridgeCopyNamedImageRenditions(catalog, &values, &error) else {
            throw AssetCatalogPatcherError.bridge(error?.localizedDescription ?? "CoreUI rendition enumeration failed.")
        }
        return try (values as? [[String: Any]] ?? []).map { value in
            guard let name = value["name"] as? String,
                  let scale = value["scale"] as? NSNumber,
                  let width = value["width"] as? NSNumber,
                  let height = value["height"] as? NSNumber,
                  let hasInternalLink = value["hasInternalLink"] as? NSNumber,
                  let rgbaData = value["rgbaData"] as? Data else {
                throw AssetCatalogPatcherError.invalidRenditionMetadata
            }
            return AssetCatalogRendition(
                name: name,
                scale: scale.intValue,
                width: width.intValue,
                height: height.intValue,
                hasInternalLink: hasInternalLink.boolValue,
                rgbaData: rgbaData
            )
        }
    }

    private static func validatesTransformedPixels(_ actual: Data, expected: Data) -> Bool {
        guard actual.count == expected.count, actual.count.isMultiple(of: 4) else { return false }
        return actual.withUnsafeBytes { actualRaw in
            expected.withUnsafeBytes { expectedRaw in
                let a = actualRaw.bindMemory(to: UInt8.self)
                let e = expectedRaw.bindMemory(to: UInt8.self)
                for offset in stride(from: 0, to: a.count, by: 4) {
                    let actualAlpha = a[offset + 3]
                    let expectedAlpha = e[offset + 3]
                    guard abs(Int(actualAlpha) - Int(expectedAlpha)) <= 2 else { return false }
                    if actualAlpha == 0 && expectedAlpha == 0 { continue }
                    let tolerance = max(3, Int(255 / max(1, Int(min(actualAlpha, expectedAlpha)))))
                    for component in 0..<3 {
                        let actualStraight = unpremultiply(a[offset + component], alpha: actualAlpha)
                        let expectedStraight = unpremultiply(e[offset + component], alpha: expectedAlpha)
                        guard abs(Int(actualStraight) - Int(expectedStraight)) <= tolerance else { return false }
                    }
                }
                return true
            }
        }
    }
    private static func nonTargetMetadata(_ renditions: [AssetCatalogRendition]) -> [String] {
        renditions
            .filter { !allowedNames.contains($0.name) }
            .map { "\($0.name)/\($0.scale)/\($0.width)x\($0.height)/\($0.hasInternalLink)/\(SHA256.data($0.rgbaData))" }
            .sorted()
    }
}
