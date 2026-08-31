import Foundation
import HiPayPayments

/// Optional gateway parameters for an order, passed to `pay(...)` / `payWithSavedCard(...)`.
/// Every field is optional; a `nil` field is NOT sent.
///
/// ```swift
/// let options = HiPayOrderOptions(
///     notifyUrl: "https://your-backend.example/hipay/notify",
///     softDescriptor: "MY SHOP"
/// )
/// let tx = try await controller.pay(orderId: …, amount: …, description: …,
///                                   redirectScheme: …, options: options)
/// ```
///
/// A struct with defaulted properties rather than the KMP builder: adding a property here stays
/// source-compatible for you, which is the same guarantee the Kotlin side gets from its builder.
/// `custom` is the escape hatch for a gateway parameter this SDK does not model.
public struct HiPayOrderOptions: Sendable {
    /// Overrides the back-office notification URL for this order only. Must be `http(s)`.
    ///
    /// Not covered by the order signature, so a tampered build of your app could redirect the
    /// notification. Notifications stay signed, so nothing can be forged in your name, but yours can be
    /// suppressed. Prefer the back-office setting in production.
    public var notifyUrl: String?

    /// Bank-statement descriptor. Acquirers truncate and normalise it, so treat length as advisory.
    public var softDescriptor: String?

    /// A longer description, where the order's `description` is the short one.
    public var longDescription: String?

    /// Shopping-cart JSON, as the gateway documents it. Passed through verbatim.
    public var basket: String?

    /// Any other gateway parameter, by its exact wire name. Names the SDK owns are rejected when the
    /// order is built — see `OrderOptions.RESERVED_FIELDS`.
    public var custom: [String: String]

    public init(
        notifyUrl: String? = nil,
        softDescriptor: String? = nil,
        longDescription: String? = nil,
        basket: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.notifyUrl = notifyUrl
        self.softDescriptor = softDescriptor
        self.longDescription = longDescription
        self.basket = basket
        self.custom = custom
    }

    /// Builds the KMP value. Throws `HiPayError.validation` on a rejected value — a non-http
    /// `notifyUrl`, a blank value, or a reserved `custom` name. The
    /// validation is the shared one, so both channels refuse exactly the same inputs.

    /// `package`, not `internal`: the Apple Pay module needs it to attach options to a wallet order,
    /// and not `public`, because that would put the Kotlin `OrderOptions` type in the surface
    /// merchants see (D4 — the KMP models never cross into host code).
    package var kmp: OrderOptions {
        get throws {
            let builder = OrderOptions.Builder()
            do {
                if let notifyUrl { _ = builder.notifyUrl(url: notifyUrl) }
                if let softDescriptor { _ = builder.softDescriptor(descriptor: softDescriptor) }
                if let longDescription { _ = builder.longDescription(description: longDescription) }
                if let basket { _ = builder.basket(json: basket) }
                // Sorted so a rejected entry always reports the same one, whatever the dictionary order.
                for name in custom.keys.sorted() {
                    _ = builder.custom(name: name, value: custom[name]!)
                }
                return try builder.build()
            } catch {
                throw HiPayError.from(error)
            }
        }
    }
}
