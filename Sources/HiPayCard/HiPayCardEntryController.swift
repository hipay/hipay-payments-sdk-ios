import Foundation
import HiPayCore
import HiPayFullservice

/// Owns the card-entry state INSIDE the library boundary: the host creates
/// the controller, embeds `HiPayCardEntryView`, and calls `tokenize()` from
/// its own pay button — it never reads the PAN (PCI boundary, NFR2).
///
/// All rules (network detection, formatting, completion, CVC policy,
/// validation) come from the KMP layer — no logic in Swift (D1). The view
/// binds the raw field values and re-applies formatting from `.onChange`
/// via the `*Edited()` handlers (see their comment for the SwiftUI
/// rendering constraint).
///
/// v1 accepted limit (documented threat model): the controller lives in the
/// host process memory; binary isolation of the card path is the post-v1
/// PCI-DSS step (FR18).
@MainActor
public final class HiPayCardEntryController: ObservableObject {

    // Field state is internal: visible to the entry view, opaque to the host.
    // Settable by the view's TextFields (same module); reformatted in the
    // *Edited() handlers below.
    @Published var holder: String = ""
    @Published var cardNumber: String = ""
    @Published var expiry: String = ""
    @Published var cvc: String = ""

    private var previousExpiry: String = ""
    // CVC length + requirement of the last detected network — used to clear a
    // CVV that no longer fits when the network changes.
    private var previousCvcContext: (length: Int, required: Bool)?

    // MARK: - Network resolution (icons / co-branding)

    /// Networks to display, default-selected first. Backend-resolved (incl.
    /// co-brand CB/BCMC) once the number is valid; before that, the locally
    /// BIN-detected single network — empty shows the neutral icon.
    @Published public private(set) var networks: [HiPayCardNetwork] = []
    /// The network the order should use (`payment_product`). Defaults to the
    /// co-brand when present; the user may change it via `selectNetwork`.
    @Published public private(set) var selectedNetwork: HiPayCardNetwork?

    private let configuration: HiPayConfiguration
    private lazy var tokenizer = CardTokenizer(config: configuration.kmpConfig)
    // BIN already resolved against the backend — avoids re-querying per keystroke.
    private var lastResolvedDigits: String?
    // True only after an explicit user tap — so a backend refinement keeps the
    // user's co-brand choice but otherwise re-defaults to the domestic network.
    private var userDidSelect = false

    public init(configuration: HiPayConfiguration) {
        self.configuration = configuration
    }

    /// The host picks one of `networks` (co-branding choice). Ignored if the
    /// network is not among the currently offered ones.
    public func selectNetwork(_ network: HiPayCardNetwork) {
        if networks.contains(network) {
            selectedNetwork = network
            userDidSelect = true
        }
    }

    // MARK: - Field updates (live formatting, called from the view's onChange)
    // A TextField only re-renders a transformed value when the write happens
    // OUTSIDE its own edit transaction: writing from the binding setter or a
    // didSet renders on focus loss only (iOS 15/16). The view therefore binds
    // the raw @Published value and calls these handlers from .onChange — the
    // second assignment here is what reformats live. The `!=` guards
    // terminate the onChange -> write -> onChange recursion.

    /// Holder name, forced to upper case (max 60 chars, FR11).
    func holderEdited() {
        let formatted = String(holder.uppercased().prefix(60))
        if formatted != holder { holder = formatted }
    }

    /// Card number, auto-formatted per detected network while typing
    /// (Amex 4-6-5, others groups of 4 — KMP rules).
    func numberEdited() {
        // Explicit 19-digit cap (max PAN length) — don't rely on format()'s
        // group template as the de-facto length limit.
        let capped = String(cardNumber.filter(\.isNumber).prefix(19))
        let formatted = CardNetworks.shared.format(number: capped)
        if formatted != cardNumber { cardNumber = formatted }

        // A CVV is network-specific: when the detected network's CVC rule
        // changes (e.g. Amex 4-digit -> another network's 3-digit, or
        // required <-> not required), a CVV typed for the previous network no
        // longer fits — clear it rather than carry a stale/wrong-length value.
        let context = (length: cvcMaxLength, required: isCvcRequired)
        if let previous = previousCvcContext, previous != context, !cvc.isEmpty {
            cvc = ""
        }
        previousCvcContext = context

        refreshNetworks()
    }

    // MARK: - Network resolution

