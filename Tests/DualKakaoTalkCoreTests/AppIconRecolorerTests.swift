import XCTest
@testable import DualKakaoTalkCore

final class AppIconRecolorerTests: XCTestCase {
    /// KakaoTalk's field colour and the speech bubble that must survive untouched.
    private let kakaoYellow = RGBA(red: 0xFA, green: 0xE1, blue: 0x00, alpha: 0xFF)
    private let bubbleBrown = RGBA(red: 0x39, green: 0x1B, blue: 0x1B, alpha: 0xFF)

    func testYellowFieldBecomesGreen() {
        let output = AppIconRecolorer.transform(kakaoYellow)
        XCTAssertGreaterThan(output.green, output.red)
        XCTAssertGreaterThan(output.green, output.blue)

        let hue = AppIconRecolorer.hsb(output).hue
        XCTAssertEqual(hue, AppIconRecolorer.targetHue, accuracy: 6)
    }

    func testYellowFieldTracksTheYellowsBrightnessAtTheConfiguredScale() {
        let output = AppIconRecolorer.transform(kakaoYellow)
        XCTAssertEqual(
            AppIconRecolorer.luminance(output),
            AppIconRecolorer.luminance(kakaoYellow) * AppIconRecolorer.luminanceScale,
            accuracy: 0.03
        )
    }

    func testShadingSurvivesTheRotation() {
        // A darker yellow must stay darker after the rotation, or gradients flatten out.
        let lit = AppIconRecolorer.transform(kakaoYellow)
        let shaded = AppIconRecolorer.transform(RGBA(red: 0xD8, green: 0xC2, blue: 0x00, alpha: 0xFF))
        XCTAssertLessThan(AppIconRecolorer.luminance(shaded), AppIconRecolorer.luminance(lit))
    }

    func testSpeechBubbleAndNeutralsAreUntouched() {
        for pixel in [
            bubbleBrown,
            RGBA(red: 0xFF, green: 0xFF, blue: 0xFF, alpha: 0xFF),
            RGBA(red: 0x00, green: 0x00, blue: 0x00, alpha: 0xFF),
            RGBA(red: 0x80, green: 0x80, blue: 0x80, alpha: 0xFF),
            RGBA(red: 0x22, green: 0x55, blue: 0xCC, alpha: 0xFF),
        ] {
            XCTAssertEqual(AppIconRecolorer.transform(pixel), pixel)
        }
    }

    func testFullyTransparentPixelsAreUntouched() {
        let clear = RGBA(red: 0xFA, green: 0xE1, blue: 0x00, alpha: 0x00)
        XCTAssertEqual(AppIconRecolorer.transform(clear), clear)
    }

    func testFieldWeightTapersInsteadOfBanding() {
        XCTAssertEqual(AppIconRecolorer.fieldWeight(hue: 54, saturation: 1), 1)
        XCTAssertEqual(AppIconRecolorer.fieldWeight(hue: 0, saturation: 1), 0)
        XCTAssertEqual(AppIconRecolorer.fieldWeight(hue: 180, saturation: 1), 0)
        // Desaturated pixels have no reliable hue.
        XCTAssertEqual(AppIconRecolorer.fieldWeight(hue: 54, saturation: 0.1), 0)

        let edge = AppIconRecolorer.fieldWeight(hue: 32, saturation: 1)
        XCTAssertGreaterThan(edge, 0)
        XCTAssertLessThan(edge, 1)
    }

    func testAntialiasedEdgePixelsArePartiallyShifted() {
        // Hue 32 degrees: on the taper between the brown bubble and the yellow field.
        let edge = RGBA(red: 0xC8, green: 0x80, blue: 0x30, alpha: 0xFF)
        let output = AppIconRecolorer.transform(edge)
        XCTAssertNotEqual(output, edge)
        // Judge the shift by hue, not by the green channel: luminanceScale settles the field
        // darker, so a shifted pixel can carry no more green than it started with.
        let shiftedHue = AppIconRecolorer.hsb(output).hue
        XCTAssertGreaterThan(shiftedHue, AppIconRecolorer.hsb(edge).hue)
        XCTAssertLessThan(shiftedHue, AppIconRecolorer.targetHue)
        XCTAssertLessThan(output.red, edge.red)
        XCTAssertEqual(output.alpha, edge.alpha)
    }

    func testRoundTripBetweenRGBAndHSB() {
        for pixel in [kakaoYellow, bubbleBrown, ColorTransformer.menuBarGreen] {
            let components = AppIconRecolorer.hsb(pixel)
            let restored = AppIconRecolorer.rgba(
                hue: components.hue,
                saturation: components.saturation,
                brightness: components.brightness,
                alpha: pixel.alpha
            )
            XCTAssertEqual(Double(restored.red), Double(pixel.red), accuracy: 1)
            XCTAssertEqual(Double(restored.green), Double(pixel.green), accuracy: 1)
            XCTAssertEqual(Double(restored.blue), Double(pixel.blue), accuracy: 1)
        }
    }
}
