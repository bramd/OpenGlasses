import XCTest
@testable import OpenGlasses

/// The `openglasses://` scheme is an unauthenticated entry point — any app on the device can open
/// it silently. These cover the two halves of the fix: which links demand a first-party caller,
/// and whether a presented token is actually accepted.
final class DeepLinkTrustTests: XCTestCase {

    private let suiteName = "DeepLinkTrustTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        DeepLinkTrust.testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        DeepLinkTrust.testDefaults = nil
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: - Policy: what needs a trusted caller

    func testActingLinksRequireTrust() {
        let acting: [(String, String)] = [
            ("action", "photo"),      // captures a frame from the glasses
            ("action", "describe"),   // captures and sends to the LLM
            ("action", "ask"),        // opens the mic
            ("listen", "on"),
            ("listen", "toggle"),
            ("quickaction", "some-id"),
            ("persona", "some-id"),   // applies routing then starts a listening turn
            ("connect", "connect"),   // connectAndListen
        ]
        for (host, action) in acting {
            XCTAssertTrue(DeepLinkTrust.requiresTrustedCaller(host: host, action: action),
                          "\(host)/\(action) acts and must require a trusted caller")
        }
    }

    /// Capability-*reducing* links stay open on purpose — a hostile caller gains nothing by
    /// stopping the mic, and gating them would break the panic-off path.
    func testCapabilityReducingLinksStayOpen() {
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: "listen", action: "off"))
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: "disconnect", action: "disconnect"))
    }

    func testUnknownHostNeedsNoTrust() {
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: "shortcut-result", action: ""))
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: nil, action: ""))
    }

    func testListenOffIsCaseInsensitive() {
        XCTAssertFalse(DeepLinkTrust.requiresTrustedCaller(host: "listen", action: "OFF"))
    }

    // MARK: - Token round trip

    func testSignedLinkIsTrusted() {
        DeepLinkTrust.ensureToken()
        let signed = DeepLinkTrust.sign("openglasses://action/photo")
        XCTAssertTrue(DeepLinkTrust.isTrusted(url(signed)))
    }

    func testSigningPreservesExistingQuery() {
        DeepLinkTrust.ensureToken()
        let signed = DeepLinkTrust.sign("openglasses://action/photo?mode=wide")
        XCTAssertTrue(signed.contains("mode=wide"))
        XCTAssertTrue(DeepLinkTrust.isTrusted(url(signed)))
    }

    func testTokenIsStableAcrossCalls() {
        let first = DeepLinkTrust.ensureToken()
        let second = DeepLinkTrust.ensureToken()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second, "re-minting would invalidate links already on screen")
    }

    // MARK: - Rejection

    func testUnsignedLinkIsNotTrusted() {
        DeepLinkTrust.ensureToken()
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo")))
    }

    func testWrongTokenIsNotTrusted() {
        DeepLinkTrust.ensureToken()
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo?k=guessed")))
    }

    func testEmptyTokenIsNotTrusted() {
        DeepLinkTrust.ensureToken()
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo?k=")))
    }

    /// A near-miss must not pass — guards against a prefix/substring comparison creeping in.
    func testTruncatedTokenIsNotTrusted() {
        guard let token = DeepLinkTrust.ensureToken(), token.count > 4 else {
            return XCTFail("expected a token")
        }
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo?k=\(token.dropLast())")))
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo?k=\(token)x")))
    }

    /// With no token minted at all, nothing is trusted — `isTrusted` must never default to true.
    func testNothingIsTrustedBeforeAnyTokenExists() {
        XCTAssertNil(DeepLinkTrust.current)
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo?k=anything")))
        XCTAssertFalse(DeepLinkTrust.isTrusted(url("openglasses://action/photo")))
    }

    func testTokenIsLongEnoughToResistGuessing() {
        guard let token = DeepLinkTrust.ensureToken() else { return XCTFail("expected a token") }
        XCTAssertGreaterThanOrEqual(token.count, 20, "128 bits of base64url is ~22 chars")
    }

    func testDistinctTokensAreMintedPerContainer() {
        let first = DeepLinkTrust.ensureToken()
        UserDefaults().removePersistentDomain(forName: suiteName)
        DeepLinkTrust.testDefaults = UserDefaults(suiteName: suiteName)
        let second = DeepLinkTrust.ensureToken()
        XCTAssertNotEqual(first, second, "tokens must be random, not derived from a constant")
    }

    // MARK: - Comparison primitive

    func testConstantTimeEqualsMatchesEquality() {
        XCTAssertTrue(DeepLinkTrust.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(DeepLinkTrust.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(DeepLinkTrust.constantTimeEquals("abc", "ab"))
        XCTAssertFalse(DeepLinkTrust.constantTimeEquals("", "a"))
        XCTAssertTrue(DeepLinkTrust.constantTimeEquals("", ""))
    }
}
