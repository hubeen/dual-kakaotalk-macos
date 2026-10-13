import AppKit
import Foundation

/// Derives the dual app's Dock/Finder icon from the official icon already installed on this Mac.
///
/// Nothing is redistributed: every pixel is produced locally at install time from the copy the
/// user already owns, the same rule the menu-bar treatment follows.  Unlike the menu-bar icons
/// this step uses only public AppKit and `/usr/bin/iconutil`, so it does not depend on a
/// fingerprinted `Assets.car` and keeps working across KakaoTalk updates.
public enum AppIconRecolorer {
    /// Written only when the official bundle declares no `CFBundleIconFile` to overwrite.
    public static let fallbackIconBaseName = "AppIconDual"

    /// Hue rotation target, taken from the shared brand green so the Dock icon and the menu-bar
    /// icons read as one product.
    public static let targetHue: Double = hsb(ColorTransformer.menuBarGreen).hue

    /// KakaoTalk's field is fully saturated yellow; rotating it to green at the same saturation
    /// and the same perceived brightness reads as neon, because green carries far more luminance
    /// than yellow at equal saturation.  Capping saturation and settling the green slightly
    /// darker than the yellow lands on a solid #32C67A.  These two constants are what to tune if
    /// the icon wants a louder or quieter green.
    public static let saturationCap = 0.75
    public static let luminanceScale = 0.75

    /// Hues fully treated as "the yellow field", in degrees.
    static let fieldHueCore: ClosedRange<Double> = 40...75
    /// Hues partially treated, so antialiased edges against the brown speech bubble do not band.
    static let fieldHueTaper: ClosedRange<Double> = 25...95
    /// Below this saturation a pixel is grey, white or black and has no meaningful hue.
    static let minimumFieldSaturation = 0.25

