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
///
/// Styling: appearance comes from `theme` — build it from the shared cross-platform
/// `HiPayCardEntryStyle` (`HiPayCardTheme(style:)`) or customize `HiPayCardTheme.hipayDefault`
/// per property. Colors/typography/metrics only — behaviours (formatting, focus, one-click,
/// accessibility) are untouched by theming.
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
    // The saved card whose left-swipe trash action is currently revealed (one at a time).
    @State private var swipeRevealedCard: HiPaySavedCard?

    public init(
        controller: HiPayCardEntryController,
        theme: HiPayCardTheme = .hipayDefault,
        setsAccessibilityOrder: Bool = true
    ) {
        self.controller = controller
        self.theme = theme
        self.setsAccessibilityOrder = setsAccessibilityOrder
    }

    private func loc(_ key: CardEntryStringKey) -> String {
        HiPayCardStrings.localized(key, override: controller.settingsLocaleOverride)
    }

    // Themed placeholder (SwiftUI styles placeholders via the `prompt` Text, not the field's
    // foreground). The default placeholderColor matches the system placeholder gray, so the
    // no-style path looks unchanged.
    private func prompt(_ text: String) -> Text {
        Text(text).foregroundColor(theme.placeholderColor)
    }

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
                TextField(
                    loc(.placeholderHolder),
                    text: $controller.holder,
                    prompt: prompt(loc(.placeholderHolder))
                )
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .holder)
                    // Border goes invalid WITH the visible error (blur-gated) — never
                    // mid-typing (Android/CMP parity).
                    .modifier(EntryFieldStyle(theme: theme, valid: controller.holderError == nil))
                    .onChange(of: controller.holder) { _ in controller.holderEdited() }
                    .accessibilityLabel(loc(.labelHolder))
                    .accessibilityIdentifier("hipay.card.holder")
                errorSlot(controller.holderError, id: "hipay.card.error.holder")
            }
            .accessibilitySortPriority(order(4))

            // Card number (+ network chips overlay)
            VStack(alignment: .leading, spacing: 4) {
                TextField(
                    loc(.placeholderNumber),
                    text: $controller.cardNumber,
                    prompt: prompt(loc(.placeholderNumber))
                )
                    .keyboardType(.numberPad)
                    .textContentType(.creditCardNumber)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .number)
                    .modifier(EntryFieldStyle(theme: theme, valid: controller.numberSlotError == nil))
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
                    TextField(
                        loc(.placeholderExpiry),
                        text: $controller.expiry,
                        prompt: prompt(loc(.placeholderExpiry))
                    )
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .expiry)
                        .modifier(EntryFieldStyle(theme: theme, valid: controller.expiryError == nil))
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
                    TextField(
                        cvvPlaceholder,
                        text: $controller.cvc,
                        prompt: prompt(cvvPlaceholder)
                    )
                        .keyboardType(.numberPad)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .cvc)
                        .disabled(!controller.isCvcRequired)
                        .opacity(controller.isCvcRequired ? 1 : 0.4)
                        .modifier(EntryFieldStyle(theme: theme, valid: controller.cvcError == nil))
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
                    .foregroundColor(theme.textColor)
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
        .onChange(of: controller.selectedSavedCard) { newSelection in
            // A (re)selection snaps any revealed swipe shut so no orphaned trash lingers.
            swipeRevealedCard = nil
            guard let newSelection else { return }
            // Drop an open CVV help: the entry fields are collapsing, and it must not
            // re-appear unprompted when "New card" is next expanded.
            showCvvInfo = false
            // Keep the paying card visible: if the (re)selected card sits beyond the default fold,
            // force the list open and keep it open (the payer never pays with a hidden card). The
            // "Show more / Show less" toggle otherwise owns collapse — a selection no longer collapses.
            let idx = controller.savedCards.firstIndex(of: newSelection) ?? -1
            if idx >= controller.savedCardsDisplayCount { savedCardsExpanded = true }
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
            // Focusing another field dismisses the CVV help — the established tap-outside
            // dismissal (the help must never act as a focus trap). The CVV field itself is
            // exempt: auto-advance or tapping the field the help explains must not close it.
            if let newFocus, newFocus != .cvc { showCvvInfo = false }
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

    /// The two one-click zones: "Saved cards" (the most-recent `savedCardsDisplayCount` cards,
    /// most-recent first, selection = border) and "New card" (an actionable header whose chevron
    /// shows the expanded state). Exactly one selection at all times; VoiceOver reads the localized
    /// card label — never the bullets. When more cards are stored a "Show more / Show less" toggle
    /// reveals or hides the rest; the list force-expands (and "Show less" is disabled)
    /// while the selected card sits beyond the fold, so the paying card is never hidden. Every saved
    /// card is retained by the store — the display count only bounds what is shown by default.
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
            // Show the most-recent `displayCount` cards; a "Show more / Show less" toggle reveals or
            // hides the rest. This bounds only what is shown — every saved card is retained
            // by the store (cap 20). If the selected card sits beyond the fold the list force-expands
            // (`|| selectionBeyondFold`) so the paying card is never hidden.
            let displayCount = controller.savedCardsDisplayCount
            let hasMore = cards.count > displayCount
            let selectedIndex = controller.selectedSavedCard.flatMap { cards.firstIndex(of: $0) } ?? -1
            let selectionBeyondFold = selectedIndex >= displayCount
            let expanded = savedCardsExpanded || selectionBeyondFold
            let visibleCards = expanded ? cards : Array(cards.prefix(displayCount))
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(loc(.labelSavedCards))
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
                if hasMore {
                    showMoreToggle(expanded: expanded, canCollapse: !selectionBeyondFold)
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
                        .foregroundColor(theme.textColor)
                    Text("\(card.holder)  ·  \(display.displayExpiry)")
                        .font(.caption)
                        .foregroundColor(theme.placeholderColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(minHeight: 44)
            // Cells follow the theme's metrics so they agree with the entry fields; the
            // SELECTED cell keeps the platform accent — a thicker accent border (the fields'
            // focus treatment) and an accent tint layered OVER the theme background — as the
            // selection affordance (no accent slot in the style contract yet).
            .background {
                // Selection tint drawn over the theme background, under the content
                // (the second .background renders behind this one).
                if selected {
                    RoundedRectangle(cornerRadius: theme.cornerRadius)
                        .fill(Color.accentColor.opacity(0.08))
                }
            }
            .background(
                theme.backgroundColor,
                in: RoundedRectangle(cornerRadius: theme.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(
                        selected ? Color.accentColor : theme.borderColor,
                        lineWidth: selected ? theme.borderWidth + 1 : theme.borderWidth
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
        // Left-swipe reveals a trailing trash action; tapping it opens the delete confirmation. An
        // accidental swipe never deletes — only the trash tap (or the retained long-press / a11y
        // "Delete" action) requests it. Reverses the earlier no-visible-delete-button behaviour.
        let revealed = swipeRevealedCard == card
        let row = ZStack(alignment: .trailing) {
            if revealed {
                Button {
                    swipeRevealedCard = nil
                    if !controller.isProcessing { cardPendingDelete = card }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(loc(.labelDeleteCard))
                .accessibilityIdentifier("hipay.card.savedcard.\(index).delete")
            }
            cell
                .offset(x: revealed ? -56 : 0)
                // A horizontal drag reveals/hides the trash. High-priority so a recognized swipe wins
                // over the cell button — a swipe must NOT also select the card (which would change the
                // charged card and, via .onChange, snap the just-revealed trash shut). Below
                // minimumDistance the drag never starts, so a plain tap still selects (and long-press
                // still requests delete).
                .highPriorityGesture(
                    DragGesture(minimumDistance: 12)
                        .onEnded { value in
                            guard !controller.isProcessing else { return }
                            withAnimation {
                                if value.translation.width < -40 {
                                    swipeRevealedCard = card
                                } else if value.translation.width > 40 {
                                    swipeRevealedCard = nil
                                }
                            }
                        }
                )
        }
        // The cell + its inline error travel as one visual unit (the field errorSlot spacing).
        return VStack(alignment: .leading, spacing: 4) {
            row
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
                    .foregroundColor(expanded ? .accentColor : theme.iconColor)
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

    /// "Show more / Show less" disclosure toggle: reveals or hides the saved cards beyond
    /// the display count. A centered button whose expanded/collapsed value carries the meaning for
    /// VoiceOver (the chevron is decorative); it stays present across toggles so VoiceOver focus is
    /// retained. When [canCollapse] is false while expanded, "Show less" is disabled (the selection
    /// sits beyond the fold — collapsing would hide the paying card).
    private func showMoreToggle(expanded: Bool, canCollapse: Bool) -> some View {
        Button {
            withAnimation {
                if expanded {
                    if canCollapse { savedCardsExpanded = false }
                } else {
                    savedCardsExpanded = true
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(loc(expanded ? .labelShowLess : .labelShowMore))
                    .font(.callout)
                    .foregroundColor(.accentColor)
                Text(expanded ? "▴" : "▾")
                    .font(.callout)
                    .foregroundColor(.accentColor)
                    .accessibilityHidden(true) // decorative: the button value carries the meaning
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(expanded && !canCollapse) // "Show less" inert while the selection sits beyond the fold
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(expanded ? loc(.a11yExpanded) : loc(.a11yCollapsed))
        .accessibilityIdentifier("hipay.card.savedcards.showmore")
    }

    /// The shared one-click section-header treatment.
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundColor(theme.placeholderColor)
            .lineLimit(1)
    }

    /// In-frame "save this card" switch (consent, default OFF) + one-line consent text. The
    /// toggle tint keeps the platform accent (no accent slot in the style contract yet) — the
    /// theme drives the label and consent text, mirroring the CMP renderer.
    private var saveCardSwitch: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { controller.saveCardOptIn },
                set: { controller.onSaveCardOptInChange($0) }
            )) {
                Text(loc(.labelSaveCard))
                    .foregroundColor(theme.textColor)
            }
            .frame(minHeight: 44)
            .accessibilityIdentifier("hipay.card.saveswitch")
            Text(loc(.consentSaveCard))
                .font(.caption)
                .foregroundColor(theme.placeholderColor)
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
            .foregroundColor(theme.invalidTextColor)
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
                .foregroundColor(theme.iconColor)
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
                brandChip(assetName: "HPCardNeutral", highlighted: false, dimmed: false, tinted: true)
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

    // A brand logo inside a credit-card-shaped chip (~1.6:1) with left/right padding around
    // the logo. Outlined when highlighted. Selection treatment mirrors the CMP renderer:
    // dimmed brand chips use 0.35 opacity — several brand marks sit on an OPAQUE plate
    // (asset audit: amex, cb), so template-tinting them flattens the plate into an
    // unreadable block; brand logos are never re-tinted. Only the neutral placeholder
    // (a true silhouette, `tinted`) takes the theme's iconColor.
    private func brandChip(
        assetName: String,
        highlighted: Bool,
        dimmed: Bool,
        tinted: Bool = false
    ) -> some View {
        Image(assetName, bundle: .module)
            .resizable()
            .renderingMode(tinted ? .template : .original)
            .scaledToFit()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: 33, height: 21) // credit-card aspect ratio (~1.586:1)
            .foregroundColor(tinted ? theme.iconColor : nil)
            .opacity(dimmed ? 0.35 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentColor, lineWidth: highlighted ? 1.5 : 0),
            )
    }
}

private struct EntryFieldStyle: ViewModifier {
    let theme: HiPayCardTheme
    let valid: Bool

    // Dynamic Type factor (1.0 at the default content size, .body curve): the themed font
    // keeps scaling like the system font it replaces. fieldHeight is a MINIMUM, so the
    // field grows with the scaled line instead of clipping the entered card data.
    @ScaledMetric(relativeTo: .body) private var typeScale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .font(theme.font(scale: typeScale))
            .foregroundColor(theme.textColor)
            .tint(theme.textColor) // caret — mirrors the CMP renderer's cursor color
            .padding(10)
            .frame(minHeight: theme.fieldHeight)
            .background(
                theme.backgroundColor,
                in: RoundedRectangle(cornerRadius: theme.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: theme.cornerRadius)
                    .stroke(
                        valid ? theme.borderColor : theme.invalidTextColor,
                        lineWidth: theme.borderWidth
                    )
            )
    }
}
