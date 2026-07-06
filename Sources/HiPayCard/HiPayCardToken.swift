import HiPayFullservice

/// Tokenization result — INTERNAL: the token is created and consumed inside the
/// SDK by `HiPayCardEntryController.pay(...)` and never crosses to the host
/// (which only ever sees a `HiPayTransaction`). The `maskedPan` is
/// backend-masked. Kept as a typed carrier between tokenize and order creation.
struct HiPayCardToken {
    let token: String
    let brand: String?
    let maskedPan: String?
    let holder: String?
    let expiryMonth: String?
    let expiryYear: String?
    let issuer: String?
    let country: String?
    let domesticNetwork: String?
    /// The KMP token, kept so the saved-card mapping stays single-sourced in
    /// Kotlin (`savedCardFromToken`). Never exposed outside the module.
    let kmp: CardToken

    init(_ kmp: CardToken) {
        self.kmp = kmp
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
