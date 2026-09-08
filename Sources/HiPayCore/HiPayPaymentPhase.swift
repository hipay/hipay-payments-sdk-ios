import Foundation

/// Where a payment currently is, for a host that wants to show progress (mirrors the KMP single
/// source of truth). `nil` on the controller means idle.
///
/// Read-only: it reports the flow, it never steers it. A payer-facing label like "contacting your
/// bank" is the host's wording to choose, not the SDK's.
public enum HiPayPaymentPhase: Sendable {
    /// Exchanging the entered card for a vault token. Skipped when paying from a saved card.
    case tokenizing
    /// The order is being created at the gateway.
    case creatingOrder
    /// The payer is in the 3DS challenge, outside the app.
    case authenticating
    /// The challenge came back and the outcome is being confirmed server-side.
    case confirming
}
