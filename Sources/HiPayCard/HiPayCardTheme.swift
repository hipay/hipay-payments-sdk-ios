import SwiftUI
import HiPayFullservice

/// SwiftUI-native appearance of `HiPayCardEntryView`, built from the shared cross-platform
/// `HiPayCardEntryStyle` contract (the single source of truth for colors, typography and
/// field metrics across iOS, Android and Compose Multiplatform).
///
/// Construct it from a shared style — `HiPayCardTheme(style: myBrandStyle)` — or start from
/// [hipayDefault] and override per property (value semantics):
///
/// ```swift
/// var theme = HiPayCardTheme.hipayDefault
/// theme.cornerRadius = 4
/// theme.borderColor = Color(red: 0, green: 0.33, blue: 1)
/// ```
///
/// `fieldHeight` is a MINIMUM: fields grow when content needs more room (large Dynamic Type
/// sizes must never clip the entered card data). `fontFamily` on the contract is reserved
/// (null = system font) — the theme always renders the system family in this release.
///
/// Validation: the metric properties enforce the shared contract's bounds — mutating them to
/// a non-finite or out-of-range value stops with a clear message at the mutation site
/// (fail-fast at integration time, never rendered wrong). Note that constructing the KOTLIN
/// `HiPayCardEntryStyle` from Swift with invalid values terminates the process with the
/// Kotlin `IllegalArgumentException` (Kotlin-initializer exceptions are not catchable from
/// Swift) — prefer starting from a valid style and overriding on the theme.
///
/// The default theme is light-mode (the cross-platform unified baseline): on a dark host
/// background, pass a dark-adapted style/theme until dedicated dark-theme support ships.
public struct HiPayCardTheme: Equatable, Sendable {
    /// Entered-text color (and the caret).
    public var textColor: Color
    /// Placeholder text color; also secondary content (section headers, consent line,
    /// saved-card sub-line) — mirrors the CMP/Android renderers. Placeholders themselves
    /// take this color from iOS 17; iOS 15/16 render the system placeholder gray (which the
    /// default value matches).
    public var placeholderColor: Color
    /// Tint for the monochrome glyphs: the neutral card silhouette and the CVV info glyph.
    /// Brand network logos are never re-tinted — unselected chips dim by opacity instead
    /// (several brand marks sit on opaque plates that a tint would flatten).
    public var iconColor: Color
    /// Inline validation-error text (and the invalid-field border).
    public var invalidTextColor: Color
    /// Entered-text size in points at the default Dynamic Type size (scales with it).
    /// Must be finite and > 0.
    public var fontSize: CGFloat {
        didSet { Self.requireFinite(fontSize, "fontSize", atLeast: .leastNormalMagnitude) }
    }
    /// Entered-text weight.
    public var fontWeight: Font.Weight
    /// Entered-text style (the contract's ITALIC).
    public var isItalic: Bool
    /// Field outline color.
    public var borderColor: Color
    /// Field outline width in points. Must be finite and >= 0.
    public var borderWidth: CGFloat {
        didSet { Self.requireFinite(borderWidth, "borderWidth", atLeast: 0) }
    }
    /// Field (and saved-card cell) corner radius in points. Must be finite and >= 0.
    public var cornerRadius: CGFloat {
        didSet { Self.requireFinite(cornerRadius, "cornerRadius", atLeast: 0) }
    }
    /// Field (and saved-card cell) container color.
    public var backgroundColor: Color
    /// MINIMUM field height in points — the field grows beyond it with content.
    /// Must be finite and > 0.
    public var fieldHeight: CGFloat {
        didSet { Self.requireFinite(fieldHeight, "fieldHeight", atLeast: .leastNormalMagnitude) }
    }

    /// The SDK's default look — the SwiftUI projection of the shared contract's
    /// `HiPayCardEntryStyle.hipayDefault` (identical baseline across platforms).
    public static let hipayDefault = HiPayCardTheme()

    /// Pre-existing name of the default look, kept for source compatibility.
    @available(*, deprecated, renamed: "hipayDefault")
    public static let `default` = hipayDefault

    /// Maps the shared platform-neutral contract to SwiftUI types.
    public init(style: HiPayCardEntryStyle = HiPayCardEntryStyle.companion.hipayDefault) {
        textColor = Color(hiPayArgb: style.textColor)
        placeholderColor = Color(hiPayArgb: style.placeholderColor)
        iconColor = Color(hiPayArgb: style.iconColor)
        invalidTextColor = Color(hiPayArgb: style.invalidTextColor)
        fontSize = CGFloat(style.fontSize)
        fontWeight = Self.weight(style.fontWeight)
        isItalic = style.fontStyle == HiPayFontStyle.italic
        borderColor = Color(hiPayArgb: style.borderColor)
        borderWidth = CGFloat(style.borderWidth)
        cornerRadius = CGFloat(style.cornerRadius)
        backgroundColor = Color(hiPayArgb: style.backgroundColor)
        fieldHeight = CGFloat(style.fieldHeight)
    }

    /// The entered-text font. `scale` carries the host's Dynamic Type factor (see
    /// `@ScaledMetric` at the call site) so the themed font keeps scaling like the system
    /// font it replaces; the system family is always used (contract `fontFamily` reserved).
    public func font(scale: CGFloat = 1) -> Font {
        let base = Font.system(size: fontSize * scale, weight: fontWeight)
        return isItalic ? base.italic() : base
    }

    private static func weight(_ weight: HiPayFontWeight) -> Font.Weight {
        // Kotlin enum entries are exported as class instances — no Swift switch.
        // Fallback .regular; a contract addition trips the exported-entries test.
        if weight == .medium { return .medium }
        if weight == .semibold { return .semibold }
        if weight == .bold { return .bold }
        return .regular
    }

    // Same bounds as the shared contract — a styling value must fail fast at the
    // integrator's mutation site, never render an unusable payment form.
    private static func requireFinite(_ value: CGFloat, _ name: String, atLeast: CGFloat) {
        precondition(
            value.isFinite && value >= atLeast,
            "HiPayCardTheme.\(name) must be finite and \(atLeast > 0 ? "> 0" : ">= 0"), got \(value)"
        )
    }
}

extension Color {
    /// ARGB packed in an `Int64` (`0xAARRGGBB`, the shared contract encoding, sRGB) → Color.
    init(hiPayArgb argb: Int64) {
        self.init(
            .sRGB,
            red: Double((argb >> 16) & 0xFF) / 255,
            green: Double((argb >> 8) & 0xFF) / 255,
            blue: Double(argb & 0xFF) / 255,
            opacity: Double((argb >> 24) & 0xFF) / 255
        )
    }
}
