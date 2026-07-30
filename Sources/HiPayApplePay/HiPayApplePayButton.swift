//
//  HiPayApplePayButton.swift
//  HiPayApplePay
//
//  The native Apple Pay button, positionable by the merchant (the host owns the Pay action — no
//  checkout screen imposed by the SDK). Apple forbids redrawing the button, so this wraps the real
//  PassKit `PKPaymentButton`; only PassKit's style/type appearance options are exposed. The payment
//  flow itself is wired via `onTap` (delivered later); this component is the button only.
//

import SwiftUI
import PassKit

/// Apple Pay button style — mirrors `PKPaymentButtonStyle` (the parity with the shared KMP
/// `HiPayApplePayButtonStyle` is asserted by a test). No custom styling is possible (Apple rule).
public enum HiPayApplePayButtonStyle: CaseIterable {
    /// Dark fill, for a light background (default).
    case black
    /// White fill without a border, for a coloured/dark contrasting background.
    case white
    /// White fill with a black outline, for a light/white background.
    case whiteOutline
    /// Follows the system light/dark mode (iOS 14+).
    case automatic

    var pkStyle: PKPaymentButtonStyle {
        switch self {
        case .black: return .black
        case .white: return .white
        case .whiteOutline: return .whiteOutline
        case .automatic:
            if #available(iOS 14.0, *) { return .automatic } else { return .black }
        }
    }
}

/// Apple Pay button type (call-to-action) — mirrors `PKPaymentButtonType`. Values not available on
/// the running OS fall back to `.buy`.
public enum HiPayApplePayButtonType: CaseIterable {
    case plain, buy, checkout, book, subscribe, order
    case `continue`
    case reload, addMoney, topUp
    case tip, donate, support, contribute

    var pkType: PKPaymentButtonType {
        switch self {
        case .plain: return .plain
        case .buy: return .buy
        case .checkout: return .checkout
        case .book: return .book
        case .subscribe: return .subscribe
        case .donate: return .donate
        case .order:
            if #available(iOS 14.0, *) { return .order } else { return .buy }
        case .reload:
            if #available(iOS 14.0, *) { return .reload } else { return .buy }
        case .addMoney:
            if #available(iOS 14.0, *) { return .addMoney } else { return .buy }
        case .topUp:
            if #available(iOS 14.0, *) { return .topUp } else { return .buy }
        case .tip:
            if #available(iOS 14.0, *) { return .tip } else { return .buy }
        case .support:
            if #available(iOS 14.0, *) { return .support } else { return .buy }
        case .contribute:
            if #available(iOS 14.0, *) { return .contribute } else { return .buy }
        case .continue:
            if #available(iOS 15.0, *) { return .continue } else { return .buy }
        }
    }
}

/// A positionable Apple Pay button. Place it anywhere in your view hierarchy; provide a PassKit
/// `style` + `type`, and an `onTap` to start the payment. When `isAvailable` is false (default:
/// `PKPaymentAuthorizationController.canMakePayments()`), the button renders nothing — full
/// routable-network eligibility is wired in a later story.
///
/// The button cannot be restyled beyond PassKit's options (Apple rule). For a UIKit host, embed
/// this via `UIHostingController`.
public struct HiPayApplePayButton: View {
    private let style: HiPayApplePayButtonStyle
    private let type: HiPayApplePayButtonType
    private let isAvailable: Bool
    private let onTap: () -> Void

    // Default availability check: the device must have a usable card of a network we support
    // (canMakePayments(usingNetworks:) — stricter than the network-less canMakePayments(), which is
    // true on any Apple-Pay-capable device). Refined by full routable-network eligibility later.
    private static let defaultNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .maestro, .cartesBancaires]

    public init(
        style: HiPayApplePayButtonStyle = .automatic,
        type: HiPayApplePayButtonType = .buy,
        isAvailable: Bool? = nil,
        onTap: @escaping () -> Void
    ) {
        self.style = style
        self.type = type
        self.isAvailable = isAvailable
            ?? PKPaymentAuthorizationController.canMakePayments(usingNetworks: Self.defaultNetworks)
        self.onTap = onTap
    }

    public var body: some View {
        if isAvailable {
            _PKPaymentButtonView(style: style, type: type, onTap: onTap)
                // Re-create the underlying PKPaymentButton when style/type change (they are
                // init-only on PKPaymentButton).
                .id("\(style)-\(type)")
        }
    }
}

/// Bridges the UIKit `PKPaymentButton` into SwiftUI (iOS 15 target — the SwiftUI-native
/// `PayWithApplePayButton` is iOS 16+).
private struct _PKPaymentButtonView: UIViewRepresentable {
    let style: HiPayApplePayButtonStyle
    let type: HiPayApplePayButtonType
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> PKPaymentButton {
        let button = PKPaymentButton(paymentButtonType: type.pkType, paymentButtonStyle: style.pkStyle)
        button.addTarget(context.coordinator, action: #selector(Coordinator.didTap), for: .touchUpInside)
        return button
    }

    func updateUIView(_ uiView: PKPaymentButton, context: Context) {
        // Keep the latest closure; style/type changes recreate the view via `.id(...)` above.
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func didTap() { onTap() }
    }
}
