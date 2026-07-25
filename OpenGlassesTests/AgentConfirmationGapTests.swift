import XCTest
import CoreLocation
@testable import OpenGlasses

/// Two gaps in the human-in-the-loop backstop, both found in a security review.
///
///  1. `code_agent` dispatches an arbitrary free-text task to a remote coding agent but was absent
///     from the high-impact set, so an injected instruction could start a run unconfirmed — while
///     `execute`, which has the same blast radius, was gated.
///  2. The agent-mode `.confirm` branch in `NativeToolRouter` executed the tool when no
///     confirmation coordinator was wired, so the *more* autonomous mode was the one that skipped
///     the gate. The agent-mode-off floor already failed closed.
@MainActor
final class AgentConfirmationGapTests: XCTestCase {

    private func context(rules: Set<SafetyRuleKind>,
                         autonomy: Autonomy = .autoAct) -> SafetyContext {
        SafetyContext(now: Date(), location: nil, homeRegion: nil, enabledRules: rules,
                      quietHoursStart: 22, quietHoursEnd: 7, autonomy: autonomy)
    }

    // MARK: - code_agent classification

    func testStartingAnAgentRunIsHighImpact() {
        XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent",
                                                        args: ["action": "start", "prompt": "ship it"]))
    }

    /// `AgentControlTool` defaults a missing action to `start`, so the gate must too — otherwise
    /// omitting the argument is a trivial bypass.
    func testAgentCallWithNoActionIsTreatedAsStart() {
        XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent", args: [:]))
        XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent", args: ["prompt": "x"]))
    }

    /// A non-string action also falls back to `start` inside the tool.
    func testAgentCallWithNonStringActionIsTreatedAsStart() {
        XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent", args: ["action": 7]))
    }

    func testStartClassificationIgnoresCaseAndSurroundingSpace() {
        for raw in ["START", "Start", " start ", "\tstart"] {
            XCTAssertTrue(PromptInjectionPolicy.isHighImpact(toolName: "code_agent",
                                                            args: ["action": raw]),
                          "‘\(raw)’ should be gated")
        }
    }

    /// The other half of the rule: routine actions must NOT prompt. Gating `status` would train
    /// the wearer to approve reflexively and blunt the prompt that matters.
    func testNonDispatchingAgentActionsAreNotGated() {
        for action in ["status", "cancel", "confirm", "deny", "switch_harness"] {
            XCTAssertFalse(PromptInjectionPolicy.isHighImpact(toolName: "code_agent",
                                                             args: ["action": action]),
                           "‘\(action)’ should not require confirmation")
        }
    }

    func testAgentRunSummaryNamesThePromptAndProject() {
        let summary = PromptInjectionPolicy.actionSummary(
            toolName: "code_agent", args: ["action": "start", "prompt": "delete the repo", "project": "api"])
        XCTAssertTrue(summary.contains("delete the repo"))
        XCTAssertTrue(summary.contains("api"))
    }

    // MARK: - Supervisor verdicts

    func testSupervisorConfirmsAgentDispatch() {
        let verdict = SafetySupervisor.evaluate(tool: "code_agent",
                                                args: ["action": "start", "prompt": "x"],
                                                context: context(rules: [.needsVoiceApproval]))
        guard case .confirm = verdict else {
            return XCTFail("starting a coding-agent run should require confirmation, got \(verdict)")
        }
    }

    func testSupervisorAllowsAgentStatus() {
        let verdict = SafetySupervisor.evaluate(tool: "code_agent", args: ["action": "status"],
                                                context: context(rules: [.needsVoiceApproval]))
        XCTAssertEqual(verdict, .allow)
    }

    /// The Plan W autonomy ceiling is also args-aware: an idle wearer holds a dispatch but can
    /// still ask for status.
    func testAutonomyCeilingHoldsDispatchButNotStatus() {
        let idle = context(rules: [], autonomy: .paused)
        guard case .block = SafetySupervisor.evaluate(tool: "code_agent",
                                                      args: ["action": "start", "prompt": "x"],
                                                      context: idle) else {
            return XCTFail("a paused wearer should not dispatch an agent run")
        }
        XCTAssertEqual(SafetySupervisor.evaluate(tool: "code_agent", args: ["action": "status"],
                                                 context: idle), .allow)
    }

    // MARK: - Fail-closed when no confirmation UI is available

    func testAgentModeConfirmFailsClosedWithoutCoordinator() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
        defer { Config.setAgentModeEnabled(saved) }

        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(GapFakeTool(name: "send_message"))
        let router = NativeToolRouter(registry: registry)
        router.confirmationCoordinator = nil          // headless: nothing can present a prompt
        router.safetyContextProvider = { [weak self] in
            self!.context(rules: [.needsVoiceApproval])
        }

        let result = await router.handleToolCall(name: "send_message", args: [:])
        guard case .failure(let message) = result else {
            return XCTFail("a confirm verdict with no coordinator must not execute the tool")
        }
        XCTAssertTrue(message.contains("requires user confirmation"), "got: \(message)")
    }

    /// Same situation, reached through the newly gated tool.
    func testAgentDispatchFailsClosedWithoutCoordinator() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
        defer { Config.setAgentModeEnabled(saved) }

        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(GapFakeTool(name: "code_agent"))
        let router = NativeToolRouter(registry: registry)
        router.confirmationCoordinator = nil
        router.safetyContextProvider = { [weak self] in
            self!.context(rules: [.needsVoiceApproval])
        }

        let result = await router.handleToolCall(name: "code_agent",
                                                 args: ["action": "start", "prompt": "x"])
        guard case .failure = result else {
            return XCTFail("an unconfirmable agent dispatch must not run")
        }
    }

    /// The gate must not become a blanket block: a routine action still runs headlessly.
    func testAgentStatusStillRunsWithoutCoordinator() async {
        let saved = Config.agentModeEnabled
        Config.setAgentModeEnabled(true)
        defer { Config.setAgentModeEnabled(saved) }

        let registry = NativeToolRegistry(locationService: LocationService())
        registry.register(GapFakeTool(name: "code_agent"))
        let router = NativeToolRouter(registry: registry)
        router.confirmationCoordinator = nil
        router.safetyContextProvider = { [weak self] in
            self!.context(rules: [.needsVoiceApproval])
        }

        let result = await router.handleToolCall(name: "code_agent", args: ["action": "status"])
        guard case .success = result else {
            return XCTFail("status is a read — it should not need a confirmation UI")
        }
    }
}

private struct GapFakeTool: NativeTool {
    let name: String
    var description = "fake"
    var parametersSchema: [String: Any] = ["type": "object", "properties": [:] as [String: Any]]
    func execute(args: [String: Any]) async throws -> String { "ran:\(name)" }
}
