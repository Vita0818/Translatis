import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisTools
import IntatisPermission
import IntatisConversation
@testable import IntatisAgentKernel

/// Replays a scripted sequence of chunk-lists, one per `stream` call.
private final class ScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    private var responses: [[AgentChunk]]
    private var index = 0
    private let lock = NSLock()

    init(_ responses: [[AgentChunk]]) { self.responses = responses }

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        lock.lock()
        let chunks = responses[min(index, responses.count - 1)]
        index += 1
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}

private struct PartialThenFailingToolProvider: ToolCallingProvider {
    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("partial"))
            continuation.finish(throwing: IntatisError.decoding(
                "tool-calling streaming request ended before a completion marker. Check endpoint compatibility."))
        }
    }
}

private struct SecretEchoFailingProvider: ToolCallingProvider {
    let secret: String

    func stream(_ request: AgentRequest) -> AsyncThrowingStream<AgentChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: IntatisError.provider(
                "upstream echoed Authorization: Bearer \(secret)"))
        }
    }
}

private struct NoShell: ShellRunner {
    func run(_ command: String, cwd: URL) async throws -> ShellResult { ShellResult(stdout: "", stderr: "", exitCode: 0) }
}
private struct StaticShell: ShellRunner {
    let result: ShellResult
    func run(_ command: String, cwd: URL) async throws -> ShellResult { result }
}
private actor ScriptedShellState {
    private var results: [ShellResult]
    private var commands: [String] = []

    init(_ results: [ShellResult]) {
        self.results = results
    }

    func next(command: String) -> ShellResult {
        commands.append(command)
        guard !results.isEmpty else {
            return ShellResult(stdout: "", stderr: "no scripted shell result", exitCode: 1)
        }
        return results.removeFirst()
    }

    func recordedCommands() -> [String] {
        commands
    }
}
private final class ScriptedShell: ShellRunner, @unchecked Sendable {
    private let state: ScriptedShellState

    init(_ results: [ShellResult]) {
        self.state = ScriptedShellState(results)
    }

    func run(_ command: String, cwd: URL) async throws -> ShellResult {
        await state.next(command: command)
    }

    func commands() async -> [String] {
        await state.recordedCommands()
    }
}
private struct NoGit: GitService {
    func status(workspace: URL) async throws -> String { "" }
    func diff(workspace: URL) async throws -> String { "" }
    func stagedDiff(workspace: URL) async throws -> String { "" }
    func repositoryInfo(workspace: URL) async throws -> String { "root: \(workspace.path)\nbranch: main" }
    func recentCommits(limit: Int, workspace: URL) async throws -> String { "(no commits)" }
    func diffAgainst(base: String, workspace: URL) async throws -> String { "" }
    func branchInfo(workspace: URL) async throws -> String { "current: main\nbranches:\n* main" }
    func createBranch(name: String, startPoint: String?, workspace: URL) async throws -> String { "created branch \(name)" }
    func stage(paths: [String], workspace: URL) async throws -> String { "staged \(paths.joined(separator: ","))" }
    func unstage(paths: [String], workspace: URL) async throws -> String { "unstaged \(paths.joined(separator: ","))" }
    func commit(message: String, workspace: URL) async throws -> String { "committed \(message)" }
    func applyPatch(diff: String, reverse: Bool, checkOnly: Bool, cached: Bool, workspace: URL) async throws -> GitPatchResult {
        GitPatchResult(text: "patch", changedFiles: ["file.txt"], diff: diff)
    }
    func worktrees(workspace: URL) async throws -> String { "(no worktrees)" }
    func createWorktree(name: String, startPoint: String?, branch: String?, workspace: URL) async throws -> String { "created worktree \(name)" }
    func removeWorktree(name: String, force: Bool, workspace: URL) async throws -> String { "removed worktree \(name)" }
    func remotes(workspace: URL) async throws -> String { "(no remotes)" }
    func fetch(remote: String, branch: String?, prune: Bool, workspace: URL) async throws -> String { "fetched \(remote)" }
    func pullFastForward(remote: String, branch: String, workspace: URL) async throws -> String { "pulled \(remote)/\(branch)" }
    func push(remote: String, branch: String, setUpstream: Bool, workspace: URL) async throws -> String { "pushed \(branch)" }
    func switchBranch(name: String, workspace: URL) async throws -> String { "switched \(name)" }
}

