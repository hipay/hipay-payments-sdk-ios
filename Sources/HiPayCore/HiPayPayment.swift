import Foundation
import HiPayFullservice

/// Headless payment facade (D4): order creation and transaction fetch.
///
/// The optional `signature` switches authentication to the HS scheme — it is
/// computed by YOUR BACKEND (SHA-1 of orderId+amount+currency+passphrase),
/// never by this SDK.
public final class HiPayPayment {

    private let gateway: GatewayClient

    public init(configuration: HiPayConfiguration) {
        gateway = GatewayClient(config: configuration.kmpConfig)
    }

    /// Creates a card order. The five redirect URLs follow the HiPay deep-link
    /// convention, derived from your app's `redirectScheme`
    /// (`{scheme}://hipay-fullservice/gateway/orders/{orderId}/{status}`).
    ///
    /// - Parameter authenticationIndicator: 0 bypass 3DS, 1 if available, 2 mandatory.
    public func requestCardOrder(
        orderId: String,
        amount: String,
        currency: String = "EUR",
        description: String,
        language: String = "en_GB",
        cardToken: String,
        redirectScheme: String,
        authenticationIndicator: Int = 0,
        signature: String? = nil
    ) async throws -> HiPayTransaction {
        let base = "\(redirectScheme)://hipay-fullservice/gateway/orders/\(orderId)"
        let order = OrderRequest(
            orderId: orderId,
            paymentProduct: "visa",
            amount: amount,
            description: description,
            acceptUrl: "\(base)/accept",
            declineUrl: "\(base)/decline",
            pendingUrl: "\(base)/pending",
            exceptionUrl: "\(base)/exception",
            cancelUrl: "\(base)/cancel",
            operation: .sale,
            currency: currency,
            language: language,
            customerId: nil,
            ipAddress: nil,
            customer: nil,
            shippingAddress: nil,
            customData: [:],
            cardToken: cardToken,
            eci: 7,
            authenticationIndicator: Int32(authenticationIndicator)
        )
        do {
            return HiPayTransaction(try await gateway.requestNewOrder(order: order, signature: signature))
        } catch {
            throw HiPayError.from(error)
        }
    }

    /// Fetches the current transaction state — the ONLY trusted way to read
    /// the outcome after a redirect (FR9).
    public func getTransaction(reference: String, signature: String? = nil) async throws -> HiPayTransaction {
        do {
            return HiPayTransaction(try await gateway.getTransaction(reference: reference, signature: signature))
        } catch {
            throw HiPayError.from(error)
        }
    }
}
