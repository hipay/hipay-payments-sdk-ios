import HiPayFullservice

/// Tokenization result handed to the host — the only thing that crosses the
/// card-entry boundary (NFR2). The `maskedPan` is masked by the backend.
public struct HiPayCardToken: Sendable {
    public let token: String
    public let brand: String?
    public let maskedPan: String?
    public let holder: String?
    public let expiryMonth: String?
    public let expiryYear: String?
    public let issuer: String?
    public let country: String?
    public let domesticNetwork: String?

    init(_ kmp: CardToken) {
        token = kmp.token
        brand = kmp.brand
        maskedPan = kmp.pan
        holder = kmp.cardHolder
        expiryMonth = kmp.cardExpiryMonth
        expiryYear = kmp.cardExpiryYear
        issuer = kmp.issuer
        country = kmp.country
        domesticNetwork = kmp.domesticNetwork
    }
}
