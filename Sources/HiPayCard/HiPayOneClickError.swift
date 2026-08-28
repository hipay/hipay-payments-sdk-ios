// PCI: com.hipay.card path — never log here; masked pan + expiry only, never a token.
import HiPayCore
import HiPayPayments

/// A transient one-click payment failure published by `HiPayCardEntryController` — the Swift
/// face of the KMP `OneClickError`, keeping Kotlin types off the public surface. Carries the
/// affected card's masked identity plus a reason; set inside `payWithSavedCard(_:...)` (the call
/// still throws/returns exactly as before — this is additive), cleared on the next attempt, on
/// any selection change, on a new-card field edit, and by a `refreshSavedCards()` that no longer
/// lists the affected card.
public struct HiPayOneClickError: Equatable {
    /// Why the attempt failed — mirrors the shared KMP `OneClickErrorReason`.
    public enum Reason {
        /// The gateway returned a declined transaction for the attempt.
        case declined
        /// The stored token was rejected as no longer usable — the card has been purged locally.
        case tokenInvalid
        /// A 3DS challenge was presented and failed or was cancelled/abandoned.
        case threeDSFailed
        /// The attempt failed on a card whose expiry had already passed at attempt time.
        case expired
        /// Any other transient failure (network/server/client) — the card stays usable.
        case generic
        /// Not a failure: the attempt is still being confirmed — surfaced as a soft hint.
        case pending
    }

    /// The KMP error (identity matching + surface policy). Module-internal by design.
    let kmp: OneClickError

    init(_ kmp: OneClickError) {
        self.kmp = kmp
    }

    /// Backend-masked pan of the affected card (BIN6 + last4) — never the raw PAN.
    public var maskedPan: String { kmp.maskedPan }
    /// Affected card's expiry month, "MM".
    public var expiryMonth: String { kmp.expiryMonth }
    /// Affected card's expiry year as persisted ("YYYY", possibly "YY").
    public var expiryYear: String { kmp.expiryYear }

    /// Why the attempt failed.
    public var reason: Reason {
        switch kmp.reason {
        case .declined: return .declined
        case .tokenInvalid: return .tokenInvalid
        case .threeDsFailed: return .threeDSFailed
        case .expired: return .expired
        case .generic: return .generic
        case .pending: return .pending
        // Forward-compat fallback only — every KMP reason above is mapped explicitly, so a
        // new one shows up as an unmapped case here (the Kotlin `messageKey()` still renders it).
        default: return .generic
        }
    }

    /// True when `card` is the card this error is about (masked-pan + expiry identity —
    /// stable across reloads and cosmetic re-masks).
    public func matches(_ card: HiPaySavedCard) -> Bool {
        kmp.matches(card: card.kmp)
    }

    /// The localized message key for this error (resolved via `HiPayCardStrings`).
    var messageKey: CardEntryStringKey {
        kmp.reason.messageKey() // KMP extension, exported as a category on the reason enum
    }

    public static func == (lhs: HiPayOneClickError, rhs: HiPayOneClickError) -> Bool {
        lhs.kmp == rhs.kmp // KMP value equality (card identity + reason)
    }
}

extension HiPayTransactionState {
    /// The KMP mirror of this state, for the shared one-click outcome mapper.
    var kmp: TransactionState {
        switch self {
        case .completed: return .completed
        case .forwarding: return .forwarding
        case .pending: return .pending
        case .declined: return .declined
        case .error: return .error
        }
    }
}
