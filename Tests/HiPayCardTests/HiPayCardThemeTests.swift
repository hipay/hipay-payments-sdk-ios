import SwiftUI
import HiPayFullservice
import XCTest
@testable import HiPayCard

/// The shared-contract → SwiftUI mapping (colors, typography, metrics) — pure, no rendering.
/// The visual result is covered by the demo/manual matrix (default + custom, vs Android/CMP).
final class HiPayCardThemeTests: XCTestCase {

    // MARK: ARGB Int64 → Color

    func testArgbMapsToSRGBComponentsWithAlpha() {
        let color = Color(hiPayArgb: 0x801A237E)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(r, 0x1A / 255, accuracy: 0.002)
        XCTAssertEqual(g, 0x23 / 255, accuracy: 0.002)
        XCTAssertEqual(b, 0x7E / 255, accuracy: 0.002)
        XCTAssertEqual(a, 0x80 / 255, accuracy: 0.002)
    }

    // MARK: hipayDefault mirrors the shared contract

    func testHipayDefaultMirrorsTheSharedContractValues() {
        let theme = HiPayCardTheme.hipayDefault
        XCTAssertEqual(theme.textColor, Color(hiPayArgb: 0xFF111111))
        XCTAssertEqual(theme.placeholderColor, Color(hiPayArgb: 0xFF8E8E93))
        XCTAssertEqual(theme.iconColor, Color(hiPayArgb: 0xFF8E8E93))
        XCTAssertEqual(theme.invalidTextColor, Color(hiPayArgb: 0xFFD32F2F))
        XCTAssertEqual(theme.fontSize, 16)
        XCTAssertEqual(theme.fontWeight, .regular)
        XCTAssertFalse(theme.isItalic)
        XCTAssertEqual(theme.borderColor, Color(hiPayArgb: 0xFFC7C7CC))
        XCTAssertEqual(theme.borderWidth, 1)
        XCTAssertEqual(theme.cornerRadius, 12)
        XCTAssertEqual(theme.backgroundColor, Color(hiPayArgb: 0xFFFFFFFF))
        XCTAssertEqual(theme.fieldHeight, 42)
    }

    func testDefaultKeepsItsPreExistingNameAndEqualsHipayDefault() {
        XCTAssertEqual(HiPayCardTheme.default, HiPayCardTheme.hipayDefault)
    }

    // MARK: font enums

    func testEveryFontWeightHasASwiftUIMapping() {
        XCTAssertEqual(theme(weight: .regular).fontWeight, .regular)
        XCTAssertEqual(theme(weight: .medium).fontWeight, .medium)
        XCTAssertEqual(theme(weight: .semibold).fontWeight, .semibold)
        XCTAssertEqual(theme(weight: .bold).fontWeight, .bold)
    }

    func testFontStyleMapsToTheItalicFlag() {
        XCTAssertFalse(theme(fontStyle: .normal).isItalic)
        XCTAssertTrue(theme(fontStyle: .italic).isItalic)
    }

    // MARK: custom style mapping

    func testCustomStyleMapsEveryPrimitive() {
        let theme = HiPayCardTheme(style: brandStyle())
        XCTAssertEqual(theme.textColor, Color(hiPayArgb: 0xFF1A237E))
        XCTAssertEqual(theme.placeholderColor, Color(hiPayArgb: 0xFF7986CB))
        XCTAssertEqual(theme.iconColor, Color(hiPayArgb: 0xFF3949AB))
        XCTAssertEqual(theme.invalidTextColor, Color(hiPayArgb: 0xFFC62828))
        XCTAssertEqual(theme.fontSize, 18)
        XCTAssertEqual(theme.fontWeight, .medium)
        XCTAssertTrue(theme.isItalic)
        XCTAssertEqual(theme.borderColor, Color(hiPayArgb: 0xFF3949AB))
        XCTAssertEqual(theme.borderWidth, 2)
        XCTAssertEqual(theme.cornerRadius, 20)
        XCTAssertEqual(theme.backgroundColor, Color(hiPayArgb: 0xFFE8EAF6))
        XCTAssertEqual(theme.fieldHeight, 64)
    }

    func testPerPropertyOverrideFromTheDefault() {
        // The Swift-side override ergonomics: mutate a value-type copy of the default.
        var theme = HiPayCardTheme.hipayDefault
        theme.cornerRadius = 4
        XCTAssertEqual(theme.cornerRadius, 4)
        XCTAssertNotEqual(theme, .hipayDefault)
        XCTAssertEqual(theme.fieldHeight, HiPayCardTheme.hipayDefault.fieldHeight)
    }

    // MARK: helpers

    private func theme(
        weight: HiPayFontWeight = .regular,
        fontStyle: HiPayFontStyle = .normal
    ) -> HiPayCardTheme {
        HiPayCardTheme(
            style: HiPayCardEntryStyle.companion.hipayDefault.doCopy(
                textColor: 0xFF111111,
                placeholderColor: 0xFF8E8E93,
                iconColor: 0xFF8E8E93,
                invalidTextColor: 0xFFD32F2F,
                fontFamily: nil,
                fontSize: 16,
                fontStyle: fontStyle,
                fontWeight: weight,
                borderColor: 0xFFC7C7CC,
                borderWidth: 1,
                cornerRadius: 12,
                backgroundColor: 0xFFFFFFFF,
                fieldHeight: 42
            )
        )
    }

    private func brandStyle() -> HiPayCardEntryStyle {
        HiPayCardEntryStyle(
            textColor: 0xFF1A237E,
            placeholderColor: 0xFF7986CB,
            iconColor: 0xFF3949AB,
            invalidTextColor: 0xFFC62828,
            fontFamily: nil,
            fontSize: 18,
            fontStyle: .italic,
            fontWeight: .medium,
            borderColor: 0xFF3949AB,
            borderWidth: 2,
            cornerRadius: 20,
            backgroundColor: 0xFFE8EAF6,
            fieldHeight: 64
        )
    }
}
