import HiPayFullservice

/// Target HiPay platform.
public enum HiPayEnvironment: Sendable {
    case stage
    case production
}

/// SDK configuration, built by the host and passed to HiPay components.
/// No global state (architecture D7).
public struct HiPayConfiguration: Sendable {
    public let username: String
    public let password: String
    public let environment: HiPayEnvironment

    public init(username: String, password: String, environment: HiPayEnvironment) {
        self.username = username
        self.password = password
        self.environment = environment
    }
}

extension HiPayConfiguration {
    /// Internal bridge to the KMP config — never exposed to merchants (D4).
    package var kmpConfig: HiPayConfig {
        HiPayConfig(
            username: username,
            password: password,
            environment: environment == .stage ? .stage : .production
        )
    }
}
