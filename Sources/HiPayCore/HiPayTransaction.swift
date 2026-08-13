import Foundation
import HiPayFullservice

/// Typed transaction state (mirrors the KMP single source of truth).
public enum HiPayTransactionState: Sendable {
    case completed
    case forwarding
    case pending
    case declined
    case error
}

/// Transaction snapshot handed to the host (FR5) — pure Swift (D4).
public struct HiPayTransaction: Sendable {
    public let state: HiPayTransactionState
    public let transactionReference: String?
    /// Non-nil when `state == .forwarding`: open it (browser / SFSafariViewController)
    /// and wait for the return deep link. The SDK never opens UI itself (FR7).
    public let forwardUrl: URL?
    public let status: String?
    public let reason: String?
    public let threeDSecureAuthenticationStatus: String?

    package init(_ kmp: Transaction) {
        switch kmp.state {
        case .completed: state = .completed
        case .forwarding: state = .forwarding
        case .pending: state = .pending
        case .declined: state = .declined
        default: state = .error
        }
        transactionReference = kmp.transactionReference
        let raw = kmp.forwardUrl ?? ""
        forwardUrl = raw.isEmpty ? nil : URL(string: raw)
        status = kmp.status
        reason = kmp.reason
        threeDSecureAuthenticationStatus = kmp.threeDSecure?.authenticationStatus
    }

    private init(state: HiPayTransactionState, transactionReference: String?) {
        self.state = state
        self.transactionReference = transactionReference
        self.forwardUrl = nil
        self.status = nil
        self.reason = nil
        self.threeDSecureAuthenticationStatus = nil
    }

    /// Indeterminate "verification pending" snapshot (story 11.16): the SDK could not reach the server
    /// to confirm a 3DS return, so the real outcome is unknown. `.pending` — NOT `.forwarding` (which
    /// means a server-confirmed not-completed = genuine abort): the host should treat it as awaiting
    /// confirmation and re-query `getTransaction` later, never as a failure or an abort.
    public static func verificationPending(reference: String?) -> HiPayTransaction {
        HiPayTransaction(state: .pending, transactionReference: reference)
    }
}
