import XCTest
@testable import OpenGlasses

/// The x-callback-url return leg is an `openglasses://` deep link, so any app on the device can
/// open it. While a `run_shortcut` call is pending (up to 30s) another app could answer it with
/// text of its own, and that text is handed to the model as the tool's result. These cover the
/// one-shot token that closes it.
@MainActor
final class ShortcutCallbackTrustTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Token matching

    func testCallbackWithTheMintedTokenMatches() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertTrue(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=\(token)&output=hi"), expected: token))
    }

    func testCallbackWithoutATokenIsRejected() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?output=spoofed"), expected: token))
    }

    func testCallbackWithAWrongTokenIsRejected() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=guessed&output=spoofed"), expected: token))
    }

    /// Nothing pending: a callback arriving unprompted must never match.
    func testCallbackWithNothingPendingIsRejected() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=\(token)"), expected: nil))
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=\(token)"), expected: ""))
    }

    func testNearMissTokenIsRejected() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=\(token.dropLast())"), expected: token))
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb=\(token)x"), expected: token))
    }

    func testEmptyTokenParamIsRejected() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        XCTAssertNil(ShortcutCallbackManager.token(in: url("openglasses://shortcut-result?cb=")))
        XCTAssertFalse(ShortcutCallbackManager.isMatchingCallback(
            url: url("openglasses://shortcut-result?cb="), expected: token))
    }

    func testTokensAreUniquePerInvocation() {
        let tokens = Set((0..<50).map { _ in ShortcutCallbackManager.makeCallbackToken() })
        XCTAssertEqual(tokens.count, 50, "a reused token would let one callback answer another call")
    }

    // MARK: - Wire format

    /// The token rides unencoded inside the outer `shortcuts://x-callback-url` query. That's only
    /// safe because its alphabet contains no `&` (the outer delimiter) — assert it, since a change
    /// to the generator would silently truncate the callback URL Shortcuts receives.
    func testTokenAlphabetCannotBreakOutOfTheOuterQuery() {
        for _ in 0..<50 {
            let token = ShortcutCallbackManager.makeCallbackToken()
            XCTAssertFalse(token.contains("&"), "‘\(token)’ would terminate the x-success value")
            XCTAssertFalse(token.contains("?"))
            XCTAssertFalse(token.contains("="))
            XCTAssertFalse(token.contains("+"))
            XCTAssertFalse(token.contains("/"))
        }
    }

    /// A nested `?` inside a query value is legal and non-delimiting, so the callback URL must
    /// survive a round trip through the outer URL exactly as built.
    func testCallbackURLSurvivesEmbeddingInTheOuterQuery() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        let inner = "openglasses://shortcut-result?cb=\(token)"
        let outer = url("shortcuts://x-callback-url/run-shortcut?name=Test&x-success=\(inner)")

        let extracted = URLComponents(url: outer, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "x-success" }?.value
        XCTAssertEqual(extracted, inner, "the callback URL must reach Shortcuts intact")

        // And the app must still recognise its own token coming back.
        XCTAssertTrue(ShortcutCallbackManager.isMatchingCallback(url: url(extracted!), expected: token))
    }

    /// The outer `name` param must not be swallowed by the nested query.
    func testOuterParamsStillParseAlongsideTheNestedCallback() {
        let token = ShortcutCallbackManager.makeCallbackToken()
        let outer = url("shortcuts://x-callback-url/run-shortcut?name=Test"
                        + "&x-success=openglasses://shortcut-result?cb=\(token)"
                        + "&x-cancel=openglasses://shortcut-cancel?cb=\(token)")
        let items = URLComponents(url: outer, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Test")
        XCTAssertNotNil(items.first { $0.name == "x-cancel" }?.value)
        XCTAssertNil(items.first { $0.name == "cb" }?.value,
                     "the nested token must not surface as an outer parameter")
    }

    // MARK: - End to end through the manager

    func testSpoofedCallbackDoesNotResolveButTheRealOneDoes() async {
        let manager = ShortcutCallbackManager()
        let token = ShortcutCallbackManager.makeCallbackToken()
        manager.setPending(toolName: "run_shortcut", callbackToken: token)

        async let pending = manager.waitForResult(timeout: 5)

        // Let the continuation be installed before any callback arrives.
        try? await Task.sleep(nanoseconds: 100_000_000)

        // A hostile app answers first — must be ignored.
        manager.handleCallback(url: url("openglasses://shortcut-result?output=spoofed"))
        manager.handleCallback(url: url("openglasses://shortcut-result?cb=wrong&output=spoofed"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        // The real shortcut answers.
        manager.handleCallback(url: url("openglasses://shortcut-result?cb=\(token)&output=real"))

        let result = await pending
        XCTAssertEqual(result, "real", "the spoofed callbacks must not have resolved the wait")
    }

    /// The token is burned on use, so a captured callback can't answer the next invocation.
    func testCallbackTokenIsNotReplayable() async {
        let manager = ShortcutCallbackManager()
        let token = ShortcutCallbackManager.makeCallbackToken()
        manager.setPending(toolName: "run_shortcut", callbackToken: token)

        async let first = manager.waitForResult(timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000)
        manager.handleCallback(url: url("openglasses://shortcut-result?cb=\(token)&output=first"))
        let firstResult = await first
        XCTAssertEqual(firstResult, "first")

        // A second invocation mints a different token; the old callback must not answer it.
        let newToken = ShortcutCallbackManager.makeCallbackToken()
        manager.setPending(toolName: "run_shortcut", callbackToken: newToken)
        async let second = manager.waitForResult(timeout: 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        manager.handleCallback(url: url("openglasses://shortcut-result?cb=\(token)&output=replayed"))

        let secondResult = await second
        XCTAssertNil(secondResult, "the replayed callback should have been ignored, leaving a timeout")
    }

    func testCancelAndErrorCallbacksAlsoRequireTheToken() async {
        let manager = ShortcutCallbackManager()
        let token = ShortcutCallbackManager.makeCallbackToken()
        manager.setPending(toolName: "run_shortcut", callbackToken: token)

        async let pending = manager.waitForResult(timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000)

        manager.handleCallback(url: url("openglasses://shortcut-cancel"))
        manager.handleCallback(url: url("openglasses://shortcut-error?output=fake"))
        try? await Task.sleep(nanoseconds: 100_000_000)

        manager.handleCallback(url: url("openglasses://shortcut-cancel?cb=\(token)"))
        let result = await pending
        XCTAssertEqual(result, "Shortcut was cancelled.")
    }
}
