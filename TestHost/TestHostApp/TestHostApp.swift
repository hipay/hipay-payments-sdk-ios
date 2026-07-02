import SwiftUI

// Bare host app for the Swift unit tests: the Keychain requires the test process to carry an
// application identifier, which a plain SPM test bundle (run by Apple's generic xctest agent)
// does not have. Hosting the tests in an app process is the standard fix. No SDK code here —
// the tested code is linked into the test bundle, not the host.
@main
struct TestHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("HiPayCard test host")
        }
    }
}
