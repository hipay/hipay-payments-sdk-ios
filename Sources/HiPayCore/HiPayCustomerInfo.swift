import Foundation
import HiPayFullservice

/// Optional customer / shipping details attached to an order (FR27, story 6.1).
/// All fields are optional; a `nil` field is NOT sent.
///
/// Field contract (mirrors the legacy mapper):
/// - `state` is the **region/state**.
/// - `country` is an **ISO code** (e.g. `"FR"`), NOT the country name.
/// - `email` / `phone` are **customer-only**: when this value is passed as the
///   shipping address, the SDK sends the `shipto_` personal-info subset and
///   drops email/phone.
///
/// The same value type is used for both the customer and the shipping address;
/// the SDK maps it to the KMP `CustomerInfo`, which performs the flat (customer)
/// vs `shipto_`-prefixed (shipping) serialization.
public struct HiPayCustomerInfo: Sendable {
    public var firstName: String?
    public var lastName: String?
    public var email: String?
    public var phone: String?
    public var streetAddress: String?
    public var streetAddress2: String?
    public var recipientInfo: String?
    public var city: String?
    public var state: String?
    public var zipCode: String?
    public var country: String?

    public init(
        firstName: String? = nil,
        lastName: String? = nil,
        email: String? = nil,
        phone: String? = nil,
        streetAddress: String? = nil,
        streetAddress2: String? = nil,
        recipientInfo: String? = nil,
        city: String? = nil,
        state: String? = nil,
        zipCode: String? = nil,
        country: String? = nil
    ) {
        self.firstName = firstName
        self.lastName = lastName
        self.email = email
        self.phone = phone
        self.streetAddress = streetAddress
        self.streetAddress2 = streetAddress2
        self.recipientInfo = recipientInfo
        self.city = city
        self.state = state
        self.zipCode = zipCode
        self.country = country
    }

    /// Maps to the KMP `CustomerInfo` (the legacy-parity serializer). Internal —
    /// the host only ever sees `HiPayCustomerInfo`.
    func kmp() -> CustomerInfo {
        CustomerInfo(
            firstName: firstName,
            lastName: lastName,
            streetAddress: streetAddress,
            streetAddress2: streetAddress2,
            recipientInfo: recipientInfo,
            city: city,
            state: state,
            zipCode: zipCode,
            country: country,
            email: email,
            phone: phone
        )
    }
}