final class IntatisAgentKernelTests: XCTestCase {

    func testRuntimeModesKeepDistinctDefaultIterationBudgets() {
        let code = AgentRuntime.code(allowsShell: false)
        let cowork = AgentRuntime.cowork(
            registry: .standard(),
            engine: PermissionEngine(),
            allowsShell: false)

        XCTAssertEqual(code.maxIterations, 50)
        XCTAssertEqual(
            code.maxIterations,
            AgentRuntime.defaultCodeMaxIterations)
        XCTAssertEqual(cowork.maxIterations, 64)
        XCTAssertEqual(
            cowork.maxIterations,
            AgentRuntime.defaultCoworkMaxIterations)
        XCTAssertEqual(code.modelContextPolicy, .unspecified)
        XCTAssertEqual(cowork.modelContextPolicy, .unspecified)

        let exactPolicy = AgentModelContextPolicy(
            contextWindowTokens: 200_000,
            autoCompactTokenLimit: 120_000,
            compHash: "exact-profile")
        let stableMainRuntime = AgentRuntime.cowork(
            registry: .standard(),
            engine: PermissionEngine(),
            allowsShell: false,
            modelContextPolicy: exactPolicy)
        XCTAssertEqual(
            stableMainRuntime.modelContextPolicy,
            exactPolicy)

        let codeRuntimeWithExactMetadata = AgentRuntime.code(
            allowsShell: false,
            modelContextPolicy: exactPolicy)
        XCTAssertEqual(
            codeRuntimeWithExactMetadata.modelContextPolicy,
            exactPolicy)
    }

    private func workspaceAndLog() throws -> (URL, EventLog) {
        let ws = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-kernel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let log = try EventLog(session: SessionID(rawValue: "sess_k"),
                               fileURL: ws.appendingPathComponent(".log/events.jsonl"))
        return (ws, log)
    }

