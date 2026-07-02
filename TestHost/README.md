# TestHost — app-hosted runner for the Swift unit tests

The Swift unit tests in `../Tests/HiPayCardTests` exercise the iOS Keychain, which requires the
test process to carry an application identifier. A plain SPM test target runs inside Apple's
generic `xctest` agent (no identifier → every `SecItem*` call fails with
`errSecMissingEntitlement`), so the tests are hosted in this bare app instead — the standard
approach for Keychain-touching libraries.

- `HiPayCardTestHost` — empty SwiftUI host app (no SDK code; it only provides process identity).
- `HiPayCardTests` — unit-test bundle over `../Tests/HiPayCardTests`, linked against the local
  SPM package (`HiPayCard` + `HiPayCore`).

Run (any booted or bootable iOS simulator; **never** a macOS destination — that would hit the
macOS keychain, which has different semantics):

```bash
# Build the KMP framework first if Kotlin sources changed:
../../scripts/build-xcframework.sh

xcodebuild test -project TestHost.xcodeproj -scheme HiPayCardTestHost \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
