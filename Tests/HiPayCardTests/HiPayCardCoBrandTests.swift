import Foundation
import HiPayCore
import HiPayPayments
import XCTest
@testable import HiPayCard

/// PI-6078 — co-branded network prioritization on the Swift controller. NETWORK-FREE:
/// the backend BIN verdict is faked through the `cardInfoResolver` seam (the Swift
/// sibling of the Android/CMP resolver seams) — the "domestic co-brand first,
/// default-selected" rule and the manual-selection contract are what's under test;
/// the real vault call never fires. Mirrors `CmpCoBrandResolutionTest` /
/// `CardEntryCoBrandTest` (Android).
final class HiPayCardCoBrandTests: XCTestCase {

    // Real co-branded stage test PANs (Luhn-valid): CB+Visa and Bancontact+Mastercard.
    private let cbVisaPan = "4484120000000029"
    private let bcmcMcPan = "5127880999999990"

    private let configuration = HiPayConfiguration(
        username: "cobrand-swift-test-user", password: "pw", environment: .stage
    )

    @MainActor
    private func makeController(
        allowed: [HiPayCardNetwork] = [],
        brand: String,
        domesticNetwork: String
    ) -> HiPayCardEntryController {
        let controller = HiPayCardEntryController(configuration: configuration, allowedNetworks: allowed).withOfflineCeiling()
        controller.cardInfoResolver = { _ in
            CardInfo(brand: brand, domesticNetwork: domesticNetwork, cardType: nil, issuer: nil, country: nil)
        }
        return controller
    }

    /// Drives the number field like the view does (raw write + `numberEdited()`), then
    /// yields the main actor until the faked backend verdict expands the offered set.
    @MainActor
    private func enter(_ pan: String, on controller: HiPayCardEntryController) async {
        controller.cardNumber = pan
        controller.numberEdited()
        var attempts = 0
        while controller.networks.count < 2 && attempts < 1000 {
            attempts += 1
            await Task.yield()
        }
    }

    // PI-6078 — Scénario : Carte CB/Visa — CB priorisé par défaut.
    //   Étant donné que les réseaux activés sont "cb" et "visa"
    //   Quand je saisis un BIN cobrandé "cb" et "visa"
    //   Alors le réseau "cb" est sélectionné par défaut
    //   Et les logos "cb" et "visa" sont affichés (= the offered `networks` chips)
    @MainActor
    func test_cbVisaCoBrand_cbSelectedByDefault_bothLogosOffered() async {
        let controller = makeController(allowed: [.cb, .visa], brand: "VISA", domesticNetwork: "cb")
        await enter(cbVisaPan, on: controller)
        XCTAssertEqual([.cb, .visa], controller.networks)
        XCTAssertEqual(.cb, controller.selectedNetwork)
    }

    // PI-6078 — Scénario : Carte Bancontact/Mastercard — Bancontact priorisé par défaut.
    //   Étant donné que les réseaux activés sont "bancontact" et "mastercard"
    //   Quand je saisis un BIN cobrandé "bancontact" et "mastercard"
    //   Alors le réseau "bancontact" est sélectionné par défaut
    //   Et les logos "bancontact" et "mastercard" sont affichés
    @MainActor
    func test_bancontactMastercardCoBrand_bancontactSelectedByDefault() async {
        let controller = makeController(allowed: [.bcmc, .mastercard], brand: "MASTERCARD", domesticNetwork: "bcmc")
        await enter(bcmcMcPan, on: controller)
        XCTAssertEqual([.bcmc, .mastercard], controller.networks)
        XCTAssertEqual(.bcmc, controller.selectedNetwork)
        // Bancontact never requires a CVC — the policy follows the selected co-brand.
        XCTAssertFalse(controller.isCvcRequired)
        XCTAssertTrue(controller.isCvcComplete)
    }

    // PI-6078 — Scénario : Sélection manuelle du réseau sur une carte cobrandée.
    //   Étant donné qu'un BIN cobrandé CB/Visa est saisi avec "cb" sélectionné par défaut
    //   Quand l'utilisateur sélectionne manuellement "visa" via le bouton visa
    //   Alors le réseau "cb" est désélectionné
    //   Et le réseau "visa" est sélectionné
    @MainActor
    func test_manualSelectionOnCoBrandedCard_visaSelectedCbDeselected() async {
        let controller = makeController(allowed: [.cb, .visa], brand: "VISA", domesticNetwork: "cb")
        await enter(cbVisaPan, on: controller)
        XCTAssertEqual(.cb, controller.selectedNetwork)

        controller.selectNetwork(.visa)

        // Single selection: picking Visa deselects CB; both chips stay offered.
        XCTAssertEqual(.visa, controller.selectedNetwork)
        XCTAssertEqual([.cb, .visa], controller.networks)
    }

    // Guard for the co-brand-aware CVC policy (Android/CMP parity): a co-branded
    // Maestro drops the CVC requirement once the payer selects it.
    @MainActor
    func test_coBrandedMaestro_dropsTheCvcRequirement() async {
        let controller = makeController(brand: "MAESTRO", domesticNetwork: "cb")
        await enter("5341013985664960", on: controller) // CB+Maestro stage PAN
        XCTAssertEqual([.cb, .maestro], controller.networks)

        controller.selectNetwork(.maestro)

        XCTAssertFalse(controller.isCvcRequired)
        XCTAssertTrue(controller.isCvcComplete)
    }
}
