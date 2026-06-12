import SwiftUI

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
public struct HiPayCardEntryView: View {

    @ObservedObject private var controller: HiPayCardEntryController
    private let theme: HiPayCardTheme
    @FocusState private var focus: Field?

    private enum Field { case holder, number, expiry, cvc }

    public init(controller: HiPayCardEntryController, theme: HiPayCardTheme = .default) {
        self.controller = controller
        self.theme = theme
    }

    // The TextFields bind the raw @Published values; formatting is re-applied
    // from .onChange via the controller's *Edited() handlers — a write from
    // the binding setter or a didSet only renders on focus loss (iOS 15/16).
    public var body: some View {
        VStack(spacing: 12) {
            TextField("CARD HOLDER", text: $controller.holder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focus, equals: .holder)
                .modifier(EntryFieldStyle(valid: controller.isHolderAcceptable))
                .onChange(of: controller.holder) { _ in
                    controller.holderEdited()
                }

            TextField("Card number", text: $controller.cardNumber)
                .keyboardType(.numberPad)
                .textContentType(.creditCardNumber)
                .focused($focus, equals: .number)
                .modifier(EntryFieldStyle(valid: controller.isNumberAcceptable))
                .onChange(of: controller.cardNumber) { _ in
                    controller.numberEdited()
                    if controller.isNumberComplete { focus = .expiry }
                }

            HStack(spacing: 12) {
                TextField("MM/YY", text: $controller.expiry)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .expiry)
                    .modifier(EntryFieldStyle(valid: controller.isExpiryAcceptable))
                    .onChange(of: controller.expiry) { _ in
                        controller.expiryEdited()
                        guard controller.isExpiryComplete else { return }
                        focus = controller.isCvcRequired ? .cvc : nil
                    }

                // CVV is NOT masked (user decision 2026-06-12) — short-lived,
                // low-sensitivity input; visibility prevents typing errors.
                TextField(controller.isCvcRequired ? "CVV" : "CVV (optional)", text: $controller.cvc)
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
            }
        }
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
