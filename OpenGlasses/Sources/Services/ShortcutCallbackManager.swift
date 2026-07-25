import Foundation

/// Manages x-callback-url results from Siri Shortcuts.
/// When a shortcut runs via x-callback-url and finishes, it redirects back
/// to openglasses://shortcut-result with the output. This manager bridges
/// the async gap between the URL open and the callback.
///
/// The return leg is an `openglasses://` deep link, which any app on the device can open — so
/// without a check another app could answer a pending `run_shortcut` with text of its choosing
/// while the real shortcut was still running, and that text would be handed to the model as the
/// tool's result. The app therefore mints a fresh token per invocation, stamps it on the three
/// callback URLs it gives to Shortcuts, and accepts a callback only if it carries that token.
/// Unlike [[DeepLinkTrust]]'s app-group secret this one is per-call and burned on use, so a
/// captured callback URL can't be replayed against a later invocation.
@MainActor
class ShortcutCallbackManager {
    static let shared = ShortcutCallbackManager()

    /// Query item carrying the per-invocation token.
    static let queryName = "cb"

    private var pendingToolName: String?
    private var pendingToken: String?
    private var continuation: CheckedContinuation<String?, Never>?

    /// A fresh callback token. 128 bits, URL-safe: it rides *unencoded* inside the outer
    /// `shortcuts://x-callback-url` query, so the alphabet must avoid `&`, which is a delimiter
    /// there. Base64url with the padding stripped satisfies that.
    static func makeCallbackToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The token carried by a callback URL, if any. Pure — testable without a live callback.
    static func token(in url: URL) -> String? {
        guard let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == queryName })?.value, !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Whether `url` is the answer to the invocation that minted `expected`.
    static func isMatchingCallback(url: URL, expected: String?) -> Bool {
        guard let expected, !expected.isEmpty, let presented = token(in: url) else { return false }
        return DeepLinkTrust.constantTimeEquals(presented, expected)
    }

    /// Mark that we're waiting for a shortcut result, and which token will authenticate it.
    func setPending(toolName: String, callbackToken: String) {
        pendingToolName = toolName
        pendingToken = callbackToken
    }

    /// Wait for the shortcut to callback. Returns the output text or nil on timeout.
    func waitForResult(timeout: TimeInterval = 30) async -> String? {
        return await withCheckedContinuation { cont in
            self.continuation = cont

            // Timeout
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let pending = self.continuation {
                    self.clearPending()
                    pending.resume(returning: nil)
                }
            }
        }
    }

    /// Called when the app receives a callback URL from a shortcut.
    /// URL format: openglasses://shortcut-result?cb=<token>&output=...
    func handleCallback(url: URL) {
        guard Self.isMatchingCallback(url: url, expected: pendingToken) else {
            // Either nothing is pending, or this came from something other than the shortcut we
            // launched. Never resolve on it — whatever it carries becomes tool output the model
            // reads.
            NSLog("[ShortcutCallback] Ignored callback with missing or mismatched token: %@",
                  url.host ?? "?")
            return
        }

        let host = url.host
        let params = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let output = params?.first(where: { $0.name == "output" })?.value
            ?? params?.first(where: { $0.name == "result" })?.value

        switch host {
        case "shortcut-result":
            let result = output ?? "Shortcut completed successfully."
            NSLog("[ShortcutCallback] Result: %@", String(result.prefix(200)))
            resume(with: result)

        case "shortcut-cancel":
            NSLog("[ShortcutCallback] Cancelled")
            resume(with: "Shortcut was cancelled.")

        case "shortcut-error":
            let error = output ?? "Shortcut encountered an error."
            NSLog("[ShortcutCallback] Error: %@", error)
            resume(with: "Shortcut error: \(error)")

        default:
            break
        }
    }

    /// Resolve the pending wait and burn the token, so the same callback URL can't be replayed
    /// against whatever invocation comes next.
    private func resume(with result: String) {
        let pending = continuation
        clearPending()
        pending?.resume(returning: result)
    }

    private func clearPending() {
        continuation = nil
        pendingToolName = nil
        pendingToken = nil
    }
}
