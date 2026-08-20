//
//  HiPayApplePayPayment.swift
//  HiPayApplePay
//
//  The Swift entry points for an Apple Pay payment: eligibility (drives the button's visibility) and
//  the payment itself (the button's tap action).
//
//  Both are thin wrappers over ONE shared Kotlin implementation — `runApplePayPayment` /
//  `resolveApplePayEligibility` — so the sheet behaves identically here and on Compose Multiplatform.
//  Nothing about the flow lives in Swift: no PassKit here, no tokenization, no order building.
//
//  D4: merchants see only these Swift types; the Kotlin models never cross into host code.
//

import Foundation
import HiPayCore
@_implementationOnly import HiPayPayments

// MARK: - Networks

/// The card networks HiPay can route through Apple Pay.
///
/// Deliberately narrower than the card component's network list: Amex and Bancontact are not routable via
/// Apple Pay at HiPay, so this type cannot express a restriction that could never match. A restriction can
/// only ever narrow what the account already accepts — it never widens it.
public enum HiPayApplePayNetwork: String, Sendable, CaseIterable {
    case visa
    case mastercard
    case maestro
    case cb
}

// MARK: - Configuration

/// The Apple Pay parameters supplied by the merchant, alongside the card ``HiPayConfiguration``.
///
/// Kept separate from ``HiPayConfiguration`` (which stays card-focused): a merchant not using Apple Pay
/// provides none of this.
public struct HiPayApplePayConfiguration: Sendable {
    /// The Apple Pay merchant id, e.g. `merchant.com.acme`.
    ///
    /// It must also be listed in the app's Apple Pay entitlement
    /// (`com.apple.developer.in-app-payments`), which is fixed at build time — PassKit refuses an
    /// identifier the app was not signed for.
    public var merchantIdentifier: String

    /// The merchant `.p12` certificate password, sent to the Secure Vault as `private_key_pass`.
    ///
    /// The app uses a MERCHANT certificate, so this is mandatory with no fallback. Inject it at
    /// runtime; never ship it in the binary and never log it.
    public var privateKeyPassword: String

    /// The store's brand, shown to the payer on the Apple Pay sheet's total line. Must be the
    /// merchant's store, not HiPay. Mandatory.
    public var merchantDisplayName: String

    /// An optional dedicated Apple Pay account username. When present BOTH the wallet tokenization and
    /// the order route through it; otherwise the classic account is used. Blank counts as absent.
    public var applePayUsername: String?

    /// An optional restriction on the networks offered in the sheet. Empty accepts every network the
    /// account routes; it can only narrow that set, never widen it. Applied to both the availability
    /// check and the sheet, so the button and the sheet always agree.
    public var allowedNetworks: [HiPayApplePayNetwork]

    public init(
        merchantIdentifier: String,
        privateKeyPassword: String,
        merchantDisplayName: String,
        applePayUsername: String? = nil,
        allowedNetworks: [HiPayApplePayNetwork] = []
    ) {
        self.merchantIdentifier = merchantIdentifier
        self.privateKeyPassword = privateKeyPassword
        self.merchantDisplayName = merchantDisplayName
        self.applePayUsername = applePayUsername
        self.allowedNetworks = allowedNetworks
    }
}

extension HiPayApplePayConfiguration: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted on purpose. `print`, `dump` and most crash reporters use reflection, which would emit the
    /// merchant `.p12` password verbatim — the one thing the property's own documentation forbids.
    public var description: String {
        "HiPayApplePayConfiguration(merchantIdentifier: \(merchantIdentifier), "
            + "merchantDisplayName: \(merchantDisplayName), privateKeyPassword: <redacted>, "
            + "applePayUsername: \(applePayUsername ?? "nil"), "
            + "allowedNetworks: \(allowedNetworks.map(\.rawValue)))"
    }

    public var debugDescription: String { description }
}

// MARK: - Order

/// The order an Apple Pay payment creates. Mirrors the card `pay(...)` inputs; the signature stays the
/// merchant backend's job, exactly as it is for a card payment.
public struct HiPayApplePayOrder: Sendable {
    public var orderId: String
    public var amount: String
    public var currency: String
    /// ISO country of the merchant, required by `PKPaymentRequest`.
    public var countryCode: String
    public var description: String
    /// The app's URL scheme, used to return from an authentication step-up.
    public var redirectScheme: String
    public var language: String
    /// Computed by the merchant backend — never in the app in production.
    public var signature: String?

