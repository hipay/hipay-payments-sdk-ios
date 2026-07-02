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
/// LIMITATION (by design): the exported `write(value:)` returns void and a Swift error cannot
/// cross into Kotlin frames (Kotlin/Native terminates on foreign exceptions), so a failed write
/// cannot surface as `save() == false` the way the Kotlin primitives report it. To never serve a
/// stale previous blob as current, a failed add/update deletes the item instead. Same for `clear()`.
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
        var status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var attributes = baseQuery
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        if status != errSecSuccess {
            SecItemDelete(baseQuery as CFDictionary) // never leave a stale previous blob (see LIMITATION)
        }
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary) // errSecItemNotFound = already clear
    }
}

/// One-time sweep of every saved-card item (all namespaces) under the fixed service.
func purgeAllSavedCardItems() {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: savedCardsService,
    ]
    SecItemDelete(query as CFDictionary) // errSecItemNotFound = nothing to purge
}

/// Assemble a ready `SecureCardStore` for iOS-native: the Keychain `HiPayCardSecureStore` + a
/// `Calendar`-based clock. Runs a one-time first-launch purge of ALL namespaces — the iOS Keychain
/// survives app uninstall, so without it a reinstall would resurrect the previous install's saved
/// cards; the `UserDefaults` flag IS wiped on uninstall, which is exactly the fresh-install
/// detector. The configuration carries no one-click reference — enabling one-click is the
/// integrator's explicit opt-in. Call from a single background thread (the returned store is not
/// thread-safe).
public func createSecureCardStore(configuration: HiPayConfiguration) -> SecureCardStore {
    let defaults = UserDefaults.standard
    if !defaults.bool(forKey: savedCardsLaunchedKey) {
        purgeAllSavedCardItems()
        defaults.set(true, forKey: savedCardsLaunchedKey)
    }
    let namespace = RawSecureStoreKt.secureCardStoreNamespace(config: configuration.kmpConfig)
    return SecureCardStore(raw: HiPayCardSecureStore(namespace: namespace)) {
        let components = Calendar.current.dateComponents([.year, .month], from: Date())
        return YearMonth(year: Int32(components.year ?? 0), month: Int32(components.month ?? 0))
    }
}
