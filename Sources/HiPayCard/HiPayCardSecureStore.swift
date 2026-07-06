// PCI: card path — NEVER log here, never expose the raw PAN or token.
import Foundation
import HiPayCore
import HiPayFullservice
import Security

// One generic-password item per namespace: FIXED service + namespace as the account — the same
// scheme as the Kotlin/Native CMP-iOS primitive, so both integration paths stay format-compatible
// and the first-launch purge sweeps every namespace with a single delete.
let savedCardsService = "com.hipay.savedcards"
let savedCardsLaunchedKey = "com.hipay.savedcards.launched"

/// iOS-native `RawSecureStore`: the store's serialized blob as a Keychain generic-password item —
/// `AfterFirstUnlockThisDeviceOnly`, so it is device-bound (never migrates via backup/transfer)
/// and never iCloud-synced. The OS encrypts Keychain items at rest. The saved-card LOGIC stays in
/// the exported Kotlin `SecureCardStore`; this class is only the storage primitive.
///
/// Failure handling on read is two-tier, never throws, never logs:
/// - dead entry (item data not decodable as UTF-8) → delete the item so a later write starts clean;
/// - transient status (e.g. `errSecInteractionNotAllowed` before the first unlock after boot —
///   real under the `AfterFirstUnlock` class) → nil WITHOUT deleting (the data is likely intact).
///
/// LIMITATION (by design): a Swift error cannot cross into Kotlin frames (Kotlin/Native
/// terminates on foreign exceptions), so mutation failures cannot be signaled the way the Kotlin
/// primitives report them:
/// - a failed `write(value:)` is silent — the Kotlin store's `save()` may report true while the
///   PREVIOUS blob (the last consistent state; SecItem operations are atomic) stays current;
/// - a failed `clear()` is silent — `clearAll()` may report true while the item persists.
/// Deletion verification is therefore the caller's duty: check `list()` is empty afterwards, on
/// an unlocked device. (The SDK's public out-of-checkout deletion API performs that check.)
final class HiPayCardSecureStore: NSObject, RawSecureStore {

    private let namespace: String

    init(namespace: String) {
        self.namespace = namespace
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: savedCardsService,
            kSecAttrAccount as String: namespace,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
                SecItemDelete(baseQuery as CFDictionary) // dead entry — purge so the next write starts clean
                return nil
            }
            return text
        case errSecItemNotFound:
            return nil
        default:
            return nil // transient (e.g. device not yet unlocked) — keep the item
        }
    }

    func write(value: String) {
        let data = Data(value.utf8)
        var status = updateItem(data)
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem {
                // Lost the add race against a concurrent writer — the item exists now: update it.
                _ = updateItem(data)
            }
        }
        // On any other failure the previous blob stays: it is the last consistent state (SecItem
        // operations are atomic). The failure itself cannot be signaled (see LIMITATION).
    }

    /// Update half of the upsert — re-asserts the protection class so pre-existing items (created
    /// without it, or restored precisely because they lacked `ThisDeviceOnly`) get upgraded.
    private func updateItem(_ data: Data) -> OSStatus {
        SecItemUpdate(
            baseQuery as CFDictionary,
            [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary
        )
    }

    func clear() {
        // errSecItemNotFound = already clear; any other failure is silent (see LIMITATION).
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// One-time sweep of every saved-card item (all namespaces) under the fixed service.
/// True iff the sweep is known complete (success, or nothing to purge).
@discardableResult
func purgeAllSavedCardItems() -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: savedCardsService,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
}

/// Serializes the first-launch check-purge-arm section across concurrent factory calls.
private let firstLaunchLock = NSLock()

/// Assemble a ready `SecureCardStore` for iOS-native: the Keychain `HiPayCardSecureStore` + a
/// `Calendar`-based clock. Runs a one-time first-launch purge of ALL namespaces — the iOS Keychain
/// survives app uninstall, so without it a reinstall would resurrect the previous install's saved
/// cards; the `UserDefaults` flag IS wiped on uninstall, which is exactly the fresh-install
/// detector. The configuration carries no one-click reference — enabling one-click is the
/// integrator's explicit opt-in. Call from a single background thread (the returned store is not
/// thread-safe).
public func createSecureCardStore(configuration: HiPayConfiguration) -> SecureCardStore {
    let defaults = UserDefaults.standard
    firstLaunchLock.lock()
    // The flag is armed ONLY after a successful sweep: a transient failure (e.g. a background
    // first launch before the device's first unlock) leaves it unset, so the purge retries on
    // the next launch instead of latching stale items in forever.
    if !defaults.bool(forKey: savedCardsLaunchedKey), purgeAllSavedCardItems() {
        defaults.set(true, forKey: savedCardsLaunchedKey)
    }
    firstLaunchLock.unlock()
    let namespace = RawSecureStoreKt.secureCardStoreNamespace(config: configuration.kmpConfig)
    return SecureCardStore(raw: HiPayCardSecureStore(namespace: namespace)) {
        // Pinned Gregorian: the user's calendar (Thai Buddhist year 2569, Japanese era…) would put
        // the year outside the store's plausibility window and silently disable the expiry purge.
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: Date())
        return YearMonth(year: Int32(components.year ?? 0), month: Int32(components.month ?? 0))
    }
}
