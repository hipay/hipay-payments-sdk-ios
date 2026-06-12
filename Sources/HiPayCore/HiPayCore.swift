import HiPayFullservice

// Swift facade over the HiPayFullservice KMP framework (architecture D4):
// 100% of the public iOS API lives here; the ObjC export of the KMP framework
// is an internal detail merchants never see.

public enum HiPay {

    /// Walking-skeleton probe (story 1.3): round-trips a value computed in
    /// Kotlin commonMain through the XCFramework. Removed once the real API
    /// lands (story 2.1+).
    public static func ping() async throws -> String {
        try await PingKt.ping()
    }
}
