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

    /// Brand name for accessibility announcements. Brand names
    /// are proper nouns — deliberately NOT localized (story 5.4 / D11: only the
    /// `CardEntryStringKey` UI strings are localized, network names are not).
    public var displayName: String {
        switch self {
        case .visa: return "Visa"
        case .mastercard: return "Mastercard"
        case .amex: return "American Express"
        case .maestro: return "Maestro"
        case .cb: return "CB"
        case .bcmc: return "Bancontact"
        }
    }

    /// The KMP `CardNetwork` this maps to — used to call the commonMain
    /// `AllowedNetworks` logic (story 5.7 / D13) without reimplementing it.
    var kmpNetwork: CardNetwork {
        switch self {
        case .visa: return .visa
        case .mastercard: return .mastercard
        case .amex: return .amex
        case .maestro: return .maestro
        case .cb: return .cb
        case .bcmc: return .bcmc
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

    /// The neutral (unbranded) card asset — the fallback when no network resolves.
    static let neutralAssetName = "HPCardNeutral"
}