    static let iconsetEntries: [(pixels: Int, fileName: String)] = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]

    // MARK: - Pixel transform

    /// How strongly a pixel counts as part of the yellow field: 1 inside the core hue range,
    /// tapering to 0 across the taper range, 0 for the brown speech bubble and for greys.
    public static func fieldWeight(hue: Double, saturation: Double) -> Double {
        guard saturation >= minimumFieldSaturation else { return 0 }
        if fieldHueCore.contains(hue) { return 1 }
        if hue > fieldHueTaper.lowerBound, hue < fieldHueCore.lowerBound {
            return (hue - fieldHueTaper.lowerBound) / (fieldHueCore.lowerBound - fieldHueTaper.lowerBound)
        }
        if hue > fieldHueCore.upperBound, hue < fieldHueTaper.upperBound {
            return (fieldHueTaper.upperBound - hue) / (fieldHueTaper.upperBound - fieldHueCore.upperBound)
        }
        return 0
    }

    /// Rotates the yellow field to the brand green while preserving each pixel's perceived
    /// brightness, so shading, gradients and the brown speech bubble all survive unchanged.
    public static func transform(_ pixel: RGBA) -> RGBA {
        guard pixel.alpha > 0 else { return pixel }
        let source = hsb(pixel)
        let weight = fieldWeight(hue: source.hue, saturation: source.saturation)
        guard weight > 0 else { return pixel }

        let rotated = rgba(
            hue: targetHue,
            saturation: min(source.saturation, saturationCap),
            brightness: source.brightness,
            alpha: pixel.alpha
        )
        let matched = matchingBrightness(of: rotated, to: pixel, scale: luminanceScale)
        return blend(pixel, matched, weight: weight)
    }

    // MARK: - Bundle rewriting

    /// Replaces the staged bundle's icon with the recoloured one.  Operates only on `stagedApp`,
    /// never on the official app.
    public static func installDualIcon(
        in stagedApp: URL,
        runner: InstallCommandRunning = ProcessInstallCommandRunner()
    ) throws {
        let (icon, existingIconFile) = try sourceIcon(in: stagedApp)
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DualKakaoTalkIcon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: workspace) }

        let iconset = workspace.appendingPathComponent("DualKakaoTalk.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: false)
        var rendered: [Int: Data] = [:]
        for entry in iconsetEntries {
            let png = try rendered[entry.pixels] ?? recoloredPNG(from: icon, pixels: entry.pixels)
            rendered[entry.pixels] = png
            try png.write(to: iconset.appendingPathComponent(entry.fileName), options: .atomic)
        }

        let produced = workspace.appendingPathComponent("DualKakaoTalk.icns")
        try runner.run("/usr/bin/iconutil", ["--convert", "icns", "--output", produced.path, iconset.path])

        let resources = stagedApp.appendingPathComponent("Contents/Resources", isDirectory: true)
        if let existingIconFile {
            _ = try FileManager.default.replaceItemAt(resources.appendingPathComponent(existingIconFile), withItemAt: produced)
            try setIconFile(existingIconFile, in: stagedApp)
        } else {
            let name = "\(fallbackIconBaseName).icns"
            try FileManager.default.moveItem(at: produced, to: resources.appendingPathComponent(name))
            try setIconFile(fallbackIconBaseName, in: stagedApp)
        }
    }

    /// Returns the bundle's icon plus the `Resources`-relative file name to overwrite, when the
    /// bundle ships an `.icns` we can replace in place.
    /// The `Contents/Resources`-relative icon file a bundle declares, with the extension CFBundle
    /// lets authors leave off.  The installer reads this too, to tell a rebuilt icon from an
    /// installed one, so the naming rule lives in exactly one place.
    public static func declaredIconFileName(in app: URL) -> String? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let declared = plist["CFBundleIconFile"] as? String, !declared.isEmpty
        else { return nil }
        return (declared as NSString).pathExtension.isEmpty ? "\(declared).icns" : declared
    }

    static func sourceIcon(in app: URL) throws -> (icon: NSImage, iconFileName: String?) {
        if let fileName = declaredIconFileName(in: app) {
            let iconURL = app.appendingPathComponent("Contents/Resources/\(fileName)")
            if let image = NSImage(contentsOf: iconURL) {
                return (image, fileName)
            }
        }
        // No usable CFBundleIconFile: take any icon resource the bundle ships before asking
        // LaunchServices, which would answer with a generic icon for a staged copy.
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let icnsFiles = ((try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? [])
            .filter { $0.hasSuffix(".icns") }
            .sorted()
        for fileName in icnsFiles {
            if let image = NSImage(contentsOf: resources.appendingPathComponent(fileName)) {
                return (image, fileName)
            }
        }
        let resolved = NSWorkspace.shared.icon(forFile: app.path)
        guard resolved.size.width > 0, resolved.size.height > 0 else {
            throw AppIconError.iconNotFound(app.path)
        }
        return (resolved, nil)
    }

    static func recoloredPNG(from icon: NSImage, pixels: Int) throws -> Data {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixels * 4,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw TransformError.cannotAllocateBitmap
        }
        bitmap.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let data = bitmap.bitmapData else { throw TransformError.cannotAllocateBitmap }
        // NSBitmapImageRep stores premultiplied alpha by default; hue maths needs straight alpha.
        for row in 0..<pixels {
            let rowStart = row * bitmap.bytesPerRow
            for column in 0..<pixels {
                let offset = rowStart + column * 4
                let alpha = data[offset + 3]
                let straight = RGBA(
                    red: unpremultiply(data[offset], alpha: alpha),
                    green: unpremultiply(data[offset + 1], alpha: alpha),
                    blue: unpremultiply(data[offset + 2], alpha: alpha),
                    alpha: alpha
                )
                let output = transform(straight)
                data[offset] = premultiply(output.red, alpha: output.alpha)
                data[offset + 1] = premultiply(output.green, alpha: output.alpha)
                data[offset + 2] = premultiply(output.blue, alpha: output.alpha)
                data[offset + 3] = output.alpha
            }
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw TransformError.cannotEncodePNG
        }
        return png
    }

    private static func setIconFile(_ baseName: String, in app: URL) throws {
        let url = app.appendingPathComponent("Contents/Info.plist")
        let data = try Data(contentsOf: url)
        guard var plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw InspectionError.invalidInfoPlist
        }
        plist["CFBundleIconFile"] = baseName
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: url, options: .atomic)
    }

    // MARK: - Colour maths

    static func hsb(_ pixel: RGBA) -> (hue: Double, saturation: Double, brightness: Double) {
        let red = Double(pixel.red) / 255
        let green = Double(pixel.green) / 255
        let blue = Double(pixel.blue) / 255
        let highest = max(red, green, blue)
        let lowest = min(red, green, blue)
        let delta = highest - lowest
        guard delta > 0 else { return (0, 0, highest) }

        var hue: Double
        if highest == red {
            hue = 60 * (((green - blue) / delta).truncatingRemainder(dividingBy: 6))
        } else if highest == green {
            hue = 60 * ((blue - red) / delta + 2)
        } else {
            hue = 60 * ((red - green) / delta + 4)
        }
        if hue < 0 { hue += 360 }
        return (hue, highest > 0 ? delta / highest : 0, highest)
    }

    static func rgba(hue: Double, saturation: Double, brightness: Double, alpha: UInt8) -> RGBA {
        let chroma = brightness * saturation
        let sector = hue / 60
        let secondary = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let offset = brightness - chroma
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case ..<1.0: (red, green, blue) = (chroma, secondary, 0)
        case ..<2.0: (red, green, blue) = (secondary, chroma, 0)
        case ..<3.0: (red, green, blue) = (0, chroma, secondary)
        case ..<4.0: (red, green, blue) = (0, secondary, chroma)
        case ..<5.0: (red, green, blue) = (secondary, 0, chroma)
        default: (red, green, blue) = (chroma, 0, secondary)
        }
        return RGBA(
            red: component(red + offset),
            green: component(green + offset),
            blue: component(blue + offset),
            alpha: alpha
        )
    }

    /// Rec. 709 relative luminance, so "same brightness" means what the eye reads, not what the
    /// HSB brightness channel says — green at a yellow's HSB brightness looks far too bright.
    static func luminance(_ pixel: RGBA) -> Double {
        (0.2126 * Double(pixel.red) + 0.7152 * Double(pixel.green) + 0.0722 * Double(pixel.blue)) / 255
    }

    static func matchingBrightness(of candidate: RGBA, to reference: RGBA, scale: Double = 1) -> RGBA {
        let current = luminance(candidate)
        guard current > 0.001 else { return candidate }
        let brightest = Double(max(candidate.red, candidate.green, candidate.blue)) / 255
        // Never scale past the point where a channel would clip and shift the hue back.
        let ceiling = brightest > 0 ? 1 / brightest : 1
        let gain = min(luminance(reference) * scale / current, ceiling)
        return RGBA(
            red: component(Double(candidate.red) / 255 * gain),
            green: component(Double(candidate.green) / 255 * gain),
            blue: component(Double(candidate.blue) / 255 * gain),
            alpha: candidate.alpha
        )
    }

    static func blend(_ original: RGBA, _ replacement: RGBA, weight: Double) -> RGBA {
        guard weight < 1 else { return replacement }
        func mix(_ lhs: UInt8, _ rhs: UInt8) -> UInt8 {
            component((Double(lhs) * (1 - weight) + Double(rhs) * weight) / 255)
        }
        return RGBA(
            red: mix(original.red, replacement.red),
            green: mix(original.green, replacement.green),
            blue: mix(original.blue, replacement.blue),
            alpha: original.alpha
        )
    }

    private static func component(_ value: Double) -> UInt8 {
        UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded()))
    }
}

public enum AppIconError: LocalizedError {
    case iconNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .iconNotFound(let path): "No application icon could be read from \(path)"
        }
    }
}
