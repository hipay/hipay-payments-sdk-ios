import Foundation
import HiPayCore
import HiPayFullservice
import Security
import XCTest
@testable import HiPayCard

/// Runs against the REAL simulator Keychain (no fake) — always on an iOS Simulator destination.
/// The pure store logic is covered by the shared Kotlin commonTest; here we verify the Swift
/// primitive round-trips through the Keychain and self-heals on the failure paths.
final class HiPayCardSecureStoreTests: XCTestCase {

    private var namespace = ""
    private var store: HiPayCardSecureStore!

    override func setUp() {
        super.setUp()
        namespace = "test.hipay.savedcards.\(UUID().uuidString)"
        store = HiPayCardSecureStore(namespace: namespace)
    }

    override func tearDown() {
        store.clear()
        super.tearDown()
    }

    func test_missing_entry_reads_nil() {
        XCTAssertNil(store.read())
    }

    func test_round_trip_write_then_read() {
        store.write(value: "hello-blob")
        XCTAssertEqual("hello-blob", store.read())
    }

    func test_round_trip_preserves_non_ascii_content() {
        let blob = #"{"holder":"Émilie Müller — 你好"}"#
        store.write(value: blob)
        XCTAssertEqual(blob, store.read())
    }

    func test_write_overwrites_previous_value() {
        store.write(value: "v1")
        store.write(value: "v2")
        XCTAssertEqual("v2", store.read())
    }

    func test_clear_removes_the_entry() {
        store.write(value: "x")
        store.clear()
        XCTAssertNil(store.read())
    }

    func test_clear_on_missing_entry_is_a_clean_no_op() {
        store.clear()
        XCTAssertNil(store.read())
    }

    func test_round_trip_of_a_realistic_envelope_blob() {
        let blob = #"{"version":1,"seq":1,"cards":[]}"#
        store.write(value: blob)
        XCTAssertEqual(blob, store.read())
    }

    func test_distinct_namespaces_are_isolated() {
        let other = HiPayCardSecureStore(namespace: "other.\(namespace)")
        store.write(value: "mine")
        defer { other.clear() }
        XCTAssertNil(other.read())
    }

    func test_undecodable_entry_reads_nil_and_purges_itself() {
        seedRawBytes(Data([0xFF, 0xFE, 0x00, 0xC3]))
        XCTAssertNil(store.read())
        XCTAssertFalse(rawItemExists()) // dead entry purged
        store.write(value: "recovered")
        XCTAssertEqual("recovered", store.read())
    }

    // Same namespace the factory derives (same username/environment through the KMP bridge).
    private var testConfigNamespace: String {
        RawSecureStoreKt.secureCardStoreNamespace(
            config: HiPayConfig(username: "test-user", password: "pw", environment: .stage, settings: nil)
        )
    }

    // CAUTION: this test sweeps EVERY item under the fixed saved-cards service in the process's
    // Keychain — run the suite on dedicated test simulators, not one holding real demo data.
    func test_first_launch_purge_clears_every_namespace_once() {
        let configuration = HiPayConfiguration(username: "test-user", password: "pw", environment: .stage)
        let configStore = HiPayCardSecureStore(namespace: testConfigNamespace)
        let defaults = UserDefaults.standard
        let hadFlag = defaults.bool(forKey: savedCardsLaunchedKey)
        defer {
            configStore.clear()
            // Symmetric restore: leave the flag exactly as found (absent stays absent).
            if hadFlag {
                defaults.set(true, forKey: savedCardsLaunchedKey)
            } else {
                defaults.removeObject(forKey: savedCardsLaunchedKey)
            }
        }

        defaults.removeObject(forKey: savedCardsLaunchedKey)
        store.write(value: "residual")
        _ = createSecureCardStore(configuration: configuration)
        XCTAssertNil(store.read()) // the purge swept ALL namespaces, not just the config's
        XCTAssertTrue(defaults.bool(forKey: savedCardsLaunchedKey))
        store.write(value: "kept")
        _ = createSecureCardStore(configuration: configuration) // flag now set — no second purge
        XCTAssertEqual("kept", store.read())
    }

    func test_factory_returns_a_working_store() {
        let configuration = HiPayConfiguration(username: "test-user", password: "pw", environment: .stage)
        let secureStore = createSecureCardStore(configuration: configuration)
        let configStore = HiPayCardSecureStore(namespace: testConfigNamespace)
        defer { configStore.clear() }
        XCTAssertTrue(secureStore.list().isEmpty) // fresh namespace + real clock: no crash, no cards
    }

    func test_write_asserts_the_protection_class_even_on_a_preexisting_item() {
        seedRawBytes(Data("seeded".utf8)) // raw item WITHOUT the accessibility attribute
        store.write(value: "updated")
        XCTAssertEqual("updated", store.read())
        XCTAssertEqual(
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
            rawAccessibleAttribute()
        )
    }

    // MARK: - raw Keychain access (bypasses the store)

    /// The item's `kSecAttrAccessible` value as stored, or nil if the item is absent.
    private func rawAccessibleAttribute() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: savedCardsService,
            kSecAttrAccount as String: namespace,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any] else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }

    private func seedRawBytes(_ data: Data) {
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: savedCardsService,
            kSecAttrAccount as String: namespace,
            kSecValueData as String: data,
        ]
        XCTAssertEqual(errSecSuccess, SecItemAdd(attributes as CFDictionary, nil))
    }

    private func rawItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: savedCardsService,
            kSecAttrAccount as String: namespace,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) != errSecItemNotFound
    }
}
