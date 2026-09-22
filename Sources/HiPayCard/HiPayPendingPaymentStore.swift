// PCI: the card path — NEVER log here.
import Foundation
import HiPayCore
import HiPayPayments

/// Its own flag, armed after a successful sweep, so a transient failure retries on the next launch.
private let pendingPaymentsLaunchedKey = "com.hipay.pendingpayments.launched"

/// Serializes the first-launch check-purge-arm section across concurrent factory calls.
private let pendingFirstLaunchLock = NSLock()

/// Assemble a ready `PendingPaymentStore`: the Keychain primitive the saved cards already use, under
/// its own namespace so the two never see each other.
///
/// Runs a first-launch purge for the same reason the saved-card store does — the Keychain survives an
/// uninstall, so without it a reinstall would list payments from a previous install.
///
/// Call off the main thread: the store does blocking Keychain I/O. Several instances may be used at
/// once — they share one lock inside the core.
public func createPendingPaymentStore(
    configuration: HiPayConfiguration,
    pendingTtlMillis: Int64 = PendingPaymentKt.DEFAULT_PENDING_PAYMENT_TTL_MILLIS,
    resolvedTtlMillis: Int64 = PendingPaymentKt.DEFAULT_RESOLVED_PAYMENT_TTL_MILLIS
) -> PendingPaymentStore {
    let namespace = PendingPaymentKt.pendingPaymentNamespace(config: configuration.kmpConfig)
    let raw = HiPayCardSecureStore(namespace: namespace)
    let defaults = UserDefaults.standard
    pendingFirstLaunchLock.lock()
    if !defaults.bool(forKey: pendingPaymentsLaunchedKey) {
        raw.clear()
        defaults.set(true, forKey: pendingPaymentsLaunchedKey)
    }
    pendingFirstLaunchLock.unlock()
    return PendingPaymentStore(
        raw: raw,
        now: { KotlinLong(value: Int64(Date().timeIntervalSince1970 * 1000)) },
        pendingTtlMillis: pendingTtlMillis,
        resolvedTtlMillis: resolvedTtlMillis
    )
}

/// The recovery entry point on iOS. Build it at launch — it is cheap, and the Keychain-backed store
/// behind it opens on first use, off the main thread.
///
/// Deliberately not on the card component: after a process death there is no component left to ask,
/// which is exactly when this is needed.
/// The entry lifetimes belong to the reader: expiry is evaluated when the list is read, so shortening
/// them here is what makes the flow testable without waiting seven days.
public func hiPayPaymentRecovery(
    configuration: HiPayConfiguration,
    pendingTtlMillis: Int64 = PendingPaymentKt.DEFAULT_PENDING_PAYMENT_TTL_MILLIS,
    resolvedTtlMillis: Int64 = PendingPaymentKt.DEFAULT_RESOLVED_PAYMENT_TTL_MILLIS
) -> HiPayPaymentRecovery {
    HiPayPaymentRecoveryKt.hiPayPaymentRecovery(config: configuration.kmpConfig) {
        createPendingPaymentStore(
            configuration: configuration,
            pendingTtlMillis: pendingTtlMillis,
            resolvedTtlMillis: resolvedTtlMillis
        )
    }
}
