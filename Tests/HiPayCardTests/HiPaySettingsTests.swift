import Foundation
import HiPayCore
import HiPayPayments
import XCTest
@testable import HiPayCard

/// The shared (KMP) `HiPaySettings` drives string resolution on iOS too, the per-surface
/// `HiPayCardStrings.localeOverride` still wins, matching is case-insensitive, and the Swift
/// `Locale` convenience + change listener work (the SwiftUI reactivity bridge).
final class HiPaySettingsTests: XCTestCase {

    override func tearDown() {
        HiPayCardStrings.localeOverride = nil
        super.tearDown()
    }

    func testSettingsOverrideDrivesLanguage() {
        HiPayCardStrings.localeOverride = nil
        let fr = HiPayCardStrings.localized(.labelHolder, override: Locale(identifier: "fr"))
        XCTAssertEqual(fr, "Nom du titulaire")
    }

    func testCaseInsensitiveLanguageCode() {
        HiPayCardStrings.localeOverride = nil
        let fr = HiPayCardStrings.localized(.labelHolder, override: Locale(identifier: "FR-CA"))
        XCTAssertEqual(fr, "Nom du titulaire")
    }

    func testPerSurfaceOverrideWinsOverSettings() {
        HiPayCardStrings.localeOverride = Locale(identifier: "en")
        let en = HiPayCardStrings.localized(.labelHolder, override: Locale(identifier: "fr"))
        XCTAssertEqual(en, "Cardholder name")
    }

    func testSharedSettingsConvenienceAndListener() {
        let settings = HiPaySettings(localeOverride: nil) // KMP type, shared with Android/CMP
        XCTAssertNil(settings.localeOverrideValue)

        var observed: [String?] = []
        let cancel = settings.addLocaleListener { observed.append($0) }

        settings.setLocaleOverride(Locale(identifier: "FR-CA")) // Swift Locale convenience → "fr"
        XCTAssertEqual(settings.localeOverrideValue, "fr")
        settings.setLocaleOverride(tag: "IT")                   // KMP string form → "it"
        XCTAssertEqual(settings.localeOverrideValue, "it")

        cancel()
        settings.setLocaleOverride(tag: "en")                   // no callback after cancel
        XCTAssertEqual(observed, ["fr", "it"])
    }
}
