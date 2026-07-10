import SwiftUI
import UIKit
import HiPayFullservice

/// Embeddable card-entry component (FR11b): the host drops this view into
/// its own screen; card data never leaves it (the paired
/// `HiPayCardEntryController` exposes only `pay()`/`tokenize()` and `canPay`).
///
/// Layout: holder (upper-cased) on top, card number auto-formatted WHILE
/// TYPING in the middle, expiry MM/YY bottom-left, CVV bottom-right (visible
/// in clear, shown disabled when the network does not require it). Completed
/// fields auto-advance focus; a complete MM/YY focuses the CVV when required,
/// otherwise dismisses the keyboard.
///
/// Accessibility & i18n: labels/placeholders are localized via `HiPayCardStrings`
/// (FR/EN/IT, D11); each field exposes a label + stable `accessibilityIdentifier`;
/// the number field announces the detected network and the chips are accessible
/// buttons with `.isSelected` (5.4). Inline errors (5.5) appear under each field
/// (icon + text, not colour-only) once the field has blurred, and are announced
/// politely without stealing focus. The component sets the RELATIVE traversal
/// order of its own fields (D12) unless `setsAccessibilityOrder` is false.
public struct HiPayCardEntryView: View {

    @ObservedObject private var controller: HiPayCardEntryController
    private let theme: HiPayCardTheme
    private let setsAccessibilityOrder: Bool
    @FocusState private var focus: HiPayCardEntryController.Field?

    // Track the previously focused field so we can detect a blur (iOS 15/16
    // `.onChange` gives only the new value) and which field's error to announce.
    @State private var previousFocus: HiPayCardEntryController.Field?
    // Dedup announcements so re-focus / re-edit does not re-announce the same error.
    @State private var lastAnnounced: [HiPayCardEntryController.Field: String] = [:]
    // CVV info tooltip presentation (story 5.6).
    @State private var showCvvInfo = false
    // Saved-cards list expand/collapse (only meaningful in the new-card branch with >1 card):
    // while entering a new card the list collapses to the most-recent card; this re-expands it.
    @State private var savedCardsExpanded = false
    // The saved card pending deletion — drives the confirmation dialog (UI-local, not the controller).
    @State private var cardPendingDelete: HiPaySavedCard?

    public init(
        controller: HiPayCardEntryController,
        theme: HiPayCardTheme = .default,
        setsAccessibilityOrder: Bool = true
    ) {
        self.controller = controller
        self.theme = theme
        self.setsAccessibilityOrder = setsAccessibilityOrder
    }

    private func loc(_ key: CardEntryStringKey) -> String { HiPayCardStrings.localized(key) }

    // CVC is required (enabled) or not-applicable (disabled) — never a true "optional"
    // enterable state — so the label/placeholder carry no "(optional)" suffix (story 11.3
    // review); the disabled+dimmed field already conveys "not applicable".
    private var cvvPlaceholder: String { loc(.placeholderCvv) }
    private var cvvLabel: String { loc(.labelCvv) }

    // Relative traversal order (D12): higher sort priority = announced earlier.
    // The priority sits on each field+error GROUP so the error follows its field.
    // When the host opts out, all groups use 0 (neutral) so the host controls order.
    private func order(_ priority: Double) -> Double { setsAccessibilityOrder ? priority : 0 }

    // The TextFields bind the raw @Published values; formatting is re-applied
    // from .onChange via the controller's *Edited() handlers — a write from
    // the binding setter or a didSet only renders on focus loss (iOS 15/16).
    // With the saved card selected, the entry fields are not rendered — their values stay in
    // the controller (nothing is cleared until a payment succeeds).
    private var showEntryFields: Bool {
        !(controller.oneClickEnabled && controller.selectedSavedCard != nil)
    }

    // The shared policy point decides where (and whether) the one-click error surfaces:
    // inline on the affected cell while listed, section-level when purged as no longer valid.
    private var oneClickSurface: OneClickErrorSurface? {
        OneClickErrorKt.oneClickErrorSurface(
            error: controller.lastOneClickError?.kmp,
            savedCards: controller.savedCards.map(\.kmp)
        )
    }

