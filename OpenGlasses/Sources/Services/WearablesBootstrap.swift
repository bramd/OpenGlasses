import Foundation
import MWDATCore

/// Idempotent `Wearables.configure()`.
///
/// Any access to `Wearables.shared` before `configure()` is a hard fatal inside the SDK
/// ("Call `configure()` before attempting to access Wearables!"), so every entry point that
/// reaches the SDK has to be certain configuration already happened.
///
/// Configuration used to run at launch only when `Config.hasCompletedOnboarding`, deliberately
/// deferred so the Bluetooth prompt lands during onboarding rather than at first launch. But
/// onboarding is only *shown* when `Config.needsOnboarding`, which additionally requires that no
/// API key is saved. Save a key without finishing onboarding and neither flag holds: onboarding
/// stops appearing, nothing ever calls `configure()`, there is no in-app route back to
/// onboarding, and the first tap on Connect killed the app.
///
/// Configuring lazily at the point of use keeps the deferral intent — the permission prompt still
/// waits until the user actually reaches for the glasses — without the two flags having to agree.
enum WearablesBootstrap {
    /// Main-thread only; every caller is main-actor isolated (App init, views, services).
    private static var isConfigured = false

    /// Configure the SDK unless that already happened. Returns whether it is safe to touch
    /// `Wearables.shared`; callers must treat `false` as "SDK unusable" rather than pressing on,
    /// because the alternative is the fatal above.
    @discardableResult
    static func ensureConfigured() -> Bool {
        if isConfigured { return true }
        do {
            try Wearables.configure()
            isConfigured = true
        } catch {
            // Typically malformed or missing MWDAT keys in Info.plist. Surfaced to the user by
            // the caller's connection status; logged here so the reason is in the device console.
            NSLog("[Wearables] configure() failed: \(error.localizedDescription)")
        }
        return isConfigured
    }
}
