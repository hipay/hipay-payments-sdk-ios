import Foundation
import AuthenticationServices
import UIKit
import HiPayCore
import HiPayFullservice

/// How the SDK presents the 3DS challenge when `pay(threeDS:)` hits a `FORWARDING` transaction
/// (story 11.13). Both modes are turnkey — `pay()` returns the FINAL confirmed transaction; the
/// host never calls the headless `getTransaction`/`parseCallback`.
public enum HiPayThreeDSMode {
    /// In-app `ASWebAuthenticationSession` — auto-captures the callback, no soft-lock, no host
    /// wiring needed. The default.
    case inAppSession
    /// External Safari (previous behaviour). The host must forward the return URL once via
    /// `resume3DS(_:)` (e.g. from `.onOpenURL`); the SDK then confirms and `pay()` returns.
    case externalBrowser
}

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

    /// True while a `pay()` is in flight (tokenise → order → 3DS round-trip), set by the SDK
    /// (story 11.14). The card-entry view locks its fields on this; the host disables its own
    /// Pay button with `!canPay || isProcessing`. Read-only — no integrator wiring needed.
    @Published public private(set) var isProcessing: Bool = false

    /// Result of the most recent `pay(saveCard: true)` save attempt, for the host to react to
    /// (e.g. a confirmation or a "card not saved" notice). `nil` when no save was attempted — a
    /// fresh `pay(saveCard: true)` resets it, and it stays nil when the payment does not complete.
    @Published public private(set) var lastSaveOutcome: HiPaySaveOutcome?

    // MARK: - One-click UI state (rendered by HiPayCardEntryView only when opted in)

    /// Explicit integrator opt-in for the one-click (saved cards) UI — off by default: without it
    /// the component renders and behaves exactly as before and no card store is ever created.
    public let oneClickEnabled: Bool

    /// The saved card offered for one-click (most recently used/saved); nil when none/not loaded.
    @Published public private(set) var savedCard: HiPaySavedCard?

    /// True when the saved card is the active selection (entry fields collapsed). Exactly one of
    /// {saved card, new card} is selected at all times once a card exists.
    @Published public private(set) var isSavedCardSelected = false

    /// The in-frame "save this card" switch state (consent) — default OFF, reset after each
    /// successful save (consent is per-transaction).
    @Published public private(set) var saveCardOptIn = false

    /// Select the saved card (collapses the entry fields — their values are preserved).
    public func selectSavedCard() {
        if savedCard != nil { isSavedCardSelected = true }
    }

    /// Select the new-card branch (expands the entry fields).
    public func selectNewCard() {
        isSavedCardSelected = false
    }

    /// Save-switch handler (called from the component's toggle).
    public func onSaveCardOptInChange(_ optIn: Bool) {
        saveCardOptIn = optIn
    }

    /// (Re)loads the saved card and resets the selection to it (MRU pre-selected; none → new
    /// card). Called by the component on appearance and by the pay flows on terminal outcomes;
    /// no-op (and no store created) unless ``oneClickEnabled``.
    public func refreshSavedCards() async {
        guard oneClickEnabled else { return }
        let first = await savedCardStore.with { $0.list().first }
        savedCard = first.map(HiPaySavedCard.init)
        isSavedCardSelected = first != nil
    }

    private let configuration: HiPayConfiguration

    // MARK: - 3DS presentation (story 11.13)
    /// Retained for the in-app session's lifetime + its anchor-window provider.
    private var webAuthSession: ASWebAuthenticationSession?
    private let webAuthContext = WebAuthContextProvider()
    /// Pending external-browser 3DS: `pay()` suspends here until `resume3DS(_:)` confirms, or until
    /// the app returns to the foreground without a callback (then we reconcile with the server).
    private var pending3DS: (continuation: CheckedContinuation<HiPayTransaction, Error>, reference: String?, signature: String?)?
    /// Observes app re-activation to detect a user abort in `.externalBrowser` (story 11.16).
    private var foregroundObserver: NSObjectProtocol?
    private lazy var tokenizer = CardTokenizer(config: configuration.kmpConfig)
    /// Saved-card store, created lazily off the main thread and confined to one
    /// serial queue (the KMP store is not thread-safe).
    private lazy var savedCardStore = SavedCardStoreBox(configuration: configuration)
    // BIN already resolved against the backend — avoids re-querying per keystroke.
    private var lastResolvedDigits: String?
    // True only after an explicit user tap — so a backend refinement keeps the
    // user's co-brand choice but otherwise re-defaults to the domestic network.
    private var userDidSelect = false

    /// Networks the merchant accepts (story 5.7 / D13). Empty = accept all.
    /// `networks` (displayed/selectable) is the resolved set ∩ this list.
    public let allowedNetworks: [HiPayCardNetwork]
    // Full resolved set (local or backend), BEFORE the allowed-networks filter —
    // used for the authorization check.
    private var resolvedNetworks: [HiPayCardNetwork] = []
    private var allowedKmp: [CardNetwork] { allowedNetworks.map { $0.kmpNetwork } }

    public init(
        configuration: HiPayConfiguration,
        allowedNetworks: [HiPayCardNetwork] = [],
        oneClickEnabled: Bool = false
    ) {
        self.configuration = configuration
        self.allowedNetworks = allowedNetworks
        self.oneClickEnabled = oneClickEnabled
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

    private func setNetworks(_ resolved: [HiPayCardNetwork]) {
        resolvedNetworks = resolved
        // Offered = resolved ∩ allowed (commonMain logic, story 5.1 — NOT
        // reimplemented here); empty allowed → all resolved. Only offered
        // networks are shown/selectable as chips.
        let offered = AllowedNetworks.shared
            .offered(resolved: resolved.map { $0.kmpNetwork }, allowed: allowedKmp)
            .compactMap { HiPayCardNetwork($0) }
        networks = offered
        // Keep an EXPLICIT user choice if still offered; otherwise default to
        // the first (the domestic co-brand on a backend refinement — e.g. CB).
        if userDidSelect, let sel = selectedNetwork, offered.contains(sel) { return }
        selectedNetwork = offered.first
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

    // MARK: - Inline field errors (story 5.5)

    /// The component's fields, in traversal order (matches the 5.4 a11y sort
    /// priority holder→cvc). Also the `@FocusState` value type for the view.
    public enum Field: Hashable, CaseIterable { case holder, number, expiry, cvc }

    // A field's inline error shows only AFTER it has lost focus once (blur) —
    // so we never flag a field the user hasn't finished. @Published so the view
    // re-renders when a blur is marked.
    @Published private(set) var holderBlurred = false
    @Published private(set) var numberBlurred = false
    @Published private(set) var expiryBlurred = false
    @Published private(set) var cvcBlurred = false

    /// Mark a field touched + blurred so its inline error becomes visible.
    func markBlurred(_ field: Field) {
        switch field {
        case .holder: holderBlurred = true
        case .number: numberBlurred = true
        case .expiry: expiryBlurred = true
        case .cvc: cvcBlurred = true
        }
    }

    /// Reveal every field's error at once — the host calls this from its pay
    /// button on an explicit submit attempt. Does NOT move focus (the host may
    /// focus `firstInvalidField` itself).
    public func revealErrors() {
        holderBlurred = true
        numberBlurred = true
        expiryBlurred = true
        cvcBlurred = true
    }

    // Localized message for a reason, or nil for `.valid` (value-free, NFR2).
    private func message(for reason: ValidationReason) -> String? {
        guard let key = reason.messageKey() else { return nil }
        return HiPayCardStrings.localized(key)
    }

    /// Inline error for each field — nil when the field has not blurred yet or
    /// is valid. Derived from the commonMain `CardFieldValidation` reasons (5.1)
    /// + the localized message keys (5.2). Recompute on every field-text or
    /// blur-flag change (both @Published).
    var holderError: String? {
        guard holderBlurred else { return nil }
        return message(for: CardFieldValidation.shared.holderReason(holder: holder))
    }
    var numberError: String? {
        guard numberBlurred else { return nil }
        return message(for: CardFieldValidation.shared.cardNumberReason(number: panDigits))
    }
    var expiryError: String? {
        guard expiryBlurred else { return nil }
        return message(for: CardFieldValidation.shared.expiryReason(month: expiryMonth, year: expiryYear))
    }
    var cvcError: String? {
        guard cvcBlurred else { return nil }
        return message(for: CardFieldValidation.shared.cvcReason(cvc: cvc, network: network))
    }

    // MARK: - Allowed networks (story 5.7 / D13)

    /// Whether the entered card's network is accepted by the merchant. Empty
    /// allowed list → always true; an unresolved/UNKNOWN card → true (not
    /// flagged). False only when the card resolved to network(s) and NONE are
    /// in the allowed list (i.e. the offered set — computed by the commonMain
    /// `AllowedNetworks` in `setNetworks` — is empty).
    var isNetworkAuthorized: Bool {
        allowedNetworks.isEmpty || resolvedNetworks.isEmpty || !networks.isEmpty
    }

    /// "Network not authorized" inline message — shown under the number field
    /// once it has blurred and the card's network is not accepted (value-free).
    var networkError: String? {
        guard numberBlurred, !isNetworkAuthorized else { return nil }
        return message(for: ValidationReason.networkNotAuthorized)
    }

    /// The message + a11y identifier for the number field's error slot. The
    /// "network not authorized" error takes precedence over the Luhn/incomplete
    /// error: if the merchant does not accept the card's network there is no
    /// point completing the number, so surface that first. (Co-brand caveat: for
    /// a restrictive allowed list, a still-incomplete card whose LOCAL network is
    /// disallowed may briefly show "not accepted" until backend resolution adds
    /// an allowed co-brand — it clears then.)
    var numberSlotError: (message: String, id: String)? {
        if let e = networkError { return (e, "hipay.card.error.network") }
        if let e = numberError { return (e, "hipay.card.error.number") }
        return nil
    }

    /// First field (traversal order) currently showing an error — for the host
    /// to focus on a failed submit. Nil when every field is valid/clean.
    public var firstInvalidField: Field? {
        if holderError != nil { return .holder }
        if numberSlotError != nil { return .number }
        if expiryError != nil { return .expiry }
        if cvcError != nil { return .cvc }
        return nil
    }

    /// True when every required field is filled and valid — drive the host's
    /// pay button with this (`.disabled(!controller.canPay)`). A selected saved
    /// card is always payable — field state is irrelevant on that branch.
    public var canPay: Bool {
        (oneClickEnabled && isSavedCardSelected && savedCard != nil)
            || (!holder.isEmpty
                && CardValidators.shared.isCardNumberValid(number: panDigits)
                && isExpiryComplete
                && CardValidators.shared.isExpiryDateValid(month: expiryMonth, year: expiryYear)
                && isCvcComplete
                && isNetworkAuthorized) // a disallowed network blocks pay
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
    /// With `saveCard` `true` (the payer's explicit consent — the save switch state), the card
    /// is tokenized as reusable and persisted to the secure card store, but ONLY once this call
    /// itself observes a final COMPLETED (directly, or through the SDK-managed 3DS). A PENDING
    /// outcome never saves; storage failures are silent — the payment result is unaffected.
    public func pay(
        orderId: String,
        amount: String,
        currency: String = "EUR",
        description: String,
        language: String = "en_GB",
        redirectScheme: String,
        authenticationIndicator: Int = 0,
        signature: String? = nil,
        customer: HiPayCustomerInfo? = nil,
        shipping: HiPayCustomerInfo? = nil,
        threeDS: HiPayThreeDSMode = .inAppSession,
        saveCard: Bool = false
    ) async throws -> HiPayTransaction {
        // One-click routing: with the saved card selected, the same host call pays via the
        // stored token — no tokenization, no CVV; the host's single touch-point is preserved.
        if oneClickEnabled, isSavedCardSelected, let routedCard = savedCard {
            do {
                let final = try await payWithSavedCard(
                    routedCard,
                    orderId: orderId,
                    amount: amount,
                    currency: currency,
                    description: description,
                    language: language,
                    redirectScheme: redirectScheme,
                    authenticationIndicator: authenticationIndicator,
                    signature: signature,
                    customer: customer,
                    shipping: shipping,
                    threeDS: threeDS
                )
                if final.state == .completed { await refreshSavedCards() }
                return final
            } catch let error as HiPayError {
                // The purged card must leave the UI and the selection falls back to entry.
                if case .cardNoLongerValid = error { await refreshSavedCards() }
                throw error
            }
        }
        // The component's save switch and the parameter express the same consent.
        let effectiveSave = saveCard || (oneClickEnabled && saveCardOptIn)
        if effectiveSave { lastSaveOutcome = nil }
        // Lock the fields for the whole flow (incl. the suspended 3DS); reset on every exit (11.14).
        isProcessing = true
        defer { isProcessing = false }
        // Capture the chosen network BEFORE tokenize() clears the component state.
        let paymentProduct = selectedNetwork?.paymentProductCode ?? "visa"
        let token = try await tokenize(multiUse: effectiveSave)
        let payment = HiPayPayment(configuration: configuration)
        let tx = try await payment.requestCardOrder(
            orderId: orderId,
            amount: amount,
            currency: currency,
            description: description,
            language: language,
            cardToken: token.token,
            paymentProduct: paymentProduct,
            redirectScheme: redirectScheme,
            authenticationIndicator: authenticationIndicator,
            signature: signature,
            customer: customer,
            shipping: shipping
        )
        let final = try await resolve3DS(tx, redirectScheme: redirectScheme, signature: signature, threeDS: threeDS)
        if effectiveSave, final.state == .completed {
            // Fail-soft: the payment outcome is already decided; save() reports failure as a
            // boolean, never a thrown error. Record the outcome for the host (popup/confirmation).
            if let newSavedCard = SavedCardPaymentKt.savedCardFromToken(token: token.kmp) {
                let persisted = await savedCardStore.with { $0.save(card: newSavedCard, consentGiven: true) }
                lastSaveOutcome = persisted ? .saved : .storageFailed
            } else {
                lastSaveOutcome = .notEligible
            }
            saveCardOptIn = false // consent is per-transaction
            await refreshSavedCards() // the new card appears, pre-selected for the next payment
        }
        return final
    }

    /// One-click payment with a previously saved card: the order is created directly from the
    /// stored reusable token — no card re-entry, no CVV, no tokenization round-trip. 3DS behaves
    /// exactly as in `pay(...)` (a challenge still fires when the bank requires it).
    ///
    /// On a final COMPLETED the card's recency is bumped (most-recently-used). If the gateway
    /// reports the stored token as no longer usable, the card is purged from local storage and
    /// `HiPayError.cardNoLongerValid` is thrown — fall back to card entry. A declined payment is
    /// returned as a normal DECLINED transaction.
    public func payWithSavedCard(
        _ card: HiPaySavedCard,
        orderId: String,
        amount: String,
        currency: String = "EUR",
        description: String,
        language: String = "en_GB",
        redirectScheme: String,
        authenticationIndicator: Int = 0,
        signature: String? = nil,
        customer: HiPayCustomerInfo? = nil,
        shipping: HiPayCustomerInfo? = nil,
        threeDS: HiPayThreeDSMode = .inAppSession
    ) async throws -> HiPayTransaction {
        isProcessing = true
        defer { isProcessing = false }
        let payment = HiPayPayment(configuration: configuration)
        let tx: HiPayTransaction
        do {
            tx = try await payment.requestCardOrder(
                orderId: orderId,
                amount: amount,
                currency: currency,
                description: description,
                language: language,
                cardToken: card.kmp.token,
                paymentProduct: SavedCardPaymentKt.savedCardPaymentProduct(card: card.kmp),
                redirectScheme: redirectScheme,
                authenticationIndicator: authenticationIndicator,
                signature: signature,
                customer: customer,
                shipping: shipping,
                oneClick: true
            )
        } catch let error as HiPayError {
            if case .cardNoLongerValid = error {
                // Definitive gateway verdict: purge the stale card, then surface the error.
                await savedCardStore.with { _ = $0.delete(card: card.kmp) }
            }
            throw error
        }
        let final = try await resolve3DS(tx, redirectScheme: redirectScheme, signature: signature, threeDS: threeDS)
        if final.state == .completed {
            await savedCardStore.with { _ = $0.touch(card: card.kmp) }
        }
        return final
    }

    /// The cards previously saved for one-click payment (most recent first, expired cards purged).
    public func savedCards() async -> [HiPaySavedCard] {
        await savedCardStore.with { $0.list().map(HiPaySavedCard.init) }
    }

    /// 3DS resolution shared by `pay` and `payWithSavedCard` — behaviour unchanged from `pay`.
    private func resolve3DS(
        _ tx: HiPayTransaction,
        redirectScheme: String,
        signature: String?,
        threeDS: HiPayThreeDSMode
    ) async throws -> HiPayTransaction {
        // No 3DS → already final.
        guard tx.state == .forwarding, let url = tx.forwardUrl else {
            return tx
        }
        // 3DS challenge: the SDK presents it and returns the FINAL transaction (story 11.13).
        let reference = tx.transactionReference
        switch threeDS {
        case .inAppSession:
            guard let callback = await present3DSInApp(url, callbackScheme: redirectScheme) else {
                // Sheet cancelled → DON'T assume an abort: reconcile with the server,
                // same as the external/CMP paths. The user may have validated 3DS then dismissed.
                return await reconcileOrPending(reference: reference, signature: signature)
            }
            let parsedRef = (try? HiPay.parseCallback(callback))?.queryParams["reference"]
            return await reconcileOrPending(reference: reference ?? parsedRef, signature: signature)
        case .externalBrowser:
            // Open external Safari and suspend until the host forwards the return via resume3DS(_:),
            // or until the user comes back without finishing (abort watcher, story 11.16).
            return try await withCheckedThrowingContinuation { continuation in
                self.pending3DS = (continuation, reference, signature)
                self.armExternalAbortWatcher()
                Task { @MainActor in await UIApplication.shared.open(url) }
            }
        }
    }

    /// Forward the 3DS return URL here (from `.onOpenURL`) for the `.externalBrowser` mode; the SDK
    /// confirms via `getTransaction` and resumes the suspended `pay()`. No-op if none pending or in
    /// `.inAppSession` mode (that captures the callback itself). Story 11.13.
    public func resume3DS(_ url: URL) {
        guard let pending = pending3DS else { return }
        pending3DS = nil
        clearExternalAbortWatcher() // a real callback arrived → stop watching for an abort
        Task { @MainActor in
            let parsedRef = (try? HiPay.parseCallback(url))?.queryParams["reference"]
            let tx = await reconcileOrPending(reference: pending.reference ?? parsedRef, signature: pending.signature)
            pending.continuation.resume(returning: tx)
        }
    }

    /// `.externalBrowser` return detection (story 11.16): external Safari gives no callback, so when
    /// the app returns to the foreground we wait a moment for a possible `resume3DS`, then RECONCILE
    /// with the authoritative server state (FR9) — the user may have completed 3DS without the app
    /// receiving the redirect. Never assume an abort: query `getTransaction` and return the real
    /// outcome (COMPLETED if captured, else the FORWARDING tx = genuinely not completed).
    private func armExternalAbortWatcher() {
        clearExternalAbortWatcher()
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // Give a returning `.onOpenURL` → resume3DS a chance to win first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                Task { @MainActor in self?.reconcileExternalIfStillPending() }
            }
        }
    }

    private func reconcileExternalIfStillPending() {
        guard let pending = pending3DS else { return } // resume3DS already handled it
        pending3DS = nil
        clearExternalAbortWatcher()
        Task { @MainActor in
            // Authoritative state from the captured reference — COMPLETED if the user validated,
            // still FORWARDING if they genuinely abandoned, PENDING if the server is unreachable.
            let tx = await reconcileOrPending(reference: pending.reference, signature: pending.signature)
            pending.continuation.resume(returning: tx)
        }
    }

    private func clearExternalAbortWatcher() {
        if let observer = foregroundObserver {
            NotificationCenter.default.removeObserver(observer)
            foregroundObserver = nil
        }
    }

    /// Presents the 3DS page in-app (ASWebAuthenticationSession) bound to `callbackScheme`; resumes
    /// with the callback URL, or nil if cancelled/errored. Retains the session for its lifetime.
    private func present3DSInApp(_ url: URL, callbackScheme: String) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, _ in
                self?.webAuthSession = nil // release the finished session (don't retain it until the next pay())
                continuation.resume(returning: callbackURL)
            }
            session.presentationContextProvider = webAuthContext
            session.prefersEphemeralWebBrowserSession = false
            webAuthSession = session
            session.start()
        }
    }

    /// The single 3DS-return resolver. Queries `getTransaction` for the
    /// authoritative outcome from the captured `reference` (redirect params are never trusted as the
    /// state). If we can't confirm — no reference, or the server is unreachable — we return an
    /// indeterminate PENDING snapshot ("verification required"), NEVER a false abort or a thrown error,
    /// so the host can re-query later instead of mis-reporting a possibly-captured payment.
    private func reconcileOrPending(reference: String?, signature: String?) async -> HiPayTransaction {
        guard let reference else { return .verificationPending(reference: nil) }
        do {
            return try await HiPayPayment(configuration: configuration).getTransaction(reference: reference, signature: signature)
        } catch {
            return .verificationPending(reference: reference)
        }
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
            holder = ""
            cardNumber = ""
            expiry = ""
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

/// One saved-card store per controller, every access (creation included) serialized on a
/// private queue: the KMP `SecureCardStore` is not thread-safe, and the store contract
/// mandates off-main access. Not @MainActor on purpose — the queue IS the confinement.
private final class SavedCardStoreBox {
    private let queue = DispatchQueue(label: "com.hipay.card.savedcards")
    private let configuration: HiPayConfiguration
    private var store: SecureCardStore?

    init(configuration: HiPayConfiguration) {
        self.configuration = configuration
    }

    func with<T>(_ block: @escaping (SecureCardStore) -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                let store = self.store ?? createSecureCardStore(configuration: self.configuration)
                self.store = store
                continuation.resume(returning: block(store))
            }
        }
    }
}

/// Supplies the anchor window for the in-app 3DS `ASWebAuthenticationSession` (story 11.13).
/// Resolves the current key window globally — no host wiring needed.
private final class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
