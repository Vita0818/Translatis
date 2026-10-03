import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisPermission

private func ctx(profile: PermissionProfile = .reviewed,
                 allowsShell: Bool = true,
                 root: String = "/ws") -> PermissionContext {
    PermissionContext(workspaceRoot: URL(fileURLWithPath: root), profile: profile, allowsShell: allowsShell)
}

private func call(_ name: String, _ side: SideEffect,
                  paths: [String] = [], network: Bool = false, args: String = "{}",
                  intent: PermissionIntent? = nil) -> ToolCallContext {
    ToolCallContext(toolName: name, sideEffect: side, touchedPaths: paths,
                    risksNetwork: network, rawArgs: args, intent: intent)
}

final class IntatisPermissionTests: XCTestCase {

    private let gate = DeterministicPolicyGate()

    // MARK: Scanners

    func testSecretScannerPaths() {
        XCTAssertTrue(SecretScanner.isSensitivePath(".env"))
        XCTAssertTrue(SecretScanner.isSensitivePath("config/.env.local"))
        XCTAssertTrue(SecretScanner.isSensitivePath("home/.ssh/id_rsa"))
        XCTAssertTrue(SecretScanner.isSensitivePath("certs/server.pem"))
        XCTAssertTrue(SecretScanner.isSensitivePath("~/.config/opencode/opencode.json"))
        XCTAssertTrue(SecretScanner.isSensitivePath("~/.config/intatis/config.json"))
        XCTAssertTrue(SecretScanner.isSensitivePath("~/.local/share/opencode/auth.json"))
        XCTAssertFalse(SecretScanner.isSensitivePath("src/main.swift"))
    }

    func testProtectedConfig() {
        XCTAssertTrue(SecretScanner.isProtectedConfigPath("package-lock.json"))
        XCTAssertTrue(SecretScanner.isProtectedConfigPath(".github/workflows/ci.yml"))
        XCTAssertFalse(SecretScanner.isProtectedConfigPath("src/a.swift"))
    }

