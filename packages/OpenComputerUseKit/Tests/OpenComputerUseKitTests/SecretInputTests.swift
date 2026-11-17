@testable import OpenComputerUseKit
import XCTest

final class SecretInputTests: XCTestCase {
    override func tearDown() {
        SecretInput.forgetAll()
    }

    func testOnlyPasswordLikeOrListedNamesAreAllowed() {
        XCTAssertTrue(SecretInput.isAllowed("CUA_EVAL_PASSWORD", environment: [:]))
        XCTAssertTrue(SecretInput.isAllowed("BANK_PIN", environment: [:]))
        XCTAssertTrue(SecretInput.isAllowed("LOGIN_OTP", environment: [:]))
        XCTAssertFalse(SecretInput.isAllowed("GITHUB_TOKEN", environment: [:]))
        XCTAssertFalse(SecretInput.isAllowed("HOME", environment: [:]))
        XCTAssertFalse(SecretInput.isAllowed("BAD NAME", environment: [:]))
        XCTAssertTrue(SecretInput.isAllowed("GITHUB_TOKEN", environment: ["OPEN_COMPUTER_USE_SECRET_ENV": "A, GITHUB_TOKEN"]))
    }

    func testResolvedValuesAreRedactedFromResults() throws {
        let value = try SecretInput.resolve("X_PASSWORD", environment: ["X_PASSWORD": "hunter2"])
        XCTAssertEqual(value, "hunter2")
        let result = SecretInput.redact(ToolCallResult.text("~ 2 text field Value: hunter2"))
        XCTAssertEqual(result.primaryText, "~ 2 text field Value: •••")
        XCTAssertThrowsError(try SecretInput.resolve("X_PASSWORD", environment: [:]))
        XCTAssertThrowsError(try SecretInput.resolve("HOME", environment: ["HOME": "/Users/x"]))
    }

    func testReferencedNamesIncludeBatchSteps() {
        let params: [String: Any] = ["arguments": ["app": "A", "steps": [["tool": "type_text", "secret_env": "A_PASSWORD"]]]]
        XCTAssertEqual(SecretInput.referencedNames(in: params), ["A_PASSWORD"])
    }

    func testDispatcherRejectsTextTogetherWithSecret() {
        let dispatcher = ComputerUseToolDispatcher()
        XCTAssertThrowsError(try dispatcher.callTool(name: "type_text", arguments: ["app": "missing-test-app", "text": "x", "secret_env": "A_PASSWORD"]))
    }
}
