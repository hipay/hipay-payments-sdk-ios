import Foundation
import HiPayCore
import HiPayFullservice
import XCTest
@testable import HiPayCard

/// One-click surface on the Swift controller — wrapper mapping and the saved-cards
/// accessor over the REAL simulator Keychain. No network: none of these paths
/// reaches the gateway (the pay flows are covered by the shared Kotlin tests).
final class HiPayOneClickTests: XCTestCase {

    private let configuration = HiPayConfiguration(
        username: "oneclick-swift-test-user", password: "pw", environment: .stage
    )

    private func makeStore() -> SecureCardStore {
        createSecureCardStore(configuration: configuration)
    }

    private func seededCard() -> SavedCard {
        SavedCard(
            token: String(repeating: "t", count: 64),
            maskedPan: "411111xxxxxx1111",
            network: "VISA",
            holder: "JANE DOE",
            expiryMonth: "12",
            expiryYear: "2031"
        )
    }

    override func tearDown() {
        _ = makeStore().clearAll()
        super.tearDown()
    }

    func test_wrapper_exposes_display_fields_and_a_stable_id() {
        let wrapped = HiPaySavedCard(seededCard())
        XCTAssertEqual("411111xxxxxx1111", wrapped.maskedPan)
        XCTAssertEqual("VISA", wrapped.network)
        XCTAssertEqual("JANE DOE", wrapped.holder)
        XCTAssertEqual("12", wrapped.expiryMonth)
        XCTAssertEqual("2031", wrapped.expiryYear)
        XCTAssertEqual("411111xxxxxx1111|12|2031", wrapped.id)
    }

    @MainActor
    func test_refresh_loadsAndPreselectsThePersistedCard() async {
        XCTAssertTrue(makeStore().save(card: seededCard(), consentGiven: true))
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true)
        await controller.refreshSavedCards()
        XCTAssertEqual(1, controller.savedCards.count)
        XCTAssertEqual("411111xxxxxx1111", controller.savedCards.first?.maskedPan)
        XCTAssertEqual(controller.selectedSavedCard, controller.savedCards.first)
        XCTAssertTrue(controller.canPay) // one tap away, fields empty
    }

    @MainActor
    func test_refresh_withoutOptIn_isANoOp_andNothingLoads() async {
        XCTAssertTrue(makeStore().save(card: seededCard(), consentGiven: true))
        let controller = HiPayCardEntryController(configuration: configuration) // opt-in off
        await controller.refreshSavedCards()
        XCTAssertTrue(controller.savedCards.isEmpty)
        XCTAssertNil(controller.selectedSavedCard)
    }

    func test_kmp_mapping_helpers_are_reachable_from_swift() {
        // Single-sourced logic (Kotlin): payment product derivation + wrapper round-trip.
        XCTAssertEqual("visa", SavedCardPaymentKt.savedCardPaymentProduct(card: seededCard()))
        let amex = SavedCard(
            token: "t", maskedPan: "371111xxxxx1111", network: "AMERICAN EXPRESS",
            holder: "J", expiryMonth: "01", expiryYear: "2030"
        )
        XCTAssertEqual("american-express", SavedCardPaymentKt.savedCardPaymentProduct(card: amex))
        // Hardened default: an unrecognized stored brand falls back to visa only defensively
        // (savedCardFromToken now refuses to persist such a card in the first place — covered
        // by the shared Kotlin commonTest).
        let unknown = SavedCard(
            token: "t", maskedPan: "411111xxxxxx1111", network: "future-brand",
            holder: "J", expiryMonth: "12", expiryYear: "2031"
        )
        XCTAssertEqual("visa", SavedCardPaymentKt.savedCardPaymentProduct(card: unknown))
    }
}
