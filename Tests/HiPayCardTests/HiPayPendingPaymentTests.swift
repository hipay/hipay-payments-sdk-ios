import XCTest
import HiPayPayments
@testable import HiPayCard
@testable import HiPayCore

/// The recovery store against the real Keychain, and the rule that turns a lost connection into an
/// indeterminate outcome rather than a failure.
final class HiPayPendingPaymentTests: XCTestCase {

    private let configuration = HiPayConfiguration(
        username: "swift-recovery-test-user",
        password: "pw",
        environment: .stage
    )

    private func recovery() -> HiPayPaymentRecovery { hiPayPaymentRecovery(configuration: configuration) }

    override func setUp() async throws {
        try await clearAll()
    }

    override func tearDown() async throws {
        try await clearAll()
    }

    private func clearAll() async throws {
        for payment in try await recovery().unresolvedPayments() {
            _ = try await recovery().acknowledge(orderId: payment.orderId)
        }
    }

    func testASubmittedPaymentIsListedThenCompletedByItsAnswer() async throws {
        let store = createPendingPaymentStore(configuration: configuration)

        _ = store.record(orderId: "SW-1", amount: "12.00", currency: "EUR")

        var listed = try await recovery().unresolvedPayments()
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?.orderId, "SW-1")
        XCTAssertEqual(listed.first?.lastState, .pending)
        // Nothing links this order to a transaction yet, and the host must be able to tell.
        XCTAssertFalse(listed.first?.referenceKnown ?? true)

        _ = store.complete(orderId: "SW-1", reference: "800000000001", state: .completed)

        listed = try await recovery().unresolvedPayments()
        XCTAssertEqual(listed.first?.lastState, .completed)
        XCTAssertTrue(listed.first?.referenceKnown ?? false)
    }

    func testAResolvedPaymentSurvivesUntilItIsAcknowledged() async throws {
        let store = createPendingPaymentStore(configuration: configuration)
        _ = store.record(orderId: "SW-2", amount: "12.00", currency: "EUR")
        _ = store.complete(orderId: "SW-2", reference: "ref", state: .completed)

        // Deleting on resolution would lose the very case this exists for: a host that dies between
        // receiving the outcome and recording it.
        let seen = try await recovery().unresolvedPayments()
        XCTAssertEqual(seen.count, 1)

        let removed = try await recovery().acknowledge(orderId: "SW-2")
        XCTAssertTrue(removed.boolValue)
        let after = try await recovery().unresolvedPayments()
        XCTAssertTrue(after.isEmpty)
    }

    func testTheStoreSurvivesAFreshFacade() async throws {
        let store = createPendingPaymentStore(configuration: configuration)
        _ = store.record(orderId: "SW-3", amount: "12.00", currency: "EUR")

        // A facade built from scratch, sharing nothing in memory with the store above — the closest a
        // hosted test gets to asking after a process death.
        let seen = try await hiPayPaymentRecovery(configuration: configuration).unresolvedPayments()
        XCTAssertEqual(seen.first?.orderId, "SW-3")
    }

    func testAnOrderLeftWithoutAReferenceIsListedAsSuch() async throws {
        let store = createPendingPaymentStore(configuration: configuration)
        _ = store.record(orderId: "SW-4", amount: "12.00", currency: "EUR")

        // The host has to be able to tell that nothing links this order to a transaction yet.
        // Refreshing it is what asks the gateway from the order id, and that needs the network.
        let listed = try await recovery().unresolvedPayments()
        XCTAssertEqual(listed.first?.lastState, .pending)
        XCTAssertFalse(listed.first?.referenceKnown ?? true)

        // An order this device never launched is answered from the store alone, with no network.
        let unknown = try await recovery().refreshPayment(orderId: "NEVER-LAUNCHED", signature: nil)
        XCTAssertNil(unknown)
    }

    func testALostConnectionIsIndeterminateNotAFailure() async throws {
        let outcome = try await indeterminateOnTransportFailure { throw HiPayError.network }

        // The gateway may well have taken the payment: a failure here is what would make a host
        // refuse an order that was charged.
        XCTAssertEqual(outcome.state, .pending)
        XCTAssertNil(outcome.transactionReference)
    }

    func testAnAnswerFromTheGatewayStaysAFailure() async throws {
        // Only a transport failure is indeterminate. A refusal is an answer, and stays one.
        do {
            _ = try await indeterminateOnTransportFailure { throw HiPayError.cardNoLongerValid }
            XCTFail("a gateway verdict must not be swallowed")
        } catch HiPayError.cardNoLongerValid {
            // expected
        }
    }
}
