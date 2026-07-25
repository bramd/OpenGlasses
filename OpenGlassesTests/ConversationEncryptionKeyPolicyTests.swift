import XCTest
import Security
@testable import OpenGlasses

/// Guards the one rule that stands between a cancelled Face ID prompt and permanently unreadable
/// conversation history: **only `errSecItemNotFound` may mint a new key.**
///
/// `getOrCreateKey` deletes the live Keychain item and generates a replacement whenever it decides
/// no key exists. Because the item is `.userPresence`-protected, `SecItemCopyMatching` also fails
/// when the user cancels the prompt, is in biometric lockout, or the device is locked. If any of
/// those collapse into "no key", the old key is destroyed and every `OGENC1` file on disk becomes
/// undecryptable. `retrievalError(for:)` is the pure seam that keeps them apart, so it can be
/// exercised here without a live Keychain or a biometric prompt.
final class ConversationEncryptionKeyPolicyTests: XCTestCase {

    // MARK: - The one status that may create a key

    func testItemNotFoundIsTheOnlyKeyNotFoundStatus() {
        XCTAssertEqual(ConversationEncryptionService.retrievalError(for: errSecItemNotFound),
                       .keyNotFound)
    }

    // MARK: - Presence failures must never read as "no key"

    func testUserCancelledPromptDoesNotReportKeyMissing() {
        XCTAssertEqual(ConversationEncryptionService.retrievalError(for: errSecUserCanceled),
                       .authenticationFailed)
    }

    func testBiometricLockoutDoesNotReportKeyMissing() {
        XCTAssertEqual(ConversationEncryptionService.retrievalError(for: errSecAuthFailed),
                       .authenticationFailed)
    }

    /// The background-save case: device locked, so a `WhenUnlocked` item can't be read.
    func testLockedDeviceDoesNotReportKeyMissing() {
        XCTAssertEqual(ConversationEncryptionService.retrievalError(for: errSecInteractionNotAllowed),
                       .authenticationFailed)
    }

    // MARK: - Everything else is a plain failure, not a licence to regenerate

    func testUnexpectedStatusMapsToKeychainErrorNotKeyNotFound() {
        let error = ConversationEncryptionService.retrievalError(for: errSecDecode)
        guard case .keychainError = error else {
            return XCTFail("Expected .keychainError, got \(error)")
        }
    }

    /// The property that actually matters, stated once over the whole failure space: no status
    /// other than `errSecItemNotFound` may ever produce `.keyNotFound`.
    func testNoOtherStatusEverYieldsKeyNotFound() {
        let statuses: [OSStatus] = [
            errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed,
            errSecDecode, errSecParam, errSecAllocate, errSecNotAvailable,
            errSecDuplicateItem, errSecMissingEntitlement, errSecInvalidKeychain,
            errSecIO, errSecUnimplemented, errSecBadReq, errSecInternalComponent,
            0, -1, -25300 + 1,
        ]
        for status in statuses where status != errSecItemNotFound {
            XCTAssertNotEqual(ConversationEncryptionService.retrievalError(for: status),
                              .keyNotFound,
                              "status \(status) must not be treated as a missing key — it would "
                              + "destroy the existing key and orphan all encrypted history")
        }
    }
}
