/// Outcome of a save requested via `HiPayCardEntryController.pay(saveCard: true)`, published by
/// the controller so a host can react — e.g. a "card saved" confirmation or a "this card can't be
/// saved" notice. `nil` until a save is attempted (the payment did not complete, or `saveCard`
/// was false). Mirrors the shared KMP `SavedCardOutcome`.
public enum HiPaySaveOutcome {
    /// The card was persisted for one-click.
    case saved
    /// The payment succeeded but the card could not be represented for storage (missing masked
    /// pan / expiry, or an unrecognized network). Not saved; retrying will not help.
    case notEligible
    /// The payment succeeded and the card was eligible, but the secure store rejected the write.
    /// Not saved; the host may retry or surface a soft error.
    case storageFailed
}
