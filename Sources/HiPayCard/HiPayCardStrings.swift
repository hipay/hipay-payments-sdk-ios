import Foundation
import HiPayFullservice

/// Resolves the shared card-entry i18n keys (`CardEntryStringKey`, story 5.1) to
/// localized text from the HiPayCard bundle catalogs (FR/EN/IT, story 5.2).
///
/// The device locale is used by default; a locale with no catalog falls back to
/// EN (the package's `defaultLocalization`). Set ``localeOverride`` to force a
/// specific language. The Android (Compose) component mirrors this resolution
/// against `strings.xml` (story 7.3).
///
/// `key.name` is the Kotlin enum constant name (e.g. `"LABEL_HOLDER"`), which is
/// exactly the `.strings` key — the key-parity guard
/// (`scripts/check-i18n-parity.sh`) fails the build if any value is missing, so
/// resolution never silently returns a raw key in shipped builds.
public enum HiPayCardStrings {

    /// Optional locale override. When set, strings resolve from that language's
    /// `.lproj`; when `nil` (default) the device locale is used with EN fallback.
    public static var localeOverride: Locale?

    /// Localized text for a shared card-entry key.
    ///
    /// Precedence: the per-surface ``localeOverride`` static → the SDK-wide `override` (from
    /// `HiPayConfiguration.settings`) → the device locale. All matched case-insensitively.
    public static func localized(_ key: CardEntryStringKey, override settingsOverride: Locale? = nil) -> String {
        let name = key.name
        if let forced = localeOverride ?? settingsOverride, let code = forced.languageCode?.lowercased() {
            // Forced language: resolve from its catalog; if that language has no
            // catalog, fall back to the EN baseline — never silently to the
            // device locale (review P3, matches `defaultLocalization`).
            let lproj = Bundle.module.path(forResource: code, ofType: "lproj")
                ?? Bundle.module.path(forResource: "en", ofType: "lproj")
            if let path = lproj, let bundle = Bundle(path: path) {
                return bundle.localizedString(forKey: name, value: name, table: nil)
            }
        }
        // Default (no override): resolve the DEVICE's preferred language explicitly. Calling
        // `Bundle.module.localizedString` directly selects via the resource sub-bundle's own
        // `preferredLocalizations`, which SPM caps to its `CFBundleDevelopmentRegion` (EN) and which
        // does NOT follow the device locale — so a French device would wrongly get EN. Match the
        // language ourselves against the device preference order (uncapped), then load that catalog
        // directly, mirroring the override branch above and the CMP renderer's
        // `NSLocale.preferredLanguages` resolution.
        let preferred = Bundle.preferredLocalizations(
            from: Bundle.module.localizations,
            forPreferences: Locale.preferredLanguages
        ).first ?? "en"
        let lproj = Bundle.module.path(forResource: preferred, ofType: "lproj")
            ?? Bundle.module.path(forResource: "en", ofType: "lproj")
        if let path = lproj, let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: name, value: name, table: nil)
        }
        return Bundle.module.localizedString(forKey: name, value: name, table: nil)
    }
}
