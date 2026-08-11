import Foundation
import HiPayCore
import HiPayFullservice
import XCTest
@testable import HiPayCard

/// The account's own contract is the ceiling on what the component may offer, and the integrator's
/// `allowedNetworks` can only narrow it. NETWORK-FREE: both backend answers are faked through the
/// controller's seams (`accountNetworksResolver` for the ceiling, `cardInfoResolver` for the BIN
/// verdict) — no vault or gateway call ever fires. Mirrors `CmpAllowedNetworksGherkinTest` and the
/// Android `CardEntryErrorsTest`.
final class HiPayCardAccountNetworksTests: XCTestCase {

    private let visaPan = "4111111111111111"

    private let configuration = HiPayConfiguration(
        username: "account-networks-test-user", password: "pw", environment: .stage
    )

    @MainActor
    private func makeController(
        allowed: [HiPayCardNetwork] = [],
        account: @escaping () async throws -> Set<CardNetwork>
    ) -> HiPayCardEntryController {
        let controller = HiPayCardEntryController(configuration: configuration, allowedNetworks: allowed)
        controller.cardInfoResolver = { _ in
            CardInfo(brand: "VISA", domesticNetwork: nil, cardType: nil, issuer: nil, country: nil)
        }
        controller.accountNetworksResolver = account
        return controller
    }

    /// Drives the number field like the view does, then yields until both async answers have landed.
    @MainActor
    private func enter(_ pan: String, on controller: HiPayCardEntryController) async {
        controller.cardNumber = pan
        controller.numberEdited()
        for _ in 0..<1000 { await Task.yield() }
    }

    // The reported bug: no integrator restriction at all, and a network the ACCOUNT does not accept
    // must still be refused. Before the ceiling existed, an absent allow-list accepted everything and
    // the refusal only came back as a gateway error once the payer had filled the form.
    @MainActor
    func test_networkTheAccountDoesNotAccept_isRefused_withoutAnyIntegratorRestriction() async {
        let controller = makeController(account: { [CardNetwork.mastercard, CardNetwork.cb] })
        await enter(visaPan, on: controller)

        XCTAssertTrue(controller.networks.isEmpty)
        XCTAssertFalse(controller.isNetworkAuthorized)
    }

    // The other half of the contract: a network the account does accept still works untouched.
    @MainActor
    func test_networkTheAccountAccepts_isOffered() async {
        let controller = makeController(account: { [CardNetwork.visa, CardNetwork.mastercard] })
        await enter(visaPan, on: controller)

        XCTAssertEqual([.visa], controller.networks)
        XCTAssertEqual(.visa, controller.selectedNetwork)
        XCTAssertTrue(controller.isNetworkAuthorized)
    }

    // An integrator cannot authorize what the account cannot process — the gateway would refuse the
    // order anyway.
    @MainActor
    func test_integrator_cannotWidenBeyondTheAccountCeiling() async {
        let controller = makeController(
            allowed: [.visa, .mastercard],
            account: { [CardNetwork.mastercard] }
        )
        await enter(visaPan, on: controller)

        XCTAssertTrue(controller.networks.isEmpty)
        XCTAssertFalse(controller.isNetworkAuthorized)
    }

    // A technical failure must never block entry: the ceiling stays open and nothing is refused. A
    // payment form killed by a network hiccup would be worse than the gap being closed.
    @MainActor
    func test_aFailedAccountQuery_leavesEntryOpen() async {
        struct Offline: Error {}
        let controller = makeController(account: { throw Offline() })
        await enter(visaPan, on: controller)

        XCTAssertEqual([.visa], controller.networks)
        XCTAssertTrue(controller.isNetworkAuthorized)
    }

    // An account contracted for no card product refuses every card — an empty answer is a verdict,
    // not a failure.
    @MainActor
    func test_anAccountWithNoCardProduct_refusesEverything() async {
        let controller = makeController(account: { [] })
        await enter(visaPan, on: controller)

        XCTAssertTrue(controller.networks.isEmpty)
        XCTAssertFalse(controller.isNetworkAuthorized)
    }
}
