import SwiftUI
import HiPayFullservice

/// Embeddable card-entry component (FR11b): the host drops this view into
/// its own screen; card data never leaves it (the paired
/// `HiPayCardEntryController` exposes only `tokenize()` -> token and
/// `canTokenize` for the host's pay button).
///
/// Layout: holder (upper-cased) on top, card number auto-formatted WHILE
/// TYPING in the middle, expiry MM/YY bottom-left, CVV bottom-right (visible
/// in clear, shown disabled when the network does not require it). Completed
/// fields auto-advance focus; a complete MM/YY focuses the CVV when required,
/// otherwise dismisses the keyboard.
///
/// Accessibility & i18n (story 5.4): labels/placeholders are localized via
/// `HiPayCardStrings` (FR/EN/IT, D11); each field exposes a label + stable
/// `accessibilityIdentifier`; the number field announces the detected network
/// (brand name) and the network chips are accessible buttons with `.isSelected`
/// (the co-brand choice is actionable non-visually). The component sets the
/// RELATIVE traversal order of its own fields (D12) unless `setsAccessibilityOrder`
/// is false (host drives ordering).
public struct HiPayCardEntryView: View {

    @ObservedObject private var controller: HiPayCardEntryController
    private let theme: HiPayCardTheme
    private let setsAccessibilityOrder: Bool
    @FocusState private var focus: Field?

    private enum Field { case holder, number, expiry, cvc }

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

    // CVV label/placeholder gain the localized "optional" suffix when the
    // detected network does not require a CVC.
    private var cvvOptional: Bool { !controller.isCvcRequired }
    private var cvvPlaceholder: String {
        cvvOptional ? "\(loc(.placeholderCvv)) (\(loc(.cvvOptional)))" : loc(.placeholderCvv)
    }
    private var cvvLabel: String {
        cvvOptional ? "\(loc(.labelCvv)), \(loc(.cvvOptional))" : loc(.labelCvv)
    }

    // Relative traversal order (D12): higher sort priority = announced earlier.
    // When the host opts out, all fields use 0 (neutral) so the host controls order.
    private func order(_ priority: Double) -> Double { setsAccessibilityOrder ? priority : 0 }

    // The TextFields bind the raw @Published values; formatting is re-applied
    // from .onChange via the controller's *Edited() handlers — a write from
    // the binding setter or a didSet only renders on focus loss (iOS 15/16).
    public var body: some View {
        VStack(spacing: 12) {
            TextField(loc(.placeholderHolder), text: $controller.holder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focus, equals: .holder)
                .modifier(EntryFieldStyle(valid: controller.isHolderAcceptable))
                .onChange(of: controller.holder) { _ in
                    controller.holderEdited()
                }
                .accessibilityLabel(loc(.labelHolder))
                .accessibilityIdentifier("hipay.card.holder")
                .accessibilitySortPriority(order(4))

            TextField(loc(.placeholderNumber), text: $controller.cardNumber)
                .keyboardType(.numberPad)
                .textContentType(.creditCardNumber)
                .autocorrectionDisabled()
                .focused($focus, equals: .number)
                .modifier(EntryFieldStyle(valid: controller.isNumberAcceptable))
                // a11y modifiers BEFORE the overlay so they bind to the field only
                // and do NOT subsume the network chips' own labels/identifiers.
                .accessibilityLabel(loc(.labelNumber))
                .accessibilityIdentifier("hipay.card.number")
                // The detected/selected network is announced on the number field
                // (brand proper noun, non-localized); empty hint when none.
                .accessibilityHint(Text(controller.selectedNetwork?.displayName ?? ""))
                .accessibilitySortPriority(order(3))
                // Network icon(s) on the right: neutral by default, the detected
                // brand once known, both + a highlighted default in co-branding.
                .overlay(alignment: .trailing) { networkIcons.padding(.trailing, 12) }
                .onChange(of: controller.cardNumber) { _ in
                    controller.numberEdited()
                    if controller.isNumberComplete { focus = .expiry }
                }

            HStack(spacing: 12) {
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
                    .accessibilitySortPriority(order(2))

                // CVV is NOT masked (user decision 2026-06-12) — short-lived,
                // low-sensitivity input; visibility prevents typing errors.
                TextField(cvvPlaceholder, text: $controller.cvc)
                    .keyboardType(.numberPad)
                    .autocorrectionDisabled()
                    .focused($focus, equals: .cvc)
                    .disabled(!controller.isCvcRequired)
                    .opacity(controller.isCvcRequired ? 1 : 0.4)
                    .modifier(EntryFieldStyle(valid: controller.isCvcAcceptable))
                    .onChange(of: controller.cvc) { _ in
                        controller.cvcEdited()
                        if controller.isCvcRequired && controller.isCvcComplete { focus = nil }
                    }
                    .accessibilityLabel(cvvLabel)
                    .accessibilityIdentifier("hipay.card.cvc")
                    .accessibilitySortPriority(order(1))
            }
        }
    }

    // Right-aligned network icons. Neutral placeholder when nothing is
    // detected; the detected brand once known; in co-branding both are shown,
    // the selected/default one highlighted (full opacity + outline) and the
    // other dimmed. Each is an accessibility BUTTON (VoiceOver gets the system
    // "double-tap to activate") labelled with the brand name; the selected one
    // carries the `.isSelected` trait — tap to switch the co-brand network.
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
    // padding around the logo. Outlined when highlighted — including the lone
    // detected network, not only the co-brand selection.
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
