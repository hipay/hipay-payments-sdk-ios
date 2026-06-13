import HiPayFullservice

/// Tokenization result — INTERNAL: the token is created and consumed inside the
/// SDK by `HiPayCardEntryController.pay(...)` and never crosses to the host
/// (which only ever sees a `HiPayTransaction`). The `maskedPan` is
/// backend-masked. Kept as a typed carrier between tokenize and order creation.
struct HiPayCardToken: Sendable {
    let token: String
    let brand: String?
    let maskedPan: String?
    let holder: String?
    let expiryMonth: String?
    let expiryYear: String?
    let issuer: String?
    let country: String?
    let domesticNetwork: String?

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
