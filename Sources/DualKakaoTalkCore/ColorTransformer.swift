import AppKit

public enum IconVariant: String, Sendable {
    case menuBar = "menu-bar"
}

public struct RGBA: Equatable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8
    public var alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public enum ColorTransformer {
    public static let menuBarGreen = RGBA(red: 0x5B, green: 0x8A, blue: 0x72, alpha: 0xFF)

    public static func transform(_ pixel: RGBA, variant: IconVariant) -> RGBA {
        guard pixel.alpha > 0 else { return pixel }

        let isNotificationRed = pixel.red >= 153 && pixel.green < 115 && pixel.blue < 115
        guard !isNotificationRed else { return pixel }
        return RGBA(
            red: menuBarGreen.red,
            green: menuBarGreen.green,
            blue: menuBarGreen.blue,
            alpha: pixel.alpha
        )
    }

    public static func recolorPNG(input: URL, output: URL, variant: IconVariant) throws {
        guard let source = NSImage(contentsOf: input),
              let tiff = source.tiffRepresentation,
              let sourceBitmap = NSBitmapImageRep(data: tiff)
        else {
            throw TransformError.invalidImage(input.path)
        }

        let width = sourceBitmap.pixelsWide
        let height = sourceBitmap.pixelsHigh
        guard let outputBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: width * 4,
            bitsPerPixel: 32
        ), let data = outputBitmap.bitmapData else {
            throw TransformError.cannotAllocateBitmap
        }

        for y in 0..<height {
            for x in 0..<width {
                guard let color = sourceBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let inputPixel = RGBA(
                    red: UInt8(clamping: Int((color.redComponent * 255).rounded())),
                    green: UInt8(clamping: Int((color.greenComponent * 255).rounded())),
                    blue: UInt8(clamping: Int((color.blueComponent * 255).rounded())),
                    alpha: UInt8(clamping: Int((color.alphaComponent * 255).rounded()))
                )
                let transformed = transform(inputPixel, variant: variant)
                let offset = y * outputBitmap.bytesPerRow + x * 4
                data[offset] = transformed.red
                data[offset + 1] = transformed.green
                data[offset + 2] = transformed.blue
                data[offset + 3] = transformed.alpha
            }
        }

        guard let png = outputBitmap.representation(using: .png, properties: [:]) else {
            throw TransformError.cannotEncodePNG
        }
        try png.write(to: output, options: .atomic)
    }
}

public enum TransformError: LocalizedError {
    case invalidImage(String)
    case cannotAllocateBitmap
    case cannotEncodePNG

    public var errorDescription: String? {
        switch self {
        case .invalidImage(let path): "Invalid image: \(path)"
        case .cannotAllocateBitmap: "Unable to allocate output bitmap"
        case .cannotEncodePNG: "Unable to encode PNG"
        }
    }
}

/// Bitmap pixels reach us premultiplied — both CoreUI renditions and `NSBitmapImageRep` — while
/// every colour transform here reasons about straight alpha.
func unpremultiply(_ component: UInt8, alpha: UInt8) -> UInt8 {
    guard alpha != 0 else { return 0 }
    return UInt8(clamping: Int((Double(component) * 255.0 / Double(alpha)).rounded()))
}

func premultiply(_ component: UInt8, alpha: UInt8) -> UInt8 {
    UInt8(clamping: Int((Double(component) * Double(alpha) / 255.0).rounded()))
}