    func testContainsSecret() {
        XCTAssertTrue(SecretScanner.containsSecret("token=ghp_abcdef123456"))
        XCTAssertTrue(SecretScanner.containsSecret("api_key=sk-supersecretvalue"))
        XCTAssertTrue(SecretScanner.containsSecret("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertFalse(SecretScanner.containsSecret("ask-user or automatic-review"))
        XCTAssertFalse(SecretScanner.containsSecret("just some normal source code"))
    }

    func testShellInspector() {
        XCTAssertTrue(ShellInspector.isDangerous("sudo rm -rf /"))
        XCTAssertTrue(ShellInspector.risksNetworkOrInstall("npm install left-pad"))
        XCTAssertTrue(ShellInspector.isReadOnlyCommand("ls -la"))
        XCTAssertFalse(ShellInspector.isReadOnlyCommand("rm file"))
    }

    // MARK: Gate

    func testGateReadAllow() {
        guard case .allow = gate.evaluate(call("read_file", .readOnly, paths: ["a.swift"]), ctx()) else {
            return XCTFail("read should allow")
        }
    }

    func testGateAllowsLocalKnowledgeSearchWithoutReviewer() {
        let intent = PermissionIntent(
            action: "knowledge.search.local",
            resources: [PermissionResource(
                kind: .tool,
                value: "knowledge_base:host-bound")],
            dataEffects: [.read],
            replayPolicy: .safeToReplay)
        guard case .allow(let reason, let risk) = gate.evaluate(
            call(
                "search_knowledge",
                .readOnly,
                intent: intent),
            ctx(profile: .reviewed)) else {
            return XCTFail("local knowledge search should use the read-only allow route")
        }
        XCTAssertEqual(reason, "search host-mounted untrusted knowledge evidence")
        XCTAssertEqual(risk, .low)
    }

    func testGateWriteReviewedPassesToReviewer() {
        guard case .pass(let reason, let risk) = gate.evaluate(call("write_file", .write, paths: ["a.swift"]),
                                                             ctx(profile: .reviewed)) else {
            return XCTFail("write in reviewed should pass to the configured reviewer route")
        }
        XCTAssertEqual(reason, "modify workspace resource")
        XCTAssertEqual(risk, .medium)
    }

    func testGateWriteManualPassesToReviewer() {
        guard case .pass = gate.evaluate(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .manual)) else {
            return XCTFail("write in manual should pass to the configured reviewer route")
        }
    }

    func testGateDeniesSensitiveRead() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: [".env"]), ctx()) else {
            return XCTFail(".env read should deny")
        }
    }

    func testGateDeniesEscape() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: ["../etc/passwd"]), ctx()) else {
            return XCTFail("escape should deny")
        }
    }

    func testGateShellDeniedInSandbox() {
        guard case .deny = gate.evaluate(call("run_shell", .exec, args: #"{"command":"ls"}"#),
                                         ctx(allowsShell: false)) else {
            return XCTFail("shell with allowsShell=false should deny")
        }
    }

    func testGateShellBackedNetworkDeniedWhenShellDisabled() {
        guard case .deny = gate.evaluate(call("browser_navigate", .exec, network: true, args: #"{"url":"https://example.com"}"#),
                                         ctx(allowsShell: false)) else {
            return XCTFail("shell-backed browser network should deny when shell is disabled")
        }
    }

    func testGateShellBackedNetworkDeniedInReadOnly() {
        guard case .deny = gate.evaluate(call("browser_navigate", .exec, network: true, args: #"{"url":"https://example.com"}"#),
                                         ctx(profile: .readOnly, allowsShell: true)) else {
            return XCTFail("shell-backed browser network should deny in read_only")
        }
    }

    func testGateShellBackedNetworkPassesWhenShellAllowed() {
        guard case .pass = gate.evaluate(call("browser_navigate", .exec, network: true, args: #"{"url":"https://example.com"}"#),
                                        ctx(profile: .reviewed, allowsShell: true)) else {
            return XCTFail("shell-backed browser network should pass to reviewer when shell is allowed")
        }
    }

    func testGateAllowsStructuredDocumentReaderUnderReadOnlyWithoutShellAuthority() {
        let intent = PermissionIntent(
            action: "document.read",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "report.docx",
                access: .readOnly)],
            metadata: [
                "execution_class": .string(
                    PermissionIntent.structuredReadOnlyExecutionClass),
            ],
            dataEffects: [.read, .execute],
            risks: [.processExecution],
            replayPolicy: .doNotReplay)

        XCTAssertTrue(intent.isReadOnlyWorkspaceCompatible)
        XCTAssertTrue(intent.isStructuredReadOnlyExecution)
        guard case .allow(let reason, let risk) = gate.evaluate(
            call(
                "read_docx",
                .exec,
                paths: ["report.docx"],
                intent: intent),
            ctx(profile: .readOnly, allowsShell: false)) else {
            return XCTFail("fixed structured read-only execution should allow without review")
        }
        XCTAssertEqual(reason, "run fixed structured read-only document backend")
        XCTAssertEqual(risk, .medium)
    }

    func testStructuredReadOnlyMarkerCannotAuthorizeMutationOrGenericShell() {
        let mutating = PermissionIntent(
            action: "document.read",
            resources: [PermissionResource(
                kind: .workspacePath,
                value: "report.docx",
                access: .readWrite)],
            metadata: [
                "execution_class": .string(
                    PermissionIntent.structuredReadOnlyExecutionClass),
            ],
            dataEffects: [.read, .execute, .mutate],
            risks: [.processExecution, .workspaceMutation],
            replayPolicy: .doNotReplay)
        XCTAssertFalse(mutating.isReadOnlyWorkspaceCompatible)
        XCTAssertFalse(mutating.isStructuredReadOnlyExecution)

        guard case .deny = gate.evaluate(
            call("run_shell", .exec, args: #"{"command":"ls"}"#),
            ctx(profile: .readOnly, allowsShell: true)) else {
            return XCTFail("generic shell must remain denied in read_only")
        }
    }

    func testGateDestructiveNetworkPassesHighRisk() {
        guard case .pass(let reason, let risk) = gate.evaluate(call("git_push", .destructive, paths: [".git"], network: true),
                                                             ctx(profile: .reviewed, allowsShell: true)) else {
            return XCTFail("destructive network operation should pass to reviewer")
        }
        XCTAssertEqual(risk, .high)
        XCTAssertTrue(reason.contains("destructive network"))
    }

    func testGateShellSudoDenied() {
        guard case .deny = gate.evaluate(call("run_shell", .exec, args: #"{"command":"sudo rm -rf /"}"#),
                                         ctx(allowsShell: true)) else {
            return XCTFail("sudo should deny")
        }
    }

    func testGateShellReadOnlyAllowed() {
        guard case .allow = gate.evaluate(call("run_shell", .exec, args: #"{"command":"ls -la"}"#),
                                          ctx(profile: .reviewed, allowsShell: true)) else {
            return XCTFail("ls should allow")
        }
    }

    func testGateLockedDenies() {
        guard case .deny = gate.evaluate(call("read_file", .readOnly, paths: ["a"]), ctx(profile: .locked)) else {
            return XCTFail("locked should deny")
        }
    }

    func testGateAllowsOnlyExactCurrentSessionRenameIntent() {
        let intent = PermissionIntent(
            action: "session.rename",
            resources: [PermissionResource(kind: .tool, value: "current_session")],
            dataEffects: [.none],
            controlEffects: [],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
        guard case .allow(_, let risk) = gate.evaluate(
            call("rename_session", .write, intent: intent),
            ctx(profile: .reviewed)) else {
            return XCTFail("the host-bound current-session rename should be deterministic low risk")
        }
        XCTAssertEqual(risk, .low)
    }

    func testGateDoesNotAutoAllowNearMissSessionRenameIntent() {
        let intent = PermissionIntent(
            action: "session.rename",
            resources: [PermissionResource(kind: .tool, value: "another_session")],
            dataEffects: [.none],
            controlEffects: [],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
        guard case .pass = gate.evaluate(
            call("rename_session", .write, intent: intent),
            ctx(profile: .reviewed)) else {
            return XCTFail("a non-current target must not use the deterministic rename exception")
        }
    }

    func testGateLockedDeniesExactCurrentSessionRenameIntent() {
        let intent = PermissionIntent(
            action: "session.rename",
            resources: [PermissionResource(kind: .tool, value: "current_session")],
            dataEffects: [.none],
            controlEffects: [],
            risks: [.controlPlaneMutation],
            replayPolicy: .doNotReplay)
        guard case .deny = gate.evaluate(
            call("rename_session", .write, intent: intent),
            ctx(profile: .locked)) else {
            return XCTFail("locked remains a hard deny")
        }
    }

    // MARK: Engine

    func testEngineWriteWithoutAutomaticResponderAsks() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .reviewed))
        XCTAssertEqual(outcome.decision, .askUser)
    }

    func testEngineDenyIsFinal() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("read_file", .readOnly, paths: [".env"]), ctx())
        XCTAssertEqual(outcome.decision, .deny)
    }

    func testEngineAllowPassesThrough() async {
        let engine = PermissionEngine()
        let outcome = await engine.decide(call("read_file", .readOnly, paths: ["a.swift"]), ctx())
        XCTAssertEqual(outcome.decision, .allow)
    }

    func testEngineReviewerIsTheSingleInEngineApprovalRoute() async {
        struct AllowReviewer: PermissionReviewer {
            func review(_ c: ToolCallContext, _ x: PermissionContext,
                        gateReason: String, risk: RiskLevel) async -> PermissionOutcome {
                PermissionOutcome(decision: .allow, risk: .low, reason: "reviewer ok")
            }
        }
        let engine = PermissionEngine(reviewer: AllowReviewer())
        let outcome = await engine.decide(call("write_file", .write, paths: ["a.swift"]), ctx(profile: .reviewed))
        XCTAssertEqual(outcome.decision, .allow)
        XCTAssertEqual(outcome.reason, "reviewer ok")
    }

    func testReadOnlyLeaseCanSpawnReadOnlyChildButCannotGrantReadWrite() {
        func spawnIntent(_ access: WorkspaceAccess) -> PermissionIntent {
            PermissionIntent(
                action: "agent.spawn",
                resources: [PermissionResource(kind: .workspace, value: "/ws", access: access)],
                metadata: [
                    "requestedAccess": .string(access.rawValue),
                    "canCoordinate": .bool(false),
                ],
                dataEffects: [.none],
                controlEffects: [.createAgent, .grantCapability],
                risks: [.controlPlaneMutation, .capabilityGrant],
                replayPolicy: .doNotReplay)
        }
        guard case .pass(let reason, _) = gate.evaluate(
            call("spawn_agent", .write, intent: spawnIntent(.readOnly)),
            ctx(profile: .readOnly)) else {
            return XCTFail("read-only parent should be able to request a read-only child")
        }
        XCTAssertFalse(reason.contains("write to workspace"))
        guard case .deny = gate.evaluate(
            call("spawn_agent", .write, intent: spawnIntent(.readWrite)),
            ctx(profile: .readOnly)) else {
            return XCTFail("read-only parent must not grant read-write access")
        }
    }

    func testWorkTaskAndGoalControlEffectsAreNotWorkspaceWrites() {
        let cases: [(String, PermissionControlEffect, PermissionResource)] = [
            ("task.create", .createTask, PermissionResource(kind: .task, value: "current-run")),
            ("task.update", .updateTask, PermissionResource(kind: .task, value: "wt_test")),
            ("task.cancel", .cancelTask, PermissionResource(kind: .task, value: "wt_test")),
            ("task.delegate", .delegateTask, PermissionResource(kind: .task, value: "wt_test")),
            ("goal.edit", .editGoal, PermissionResource(kind: .goal, value: "goal_test")),
            ("goal.pause", .pauseGoal, PermissionResource(kind: .goal, value: "goal_test")),
            ("goal.resume", .resumeGoal, PermissionResource(kind: .goal, value: "goal_test")),
            ("goal.clear", .clearGoal, PermissionResource(kind: .goal, value: "goal_test")),
            ("goal.submit_verdict", .submitGoalVerdict, PermissionResource(kind: .goal, value: "goal_test")),
            ("run.close.completed", .closeRun, PermissionResource(kind: .task, value: "current_run")),
        ]

        for (action, controlEffect, resource) in cases {
            let intent = PermissionIntent(
                action: action,
                resources: [resource],
                dataEffects: [.none],
                controlEffects: [controlEffect],
                risks: [.controlPlaneMutation],
                replayPolicy: .doNotReplay)
            guard case .pass(let reason, _) = gate.evaluate(
                call(action, .write, intent: intent),
                ctx(profile: .readOnly)) else {
                XCTFail("\(action) should enter control-plane review for a read-only workspace lease")
                continue
            }
            XCTAssertFalse(reason.contains("workspace"), "\(action) was misclassified: \(reason)")
        }
    }
}
