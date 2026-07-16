import HiPayFullservice

/// Target HiPay platform.
public enum HiPayEnvironment: Sendable {
    case stage
    case production
}

/// SDK configuration, built by the host and passed to HiPay components.
/// No global state (architecture D7) — the optional ``settings`` follow the same rule (an injected
/// instance shared across components, never a singleton). Not `Sendable`: ``settings`` is a shared
/// mutable object (the same `HiPaySettings` type used on Android/CMP).
public struct HiPayConfiguration {
    public let username: String
    public let password: String
    public let environment: HiPayEnvironment
    /// Optional cross-cutting SDK settings (e.g. display locale) — the shared `HiPaySettings`.
    /// Defaults to `nil` (each component follows the device locale). Additive since 0.3.0.
    public let settings: HiPaySettings?

    public init(
        username: String,
        password: String,
        environment: HiPayEnvironment,
        settings: HiPaySettings? = nil
    ) {
        self.username = username
        self.password = password
        self.environment = environment
        self.settings = settings
    }
}

extension HiPayConfiguration {
    /// Internal bridge to the KMP config — never exposed to merchants (D4). Carries the same shared
    /// ``settings`` so the language preference is one instance across the whole SDK.
    package var kmpConfig: HiPayConfig {
        HiPayConfig(
            username: username,
            password: password,
            environment: environment == .stage ? .stage : .production,
            settings: settings
        )
    }
}