    private var oneClickErrorMessage: String? {
        controller.lastOneClickError.map { loc($0.messageKey) }
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Also composed when the list just emptied with a section-level one-click error to
            // show (the last card was purged as no longer valid) — the payer must learn why.
            if controller.oneClickEnabled,
               !controller.savedCards.isEmpty || oneClickSurface == .section {
                savedCardsSections
                    .accessibilitySortPriority(order(5))
            }
            if showEntryFields {
            // Holder
            VStack(alignment: .leading, spacing: 4) {
                TextField(loc(.placeholderHolder), text: $controller.holder)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .holder)
                    .modifier(EntryFieldStyle(valid: controller.isHolderAcceptable))
                    .onChange(of: controller.holder) { _ in controller.holderEdited() }
                    .accessibilityLabel(loc(.labelHolder))
                    .accessibilityIdentifier("hipay.card.holder")
                errorSlot(controller.holderError, id: "hipay.card.error.holder")
            }
            .accessibilitySortPriority(order(4))

            // Card number (+ network chips overlay)
            VStack(alignment: .leading, spacing: 4) {
                TextField(loc(.placeholderNumber), text: $controller.cardNumber)
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .number)
                    .modifier(EntryFieldStyle(valid: controller.isNumberAcceptable))
                    // a11y modifiers BEFORE the overlay so they bind to the field
                    // only and do NOT subsume the network chips' own a11y.
                    .accessibilityLabel(loc(.labelNumber))
                    .accessibilityIdentifier("hipay.card.number")
                    .accessibilityHint(Text(controller.selectedNetwork?.displayName ?? ""))
                    .overlay(alignment: .trailing) { networkIcons.padding(.trailing, 12) }
                    .onChange(of: controller.cardNumber) { _ in
                        controller.numberEdited()
                        if controller.isNumberComplete { focus = .expiry }
                    }
                errorSlot(controller.numberSlotError?.message,
                          id: controller.numberSlotError?.id ?? "hipay.card.error.number")
            }
            .accessibilitySortPriority(order(3))

            HStack(alignment: .top, spacing: 12) {
                // Expiry
                VStack(alignment: .leading, spacing: 4) {
                    TextField(loc(.placeholderExpiry), text: $controller.expiry)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .expiry)
                        .modifier(EntryFieldStyle(valid: controller.isExpiryAcceptable))
                        .onChange(of: controller.expiry) { _ in
                            controller.expiryEdited()
                            guard controller.isExpiryComplete else { return }
                            focus = controller.isCvcRequired ? .cvc : nil
                        }
                        .accessibilityLabel(loc(.labelExpiry))
                        .accessibilityIdentifier("hipay.card.expiry")
                }
                .accessibilitySortPriority(order(2))

