// PCI: com.hipay.card path — never log here, never expose the stored token.
import HiPayFullservice

/// A card the payer saved for one-click payment — the Swift face of the KMP
/// `SavedCard` (D4: no Kotlin type on the public surface). Exposes ONLY the
/// display metadata; the reusable payment token stays inside the SDK and is
/// consumed by `HiPayCardEntryController.payWithSavedCard(_:...)`.
public struct HiPaySavedCard: Identifiable, Equatable {
    /// The KMP card (carries the token). Module-internal by design.
    let kmp: SavedCard

    init(_ kmp: SavedCard) {
        self.kmp = kmp
    }

    /// Backend-masked pan (BIN6 + last4, e.g. "411111xxxxxx1111") — never the raw PAN.
    public var maskedPan: String { kmp.maskedPan }
    /// Card brand as persisted at save time (e.g. "VISA").
    public var network: String { kmp.network }
    /// Cardholder name.
    public var holder: String { kmp.holder }
    /// Expiry month, "MM".
    public var expiryMonth: String { kmp.expiryMonth }
    /// Expiry year as persisted ("YYYY", possibly "YY").
    public var expiryYear: String { kmp.expiryYear }

    /// Stable identity for lists — the store's own card identity (masked pan + expiry).
    public var id: String { "\(maskedPan)|\(expiryMonth)|\(expiryYear)" }

    public static func == (lhs: HiPaySavedCard, rhs: HiPaySavedCard) -> Bool {
        lhs.kmp.token == rhs.kmp.token && lhs.id == rhs.id
    }
}
