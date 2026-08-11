import Foundation
import AuthenticationServices
import Combine
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

    /// The most recent one-click failure, as a transient observable outcome (the sibling of
    /// ``lastSaveOutcome`` for the pay path): the affected card's masked identity plus a reason.
    /// Set inside `payWithSavedCard(_:...)` — the call still throws/returns exactly as before;
    /// this is additive. Cleared at the start of the next attempt, on any selection change, on a
    /// new-card field edit, and by a ``refreshSavedCards()`` that no longer lists the affected
    /// card. The component renders it via the shared surface policy; hosts may read it too.
    @Published public private(set) var lastOneClickError: HiPayOneClickError?

    // MARK: - One-click UI state (rendered by HiPayCardEntryView only when opted in)

    /// Explicit integrator opt-in for the one-click (saved cards) UI — off by default: without it
    /// the component renders and behaves exactly as before and no card store is ever created.
    /// Headless-host note: once ``refreshSavedCards()`` has pre-selected a saved card, a plain
    /// ``pay(orderId:amount:currency:description:language:redirectScheme:authenticationIndicator:signature:customer:shipping:threeDS:saveCard:)``
    /// routes to that stored token (no CVV) — call ``selectNewCard()`` first to force card entry.
    public let oneClickEnabled: Bool

    /// How many saved cards the one-click UI shows before a "Show more" control (story 12-9).
    /// Clamped to 1...10 (default 3); bounds only the DISPLAY — every saved card is still persisted.
    public let savedCardsDisplayCount: Int

    /// The saved cards offered for one-click, most recently used/saved first (expired cards
    /// purged); empty when none or not loaded. Refreshed via ``refreshSavedCards()``.
    @Published public private(set) var savedCards: [HiPaySavedCard] = []

    /// The active selection: a saved card (entry fields collapsed, values preserved) or nil =
    /// the new-card branch. Never points outside ``savedCards``.
    @Published public private(set) var selectedSavedCard: HiPaySavedCard?

    /// The in-frame "save this card" switch state (consent) — default OFF, reset after each
    /// successful save (consent is per-transaction).
    @Published public private(set) var saveCardOptIn = false

    /// Select `card` (collapses the entry fields — their values are preserved). Ignored when the
    /// card is not one of ``savedCards``.
    public func selectSavedCard(_ card: HiPaySavedCard) {
        if savedCards.contains(card) {
            selectedSavedCard = card
            lastOneClickError = nil // a new intent supersedes the previous failure
        }
    }

    /// Select the new-card branch (expands the entry fields).
    public func selectNewCard() {
        selectedSavedCard = nil
        lastOneClickError = nil // a new intent supersedes the previous failure
    }

    /// Save-switch handler (called from the component's toggle).
    public func onSaveCardOptInChange(_ optIn: Bool) {
        saveCardOptIn = optIn
    }

    // True once the first load has run: the first load pre-selects the most recent card; later
    // re-appearance loads must NOT (they preserve the payer's current choice — see `reload`).
    private var hasLoadedOnce = false

    /// (Re)loads ``savedCards`` for the component. Called on appearance and on each re-appearance.
    /// The selection is PRESERVED across a reload when it still resolves to a present card (a
    /// re-appearance must never silently switch the payer back to a stored card after they picked
    /// "new card"); the most recent card is pre-selected only on the very first load. No-op (and
    /// no store created) unless ``oneClickEnabled``. Headless-host note: this pre-selection makes a
    /// subsequent plain `pay(...)` route to the stored token — call ``selectNewCard()`` to opt back
    /// into card entry.
    public func refreshSavedCards() async {
        await reload(reselectMostRecent: false)
        // An app-foreground refresh drops a stale one-click error unless the affected card is
        // still listed (then it is still the last failure and keeps its inline surface).
        // Never while a pay is in flight: that path sets and manages the error under its own lock
        // (e.g. tokenInvalid set just before its purge+reload) — a concurrent refresh must not wipe it.
        if !isProcessing, let error = lastOneClickError, !savedCards.contains(where: error.matches) {
            lastOneClickError = nil
        }
    }

    /// Removes `card` from the saved-card store (in-component delete, driven by the gesture +
    /// confirmation), then refreshes: a deleted **selected** card drops the selection to the
    /// new-card branch, a **non-selected** one is preserved, the **last** one yields the no-card
    /// state. Fail-visible — a failed store delete leaves the card in the refreshed list. No-op
    /// unless ``oneClickEnabled``.
    public func deleteSavedCard(_ card: HiPaySavedCard) async {
        guard oneClickEnabled else { return }
        await savedCardStore.with { _ = $0.delete(card: card.kmp) }
        await reload(reselectMostRecent: false)
        // Deleting the card an error pointed at is an intent too — once the card is really
        // gone there is nothing left to recover, so don't keep a stale outcome observable.
        if let error = lastOneClickError, error.matches(card),
           !savedCards.contains(where: error.matches) {
            lastOneClickError = nil
        }
    }

    /// Core (re)load. `reselectMostRecent` forces the most-recent card back into the selection
    /// (first load, and after a save / one-click payment); otherwise a still-present selection is
    /// kept and a vanished one (e.g. a purged card) falls back to the new-card branch.
    private func reload(reselectMostRecent: Bool) async {
        guard oneClickEnabled else { return }
        let kmpCards = await savedCardStore.with { $0.list() }
        // Keep only cards whose resolved network the merchant accepts (empty allow-list → all).
        let filtered = kmpCards.filter { card in
            guard let net = CardNetworks.shared.fromApiBrand(brand: card.network) else { return true }
            return AllowedNetworks.shared.isAuthorized(network: net, allowed: effectiveAllowedKmp)
        }
        let cards = filtered.map(HiPaySavedCard.init)
        let firstLoad = !hasLoadedOnce
        hasLoadedOnce = true
        savedCards = cards
        if reselectMostRecent || firstLoad {
            selectedSavedCard = cards.first
        } else if let prev = selectedSavedCard {
            // Keep the current selection if it still resolves; a vanished card → new-card branch.
            selectedSavedCard = cards.first { $0 == prev }
        }
        // else: the payer had chosen "new card" (nil) — leave it untouched.
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

    /// In-module test seam: unit tests fake the backend co-brand verdict through this
    /// (no network); nil in production — `resolveNetworks` then calls the real
    /// `tokenizer`. Same convention as the Android/CMP controllers' resolver seams.
    var cardInfoResolver: ((String) async throws -> CardInfo)?

    /// PAN whose backend BIN verdict left NO allowed network — the only trigger
    /// for the "not authorized" error (contract 2026-07-17). Local detection alone
    /// must never show it: a co-branded card (e.g. CB+Visa with only CB allowed)
    /// locally detects the disallowed brand and would flash a false error until
    /// the verdict lands. @Published so the view re-renders when the verdict does.
    @Published private var unauthorizedDigits: String?
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

    /// Currency the account's accepted card products are resolved for — a contract can differ per
    /// currency. Only used for that resolution; `pay(...)` still takes its own currency.
    private let accountCurrency: String
    /// Card products this ACCOUNT is contracted for. `nil` = not known yet (query pending, or it
    /// failed) → the ceiling stays open and `allowedNetworks` is used as-is. An EMPTY set is a
    /// verdict, not an absence: the account accepts no card at all.
    @Published private var accountNetworks: Set<CardNetwork>?
    /// Guards the one query per controller; reset on failure so a later attempt retries.
    @Published private var accountQueryStarted = false
    /// Set once the first attempt has failed, and never cleared: from then on the component behaves
    /// as it did before the ceiling existed. Without it a retry would hide the brand icon again, so
    /// the payer would watch it blink on every attempt.
    @Published private var accountQueryFailed = false

    /// The ceiling is being fetched and nothing is known yet. While this holds, local BIN detection
    /// must NOT show a brand icon: whether that network is offerable at all is exactly what is in
    /// flight, and showing a logo we may have to take back is worse than showing it a beat later.
    /// True only during the FIRST attempt — a failed query degrades to the pre-ceiling behaviour.
    private var accountCeilingPending: Bool {
        accountQueryStarted && accountNetworks == nil && !accountQueryFailed
    }
    /// The allowed set every check must read: the account ceiling, narrowed by `allowedNetworks`.
    /// The intersection itself is the commonMain one (no set logic in Swift).
    /// `nil` = no restriction at all; an EMPTY array = a restriction that authorizes nothing (an
    /// account contracted for no card). The two must never be conflated — see `AllowedNetworks`.
    private var effectiveAllowedKmp: [CardNetwork]? {
        AllowedNetworks.shared.effectiveAllowed(account: accountNetworks, integrator: allowedKmp)
    }
    /// In-module test seam for the account ceiling — same convention as `cardInfoResolver`.
    var accountNetworksResolver: (() async throws -> Set<CardNetwork>)?

    /// Test seam that presets the ceiling SYNCHRONOUSLY. A test asserting network chips must not race
    /// an asynchronous fetch: with only `accountNetworksResolver` the ceiling lands a `Task` later, the
    /// pending state legitimately suppresses every chip until then, and the assertion becomes
    /// timing-dependent. Tests that are ABOUT the fetch keep using the resolver.
    func presetAccountNetworks(_ accepted: Set<CardNetwork>) {
        accountNetworks = accepted
        accountQueryStarted = true
    }

    /// The VAULT verdict and the PAN it belongs to. Kept apart from `resolvedNetworks`, which
    /// `setNetworks` also fills from local BIN detection: re-applying a ceiling from that would let
    /// local detection alone raise the "not authorized" error on an ambiguous co-brand, which the
    /// contract forbids, and could apply one card's networks to another card's number.
    private var vaultNetworks: [HiPayCardNetwork] = []
    private var vaultDigits: String?

    /// SDK-wide forced locale from `configuration.settings` (or nil), as a `Locale`. The per-surface
    /// `HiPayCardStrings.localeOverride` still takes precedence; the view passes this to `loc`.
    var settingsLocaleOverride: Locale? {
        guard let code = configuration.settings?.localeOverrideValue else { return nil }
        return Locale(identifier: code)
    }

    private var localeCancel: (() -> Void)?

    public init(
        configuration: HiPayConfiguration,
        allowedNetworks: [HiPayCardNetwork] = [],
        oneClickEnabled: Bool = false,
        savedCardsDisplayCount: Int = 3,
        currency: String = "EUR"
    ) {
        self.configuration = configuration
        self.allowedNetworks = allowedNetworks
        self.oneClickEnabled = oneClickEnabled
        // Mirrors the shared Kotlin contract (SavedCardsDisplayCount.kt): default 3, clamp 1...10.
        self.savedCardsDisplayCount = max(1, min(10, savedCardsDisplayCount))
        self.accountCurrency = currency
        // Re-render the card when the shared HiPaySettings language changes at runtime (no re-init).
        // The shared settings is the KMP type; bridge its change listener to a SwiftUI republish.
        localeCancel = configuration.settings?.addLocaleListener { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    deinit { localeCancel?() }

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

    // Each edit is a fresh payment intent → it supersedes a showing one-click error.

    /// Holder name, shaped by the shared sanitizer (KMP): uppercased; letters,
    /// spaces and - ' . accepted; at most 8 digits; hard-capped at 60 chars.
    func holderEdited() {
        lastOneClickError = nil
        let formatted = CardValidators.shared.sanitizeHolder(input: holder)
        if formatted != holder { holder = formatted }
    }

    /// Card number, auto-formatted per detected network while typing
    /// (Amex 4-6-5, others groups of 4 — KMP rules).
    func numberEdited() {
        lastOneClickError = nil
        // Cap to the DETECTED network's complete length (Android/CMP parity):
        // Visa 16 / Amex 15 / BCMC 17, 19 while UNKNOWN so early typing is
        // never blocked. Detect on the new digits.
        let digits = cardNumber.filter(\.isNumber)
        let detected = CardNetworks.shared.detect(number: digits)
        let capped = String(digits.prefix(Int(CardNetworks.shared.completionLength(network: detected))))
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
        // Nothing is offered while the account ceiling is still pending — see `accountCeilingPending`.
        let locallyDetected = accountCeilingPending ? [] : (local.map { [$0] } ?? [])
        guard CardValidators.shared.isCardNumberValid(number: digits) else {
            lastResolvedDigits = nil
            userDidSelect = false
            setNetworks(locallyDetected)
            return
        }
        // Same gate as the BIN verdict, kept identical across the three channels: the account
        // ceiling is asked once per controller, the verdict once per distinct PAN.
        ensureAccountNetworks()
        guard digits != lastResolvedDigits else { return }
        lastResolvedDigits = digits
        // New card: drop any prior manual choice and show its local icon
        // immediately (clears a stale co-brand from the previous number).
        userDidSelect = false
        setNetworks(locallyDetected)
        // A verdict belongs to the PAN it was resolved for: drop the previous one now, or a ceiling
        // landing before the new verdict would apply the old card's networks.
        vaultNetworks = []
        vaultDigits = nil
        Task { await resolveNetworks(for: digits) }
    }

    private func resolveNetworks(for digits: String) async {
        let year = String((Calendar.current.component(.year, from: Date())) + 1)
        do {
            let info: CardInfo
            if let resolver = cardInfoResolver {
                info = try await resolver(digits)
            } else {
                info = try await tokenizer.resolveCardInfo(
                    cardNumber: digits, expiryMonth: "12", expiryYear: year
                )
            }
            guard digits == panDigits else { return } // user kept typing
            let resolved = info.resolvedNetworks().compactMap { HiPayCardNetwork($0) }
            if !resolved.isEmpty {
                // Kept so a later-arriving ceiling can be applied to this verdict without a second
                // vault call, and under the PAN it was resolved for.
                vaultNetworks = resolved
                vaultDigits = digits
                // Whether these networks are offerable at all is still in flight: applying them now
                // would show a brand icon the ceiling may withdraw a moment later. `reapplyCeiling`
                // applies the verdict as soon as the ceiling is known.
                guard !accountCeilingPending else { return }
                applyVaultVerdict(digits, resolved)
            }
        } catch {
            // Resolution failed (offline, rejected): keep the local single icon
            // and allow a retry of the same number on the next edit.
            if digits == panDigits { lastResolvedDigits = nil }
        }
    }

    /// One account-ceiling query per controller. The view asks on appearance; this is the fallback
    /// for a host that drives the controller without the view.
    private func ensureAccountNetworks() {
        guard !accountQueryStarted else { return }
        accountQueryStarted = true
        Task { await loadAccountNetworks() }
    }

    /// Resolves the networks this account is contracted for — the ceiling the merchant restriction
    /// narrows. A technical failure leaves the ceiling OPEN (unchanged behaviour, entry never
    /// blocked, no error) and re-arms a retry on the next edit, exactly like `resolveNetworks`. A
    /// successful EMPTY answer is a verdict, not a failure: the account takes no card.
    private func loadAccountNetworks() async {
        do {
            if let resolver = accountNetworksResolver {
                accountNetworks = try await resolver()
            } else {
                accountNetworks = try await GatewayClient(config: configuration.kmpConfig)
                    .getAvailablePaymentProducts(
                        paymentProducts: CardNetworks.shared.cardPaymentProductCodes,
                        currency: accountCurrency,
                        customerCountry: nil
                    )
            }
            reapplyCeiling()
        } catch {
            if Task.isCancelled {
                // The view went away mid-flight: the ceiling is neither resolved nor failed, so the
                // one-shot guard must be released or the next appearance would never ask again.
                accountQueryStarted = false
                return
            }
            // Degrade to the pre-ceiling behaviour and re-arm a retry, without ever hiding the brand
            // icon again (see `accountQueryFailed`).
            accountQueryFailed = true
            accountQueryStarted = false
            reapplyCeiling()
            return
        }
        // Deliberately OUTSIDE the `do` above: the saved-card list is filtered by the same allowed
        // set and is loaded by a sibling `.task` reading the local Keychain — a race the network
        // always loses — so it must be re-filtered once the ceiling is known, and its own failure
        // must not undo the ceiling we just resolved.
        if oneClickEnabled { await reload(reselectMostRecent: false) }
    }

    /// Called from the view on appearance, so the ceiling is being resolved while the payer is still
    /// reading the form rather than after they have typed a BIN.
    func loadAccountNetworksIfNeeded() async {
        guard !accountQueryStarted else { return }
        accountQueryStarted = true
        await loadAccountNetworks()
    }

    /// Applies a vault verdict against the current allowed set — the ONE place that decides between
    /// "offer these networks" and the contractual not-authorized error, so the vault path and the
    /// ceiling path can never drift.
    private func applyVaultVerdict(_ digits: String, _ resolved: [HiPayCardNetwork]) {
        setNetworks(resolved)
        // Nothing left offered → the contractual "not authorized" error (`networkError`).
        unauthorizedDigits = networks.isEmpty ? digits : nil
    }

    /// The ceiling can land after the payer has already typed: re-derive the offered set and the
    /// not-authorized verdict for the number currently in the field, reusing the vault verdict
    /// already obtained FOR THAT NUMBER — never a second network call, and never local detection,
    /// which must not raise the error on its own.
    private func reapplyCeiling() {
        let digits = panDigits
        if vaultDigits == digits, !vaultNetworks.isEmpty {
            applyVaultVerdict(digits, vaultNetworks)
        } else {
            let local = HiPayCardNetwork(CardNetworks.shared.detect(number: digits))
            setNetworks(accountCeilingPending ? [] : (local.map { [$0] } ?? []))
        }
    }

    private func setNetworks(_ resolved: [HiPayCardNetwork]) {
        resolvedNetworks = resolved
        // Offered = resolved ∩ allowed (commonMain logic, story 5.1 — NOT
        // reimplemented here); empty allowed → all resolved. Only offered
        // networks are shown/selectable as chips.
        let offered = AllowedNetworks.shared
            .offered(resolved: resolved.map { $0.kmpNetwork }, allowed: effectiveAllowedKmp)
            .compactMap { HiPayCardNetwork($0) }
        networks = offered
        // Keep an EXPLICIT user choice if still offered; otherwise default to
        // the first (the domestic co-brand on a backend refinement — e.g. CB).
        if !userDidSelect || selectedNetwork.map({ offered.contains($0) }) != true {
            selectedNetwork = offered.first
        }
        // The effective network (selected co-brand) may differ from the locally detected
        // one and change the CVC policy (e.g. a backend-resolved co-branded Maestro drops
        // it). Re-cap / clear a now-stale CVC (parity with Android's applyOffered).
        cvc = isCvcRequired ? String(cvc.prefix(cvcMaxLength)) : ""
    }

    /// Expiry as "MM/YY": the slash is appended as soon as the month's 2
    /// digits are typed — but not while deleting, so backspace can cross it.
    func expiryEdited() {
        lastOneClickError = nil
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
        lastOneClickError = nil
        let formatted = String(cvc.filter(\.isNumber).prefix(cvcMaxLength))
        if formatted != cvc { cvc = formatted }
    }

    // MARK: - Network-driven rules (KMP)

    private var panDigits: String { cardNumber.filter(\.isNumber) }
    private var expiryMonth: String { String(expiry.prefix(2)) }
    private var expiryYear: String {
        expiry.count == 5 ? "20" + expiry.suffix(2) : ""
    }

    /// Effective network: the selected co-brand when present, else local detection —
    /// the CVC policy follows the payer's co-brand choice (Android/CMP parity).
    var network: CardNetwork {
        selectedNetwork?.kmpNetwork ?? CardNetworks.shared.detect(number: panDigits)
    }
    // Co-brand aware: a mono Maestro requires a CVC, a co-branded one does not.
    var isCvcRequired: Bool {
        CardNetworks.shared.isCvcRequired(network: network, offered: networks.map(\.kmpNetwork))
    }
    var cvcMaxLength: Int { Int(CardNetworks.shared.cvcLength(network: network)) }
    var isNumberComplete: Bool { CardNetworks.shared.isNumberComplete(number: panDigits) }
    var isExpiryComplete: Bool { expiry.count == 5 }
    var isCvcComplete: Bool { !isCvcRequired || cvc.count == cvcMaxLength }

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
        return HiPayCardStrings.localized(key, override: settingsLocaleOverride)
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
        return message(for: CardFieldValidation.shared.cvcReason(
            cvc: cvc, network: network, offered: networks.map(\.kmpNetwork)
        ))
    }

    // MARK: - Allowed networks (story 5.7 / D13)

    /// Whether the entered card's network is accepted. No restriction at all (`nil` effective
    /// allowed set) → always true; an unresolved/UNKNOWN card → true (not flagged). False only when
    /// the card resolved to network(s) and NONE survive the restriction (i.e. the offered set —
    /// computed by the commonMain `AllowedNetworks` in `setNetworks` — is empty).
    ///
    /// Reads the EFFECTIVE set, not `allowedNetworks`: with the account ceiling in play, an empty
    /// integrator list no longer means "everything is accepted".
    var isNetworkAuthorized: Bool {
        effectiveAllowedKmp == nil || resolvedNetworks.isEmpty || !networks.isEmpty
    }

    /// "Network not authorized" inline message — backend-verdict-gated
    /// (contractual, not blur-gated unlike expiry/CVV; value-free): shown as
    /// soon as the BIN verdict for the CURRENT number leaves no allowed
    /// network. The comparison with panDigits clears it on any further edit.
    var networkError: String? {
        guard let digits = unauthorizedDigits, digits == panDigits else { return nil }
        return message(for: ValidationReason.networkNotAuthorized)
    }

    /// The message + a11y identifier for the number field's error slot. The
    /// "network not authorized" error takes precedence over the Luhn/incomplete
    /// error: if the merchant does not accept the card's network there is no
    /// point completing the number, so surface that first. (Co-brand caveat: for
    /// a restrictive allowed list, a still-incomplete card whose LOCAL network is
    /// disallowed may briefly show "not accepted" until backend resolution adds
    /// an allowed co-brand — it clears then.)
    /// Unrepairable prefix — no supported network can ever match the typed
    /// digits (e.g. leading "1" or "30"). Immediate like `networkError` (no
    /// blur gate): further typing cannot fix it, so waiting for focus loss
    /// only delays the user.
    var patternError: String? {
        guard !panDigits.isEmpty,
              !CardNetworks.shared.isPrefixViable(number: panDigits) else { return nil }
        return message(for: ValidationReason.invalidNumber)
    }

    /// Locally UNAMBIGUOUS network rejection — shown immediately during focus (not
    /// blur-gated, no backend needed) when the detected network can never be a co-brand
    /// of any allowed one (e.g. Amex detected, only CB allowed). The AMBIGUOUS cases
    /// (Visa/MC detected with an allowed domestic co-brand like CB) stay backend-gated
    /// via `networkError` — a real co-branded card is never flashed as rejected while
    /// typing (contract 2026-07-17 + refinement 2026-07-20). Guarded on an empty offered
    /// set so a resolved allowed co-brand always wins.
    var localNetworkError: String? {
        guard networks.isEmpty,
              AllowedNetworks.shared.isLocallyUnauthorized(
                  detected: CardNetworks.shared.detect(number: panDigits), allowed: effectiveAllowedKmp
              ) else { return nil }
        return message(for: ValidationReason.networkNotAuthorized)
    }

    var numberSlotError: (message: String, id: String)? {
        if let e = networkError { return (e, "hipay.card.error.network") }
        if let e = patternError { return (e, "hipay.card.error.number") }
        if let e = localNetworkError { return (e, "hipay.card.error.network") }
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
        (oneClickEnabled && selectedSavedCard != nil)
            || (!holder.isEmpty
                && CardValidators.shared.isHolderLongEnough(holder: holder)
                && CardValidators.shared.isCardNumberValid(number: panDigits)
                && CardNetworks.shared.isPrefixViable(number: panDigits)
                && isExpiryComplete
                && CardValidators.shared.isExpiryDateValid(month: expiryMonth, year: expiryYear)
                && CardValidators.shared.isExpiryYearWithinHorizon(
                    year: expiryYear, maxYearsAhead: CardValidators.shared.EXPIRY_HORIZON_YEARS)
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
        // One-click routing: with a saved card selected, the same host call pays via the
        // stored token — no tokenization, no CVV; the host's single touch-point is preserved.
        if oneClickEnabled, let routedCard = selectedSavedCard {
            // A one-click payment saves nothing — clear any stale outcome from an earlier
            // new-card pay so the host never reads a save result against this transaction.
            lastSaveOutcome = nil
            // payWithSavedCard refreshes the saved-card state itself, inside its processing lock,
            // on COMPLETED and on cardNoLongerValid — so there is no post-unlock double-tap window.
            return try await payWithSavedCard(
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
        }
        // The component's save switch and the parameter express the same consent.
        let effectiveSave = saveCard || (oneClickEnabled && saveCardOptIn)
        if effectiveSave { lastSaveOutcome = nil }
        // Lock the fields for the whole flow (incl. the suspended 3DS); reset on every exit (11.14).
        isProcessing = true
        defer { isProcessing = false }
        // Capture the chosen network BEFORE tokenize() clears the component state.
        // Falls back to the LOCALLY DETECTED network, never to a hardcoded brand: while the account
        // ceiling is still pending there is no selected network, and a blind "visa" would declare the
        // wrong instrument for any other card.
        let paymentProduct = (selectedNetwork ?? HiPayCardNetwork(CardNetworks.shared.detect(number: panDigits)))?
            .paymentProductCode ?? "visa"
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
            await reload(reselectMostRecent: true) // the new card appears, pre-selected for the next payment
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
        lastOneClickError = nil // a fresh attempt supersedes the previous outcome
        // Sampled before the (possibly long) 3DS round-trip: the reason must reflect the
        // card as it was when the payer tapped Pay.
        let expiredAtAttempt = OneClickErrorKt.savedCardExpiredNow(card: card.kmp)
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
                // Set BEFORE the purge+reload so the error survives the card vanishing
                // (the component then shows its section-level notice).
                lastOneClickError = HiPayOneClickError(OneClickError(card: card.kmp, reason: .tokenInvalid))
                // Definitive gateway verdict: purge the stale card, then surface the error.
                await savedCardStore.with { _ = $0.delete(card: card.kmp) }
                // Refresh inside the processing lock (the defer below still holds it), so the purged
                // card is gone and the selection has fallen back to new-card before the host unlocks.
                await reload(reselectMostRecent: false)
            } else {
                lastOneClickError = HiPayOneClickError(OneClickError(card: card.kmp, reason: .generic))
            }
            throw error
        }
        let challenged = willPresent3DS(tx)
        let final: HiPayTransaction
        do {
            final = try await resolve3DS(tx, redirectScheme: redirectScheme, signature: signature, threeDS: threeDS)
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch {
            // Any failure during the 3DS phase must be observable — including non-HiPayError throws
            // from the presentation launch itself (e.g. no presenter/URL to open the challenge), which
            // a HiPayError-only catch let slip through as a null error. The host still gets the rethrow;
            // task cancellation is never relabelled.
            lastOneClickError = HiPayOneClickError(OneClickError(card: card.kmp, reason: .generic))
            throw error
        }
        if let reason = OneClickErrorKt.oneClickReasonForOutcome(
            finalState: final.state.kmp,
            challenged: challenged,
            authenticationStatus: final.threeDSecureAuthenticationStatus,
            cardExpiredAtAttempt: expiredAtAttempt
        ) {
            lastOneClickError = HiPayOneClickError(OneClickError(card: card.kmp, reason: reason))
        }
        if final.state == .completed {
            await savedCardStore.with { _ = $0.touch(card: card.kmp) }
            // Refresh inside the lock (the touched card is now MRU and re-selected) so there is no
            // post-unlock double-tap window on the store read.
            await reload(reselectMostRecent: true)
        }
        return final
    }

    /// 3DS resolution shared by `pay` and `payWithSavedCard` — behaviour unchanged from `pay`.
    private func resolve3DS(
        _ tx: HiPayTransaction,
        redirectScheme: String,
        signature: String?,
        threeDS: HiPayThreeDSMode
    ) async throws -> HiPayTransaction {
        // No 3DS → already final (the shared willPresent3DS guard — also feeds the one-click
        // `challenged` flag, so the two can never drift).
        guard willPresent3DS(tx), let url = tx.forwardUrl else {
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

    /// The single decides-a-challenge-is-presented guard for `resolve3DS` — also feeds the
    /// one-click `challenged` flag, so the two can never drift.
    private func willPresent3DS(_ tx: HiPayTransaction) -> Bool {
        guard tx.state == .forwarding, let url = tx.forwardUrl else { return false }
        return !url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
