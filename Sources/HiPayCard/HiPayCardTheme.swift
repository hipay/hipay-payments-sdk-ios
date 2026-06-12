/// Opaque styling extension point — theming is deferred post-v1 (architecture
/// decision); the parameter exists now so adding themes later is not a
/// breaking change (D4).
public struct HiPayCardTheme: Sendable {
    public static let `default` = HiPayCardTheme()

    private init() {}
}
