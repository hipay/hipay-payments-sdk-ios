import SwiftUI
import HiPayFullservice

/// A card network surfaced to the host for the brand-icon UX. Maps the KMP
/// `CardNetwork` and carries its display asset + the order `payment_product`
/// code, so the network the user selects drives the order.
public enum HiPayCardNetwork: String, Sendable, CaseIterable {
    case visa
    case mastercard
    case amex
    case maestro
    case cb
    case bcmc

    init?(_ kmp: CardNetwork) {
        switch kmp {
        case .visa: self = .visa
        case .mastercard: self = .mastercard
        case .amex: self = .amex
        case .maestro: self = .maestro
        case .cb: self = .cb
        case .bcmc: self = .bcmc
        default: return nil // UNKNOWN — no icon
        }
    }

    /// HiPay `payment_product` code used when creating the order.
    public var paymentProductCode: String {
        switch self {
        case .visa: return "visa"
        case .mastercard: return "mastercard"
        case .amex: return "american-express"
        case .maestro: return "maestro"
        case .cb: return "cb"
        case .bcmc: return "bcmc"
        }
    }

    /// Asset name in the package bundle (`Image(_:bundle: .module)`).
    var assetName: String {
        switch self {
        case .visa: return "HPVisa"
        case .mastercard: return "HPMastercard"
        case .amex: return "HPAmex"
        case .maestro: return "HPMaestro"
        case .cb: return "HPCb"
        case .bcmc: return "HPBcmc"
        }
    }
}
