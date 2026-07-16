import Foundation
import HiPayFullservice

/// Swift conveniences on the shared `HiPaySettings` (the KMP type used on every platform).
public extension HiPaySettings {

    /// Set the forced UI language from a `Locale` (uses its `languageCode`, matched
    /// case-insensitively). Pass `nil` to clear it (follow the device locale). This complements the
    /// KMP `setLocaleOverride(tag:)` string form. - Since: 0.3.0
    func setLocaleOverride(_ locale: Locale?) {
        setLocaleOverride(tag: locale?.languageCode)
    }
}
