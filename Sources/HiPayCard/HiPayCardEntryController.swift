import Foundation
import HiPayCore
import HiPayFullservice

/// Owns the card-entry state INSIDE the library boundary: the host creates
/// the controller, embeds `HiPayCardEntryView`, and calls `tokenize()` from
/// its own pay button — it never reads the PAN (PCI boundary, NFR2).
///
/// All rules (network detection, formatting, completion, CVC policy,
/// validation) come from the KMP layer — no logic in Swift (D1).
///
/// v1 accepted limit (documented threat model): the controller lives in the
/// host process memory; binary isolation of the card path is the post-v1
/// PCI-DSS step (FR18).
@MainActor
public final class HiPayCardEntryController: ObservableObject {

    // Field state is internal: visible to the entry view, opaque to the host.

    /// Holder name, forced to upper case.
    @Published var holder: String = "" {
        didSet {
            let upper = holder.uppercased()
            if upper != holder { holder = upper }
        }
    }

    /// Card number, auto-formatted per detected network (Amex 4-6-5, others 4-4-4-4).
    @Published var cardNumber: String = "" {
        didSet {
            let formatted = CardNetworks.shared.format(number: cardNumber)
            if formatted != cardNumber { cardNumber = formatted }
        }
    }

    /// Expiry as "MM/YY" with automatic slash insertion.
    @Published var expiry: String = "" {
        didSet {
            let digits = String(expiry.filter(\.isNumber).prefix(4))
            let formatted = digits.count > 2
                ? "\(digits.prefix(2))/\(digits.dropFirst(2))"
                : digits
            if formatted != expiry { expiry = formatted }
        }
    }

    /// CVC, capped to the network's length (4 for Amex, 3 otherwise).
    @Published var cvc: String = "" {
        didSet {
            let capped = String(cvc.filter(\.isNumber).prefix(cvcMaxLength))
            if capped != cvc { cvc = capped }
        }
    }

    private let configuration: HiPayConfiguration

    public init(configuration: HiPayConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Network-driven rules (KMP)

    private var panDigits: String { cardNumber.filter(\.isNumber) }
    private var expiryMonth: String { String(expiry.prefix(2)) }
    private var expiryYear: String {
        expiry.count == 5 ? "20" + expiry.suffix(2) : ""
    }

    var network: CardNetwork { CardNetworks.shared.detect(number: panDigits) }
    var isCvcRequired: Bool { CardNetworks.shared.isCvcRequired(network: network) }
    var cvcMaxLength: Int { Int(CardNetworks.shared.cvcLength(network: network)) }
    var isNumberComplete: Bool { CardNetworks.shared.isNumberComplete(number: panDigits) }
    var isExpiryComplete: Bool { expiry.count == 5 }
    var isCvcComplete: Bool { !isCvcRequired || cvc.count == cvcMaxLength }

    // Live validity — untouched (empty) fields are not flagged.
    var isNumberAcceptable: Bool {
        panDigits.isEmpty || CardValidators.shared.isCardNumberValid(number: panDigits)
    }
    var isExpiryAcceptable: Bool {
        expiry.isEmpty || !isExpiryComplete
            || CardValidators.shared.isExpiryDateValid(month: expiryMonth, year: expiryYear)
    }
    var isHolderAcceptable: Bool {
        CardValidators.shared.isHolderValid(holder: holder)
    }
    var isCvcAcceptable: Bool {
        CardValidators.shared.isCvcValid(cvc: cvc)
    }

    /// True when every required field is filled and valid — drive the host's
    /// pay button with this (`.disabled(!controller.canTokenize)`).
    public var canTokenize: Bool {
        !holder.isEmpty
            && CardValidators.shared.isCardNumberValid(number: panDigits)
            && isExpiryComplete
            && CardValidators.shared.isExpiryDateValid(month: expiryMonth, year: expiryYear)
            && isCvcComplete
    }

    /// Tokenizes the entered card against HiPay Secure Vault. On success the
    /// PAN and CVC fields are cleared (the component no longer needs them)
    /// and the host receives only the token.
    public func tokenize(multiUse: Bool = false) async throws -> HiPayCardToken {
        let tokenizer = CardTokenizer(config: configuration.kmpConfig)
        do {
            let kmpToken = try await tokenizer.generateToken(
                cardNumber: panDigits,
                expiryMonth: expiryMonth,
                expiryYear: expiryYear,
                holder: holder,
                cvc: isCvcRequired ? cvc : "",
                multiUse: multiUse
            )
            cardNumber = ""
            cvc = ""
            return HiPayCardToken(kmpToken)
        } catch {
            throw HiPayError.from(error)
        }
    }
}
