import XCTest
@testable import OpenGlasses

/// The tool timeout has to actually bound the caller's wait.
///
/// It used to race the work against a sentinel inside a `withTaskGroup`, but a task group awaits
/// all of its children before returning — so when the sentinel won, the group still blocked until
/// the real work finished. `cancelAll()` only *requests* cancellation, and most tools here (HomeKit
/// writes, URL-scheme launches, third-party SDK calls) never check it. The timeout bounded nothing.
@MainActor
final class ToolTimeoutTests: XCTestCase {

    private func router(with tool: NativeTool, timeout: TimeInterval) -> NativeToolRouter {
        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(tool)
        let router = NativeToolRouter(registry: registry)
        router.toolTimeoutSeconds = timeout
        return router
    }

    /// The regression: a tool that ignores cancellation must not hold the turn open past the
    /// timeout. Before the fix this returned only after the tool's full 2s.
    func testTimeoutReturnsWithoutWaitingForUncancellableWork() async {
        let router = router(with: UncancellableTool(name: "slow_tool", seconds: 2.0), timeout: 0.3)

        let started = Date()
        let result = await router.handleToolCall(name: "slow_tool", args: [:])
        let elapsed = Date().timeIntervalSince(started)

        guard case .failure(let message) = result else {
            return XCTFail("expected a timeout failure, got \(result)")
        }
        XCTAssertTrue(message.contains("timed out"), "got: \(message)")
        XCTAssertLessThan(elapsed, 1.5,
                          "returned after \(elapsed)s — the timeout is still waiting on the work")
    }

    /// The timeout must not fire on work that finishes in time, and the real result must survive.
    func testFastToolReturnsItsOwnResult() async {
        let router = router(with: UncancellableTool(name: "quick_tool", seconds: 0.05), timeout: 5)

        let result = await router.handleToolCall(name: "quick_tool", args: [:])
        guard case .success(let text) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(text, "finished")
    }

    /// A throwing tool still reports its own error rather than a timeout.
    func testThrowingToolReportsItsError() async {
        let router = router(with: ThrowingTool(name: "bad_tool"), timeout: 5)

        let result = await router.handleToolCall(name: "bad_tool", args: [:])
        guard case .failure(let message) = result else {
            return XCTFail("expected failure, got \(result)")
        }
        XCTAssertTrue(message.contains("Tool error"), "got: \(message)")
        XCTAssertFalse(message.contains("timed out"))
    }

    /// Only one of the two racers may resolve the call — a late finisher must not resume the
    /// continuation a second time (which would trap).
    func testLateFinisherDoesNotDoubleResolve() async {
        let router = router(with: UncancellableTool(name: "slow_tool", seconds: 0.4), timeout: 0.1)

        let result = await router.handleToolCall(name: "slow_tool", args: [:])
        guard case .failure = result else { return XCTFail("expected the timeout to win") }

        // Give the abandoned work time to finish and attempt its resume. If the guard were wrong
        // this crashes the test process rather than failing an assertion.
        try? await Task.sleep(nanoseconds: 700_000_000)
    }
}

// MARK: - Fixtures

/// Ignores cancellation on purpose: `try?` swallows the `CancellationError` from `Task.sleep`, so
/// the loop keeps running to its wall-clock deadline the way a real SDK call would.
private struct UncancellableTool: NativeTool {
    let name: String
    let seconds: TimeInterval
    var description = "test fixture"
    var parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    func execute(args: [String: Any]) async throws -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return "finished"
    }
}

private struct ThrowingTool: NativeTool {
    let name: String
    var description = "test fixture"
    var parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]

    struct Boom: Error {}
    func execute(args: [String: Any]) async throws -> String { throw Boom() }
}
