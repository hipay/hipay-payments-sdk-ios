// The facade re-exports the shared multiplatform module so that `import HiPayCore` (or
// `HiPayCard`, which depends on it) is genuinely sufficient — the integration rule the
// documentation states, and which a plain `typealias` cannot deliver: an alias exposes the NAME of a
// type, not its initializers or its enum cases, so styling the component or configuring the SDK
// still failed with "missing import of defining module".
//
// Trade-off, deliberately taken: `@_exported` is an underscored Swift feature (stable in practice,
// widely used for facade modules, but not formally supported), and it widens the facade's namespace
// to the whole shared surface. The alternative — hand-written Swift wrappers for every shared type
// exposed to integrators — is the cleaner long-term shape and belongs to a dedicated facade pass.
@_exported import HiPayPayments