    public init(
        orderId: String,
        amount: String,
        currency: String,
        countryCode: String,
        description: String,
        redirectScheme: String,
        language: String = "en_GB",
        signature: String? = nil
    ) {
        self.orderId = orderId
        self.amount = amount
        self.currency = currency
        self.countryCode = countryCode
        self.description = description
        self.redirectScheme = redirectScheme
        self.language = language
        self.signature = signature
    }
}

// The existing `description` field already satisfies CustomStringConvertible, so declaring the
// conformance stops `print` from falling back to reflection — which would emit the signature.
extension HiPayApplePayOrder: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted: the signature is derived from the merchant passphrase and must not reach a log.
    public var debugDescription: String {
        "HiPayApplePayOrder(orderId: \(orderId), amount: \(amount) \(currency), "
            + "countryCode: \(countryCode), signature: \(signature == nil ? "nil" : "<redacted>"))"
    }
}

// MARK: - Outcome

/// Every outcome the wallet and the gateway can produce.
///
/// A closed sheet is ``cancelled`` and is NOT an error — it is the payer's normal way out. A refused
/// authorization is ``declined`` and still carries its transaction. Errors are reserved for invalid
/// input and for a gateway that could not be reached at all.
public enum HiPayApplePayOutcome: Sendable {
    /// Authorized and completed. A step-up that the gateway asked for has already been resolved.
    case completed(HiPayTransaction)
    /// The wallet authorized but the gateway refused the payment.
    case declined(HiPayTransaction)
    /// Accepted but not final — re-query the transaction to settle it.
    case pending(HiPayTransaction)
    /// The gateway answered, but not with a completed payment.
    case notCompleted(HiPayTransaction)
    /// The payer dismissed the sheet. Not an error.
    case cancelled
    /// The SDK returned an outcome this version of the facade does not model. Never treat it as success
    /// or as a cancellation: reconcile on the order id.
    case unknown(String)
}

/// Why Apple Pay is or is not offerable — the answer to "why is the button not showing?".
public enum HiPayApplePayAvailabilityReason: Sendable {
    /// Routable networks exist and the device holds a usable card.
    case available
    /// No network is routable for this account. Note Amex is never routable via Apple Pay at HiPay.
    case noRoutableNetwork
    /// The device cannot pay: Apple Pay unsupported, or no provisioned card matches a routable network.
    case deviceNoUsableCard
}

/// The result of an availability check, carrying the reason so a host can explain itself.
public struct HiPayApplePayAvailability: Sendable {
    public let isAvailable: Bool
    public let reason: HiPayApplePayAvailabilityReason
    /// The networks the sheet would offer, by name.
    ///
    /// Diagnostic value: with ``reason`` `.deviceNoUsableCard` this separates the two causes. Empty
    /// means the DEVICE reported it cannot do Apple Pay at all; non-empty means the account routes only
    /// these networks and the Wallet holds no card on any of them.
    public let networks: [String]
}

// MARK: - Entry points

/// Apple Pay payment and eligibility.
public enum HiPayApplePayPayment {

    /// Whether Apple Pay can be offered right now — drives the button's visibility.
    ///
    /// Combines the device's capability (`PKPaymentAuthorizationController`) with the networks the HiPay
    /// account actually accepts. When this is `false` the button must not be shown: Apple's guidance is
    /// to hide Apple Pay rather than offer a payment that cannot succeed.
    public static func isAvailable(
        configuration: HiPayConfiguration,
        currency: String,
        customerCountry: String? = nil,
        applePay: HiPayApplePayConfiguration? = nil
    ) async throws -> Bool {
        try await availability(
            configuration: configuration,
            currency: currency,
            customerCountry: customerCountry,
            applePay: applePay
        ).isAvailable
    }

    /// The same check, with the reason — use this when the host needs to explain why Apple Pay is not
    /// offered rather than silently hiding the button.
    ///
    /// A thrown error means the check itself failed (bad credentials, gateway unreachable) and is NOT
    /// the same as "unavailable": do not collapse the two, or a configuration mistake looks like a
    /// device without a card.
    public static func availability(
        configuration: HiPayConfiguration,
        currency: String,
        customerCountry: String? = nil,
        applePay: HiPayApplePayConfiguration? = nil
    ) async throws -> HiPayApplePayAvailability {
        let result = try await eligibility(configuration, currency, customerCountry, applePay)
        let reason: HiPayApplePayAvailabilityReason
        switch result.reason {
        case .available: reason = .available
        case .noRoutableNetwork: reason = .noRoutableNetwork
        default: reason = .deviceNoUsableCard
        }
        return HiPayApplePayAvailability(
            isAvailable: result.state == .available,
            reason: reason,
            networks: result.resolvedNetworks.map { $0.name }
        )
    }