    private func writeArgs(path: String, content: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["path": path, "content": content])
        return String(decoding: data, as: UTF8.self)
    }

    private func makeLoop(ws: URL, log: EventLog, provider: ToolCallingProvider,
                          responder: PermissionResponder,
                          includeUsage: Bool = false,
                          shell: ShellRunner = NoShell()) -> AgentLoop {
        AgentLoop(
            log: log,
            provider: provider,
            registry: .standard(),
            engine: PermissionEngine(),
            responder: responder,
            agent: Agent(name: AgentID(rawValue: "Coder"), workspaceRoot: ws,
                         model: ModelID(rawValue: "m"), profile: .reviewed),
            allowsShell: true,
            shell: shell,
            git: NoGit(),
            includeUsage: includeUsage
        )
    }

    private func toolResults(in log: EventLog) async -> [ToolResultPayload] {
        await log.replay().compactMap { envelope in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }
    }

    func testApprovedWriteExecutesAndLogs() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs(path: "out.txt", content: "hello"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Done."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))
        try await loop.send("create out.txt with hello")

        let written = try String(contentsOf: ws.appendingPathComponent("out.txt"), encoding: .utf8)
        XCTAssertEqual(written, "hello")

        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.toolCall))
        XCTAssertTrue(types.contains(.permissionRequest))   // write in reviewed → pass → no reviewer → ask
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertTrue(types.contains(.messageCompleted))
    }

    func testAgentLoopPreservesPartialTextWhenStreamEndsWithoutCompletionMarker() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: PartialThenFailingToolProvider(),
                            responder: FixedResponder(.allow))

        do {
            try await loop.send("inspect")
            XCTFail("expected incomplete stream error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("completion marker"))
        }

        let projection = CodeProjection.build(from: await log.replay())
        let agentItem = projection.items.first { $0.kind == .agent }
        XCTAssertEqual(agentItem?.body, "partial")
        XCTAssertEqual(agentItem?.complete, false)
        XCTAssertEqual(agentItem?.recoveryAdvice?.title, "Response stopped before completion")
        let errorItem = projection.items.first { $0.kind == .error }
        XCTAssertEqual(errorItem?.recoveryAdvice?.title, "Check endpoint compatibility")
    }

    func testProviderErrorSecretIsRedactedBeforeDurableEventLogWrite() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        let secret = "opaque-provider-secret-must-not-persist"
        let loop = makeLoop(
            ws: ws,
            log: log,
            provider: SecretEchoFailingProvider(secret: secret),
            responder: FixedResponder(.allow))

        do {
            _ = try await loop.send("trigger a provider failure")
            XCTFail("expected provider failure")
        } catch {
            // Callers may classify the original error in memory; the durable
            // projection must contain only the sanitized form.
        }

        let payloads = await log.replay().compactMap { envelope -> ErrorPayload? in
            guard case .error(let payload) = envelope.event else { return nil }
            return payload
        }
        let durable = try XCTUnwrap(payloads.last)
        XCTAssertFalse(durable.message.contains(secret))
        XCTAssertTrue(durable.message.contains("REDACTED"))
        let rawLog = try String(
            contentsOf: ws.appendingPathComponent(".log/events.jsonl"),
            encoding: .utf8)
        XCTAssertFalse(rawLog.contains(secret))
    }

    func testDeniedWriteDoesNotExecute() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "write_file", arguments: writeArgs(path: "out.txt", content: "x"))]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Okay, I won't."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))
        try await loop.send("create out.txt")

        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        let result = events.compactMap { envelope -> ToolResultPayload? in
            if case .toolResult(let payload) = envelope.event { return payload }
            return nil
        }.first
        XCTAssertTrue(result?.observation.contains("permission denied") == true)
        XCTAssertEqual(result?.toolCallId, "c1")
        XCTAssertEqual(result?.outcome, .denied)
        XCTAssertEqual(result?.failureSource, .userDenied)
        XCTAssertNotNil(result?.turnID)
        XCTAssertNotNil(result?.permissionRequestID)
        let turnOutcomes = events.compactMap { envelope -> TurnOutcomePayload? in
            if case .turnOutcome(let payload) = envelope.event { return payload }
            return nil
        }
        XCTAssertEqual(turnOutcomes.map(\.outcome), [.completed])
    }

    func testReadOnlyToolNeedsNoApproval() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "c1", name: "read_file", arguments: #"{"path":"in.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("It says data."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))
        try await loop.send("read in.txt")

        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertFalse(types.contains(.permissionRequest))   // reads are auto-allowed
    }

    func testAgentLoopRunsBrowserSearchThroughPermissionFlow() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let searchArgs = """
        {"query":"Intatis browser tools","engine":"duckduckgo","profile":"agent-web","channel":"msedge","waitMillis":0,"maxCharacters":2000}
        """
        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "search",
                                  name: "browser_search",
                                  arguments: searchArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I found browser tool results."), .done(finishReason: "stop")],
        ])
        let browserStdout = #"{"action":"search","profile":"agent-web","backend":"cdp","backendDetail":"edge","url":"https://duckduckgo.com/?q=Intatis%20browser%20tools","title":"Search Results","text":"Search results for Intatis browser tools","links":[{"text":"Intatis browser tool docs","href":"https://example.com/intatis-browser"}],"elements":[{"role":"textbox","name":"Search","selector":"input[name=q]","tag":"input","type":"search"}]}"#
        let shell = StaticShell(result: ShellResult(stdout: browserStdout, stderr: "", exitCode: 0))
        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: provider,
                            responder: FixedResponder(.allow),
                            shell: shell)

        let answer = try await loop.send("search the web for Intatis browser tools")
        XCTAssertEqual(answer, "I found browser tool results.")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        XCTAssertTrue(types.contains(.permissionResolved))
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertTrue(types.contains(.messageCompleted))

        let request = try XCTUnwrap(events.compactMap { envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertEqual(request.tool, "browser_search")
        XCTAssertTrue(request.reason.contains("browser") || request.reason.contains("network"))

        let browserResults = await toolResults(in: log)
        let result = try XCTUnwrap(browserResults.first)
        XCTAssertTrue(result.observation.contains("browser action: search"), result.observation)
        XCTAssertTrue(result.observation.contains("Intatis browser tool docs - https://example.com/intatis-browser"), result.observation)
        XCTAssertTrue(result.observation.contains(#"textbox "Search" selector=input[name=q] type=search"#), result.observation)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/agent-web.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://duckduckgo.com/?q=Intatis%20browser%20tools")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"agent-web""#), history)
        XCTAssertTrue(history.contains(#""action":"search""#), history)
    }

    func testAgentLoopCompletesBrowserFormTaskThroughPermissionFlow() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let navigateArgs = """
        {"url":"https://example.com/task","profile":"agent-task","channel":"msedge","waitMillis":0,"maxCharacters":2000}
        """
        let typeArgs = """
        {"profile":"agent-task","selector":"input[name=name]","value":"Ada Lovelace","waitMillis":0,"maxCharacters":2000}
        """
        let submitArgs = """
        {"profile":"agent-task","selector":"form","timeoutMillis":2000,"waitMillis":0,"maxCharacters":2000}
        """
        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "nav", name: "browser_navigate", arguments: navigateArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "fill", name: "browser_type", arguments: typeArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "submit", name: "browser_submit", arguments: submitArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Submitted the online task."), .done(finishReason: "stop")],
        ])
        let shell = ScriptedShell([
            ShellResult(
                stdout: #"{"action":"navigate","profile":"agent-task","backend":"cdp","url":"https://example.com/task","title":"Task Form","text":"Task form Name Continue","links":[],"elements":[{"role":"textbox","name":"Name","selector":"input[name=name]","tag":"input","type":"text"},{"role":"button","name":"Continue","selector":"button[type=submit]","tag":"button"}]}"#,
                stderr: "",
                exitCode: 0),
            ShellResult(
                stdout: #"{"action":"type","profile":"agent-task","backend":"cdp","url":"https://example.com/task","title":"Task Form","text":"Name field filled; Continue button ready","links":[],"elements":[{"role":"textbox","name":"Name","selector":"input[name=name]","tag":"input","type":"text"},{"role":"button","name":"Continue","selector":"button[type=submit]","tag":"button"}]}"#,
                stderr: "",
                exitCode: 0),
            ShellResult(
                stdout: #"{"action":"submit","profile":"agent-task","backend":"cdp","url":"https://example.com/done","title":"Done","text":"Submitted successfully. Confirmation 42.","links":[],"elements":[]}"#,
                stderr: "",
                exitCode: 0),
        ])
        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: provider,
                            responder: FixedResponder(.allow),
                            shell: shell)

        let answer = try await loop.send("open the task form, enter the requested name, and submit it")
        XCTAssertEqual(answer, "Submitted the online task.")

        let events = await log.replay()
        let requests = events.compactMap { envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(requests.map(\.tool), ["browser_navigate", "browser_type", "browser_submit"])
        XCTAssertTrue(requests.allSatisfy { $0.reason.contains("network") || $0.reason.contains("browser") })
        let commands = await shell.commands()
        XCTAssertEqual(commands.count, 3)

        let results = await toolResults(in: log)
        XCTAssertEqual(results.map(\.toolCallId), ["nav", "fill", "submit"])
        XCTAssertTrue(results[0].observation.contains("browser action: navigate"), results[0].observation)
        XCTAssertTrue(results[0].observation.contains(#"textbox "Name" selector=input[name=name] type=text"#), results[0].observation)
        XCTAssertTrue(results[1].observation.contains("browser action: type"), results[1].observation)
        XCTAssertFalse(results[1].observation.contains("Ada Lovelace"), results[1].observation)
        XCTAssertTrue(results[2].observation.contains("browser action: submit"), results[2].observation)
        XCTAssertTrue(results[2].observation.contains("Submitted successfully. Confirmation 42."), results[2].observation)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/agent-task.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/done")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"agent-task""#), history)
        XCTAssertTrue(history.contains(#""action":"navigate""#), history)
        XCTAssertTrue(history.contains(#""action":"type""#), history)
        XCTAssertTrue(history.contains(#""action":"submit""#), history)
        XCTAssertTrue(events.map { $0.event.type }.contains(.messageCompleted))
    }

    func testAgentLoopBrowsesDynamicFeedThroughPermissionFlow() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let navigateArgs = """
        {"url":"https://example.com/social","profile":"social-feed","channel":"msedge","waitMillis":0,"maxCharacters":2000}
        """
        let scrollArgs = """
        {"profile":"social-feed","direction":"down","amount":900,"waitMillis":0,"maxCharacters":2000}
        """
        let waitArgs = """
        {"profile":"social-feed","text":"New posts loaded","timeoutMillis":1000,"waitMillis":0,"maxCharacters":2000}
        """
        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "feed-nav", name: "browser_navigate", arguments: navigateArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "feed-scroll", name: "browser_scroll", arguments: scrollArgs)]),
             .done(finishReason: "tool_calls")],
            [.toolCalls([ToolCall(id: "feed-wait", name: "browser_wait", arguments: waitArgs)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I reviewed the latest feed posts."), .done(finishReason: "stop")],
        ])
        let shell = ScriptedShell([
            ShellResult(
                stdout: #"{"action":"navigate","profile":"social-feed","backend":"cdp","url":"https://example.com/social","title":"Social Feed","text":"Timeline Alice posted Launch update Like Reply Load more","links":[{"text":"Alice","href":"https://example.com/u/alice"}],"elements":[{"role":"button","name":"Like","selector":"button[data-action=like]","tag":"button"},{"role":"button","name":"Load more","selector":"button.load-more","tag":"button"}]}"#,
                stderr: "",
                exitCode: 0),
            ShellResult(
                stdout: #"{"action":"scroll","profile":"social-feed","backend":"cdp","url":"https://example.com/social","title":"Social Feed","text":"Timeline Alice posted Launch update. Bob posted Release notes. New posts loading.","links":[{"text":"Bob","href":"https://example.com/u/bob"}],"elements":[{"role":"button","name":"Like","selector":"button[data-post=bob-like]","tag":"button"}]}"#,
                stderr: "",
                exitCode: 0),
            ShellResult(
                stdout: #"{"action":"wait","profile":"social-feed","backend":"cdp","url":"https://example.com/social","title":"Social Feed","text":"New posts loaded. Cara posted Incident review.","links":[{"text":"Cara","href":"https://example.com/u/cara"}],"elements":[{"role":"button","name":"Reply","selector":"button[data-post=cara-reply]","tag":"button"}]}"#,
                stderr: "",
                exitCode: 0),
        ])
        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: provider,
                            responder: FixedResponder(.allow),
                            shell: shell)

        let answer = try await loop.send("check the social feed for the latest visible posts")
        XCTAssertEqual(answer, "I reviewed the latest feed posts.")

        let events = await log.replay()
        let requests = events.compactMap { envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event else { return nil }
            return payload
        }
        XCTAssertEqual(requests.map(\.tool), ["browser_navigate", "browser_scroll", "browser_wait"])
        XCTAssertTrue(requests.allSatisfy { $0.reason.contains("network") || $0.reason.contains("browser") })
        let commands = await shell.commands()
        XCTAssertEqual(commands.count, 3)

        let results = await toolResults(in: log)
        XCTAssertEqual(results.map(\.toolCallId), ["feed-nav", "feed-scroll", "feed-wait"])
        XCTAssertTrue(results[0].observation.contains("browser action: navigate"), results[0].observation)
        XCTAssertTrue(results[0].observation.contains(#"button "Load more" selector=button.load-more"#), results[0].observation)
        XCTAssertTrue(results[1].observation.contains("browser action: scroll"), results[1].observation)
        XCTAssertTrue(results[1].observation.contains("Bob posted Release notes"), results[1].observation)
        XCTAssertTrue(results[2].observation.contains("browser action: wait"), results[2].observation)
        XCTAssertTrue(results[2].observation.contains("Cara posted Incident review"), results[2].observation)
        XCTAssertTrue(results[2].observation.contains(#"button "Reply" selector=button[data-post=cara-reply]"#), results[2].observation)

        let stateURL = ws.appendingPathComponent(".intatis/browser/state/social-feed.json")
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
        XCTAssertEqual(state["url"] as? String, "https://example.com/social")

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        let history = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertTrue(history.contains(#""profile":"social-feed""#), history)
        XCTAssertTrue(history.contains(#""action":"navigate""#), history)
        XCTAssertTrue(history.contains(#""action":"scroll""#), history)
        XCTAssertTrue(history.contains(#""action":"wait""#), history)
        XCTAssertTrue(events.map { $0.event.type }.contains(.messageCompleted))
    }

    func testAgentLoopRunsBrowserProfileDeleteThroughDestructivePermissionFlow() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let workCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/work/Default/Cookies")
        let personalCookieFile = ws.appendingPathComponent(".intatis/browser/profiles/personal/Default/Cookies")
        try FileManager.default.createDirectory(at: workCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalCookieFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("secret-cookie-token".utf8).write(to: workCookieFile)
        try Data("personal-cookie-token".utf8).write(to: personalCookieFile)

        let activeMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/DevToolsActivePort")
        let lockMarkerFile = ws.appendingPathComponent(".intatis/browser/profiles/work/SingletonLock")
        try Data("active-marker-secret".utf8).write(to: activeMarkerFile)
        try Data("lock-marker-secret".utf8).write(to: lockMarkerFile)

        let workStateURL = ws.appendingPathComponent(".intatis/browser/state/work.json")
        let personalStateURL = ws.appendingPathComponent(".intatis/browser/state/personal.json")
        try FileManager.default.createDirectory(at: workStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"profile":"work","url":"https://example.com/work"}"#.utf8).write(to: workStateURL)
        try Data(#"{"profile":"personal","url":"https://example.com/personal"}"#.utf8).write(to: personalStateURL)

        let workDownload = ws.appendingPathComponent(".intatis/browser/downloads/work/report.pdf")
        let personalDownload = ws.appendingPathComponent(".intatis/browser/downloads/personal/keep.pdf")
        try FileManager.default.createDirectory(at: workDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: personalDownload.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("download-secret-body".utf8).write(to: workDownload)
        try Data("personal-download-body".utf8).write(to: personalDownload)

        let historyURL = ws.appendingPathComponent(".intatis/browser/history.jsonl")
        try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let history = [
            #"{"ts":"2026-07-07T01:00:00Z","profile":"work","action":"navigate","url":"https://example.com/work","title":"Work"}"#,
            #"{"ts":"2026-07-07T02:00:00Z","profile":"personal","action":"navigate","url":"https://example.com/personal","title":"Personal"}"#,
            #"{"ts":"2026-07-07T03:00:00Z","profile":"work","action":"download","url":"https://example.com/report","title":"Report"}"#,
        ].joined(separator: "\n") + "\n"
        try Data(history.utf8).write(to: historyURL)

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "delete-profile",
                                  name: "browser_profile_delete",
                                  arguments: #"{"profile":"work","confirmProfile":"work"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Deleted the stale browser profile."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        let answer = try await loop.send("delete the stale work browser profile")
        XCTAssertEqual(answer, "Deleted the stale browser profile.")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertTrue(types.contains(.permissionRequest))
        XCTAssertTrue(types.contains(.permissionResolved))
        XCTAssertTrue(types.contains(.toolResult))
        XCTAssertTrue(types.contains(.messageCompleted))

        let request = try XCTUnwrap(events.compactMap { envelope -> PermissionRequestPayload? in
            guard case .permissionRequest(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertEqual(request.tool, "browser_profile_delete")
        XCTAssertEqual(request.risk, .high)
        XCTAssertTrue(request.reason.contains("destructive operation"))
        XCTAssertTrue(request.args.contains(#""profile":"work""#))
        XCTAssertTrue(request.args.contains(#""confirmProfile":"work""#))

        let results = await toolResults(in: log)
        let result = try XCTUnwrap(results.first)
        XCTAssertTrue(result.observation.contains("browser profile deleted: work"), result.observation)
        XCTAssertTrue(result.observation.contains("profile runtime markers: present before delete"), result.observation)
        XCTAssertTrue(result.observation.contains("removed profile data: yes (.intatis/browser/profiles/work)"), result.observation)
        XCTAssertTrue(result.observation.contains("removed state file: yes (.intatis/browser/state/work.json)"), result.observation)
        XCTAssertTrue(result.observation.contains("removed downloads: yes (.intatis/browser/downloads/work)"), result.observation)
        XCTAssertTrue(result.observation.contains("removed history entries: 2"), result.observation)
        XCTAssertTrue(result.observation.contains("kept history entries: 1"), result.observation)
        XCTAssertFalse(result.observation.contains("secret-cookie-token"))
        XCTAssertFalse(result.observation.contains("active-marker-secret"))
        XCTAssertFalse(result.observation.contains("lock-marker-secret"))
        XCTAssertFalse(result.observation.contains("DevToolsActivePort"))
        XCTAssertFalse(result.observation.contains("SingletonLock"))
        XCTAssertFalse(result.observation.contains("download-secret-body"))
        XCTAssertFalse(result.observation.contains("Default/Cookies"))
        XCTAssertFalse(result.observation.contains("report.pdf"))

        XCTAssertFalse(FileManager.default.fileExists(atPath: workCookieFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workStateURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDownload.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalCookieFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalStateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: personalDownload.path))

        let remainingHistory = try String(contentsOf: historyURL, encoding: .utf8)
        XCTAssertFalse(remainingHistory.contains(#""profile":"work""#))
        XCTAssertTrue(remainingHistory.contains(#""profile":"personal""#))
    }

    func testAgentLoopMergesResponseUsageThenAccumulatesAcrossToolIterations() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [
                .usage(Usage(promptTokens: 10, cachedPromptTokens: 4)),
                .usage(Usage(completionTokens: 1, totalTokens: 11)),
                .toolCalls([ToolCall(id: "read", name: "read_file", arguments: #"{"path":"in.txt"}"#)]),
                .done(finishReason: "tool_calls"),
            ],
            [
                .textDelta("Done."),
                .usage(Usage(promptTokens: 5, cachedPromptTokens: 1)),
                .usage(Usage(completionTokens: 2, totalTokens: 7)),
                .done(finishReason: "stop"),
            ],
        ])
        let loop = makeLoop(ws: ws,
                            log: log,
                            provider: provider,
                            responder: FixedResponder(.deny),
                            includeUsage: true)

        try await loop.send("read in.txt")

        let events = await log.replay()
        let stats = events.compactMap { envelope -> TurnStatsPayload? in
            guard case .turnStats(let payload) = envelope.event else { return nil }
            return payload
        }.last
        let responseMessageID = events.compactMap { envelope -> MessageID? in
            guard case .messageCompleted(let payload) = envelope.event,
                  payload.text == "Done." else { return nil }
            return payload.messageId
        }.last
        let outcomeTurnID = events.compactMap { envelope -> TurnID? in
            guard case .turnOutcome(let payload) = envelope.event else {
                return nil
            }
            return payload.turnID
        }.last
        XCTAssertEqual(stats?.promptTokens, 15)
        XCTAssertEqual(stats?.cachedPromptTokens, 5)
        XCTAssertEqual(stats?.completionTokens, 3)
        XCTAssertEqual(stats?.totalTokens, 18)
        XCTAssertEqual(stats?.responseMessageID, responseMessageID)
        XCTAssertEqual(stats?.turnID, outcomeTurnID)

        let projectedReply = CodeProjection.build(from: events).items.first {
            $0.id == responseMessageID?.rawValue
        }
        XCTAssertEqual(projectedReply?.turnStats?.totalTokens, 18)
    }

    func testInvalidJSONToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "bad_json",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt","content":"unterminated"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need valid JSON."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let result = await toolResults(in: log).first
        XCTAssertTrue(result?.observation.hasPrefix("invalid tool input:") == true)
        XCTAssertTrue(result?.observation.contains("write_file") == true)
    }

    func testNonObjectToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "not_object",
                                  name: "write_file",
                                  arguments: #""out.txt""#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need an object."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: arguments for write_file must be a JSON object matching the tool schema.")
    }

    func testMissingRequiredToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "missing_required",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt"}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need content."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: arguments for write_file are missing required field(s): content.")
    }

    func testWrongTypeToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "wrong_type",
                                  name: "write_file",
                                  arguments: #"{"path":"out.txt","content":42}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need text content."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument content for write_file must be string.")
    }

    func testNumericConstraintToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }
        try Data("data".utf8).write(to: ws.appendingPathComponent("in.txt"))

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "bad_limit",
                                  name: "read_file",
                                  arguments: #"{"path":"in.txt","maxBytes":0}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need a positive byte limit."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("read in.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument maxBytes for read_file must be >= 1.")
    }

    func testStringLengthToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "empty_path",
                                  name: "read_file",
                                  arguments: #"{"path":""}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I need a path."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("read an empty path")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(types.contains(.permissionRequest))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation, "invalid tool input: argument path for read_file must have at least 1 character.")
    }

    func testUnknownToolArgumentsDoNotRequestPermissionOrExecuteTool() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let rawArguments = #"{"path":"out.txt","content":"hello","overwrite":true}"#
        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "unknown_field",
                                  name: "write_file",
                                  arguments: rawArguments)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("I should only use known fields."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("create out.txt")

        let events = await log.replay()
        let types = events.map { $0.event.type }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.appendingPathComponent("out.txt").path))
        XCTAssertFalse(types.contains(.permissionRequest))
        XCTAssertFalse(types.contains(.patchProposed))
        let durableCall = try XCTUnwrap(events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertEqual(durableCall.args, #"{"_intatis":"arguments_redacted"}"#)
        XCTAssertEqual(durableCall.argsRedacted, true)
        XCTAssertNil(durableCall.argsDigest)
        XCTAssertEqual(durableCall.argsCharacterCount, rawArguments.count)
        let encodedEvents = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encodedEvents.contains(rawArguments))
        XCTAssertFalse(encodedEvents.contains(ToolRegistry.authorizationDigest(rawArguments)))
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation,
                       "invalid tool input: arguments for write_file contain unknown field(s): overwrite. Allowed fields: content, path.")
    }

    func testUnknownToolNameAndArgumentsAreRedactedBeforeEventLog() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let secret = "sk-unknown-tool-secret-123456789"
        let rawName = "https://private-tool.example.test/run?token=\(secret)"
        let rawArguments = #"{"api_key":"sk-unknown-tool-secret-123456789"}"#
        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(
                id: "unknown-sensitive",
                name: rawName,
                arguments: rawArguments)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Unknown tool rejected."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(
            ws: ws,
            log: log,
            provider: provider,
            responder: FixedResponder(.allow))

        try await loop.send("Reject the unknown tool.")

        let events = await log.replay()
        let call = try XCTUnwrap(events.compactMap { envelope -> ToolCallPayload? in
            guard case .toolCall(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertEqual(call.name, "[REDACTED_URL]")
        XCTAssertEqual(call.args, #"{"_intatis":"arguments_redacted"}"#)
        XCTAssertNil(call.argsDigest)
        let result = try XCTUnwrap(events.compactMap { envelope -> ToolResultPayload? in
            guard case .toolResult(let payload) = envelope.event else { return nil }
            return payload
        }.first)
        XCTAssertTrue(result.observation.contains("unknown tool: [REDACTED_URL]"))
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains(rawName))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains(rawArguments))
        XCTAssertFalse(encoded.contains(ToolRegistry.authorizationDigest(rawArguments)))
    }

    func testEmptyArgumentsAreNormalizedForNoArgumentTools() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "status", name: "git_status", arguments: "")]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Clean."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))

        try await loop.send("show git status")

        let events = await log.replay()
        let result = await toolResults(in: log).first
        XCTAssertFalse(events.map { $0.event.type }.contains(.permissionRequest))
        XCTAssertEqual(result?.observation, "clean")
    }

    func testGitWriteToolRequestsPermissionBeforeExecution() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "stage",
                                  name: "git_stage",
                                  arguments: #"{"paths":["Sources/App.swift"]}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Permission denied."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))

        try await loop.send("stage a file")

        let events = await log.replay()
        XCTAssertTrue(events.contains {
            if case .permissionRequest(let payload) = $0.event {
                return payload.tool == "git_stage"
            }
            return false
        })
        let result = await toolResults(in: log).first
        XCTAssertEqual(result?.observation,
                       "permission denied: modify workspace resource")
    }

    func testNoArgumentToolsRejectUnknownArguments() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "status_with_extra",
                                  name: "git_status",
                                  arguments: #"{"path":"."}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("No extra fields."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.deny))

        try await loop.send("show git status")

        let events = await log.replay()
        let result = await toolResults(in: log).first
        XCTAssertFalse(events.map { $0.event.type }.contains(.permissionRequest))
        XCTAssertEqual(result?.observation,
                       "invalid tool input: arguments for git_status contain unknown field(s): path. Allowed fields: no fields.")
    }

    func testGitPushRejectsForceArgumentBeforePermission() async throws {
        let (ws, log) = try workspaceAndLog()
        defer { try? FileManager.default.removeItem(at: ws) }

        let provider = ScriptedProvider([
            [.toolCalls([ToolCall(id: "push",
                                  name: "git_push",
                                  arguments: #"{"remote":"origin","branch":"main","confirmRemote":"origin","confirmBranch":"main","force":true}"#)]),
             .done(finishReason: "tool_calls")],
            [.textDelta("Force rejected."), .done(finishReason: "stop")],
        ])
        let loop = makeLoop(ws: ws, log: log, provider: provider, responder: FixedResponder(.allow))

        try await loop.send("push forcefully")

        let events = await log.replay()
        let result = await toolResults(in: log).first
        XCTAssertFalse(events.map { $0.event.type }.contains(.permissionRequest))
        XCTAssertTrue(result?.observation.contains("unknown field(s): force") == true, result?.observation ?? "")
    }
}
