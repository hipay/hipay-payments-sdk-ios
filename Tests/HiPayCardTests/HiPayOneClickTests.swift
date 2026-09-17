import Foundation
import HiPayCore
import HiPayPayments
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

    /// The display count is exposed clamped. Asserted against the SHARED Kotlin constants, not against
    /// Swift literals: the point of the check is that iOS cannot drift from the single-sourced bounds,
    /// and a test written with its own copies of 1/3/10 would keep passing after a divergence.
    @MainActor
    func test_savedCardsDisplayCount_defaultsToAndClampsToTheSharedKotlinBounds() {
        let expectedDefault = Int(SavedCardsDisplayCountKt.DEFAULT_SAVED_CARDS_DISPLAY_COUNT)
        let expectedMin = Int(SavedCardsDisplayCountKt.MIN_SAVED_CARDS_DISPLAY_COUNT)
        let expectedMax = Int(SavedCardsDisplayCountKt.MAX_SAVED_CARDS_DISPLAY_COUNT)
        XCTAssertEqual(expectedDefault, HiPayCardEntryController(configuration: configuration).savedCardsDisplayCount)
        XCTAssertEqual(expectedMin, HiPayCardEntryController(configuration: configuration, savedCardsDisplayCount: expectedMin - 1).savedCardsDisplayCount)
        XCTAssertEqual(expectedMax, HiPayCardEntryController(configuration: configuration, savedCardsDisplayCount: expectedMax + 1).savedCardsDisplayCount)
        // An in-range value passes through untouched.
        XCTAssertEqual(expectedDefault + 1, HiPayCardEntryController(configuration: configuration, savedCardsDisplayCount: expectedDefault + 1).savedCardsDisplayCount)
        // A value that would trap a plain Int32 conversion still clamps instead of crashing.
        XCTAssertEqual(expectedMax, HiPayCardEntryController(configuration: configuration, savedCardsDisplayCount: Int.max).savedCardsDisplayCount)
        XCTAssertEqual(expectedMin, HiPayCardEntryController(configuration: configuration, savedCardsDisplayCount: Int.min).savedCardsDisplayCount)
    }

    @MainActor
    func test_refresh_loadsAndPreselectsThePersistedCard() async {
        XCTAssertTrue(makeStore().save(card: seededCard(), consentGiven: true))
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true).withOfflineCeiling()
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

    /// Seeds 3 cards in order, so the store's MRU-first list is [CARD THREE, CARD TWO, CARD ONE].
    private func seedCards() {
        let store = makeStore()
        for (i, spec) in [
            ("411111xxxxxx1111", "VISA", "CARD ONE"),
            ("510510xxxxxx2222", "MASTERCARD", "CARD TWO"),
            ("411111xxxxxx3333", "VISA", "CARD THREE"),
        ].enumerated() {
            XCTAssertTrue(store.save(
                card: SavedCard(
                    token: String(repeating: String(i), count: 64),
                    maskedPan: spec.0, network: spec.1, holder: spec.2,
                    expiryMonth: "12", expiryYear: "2031"
                ),
                consentGiven: true
            ))
        }
    }

    // MARK: - The new-card row toggles both ways (mirrored in the Kotlin controllers)

    @MainActor
    func test_collapseNewCard_returnsToTheCardTheExpandWasLeftFrom() async {
        seedCards()
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true).withOfflineCeiling()
        await controller.refreshSavedCards()
        // Not the pre-selected MRU, so a fallback to the first card cannot pass by accident.
        let chosen = controller.savedCards[1]
        controller.selectSavedCard(chosen)

        controller.selectNewCard()
        XCTAssertNil(controller.selectedSavedCard)
        XCTAssertTrue(controller.canCollapseNewCard)

        controller.collapseNewCard()
        XCTAssertEqual(chosen, controller.selectedSavedCard)
        XCTAssertFalse(controller.canCollapseNewCard) // nothing left to collapse back to
    }

    /// The remembered card can be deleted while the fields are open. An inert control would look
    /// broken for a reason the payer cannot see, so it falls back to the most recent one.
    @MainActor
    func test_collapseNewCard_fallsBackToTheMostRecentWhenTheRememberedCardIsGone() async {
        seedCards()
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true).withOfflineCeiling()
        await controller.refreshSavedCards()
        let chosen = controller.savedCards[1]
        controller.selectSavedCard(chosen)
        controller.selectNewCard()
        await controller.deleteSavedCard(chosen)
        // The deleted card was not the selected one (that is the new-card branch), so the delete
        // re-selected nothing and the fields are still open.
        XCTAssertNil(controller.selectedSavedCard)

        controller.collapseNewCard()
        XCTAssertEqual(controller.savedCards.first, controller.selectedSavedCard)
    }

    @MainActor
    func test_collapseNewCard_isANoOpWithoutSavedCards() async {
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true).withOfflineCeiling()
        await controller.refreshSavedCards()
        XCTAssertFalse(controller.canCollapseNewCard)
        controller.collapseNewCard()
        XCTAssertNil(controller.selectedSavedCard) // still the new-card branch
    }

    // MARK: - The load-settled flag the component gates its entry fields on

    @MainActor
    func test_savedCardsLoaded_isFalseUntilTheFirstLoadSettles() async {
        seedCards()
        let controller = HiPayCardEntryController(configuration: configuration, oneClickEnabled: true).withOfflineCeiling()
        XCTAssertFalse(controller.savedCardsLoaded)
        await controller.refreshSavedCards()
        XCTAssertTrue(controller.savedCardsLoaded)
        // Set LAST, so the component never renders a settled load with no selection applied.
        XCTAssertEqual(controller.savedCards.first, controller.selectedSavedCard)
    }

    /// Fail-open: the flag means "nothing more is coming". Left false on the opted-out early exit,
    /// the component would hide its entry fields for good.
    @MainActor
    func test_savedCardsLoaded_settlesEvenWithOneClickOff() async {
        let controller = HiPayCardEntryController(configuration: configuration) // opt-in off
        await controller.refreshSavedCards()
        XCTAssertTrue(controller.savedCardsLoaded)
    }

    // MARK: - The phase a host reads to show its own progress wording

    /// Idle is `nil`. The running phases need a live order call, so they are covered on the Kotlin
    /// controllers, which have an order seam this one has no equivalent of.
    @MainActor
    func test_paymentPhase_isNilWhileIdle() {
        XCTAssertNil(HiPayCardEntryController(configuration: configuration).paymentPhase)
    }
}
