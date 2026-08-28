import Foundation
import HiPayPayments
@testable import HiPayCard

/// The component asks the account which card networks it may offer as soon as the view appears, and
/// shows no brand icon until that answer lands. Unit tests are network-free, so without a preset every
/// chip assertion would depend on a fetch that never completes — or completes at an unpredictable
/// moment under load.
///
/// A permissive ceiling keeps each test asserting what it means to assert: the integrator restriction
/// and the vault verdict. Tests that are ABOUT the ceiling own it themselves.
extension HiPayCardEntryController {
    @MainActor
    func withOfflineCeiling(
        _ accepted: Set<CardNetwork> = [
            CardNetwork.visa, CardNetwork.mastercard, CardNetwork.amex,
            CardNetwork.maestro, CardNetwork.cb, CardNetwork.bcmc,
        ]
    ) -> HiPayCardEntryController {
        presetAccountNetworks(accepted)
        return self
    }
}