    /// Local BIN detection drives an immediate single icon; once the number is
    /// complete and valid, the backend refines it (adds the CB/BCMC co-brand).
    private func refreshNetworks() {
        let digits = panDigits
        let local = HiPayCardNetwork(CardNetworks.shared.detect(number: digits))

        // Resolve once the number is Luhn-valid (12-19) — NOT on the
        // network-specific completion length: a real 16-digit BCMC card is
        // valid before our 17-digit "complete" heuristic, and the legacy
        // likewise triggers on validity. Local detection drives the icon
        // meanwhile.
        guard CardValidators.shared.isCardNumberValid(number: digits) else {
            lastResolvedDigits = nil
            userDidSelect = false
            setNetworks(local.map { [$0] } ?? [])
            return
        }
        guard digits != lastResolvedDigits else { return }
        lastResolvedDigits = digits
        // New card: drop any prior manual choice and show its local icon
        // immediately (clears a stale co-brand from the previous number).
        userDidSelect = false
        setNetworks(local.map { [$0] } ?? [])
        Task { await resolveNetworks(for: digits) }
    }

    private func resolveNetworks(for digits: String) async {
        let year = String((Calendar.current.component(.year, from: Date())) + 1)
        do {
            let info = try await tokenizer.resolveCardInfo(
                cardNumber: digits, expiryMonth: "12", expiryYear: year
            )
            guard digits == panDigits else { return } // user kept typing
            let resolved = info.resolvedNetworks().compactMap { HiPayCardNetwork($0) }
            if !resolved.isEmpty { setNetworks(resolved) }
        } catch {
            // Resolution failed (offline, rejected): keep the local single icon
            // and allow a retry of the same number on the next edit.
            if digits == panDigits { lastResolvedDigits = nil }
        }
    }

    private func setNetworks(_ list: [HiPayCardNetwork]) {
        networks = list
        // Keep an EXPLICIT user choice if still offered; otherwise default to
        // the first (the domestic co-brand on a backend refinement — e.g. CB).
        if userDidSelect, let sel = selectedNetwork, list.contains(sel) { return }
        selectedNetwork = list.first
    }

    /// Expiry as "MM/YY": the slash is appended as soon as the month's 2
    /// digits are typed — but not while deleting, so backspace can cross it.
    func expiryEdited() {
        let digits = String(expiry.filter(\.isNumber).prefix(4))
        let isDeleting = expiry.count < previousExpiry.count
        let formatted: String
        if digits.count >= 3 {
            formatted = "\(digits.prefix(2))/\(digits.dropFirst(2))"
        } else if digits.count == 2 && !isDeleting {
            formatted = digits + "/"
        } else {
            formatted = digits
        }
        previousExpiry = formatted
        if formatted != expiry { expiry = formatted }
    }

    /// CVC, capped to the network's length (4 for Amex, 3 otherwise).
    func cvcEdited() {
        let formatted = String(cvc.filter(\.isNumber).prefix(cvcMaxLength))
        if formatted != cvc { cvc = formatted }
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
    /// pay button with this (`.disabled(!controller.canPay)`).
    public var canPay: Bool {
        !holder.isEmpty
            && CardValidators.shared.isCardNumberValid(number: panDigits)
            && isExpiryComplete
            && CardValidators.shared.isExpiryDateValid(month: expiryMonth, year: expiryYear)
            && isCvcComplete
    }

    /// Tokenizes the entered card, creates the order, and returns the
    /// transaction — the card token is created and consumed ENTIRELY inside the
    /// SDK and never crosses to the host (the host only ever sees the
    /// `HiPayTransaction`). The PAN/CVC are cleared once tokenized.
    ///
    /// On a 3DS challenge the returned transaction is `.forwarding`: open its
    /// `forwardUrl`, then confirm via `HiPayPayment.getTransaction(reference:)`
    /// on the return deep link (the token is not needed past this point).
    ///
    /// The `signature` is the HS signature of orderId+amount+currency, computed
    /// by your backend — the SDK never computes it.
    public func pay(
        orderId: String,
        amount: String,
        currency: String = "EUR",
        description: String,
        language: String = "en_GB",
        redirectScheme: String,
        authenticationIndicator: Int = 0,
        signature: String? = nil
    ) async throws -> HiPayTransaction {
        // Capture the chosen network BEFORE tokenize() clears the component state.
        let paymentProduct = selectedNetwork?.paymentProductCode ?? "visa"
        let token = try await tokenize()
        let payment = HiPayPayment(configuration: configuration)
        return try await payment.requestCardOrder(
            orderId: orderId,
            amount: amount,
            currency: currency,
            description: description,
            language: language,
            cardToken: token.token,
            paymentProduct: paymentProduct,
            redirectScheme: redirectScheme,
            authenticationIndicator: authenticationIndicator,
            signature: signature
        )
    }

    /// Tokenizes against HiPay Secure Vault. Internal: the token never leaves
    /// the SDK — `pay()` consumes it directly. PAN/CVC are cleared on success.
    func tokenize(multiUse: Bool = false) async throws -> HiPayCardToken {
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
            networks = []
            selectedNetwork = nil
            lastResolvedDigits = nil
            userDidSelect = false
            return HiPayCardToken(kmpToken)
        } catch {
            throw HiPayError.from(error)
        }
    }
}