                // CVV — NOT masked (user decision 2026-06-12); disabled when the
                // detected network does not require a CVC.
                VStack(alignment: .leading, spacing: 4) {
                    TextField(cvvPlaceholder, text: $controller.cvc)
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .cvc)
                        .disabled(!controller.isCvcRequired)
                        .opacity(controller.isCvcRequired ? 1 : 0.4)
                        .modifier(EntryFieldStyle(valid: controller.isCvcAcceptable))
                        .accessibilityLabel(cvvLabel)
                        .accessibilityIdentifier("hipay.card.cvc")
                        // Info affordance INSIDE the field, right-aligned (a11y modifiers
                        // applied BEFORE the overlay so the button keeps its own identity).
                        // Shown only when the CVV is required: a `.disabled` field
                        // propagates `isEnabled = false` into its overlay regardless of
                        // modifier order, which would make the button untappable — and a
                        // CVV explanation is moot when no CVV is needed.
                        .overlay(alignment: .trailing) {
                            if controller.isCvcRequired {
                                cvvInfoButton.padding(.trailing, 6)
                            }
                        }
                        .onChange(of: controller.cvc) { _ in
                            controller.cvcEdited()
                            if controller.isCvcRequired && controller.isCvcComplete { focus = nil }
                        }
                        // Reset the help when CVC stops being required so it never re-shows
                        // unprompted when a CVC-required card is re-entered (review 11.2).
                        .onChange(of: controller.isCvcRequired) { isRequired in
                            if !isRequired { showCvvInfo = false }
                        }
                }
                .accessibilitySortPriority(order(1))
            }
            // Expiry/CVV errors full width below the row (11.2), between the fields and the info.
            errorSlot(controller.expiryError, id: "hipay.card.error.expiry")
            errorSlot(controller.cvcError, id: "hipay.card.error.cvc")
            // CVV help as a full-width inline text (no popover, 11.2), toggled by the "ⓘ".
            if controller.isCvcRequired && showCvvInfo {
                Text(loc(.cvvTooltip))
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hipay.card.cvc.tooltip")
            }
            // In-frame save switch + one-line consent — the new-card branch of one-click only.
            if controller.oneClickEnabled {
                saveCardSwitch
            }
            } // showEntryFields
        }
        // One-click: load the saved card on appearance (no-op unless opted in — fail-soft).
        .task { await controller.refreshSavedCards() }
        // Simple platform-standard expand/collapse when the selection changes.
        .animation(.default, value: controller.selectedSavedCard)
        // Forget a manual list re-expand once a saved card is (re)selected, so each fresh new-card
        // entry starts collapsed again (the collapse-to-MRU behaviour never silently stops).
        .onChange(of: controller.selectedSavedCard) { newSelection in
            if newSelection != nil { savedCardsExpanded = false }
        }
        // Delete confirmation (long-press / a11y action set `cardPendingDelete`). An `.alert`
        // (not a `.confirmationDialog`) — the destructive-confirm equivalent of the Android
        // `AlertDialog`, and reliably driveable under XCUITest via `app.alerts`.
        .alert(
            loc(.confirmDeleteCard),
            isPresented: Binding(
                get: { cardPendingDelete != nil },
                set: { presented in if !presented { cardPendingDelete = nil } }
            ),
            presenting: cardPendingDelete
        ) { card in
            Button(loc(.labelDeleteCard), role: .destructive) {
                Task { await controller.deleteSavedCard(card) }
                cardPendingDelete = nil
            }
            Button(loc(.labelCancel), role: .cancel) { cardPendingDelete = nil }
        }
        // Drop a pending confirmation if its card vanishes from the list underneath the open alert
        // (a concurrent reload on foreground, or an expiry purge) — otherwise the payer would
        // confirm deleting a card they can no longer see.
        .onChange(of: controller.savedCards) { cards in
            if let pending = cardPendingDelete, !cards.contains(pending) { cardPendingDelete = nil }
        }
        // Single blur detector for all fields: when focus leaves a field, mark it
        // blurred (reveals its inline error) and announce the error politely once.
        .onChange(of: focus) { newFocus in
            // Skip when focus was lost because the fields collapsed (a saved card was just
            // selected): the field is gone, so marking it blurred / announcing its error is
            // spurious. previousFocus still advances so the detector never gets stuck.
            if showEntryFields, let blurred = previousFocus, blurred != newFocus {
                controller.markBlurred(blurred)
                announceError(for: blurred)
            }
            previousFocus = newFocus
        }
        // Announce a freshly surfaced one-click error politely (the field-error announce path):
        // non-focus-stealing, deferred a runloop so it lands after any focus-change utterance.
        .onChange(of: controller.lastOneClickError) { error in
            guard let error, oneClickSurface != nil else { return }
            let message = loc(error.messageKey)
            DispatchQueue.main.async {
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
        // Lock all fields while a payment is in flight — driven by the SDK itself (story 11.14):
        // the controller sets isProcessing across pay() (incl. the 3DS round-trip), no host wiring.
        // SwiftUI cascades .disabled to children and composes with each field's own .disabled.
        .disabled(controller.isProcessing)
    }

    // MARK: - One-click sections (shared header treatment; no radio indicator by design)

    /// The two one-click zones: "Saved cards" (the list of ≤3 saved cards, most-recent first,
    /// selection = border) and "New card" (an actionable header whose chevron shows the expanded
    /// state). Exactly one selection at all times; VoiceOver reads the localized card label — never
    /// the bullets. While the new-card branch is active the list collapses to the most-recent card
    /// and the "Saved cards" header gains its own chevron to re-expand (single card → no collapse).
    @ViewBuilder private var savedCardsSections: some View {
        let surface = oneClickSurface
        if controller.savedCards.isEmpty {
            // The last card vanished as no longer valid mid-checkout: the list is gone but the
            // payer still needs to know why — the section message alone, above the open fields.
            if surface == .section, let message = oneClickErrorMessage {
                errorSlot(message, id: "hipay.card.error.oneclick.section")
            }
        } else {
            let cards = controller.savedCards
            let newCardBranch = controller.selectedSavedCard == nil
            let collapsible = newCardBranch && cards.count > 1
            let showAllCards = !newCardBranch || savedCardsExpanded
            let visibleCards = showAllCards ? cards : Array(cards.prefix(1))
            VStack(alignment: .leading, spacing: 12) {
                if collapsible {
                    savedCardsCollapsibleHeader
                } else {
                    sectionHeader(loc(.labelSavedCards))
                }
                if surface == .section, let message = oneClickErrorMessage {
                    errorSlot(message, id: "hipay.card.error.oneclick.section")
                }
                ForEach(Array(visibleCards.enumerated()), id: \.element.id) { index, card in
                    savedCardCell(
                        card,
                        index: index,
                        error: surface == .inlineCard
                            ? controller.lastOneClickError.flatMap { $0.matches(card) ? $0 : nil }
                            : nil
                    )
                }
                newCardHeader
            }
        }
    }

    /// One saved-card cell: 2-line masked display, border-only selection (no radio), merged label.
    /// With a one-click `error` targeting this card, an inline error renders under the cell (the
    /// field errorSlot pattern — icon + text) and joins the cell's merged label.
    private func savedCardCell(_ card: HiPaySavedCard, index: Int, error: HiPayOneClickError? = nil) -> some View {
        let display = SavedCardDisplayKt.savedCardDisplay(card: card.kmp)
        let platformNetwork = display.network.flatMap { HiPayCardNetwork($0) }
        let baseA11yLabel = String(
            format: loc(.a11ySavedCard),
            platformNetwork?.displayName ?? card.network,
            display.last4,
            display.displayExpiry
        )
        // The error is part of the merged cell label: focusing the cell reads why it failed.
        let a11yLabel = error.map { "\(baseA11yLabel), \(loc($0.messageKey))" } ?? baseA11yLabel
        let selected = controller.selectedSavedCard == card
        let cell = Button { controller.selectSavedCard(card) } label: {
            HStack(spacing: 10) {
                Image(platformNetwork?.assetName ?? HiPayCardNetwork.neutralAssetName, bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(display.maskedNumber)
                        .font(.body.monospaced())
                        .foregroundColor(.primary)
                    Text("\(card.holder)  ·  \(display.displayExpiry)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(minHeight: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        selected ? Color.accentColor : Color.secondary.opacity(0.4),
                        lineWidth: selected ? 1.8 : 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("hipay.card.savedcard.\(index)")
        // Long-press requests delete (no visible button, PM decision); the mandatory a11y custom
        // action makes deletion reachable to VoiceOver (the long-press gesture is invisible to it).
        // Both are gated on isProcessing explicitly — a custom a11y action is not reliably
        // suppressed by the ancestor .disabled, so delete must not be reachable mid-payment.
        .onLongPressGesture { if !controller.isProcessing { cardPendingDelete = card } }
        .accessibilityAction(named: Text(loc(.labelDeleteCard))) {
            if !controller.isProcessing { cardPendingDelete = card }
        }
        // The cell + its inline error travel as one visual unit (the field errorSlot spacing).
        return VStack(alignment: .leading, spacing: 4) {
            cell
            if let error {
                errorSlot(loc(error.messageKey), id: "hipay.card.error.savedcard.\(index)")
            }
        }
    }

    /// "New card": an actionable BUTTON whose expanded/collapsed value carries the meaning.
    private var newCardHeader: some View {
        let expanded = controller.selectedSavedCard == nil
        return Button { controller.selectNewCard() } label: {
            HStack {
                sectionHeader(loc(.labelNewCard))
                Spacer()
                Text(expanded ? "▾" : "▸")
                    .font(.callout)
                    .foregroundColor(expanded ? .accentColor : .secondary)
                    .accessibilityHidden(true) // decorative: the button value carries the meaning
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? loc(.a11yExpanded) : loc(.a11yCollapsed))
        .accessibilityIdentifier("hipay.card.newcard")
    }

    /// "Saved cards" header, collapsible in the new-card branch: a button re-expanding the list.
    private var savedCardsCollapsibleHeader: some View {
        Button { withAnimation { savedCardsExpanded.toggle() } } label: {
            HStack {
                sectionHeader(loc(.labelSavedCards))
                Spacer()
                Text(savedCardsExpanded ? "▾" : "▸")
                    .font(.callout)
                    .foregroundColor(savedCardsExpanded ? .accentColor : .secondary)
                    .accessibilityHidden(true) // decorative: the button value carries the meaning
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(savedCardsExpanded ? loc(.a11yExpanded) : loc(.a11yCollapsed))
        .accessibilityIdentifier("hipay.card.savedcards.header")
    }

    /// The shared one-click section-header treatment.
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    /// In-frame "save this card" switch (consent, default OFF) + one-line consent text.
    private var saveCardSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { controller.saveCardOptIn },
                set: { controller.onSaveCardOptInChange($0) }
            )) {
                Text(loc(.labelSaveCard))
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("hipay.card.saveswitch")
            Text(loc(.consentSaveCard))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("hipay.card.consent")
        }
    }

    // Inline error slot under a field: icon + text (NOT colour-only, WCAG 1.4.1).
    // Collapses to nothing when there is no error (user preference: tighter
    // vertical spacing when valid — the error expands the layout when it appears,
    // rather than reserving a permanent blank line). Sizes to content
    // (.fixedSize) so a long localized message wraps at large Dynamic Type.
    @ViewBuilder private func errorSlot(_ message: String?, id: String) -> some View {
        if let message {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(message)
                    .accessibilityIdentifier(id)
            }
            .font(.caption)
            .foregroundColor(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // Post a polite, non-focus-stealing announcement of a field's error on blur.
    // Deferred to the next runloop so it lands after VoiceOver's focus-change
    // utterance; deduped so re-focus/re-edit does not repeat it. (Queued/polite
    // priority is iOS 17+; at iOS 15/16 this is best-effort, non-interrupting.)
    private func announceError(for field: HiPayCardEntryController.Field) {
        let message: String?
        switch field {
        case .holder: message = controller.holderError
        case .number: message = controller.numberSlotError?.message
        case .expiry: message = controller.expiryError
        case .cvc: message = controller.cvcError
        }
        // Reset the dedup cache when the field is now valid, so a later
        // recurrence of the same message is announced again (not suppressed).
        guard let message else { lastAnnounced[field] = nil; return }
        guard lastAnnounced[field] != message else { return }
        lastAnnounced[field] = message
        DispatchQueue.main.async {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    // CVV info affordance (story 11.2): tap TOGGLES the full-width inline help text rendered
    // below the expiry/CVV row (no popover). The button's a11y label IS the explanation, so
    // VoiceOver reads it on demand when focused.
    private var cvvInfoButton: some View {
        Button { showCvvInfo.toggle() } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44) // tap target >= 44x44 (HIG)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(loc(.cvvTooltip)))
        .accessibilityIdentifier("hipay.card.cvc.info")
    }

    // Right-aligned network icons. Neutral placeholder when nothing is detected;
    // the detected brand once known; in co-branding both are shown, the selected
    // one highlighted and the other dimmed. Each is an accessibility BUTTON
    // (VoiceOver gets the system "double-tap to activate") labelled with the
    // brand name; the selected one carries `.isSelected` — tap to switch.
    @ViewBuilder private var networkIcons: some View {
        HStack(spacing: 6) {
            if controller.networks.isEmpty {
                brandChip(assetName: "HPCardNeutral", highlighted: false, dimmed: true)
                    .accessibilityHidden(true) // decorative neutral placeholder
            } else {
                ForEach(controller.networks, id: \.self) { net in
                    let isSelected = controller.selectedNetwork == net
                    Button {
                        controller.selectNetwork(net)
                    } label: {
                        brandChip(assetName: net.assetName, highlighted: isSelected, dimmed: !isSelected)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44) // tap target >= 44x44 (HIG)
                    .contentShape(Rectangle())
                    .accessibilityLabel(Text(net.displayName))
                    .accessibilityIdentifier("hipay.card.network.\(net.rawValue)")
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
        }
    }

    // A brand logo inside a credit-card-shaped chip (~1.6:1) with left/right
    // padding around the logo. Outlined when highlighted.
    private func brandChip(assetName: String, highlighted: Bool, dimmed: Bool) -> some View {
        Image(assetName, bundle: .module)
            .resizable()
            .scaledToFit()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: 33, height: 21) // credit-card aspect ratio (~1.586:1)
            .opacity(dimmed ? 0.35 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: highlighted ? 1.5 : 0),
            )
    }
}

private struct EntryFieldStyle: ViewModifier {
    let valid: Bool

    func body(content: Content) -> some View {
        content
            .padding(10)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(valid ? Color.secondary.opacity(0.4) : Color.red, lineWidth: 1)
            )
    }
}
