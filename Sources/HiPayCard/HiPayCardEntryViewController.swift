import SwiftUI
import UIKit

/// UIKit / Compose-Multiplatform interop accessor (D1): wraps the SwiftUI
/// entry view in a `UIHostingController` so non-SwiftUI hosts can embed the
/// component (`UIKitViewController` on the CMP side).
public enum HiPayCardEntryViewController {

    @MainActor
    public static func make(
        controller: HiPayCardEntryController,
        theme: HiPayCardTheme = .hipayDefault
    ) -> UIViewController {
        UIHostingController(rootView: HiPayCardEntryView(controller: controller, theme: theme))
    }
}
