import SwiftUI

/// Embeddable card-entry component (FR11b): the host drops this view into
/// its own screen; card data never leaves it (the paired
/// `HiPayCardEntryController` exposes only `tokenize()` -> token and
/// `canTokenize` for the host's pay button).
///
/// Layout: holder (upper-cased) on top, auto-formatted card number in the
/// middle, expiry MM/YY bottom-left, CVV bottom-right (shown disabled when
/// the network does not require it). Completed fields auto-advance focus.
public struct HiPayCardEntryView: View {

    @ObservedObject private var controller: HiPayCardEntryController
    private let theme: HiPayCardTheme
    @FocusState private var focus: Field?

    private enum Field { case holder, number, expiry, cvc }

    public init(controller: HiPayCardEntryController, theme: HiPayCardTheme = .default) {
        self.controller = controller
        self.theme = theme
    }

    public var body: some View {
        VStack(spacing: 12) {
            TextField("CARD HOLDER", text: $controller.holder)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .focused($focus, equals: .holder)
                .modifier(EntryFieldStyle(valid: controller.isHolderAcceptable))

            TextField("Card number", text: $controller.cardNumber)
                .keyboardType(.numberPad)
                .textContentType(.creditCardNumber)
                .focused($focus, equals: .number)
                .modifier(EntryFieldStyle(valid: controller.isNumberAcceptable))
                .onChange(of: controller.cardNumber) { _ in
                    if controller.isNumberComplete { focus = .expiry }
                }

            HStack(spacing: 12) {
                TextField("MM/YY", text: $controller.expiry)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .expiry)
                    .modifier(EntryFieldStyle(valid: controller.isExpiryAcceptable))
                    .onChange(of: controller.expiry) { _ in
                        if controller.isExpiryComplete {
                            focus = controller.isCvcRequired ? .cvc : nil
                        }
                    }

                SecureField(controller.isCvcRequired ? "CVV" : "CVV (optional)", text: $controller.cvc)
                    .keyboardType(.numberPad)
                    .focused($focus, equals: .cvc)
                    .disabled(!controller.isCvcRequired)
                    .opacity(controller.isCvcRequired ? 1 : 0.4)
                    .modifier(EntryFieldStyle(valid: controller.isCvcAcceptable))
                    .onChange(of: controller.cvc) { _ in
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