    /// Presents the Apple Pay sheet and runs the payment.
    ///
    /// A second call while one is in flight fails immediately without presenting a second sheet, so a
    /// double tap cannot create two orders.
    ///
    /// The routable networks are resolved here rather than passed in, so the sheet can never offer a
    /// network the account has stopped accepting since the button was drawn.
    public static func pay(
        configuration: HiPayConfiguration,
        applePay: HiPayApplePayConfiguration,
        order: HiPayApplePayOrder,
        customerCountry: String? = nil
    ) async throws -> HiPayApplePayOutcome {
        // Resolved outside the do/catch: it already throws a mapped HiPayError, and re-wrapping it
        // through HiPayError.from would erase the case (a Swift enum carries no KotlinException).
        let resolved = try await eligibility(configuration, order.currency, customerCountry, applePay)
        do {
            let result = try await ApplePayPresenter_iosKt.runApplePayPayment(
                config: configuration.kmpConfig,
                applePayConfig: applePay.kmp,
                // An unavailable result must not open a sheet. Passing an empty set makes the shared
                // implementation raise its own validation error, so the message is the SDK's and both
                // channels fail identically — rather than PassKit failing to present, which surfaces as
                // an indistinguishable transport-looking error.
                resolvedNetworks: resolved.state == .available ? resolved.resolvedNetworks : [],
                order: order.kmp
            )
            return HiPayApplePayOutcome(result)
        } catch {
            throw HiPayError.from(error)
        }
    }

    private static func eligibility(
        _ configuration: HiPayConfiguration,
        _ currency: String,
        _ customerCountry: String?,
        _ applePay: HiPayApplePayConfiguration?
    ) async throws -> ApplePayEligibilityResult {
        do {
            return try await ApplePayEligibilityKt.resolveApplePayEligibility(
                config: configuration.kmpConfig,
                device: ApplePayDeviceCapability_iosKt.defaultApplePayDeviceCapability(),
                currency: currency,
                customerCountry: customerCountry,
                allowedNetworks: (applePay?.allowedNetworks ?? []).map { $0.kmp }
            )
        } catch {
            throw HiPayError.from(error)
        }
    }
}

// MARK: - Bridges (internal to the package, D4)

private extension HiPayApplePayConfiguration {
    var kmp: HiPayApplePayConfig {
        HiPayApplePayConfig(
            merchantIdentifier: merchantIdentifier,
            privateKeyPassword: privateKeyPassword,
            merchantDisplayName: merchantDisplayName,
            applePayUsername: applePayUsername,
            allowedNetworks: allowedNetworks.map { $0.kmp }
        )
    }
}

private extension HiPayApplePayNetwork {
    var kmp: CardNetwork {
        switch self {
        case .visa: return .visa
        case .mastercard: return .mastercard
        case .maestro: return .maestro
        case .cb: return .cb
        }
    }
}

private extension HiPayApplePayOrder {
    var kmp: ApplePayOrder {
        ApplePayOrder(
            orderId: orderId,
            amount: amount,
            currency: currency,
            countryCode: countryCode,
            description: description,
            redirectScheme: redirectScheme,
            language: language,
            signature: signature
        )
    }
}

private extension HiPayApplePayOutcome {
    /// Maps the Kotlin sealed result. The subclass checks are ordered so no case can be swallowed by a
    /// superclass match.
    init(_ kmp: ApplePayPaymentResult) {
        switch kmp {
        case let completed as ApplePayPaymentResult.Completed:
            self = .completed(HiPayTransaction(completed.transaction))
        case let declined as ApplePayPaymentResult.Declined:
            self = .declined(HiPayTransaction(declined.transaction))
        case let pending as ApplePayPaymentResult.Pending:
            self = .pending(HiPayTransaction(pending.transaction))
        case let notCompleted as ApplePayPaymentResult.NotCompleted:
            self = .notCompleted(HiPayTransaction(notCompleted.transaction))
        case is ApplePayPaymentResult.Cancelled:
            self = .cancelled
        default:
            // Explicit rather than folded into `.cancelled`: a future outcome reported as "the payer
            // walked away" is the one default where a host neither fulfils nor reconciles.
            self = .unknown(String(describing: kmp))
        }
    }
}
