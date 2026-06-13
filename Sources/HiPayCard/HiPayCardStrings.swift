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
    public static func localized(_ key: CardEntryStringKey) -> String {
        let name = key.name
        if let override = localeOverride,
           let code = override.languageCode,
           let path = Bundle.module.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle.localizedString(forKey: name, value: name, table: nil)
        }
        return Bundle.module.localizedString(forKey: name, value: name, table: nil)
    }
}
