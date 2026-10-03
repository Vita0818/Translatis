import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisTools requires CryptoKit or swift-crypto")
#endif
import IntatisCore
import IntatisProtocol

/// Raw JSON arguments for a tool call, with a typed decode helper.
public struct ToolArgs: Sendable {
    public let raw: String
    public init(raw: String) { self.raw = raw }

    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = raw.data(using: .utf8) else {
            throw IntatisError.decoding("tool args are not valid UTF-8")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw IntatisError.decoding("tool args: \(error.localizedDescription)")
        }
    }
}

/// The result of executing a tool. `diff`/`changedFiles` are set by mutating tools.
public struct ToolObservation: Equatable, Sendable {
    public var text: String
    public var truncated: Bool
    public var diff: String?
    public var changedFiles: [String]?
    /// Optional SDK-independent MCP content preserved beside the legacy text
    /// projection. Existing tools and callers continue to use `text` only.
    public var structuredResult: MCPStructuredToolResult?
    /// Provider-native deferred tool definitions returned by `tool_search`.
    /// AgentKernel persists this as a dedicated Responses input item; it must
    /// never be merged into the next request's top-level tool catalog.
    public var toolSearchOutput: ModelToolSearchOutput?
    public init(text: String,
                truncated: Bool = false,
                diff: String? = nil,
                changedFiles: [String]? = nil,
                structuredResult: MCPStructuredToolResult? = nil,
                toolSearchOutput: ModelToolSearchOutput? = nil) {
        self.text = text
        self.truncated = truncated
        self.diff = diff
        self.changedFiles = changedFiles
        self.structuredResult = structuredResult
        self.toolSearchOutput = toolSearchOutput
    }
}

/// Static metadata the permission gate reads. Tools are dumb executors; they do
/// not decide whether they may run (ARCHITECTURE.md §1.2 principle E).
public enum ToolModelSpecKind: String, Equatable, Sendable {
    case function
    case toolSearch = "tool_search"
}

public struct ToolDescriptor: Equatable, Sendable {
    public let name: String
    public let description: String
    public let sideEffect: SideEffect
    public let parameters: JSONValue   // JSON-Schema object
    /// Provider-facing metadata retained with the exact registration.
    /// Permission and execution never infer these fields from a later catalog.
    public let modelSpecKind: ToolModelSpecKind
    public let strict: Bool?
    public let deferLoading: Bool?
    public let outputSchema: JSONValue?
    public let supportsParallelCalls: Bool

    public init(name: String,
                description: String,
                sideEffect: SideEffect,
                parameters: JSONValue,
                modelSpecKind: ToolModelSpecKind = .function,
                strict: Bool? = nil,
                deferLoading: Bool? = nil,
                outputSchema: JSONValue? = nil,
                supportsParallelCalls: Bool = false) {
        self.name = name
        self.description = description
        self.sideEffect = sideEffect
        self.parameters = parameters
        self.modelSpecKind = modelSpecKind
        self.strict = strict
        self.deferLoading = deferLoading
        self.outputSchema = outputSchema
        self.supportsParallelCalls = supportsParallelCalls
    }
}

// MARK: - Injected services (keep tools testable + backend-swappable)

public struct ShellResult: Equatable, Sendable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int
    public init(stdout: String, stderr: String, exitCode: Int) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

/// A managed workspace sandbox rejected process startup before the target
/// executable was entered. Only the sandbox runner may manufacture this
/// error from an attributable wrapper diagnostic. Generic command failures,
/// including an unqualified `EPERM`, must remain ordinary `ShellResult`s.
///
/// Because this error proves the target process did not start, AgentKernel may
/// durably settle the prepared execution as `not_started` without retrying it.
public struct WorkspaceSandboxDeniedError: Error, Equatable, Sendable, LocalizedError {
    public let reason: String

    init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public struct GitPatchResult: Equatable, Sendable {
    public var text: String
    public var changedFiles: [String]
    public var diff: String
    public init(text: String, changedFiles: [String], diff: String) {
        self.text = text
        self.changedFiles = changedFiles
        self.diff = diff
    }
}

public protocol ShellRunner: Sendable {
    func run(_ command: String, cwd: URL) async throws -> ShellResult
}

/// Fixed executable families accepted by the document process boundary.
/// Model-authored arguments never select one of these values: each concrete
/// document tool constructs one opaque invocation after schema, path, and
/// operation validation.
public enum DocumentBackendExecutable: String, Equatable, Sendable {
    case pythonRuntime
    case libreOffice
    case tectonic
}

/// Opaque, host-authored document backend request. Public read-only fields
/// keep injected runners observable in tests while the internal initializer
/// prevents clients outside IntatisTools from manufacturing a process launch.
public struct DocumentBackendInvocation: Equatable, Sendable {
    public let executable: DocumentBackendExecutable
    public let arguments: [String]
    public let environment: [String: String]
    public let readableWorkspacePaths: [String]
    /// User-visible destinations that were included in permission review.
    public let writableWorkspacePaths: [String]
    /// Host-created same-parent staging paths. The production runner verifies
    /// their binding to a reviewed destination before extending the process
    /// allow-list; these paths are never accepted from model arguments.
    public let internalWritableWorkspacePaths: [String]
    /// Exact files inside an internal staging root that a validator or later
    /// pipeline stage may read but must not modify. The surrounding stage can
    /// remain writable for reports or sibling outputs.
    public let internalReadOnlyWorkspacePaths: [String]

    init(executable: DocumentBackendExecutable,
         arguments: [String],
         environment: [String: String] = [:],
         readableWorkspacePaths: [String],
         writableWorkspacePaths: [String],
         internalWritableWorkspacePaths: [String] = [],
         internalReadOnlyWorkspacePaths: [String] = []) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.readableWorkspacePaths = readableWorkspacePaths
        self.writableWorkspacePaths = writableWorkspacePaths
        self.internalWritableWorkspacePaths = internalWritableWorkspacePaths
        self.internalReadOnlyWorkspacePaths = internalReadOnlyWorkspacePaths
    }
}

/// Dedicated no-shell process seam for mature document runtimes. Production
/// implementations resolve the executable from a fixed Intatis runtime and
/// reuse the managed timeout/cancellation/process-tree boundary.
public protocol DocumentBackendRunner: Sendable {
    func run(_ invocation: DocumentBackendInvocation,
             cwd: URL) async throws -> ShellResult
}

/// Opaque invocation accepted by the dedicated browser backend. Production
/// callers cannot turn this into a general shell: only Intatis browser tools
/// construct the fixed Node source, encoded structured arguments, and exact
/// workspace access plan.
struct BrowserBackendInvocation: Sendable {
    let javaScript: String
    let encodedArguments: String
    let readableWorkspacePaths: [String]
    let writableWorkspacePaths: [String]

    var injectedShellCommand: String {
        """
        set -e
        command -v node >/dev/null 2>&1 || { echo "node is not installed; install Node.js to use \(IntatisHostApplication.identity.name) browser tools" >&2; exit 127; }
        \(IntatisHostApplication.identity.environmentVariable("BROWSER_ARGS"))='\(encodedArguments)' node <<'INTATIS_BROWSER_INJECTED_NODE'
        \(javaScript)
        INTATIS_BROWSER_INJECTED_NODE
        """
    }
}

protocol BrowserBackendRunner: Sendable {
    func run(_ invocation: BrowserBackendInvocation,
             cwd: URL) async throws -> ShellResult
}

/// Compatibility seam for injected test/custom shell runners. Shipping
/// ProcessShellRunner hosts never use this adapter; they always receive the
/// dedicated browser process runner below.
struct InjectedShellBrowserBackendRunner: BrowserBackendRunner {
    let shell: ShellRunner

    func run(_ invocation: BrowserBackendInvocation,
             cwd: URL) async throws -> ShellResult {
        try await shell.run(invocation.injectedShellCommand, cwd: cwd)
    }
}

/// Immutable host identity for a terminal process. The model receives only the
/// opaque session ID; it cannot choose or widen this owner binding.
public struct TerminalSessionOwner: Equatable, Sendable {
    public let sessionID: SessionID
    public let agent: AgentID
    public let taskID: TaskID?
    public let taskAttempt: Int?
    public let workspaceRootIdentity: WorkspaceRootIdentity

    public init(sessionID: SessionID,
                agent: AgentID,
                taskID: TaskID?,
                taskAttempt: Int? = nil,
                workspaceRootIdentity: WorkspaceRootIdentity) {
        self.sessionID = sessionID
        self.agent = agent
        self.taskID = taskID
        self.taskAttempt = taskAttempt
        self.workspaceRootIdentity = workspaceRootIdentity
    }
}

public struct TerminalExecRequest: Equatable, Sendable {
    public let command: String
    public let workingDirectory: String?
    public let shellPath: String
    public let loginShell: Bool
    public let usesTTY: Bool
    public let allowsNetwork: Bool
    public let yieldMilliseconds: Int
    public let timeoutMilliseconds: Int

    public init(command: String,
                workingDirectory: String? = nil,
                shellPath: String = "/bin/zsh",
                loginShell: Bool = true,
                usesTTY: Bool = false,
                allowsNetwork: Bool = false,
                yieldMilliseconds: Int = 10_000,
                timeoutMilliseconds: Int = 300_000) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.shellPath = shellPath
        self.loginShell = loginShell
        self.usesTTY = usesTTY
        self.allowsNetwork = allowsNetwork
        self.yieldMilliseconds = yieldMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public struct TerminalInteractionRequest: Equatable, Sendable {
    public let characters: String?
    public let closeInput: Bool
    public let terminate: Bool
    public let yieldMilliseconds: Int

    public init(characters: String? = nil,
                closeInput: Bool = false,
                terminate: Bool = false,
                yieldMilliseconds: Int = 1_000) {
        self.characters = characters
        self.closeInput = closeInput
        self.terminate = terminate
        self.yieldMilliseconds = yieldMilliseconds
    }
}

public struct TerminalSessionObservation: Equatable, Sendable {
    public let sessionID: String?
    public let isRunning: Bool
    public let stdout: String
    public let stderr: String
    public let exitCode: Int?
    public let timedOut: Bool
    public let truncated: Bool

    public init(sessionID: String?,
                isRunning: Bool,
                stdout: String,
                stderr: String,
                exitCode: Int?,
                timedOut: Bool = false,
                truncated: Bool = false) {
        self.sessionID = sessionID
        self.isRunning = isRunning
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.truncated = truncated
    }
}

/// Session-owned terminal backend. A Code or Cowork runtime retains one
/// instance across AgentLoop turns and drains it during runtime shutdown.
public protocol TerminalSessionManaging: Sendable {
    func execute(_ request: TerminalExecRequest,
                 owner: TerminalSessionOwner,
                 workspaceLease: WorkspaceLease) async throws -> TerminalSessionObservation
    func interact(sessionID: String,
                  request: TerminalInteractionRequest,
                  owner: TerminalSessionOwner) async throws -> TerminalSessionObservation
    func terminate(taskID: TaskID, reason: String) async
    func terminateAll(reason: String) async
    func shutdown(reason: String) async
}

/// Git backend. v0.2 dev uses `ProcessGitService` (spawns git); the App Store
/// sandbox build swaps in a libgit2-backed implementation (ARCHITECTURE.md §9.1).
public protocol GitService: Sendable {
    func status(workspace: URL) async throws -> String   // porcelain v1
    func diff(workspace: URL) async throws -> String      // unified diff
    func stagedDiff(workspace: URL) async throws -> String // unified diff for index
    func repositoryInfo(workspace: URL) async throws -> String
    func recentCommits(limit: Int, workspace: URL) async throws -> String
    func diffAgainst(base: String, workspace: URL) async throws -> String
    func branchInfo(workspace: URL) async throws -> String
    func createBranch(name: String, startPoint: String?, workspace: URL) async throws -> String
    func stage(paths: [String], workspace: URL) async throws -> String
    func unstage(paths: [String], workspace: URL) async throws -> String
    func commit(message: String, workspace: URL) async throws -> String
    func applyPatch(diff: String, reverse: Bool, checkOnly: Bool, cached: Bool, workspace: URL) async throws -> GitPatchResult
    func worktrees(workspace: URL) async throws -> String
    func createWorktree(name: String, startPoint: String?, branch: String?, workspace: URL) async throws -> String
    func removeWorktree(name: String, force: Bool, workspace: URL) async throws -> String
    func remotes(workspace: URL) async throws -> String
    func fetch(remote: String, branch: String?, prune: Bool, workspace: URL) async throws -> String
    func pullFastForward(remote: String, branch: String, workspace: URL) async throws -> String
    func push(remote: String, branch: String, setUpstream: Bool, workspace: URL) async throws -> String
    func switchBranch(name: String, workspace: URL) async throws -> String
}

/// Provider-backed or local-model image generation service injected by the app
/// or CLI. The tool layer owns path validation; the service owns model/provider
/// resolution and writing generated bytes to the requested workspace path.
public protocol ImageGenerationToolService: Sendable {
    func generateImage(prompt: String,
                       size: String,
                       count: Int,
                       outputPath: String,
                       workspaceRoot: URL) async throws -> ToolObservation
    func editImage(image: Data,
                   filename: String,
                   mime: String,
                   prompt: String,
                   outputPath: String,
                   workspaceRoot: URL) async throws -> ToolObservation
}

/// Seam for agent-to-agent messaging (v0.3). Cowork provides an implementation
/// bound to the asking agent; the `ask_agent` tool routes through it so all
/// cross-agent traffic goes through the mediated Message Bus (ARCHITECTURE.md §7).
public enum AgentMessengerReply: Equatable, Sendable {
    case success(String)
    case failure(String)
}

public protocol AgentMessenger: Sendable {
    func ask(to agent: String, question: String) async -> AgentMessengerReply
    func sendMessage(to agent: String, content: String) async -> String
    func requestInformation(to agent: String,
                            question: String,
                            basedOn: String?) async -> String
    func replyMessage(to agent: String,
                      content: String,
                      inReplyTo: String) async -> String
    func delegateTask(authorization: ResolvedToolAuthorization,
                      executionID: String,
                      to agent: String?,
                      workTaskID: WorkTaskID?,
                      objective: String?,
                      roleHint: String?,
                      expectedDeliverable: String?) async throws -> String
}

/// Host-bound control-plane seam for the exact ContinuationRun that owns an
/// invocation. Tools never accept a session/run/task identifier from the
/// model; the Cowork host resolves those identities before exposing them.
public protocol RunController: Sendable {
    func requestClose(outcome: ContinuationRunCloseOutcome,
                      reason: String) async -> String
}

/// Seam for agent lifecycle management (v0.3 coordinator). Cowork provides an
/// implementation bound to the orchestrator so a coordinator agent can create,
/// list, and remove sub-agents through tools. Like `AgentMessenger`, the real
/// work happens in the orchestrator/registry — tools are just thin executors.
public protocol AgentManager: Sendable {
    func spawnAgent(authorization: ResolvedToolAuthorization?,
                    name: String,
                    path: String,
                    inferenceProfileID: String?,
                    requestedAccess: WorkspaceAccess,
                    canCoordinate: Bool) async -> String
    func listAgents() async -> String
    func listInferenceProfiles() async -> String
    func removeAgent(name: String) async -> String
}

public struct ToolContext: Sendable {
    public let workspaceRoot: URL
    /// Effective task/workspace lease. Direct tool hosts that omit it receive
    /// the standard read-write lease (including default secret deny patterns),
    /// so process-backed tools never silently run with a wider policy.
    public let workspaceLease: WorkspaceLease
    /// Raw, model-authored shell commands. The default runner is workspace and
    /// network confined.
    public let shell: ShellRunner
    /// Shell backend for structured Swift tools (browser/document wrappers)
    /// whose arguments and paths have already been validated by the tool. This
    /// runner is workspace-confined and network-denied.
    public let structuredShell: ShellRunner
    /// Dedicated workspace-confined structured runner for tools whose
    /// descriptor and permission request explicitly declare network access.
    /// Keeping this separate prevents a document/LaTeX wrapper from inheriting
    /// browser network authority merely because both are process-backed.
    public let networkStructuredShell: ShellRunner
    /// Dedicated backend for Intatis-generated Playwright/CDP browser
    /// invocations. It accepts only the opaque structured invocation above,
    /// never a model-authored shell string.
    let browserBackend: BrowserBackendRunner
    /// Dedicated backend for fixed document runtime invocations. Unlike
    /// `structuredShell`, this interface cannot receive a shell command.
    public let documentBackend: any DocumentBackendRunner
    /// Long-lived, runtime-owned terminal service used by `exec_command` and
    /// `write_stdin`. It is optional so isolated tool hosts must opt in rather
    /// than silently creating a process manager with the wrong lifetime.
    public let terminal: (any TerminalSessionManaging)?
    public let git: GitService
    public let messenger: AgentMessenger?
    public let agentManager: AgentManager?
    public let workTaskManager: WorkTaskManager?
    public let goalManager: GoalManager?
    public let runController: RunController?
    public let imageGenerator: ImageGenerationToolService?
    /// Host service bound to the session that owns this exact invocation.
    /// The model never supplies a session identifier.
    public let sessionNaming: SessionNamingService?
    /// Durable executor operation identifier used to make session renames
    /// idempotent across retries and reconciliation.
    public let executionID: String?
    /// Exact MCP server/tool identifiers frozen for the provider response that
    /// selected this tool call. Skill readers consume this narrow value for
    /// dependency preflight; it never contains transport configuration or
    /// credentials and defaults to an explicitly unavailable host.
    public let mcpAvailability: MCPToolAvailabilitySnapshot
    /// Immutable host authorization for the exact executor invocation. Tools
    /// that need a host-resolved target (for example delegate_task(to:auto))
    /// must consume this snapshot instead of resolving a different target from
    /// model-authored arguments after review.
    public let authorization: ResolvedToolAuthorization?
    public init(workspaceRoot: URL,
                workspaceLease: WorkspaceLease? = nil,
                shell: ShellRunner = ProcessShellRunner(),
                structuredShell: ShellRunner? = nil,
                networkStructuredShell: ShellRunner? = nil,
                browserBackendShell: ShellRunner? = nil,
                documentBackend: (any DocumentBackendRunner)? = nil,
                terminal: (any TerminalSessionManaging)? = nil,
                git: GitService = ProcessGitService(),
                messenger: AgentMessenger? = nil,
                agentManager: AgentManager? = nil,
                workTaskManager: WorkTaskManager? = nil,
                goalManager: GoalManager? = nil,
                runController: RunController? = nil,
                imageGenerator: ImageGenerationToolService? = nil,
                sessionNaming: SessionNamingService? = nil,
                executionID: String? = nil,
                mcpAvailability:
                    MCPToolAvailabilitySnapshot = .unavailable,
                authorization: ResolvedToolAuthorization? = nil) {
        let effectiveLease = workspaceLease ?? WorkspaceLease(
            rootPath: workspaceRoot.resolvingSymlinksInPath().standardizedFileURL.path,
            access: .readWrite)
        var processLease = effectiveLease
        var processDenied = Set(processLease.deniedPatterns)
        for pattern in WorkspaceLease.mandatoryManagedStoreDeniedPatterns
            where processDenied.insert(pattern).inserted {
            processLease.deniedPatterns.append(pattern)
        }
        self.workspaceRoot = workspaceRoot
        // Keep the exact reviewed lease available to authorization-aware
        // host tools such as Knowledge. Generic process backends receive the
        // independently hardened projection below.
        self.workspaceLease = effectiveLease
        if let processShell = shell as? ProcessShellRunner {
            self.shell = processShell.scoped(to: processLease)
        } else {
            self.shell = shell
        }
        let resolvedStructuredShell: ShellRunner
        if let structuredShell {
            if let processShell = structuredShell as? StructuredProcessShellRunner {
                resolvedStructuredShell = processShell.scoped(to: processLease)
            } else if let processShell = structuredShell as? ProcessShellRunner {
                resolvedStructuredShell = processShell.scoped(to: processLease)
            } else {
                resolvedStructuredShell = structuredShell
            }
        } else if shell is ProcessShellRunner {
            resolvedStructuredShell = StructuredProcessShellRunner(workspaceLease: processLease)
        } else {
            // Preserve injected fake runners in unit tests and custom hosts.
            resolvedStructuredShell = shell
        }
        self.structuredShell = resolvedStructuredShell
        let resolvedNetworkStructuredShell: ShellRunner
        if let networkStructuredShell {
            if let processShell = networkStructuredShell as? StructuredProcessShellRunner {
                resolvedNetworkStructuredShell = processShell.scoped(to: processLease)
            } else if let processShell = networkStructuredShell as? ProcessShellRunner {
                resolvedNetworkStructuredShell = processShell.scoped(to: processLease)
            } else {
                resolvedNetworkStructuredShell = networkStructuredShell
            }
        } else if shell is ProcessShellRunner, structuredShell == nil {
            resolvedNetworkStructuredShell = StructuredProcessShellRunner(
                allowsNetwork: true,
                workspaceLease: processLease)
        } else {
            // Preserve the pre-existing single fake-runner injection behavior.
            resolvedNetworkStructuredShell = resolvedStructuredShell
        }
        self.networkStructuredShell = resolvedNetworkStructuredShell
        if let browserBackendShell {
            let resolvedShell: ShellRunner
            if let processShell = browserBackendShell as? StructuredProcessShellRunner {
                resolvedShell = processShell.scoped(to: processLease)
            } else if let processShell = browserBackendShell as? ProcessShellRunner {
                resolvedShell = processShell.scoped(to: processLease)
            } else {
                resolvedShell = browserBackendShell
            }
            self.browserBackend = InjectedShellBrowserBackendRunner(shell: resolvedShell)
        } else if shell is ProcessShellRunner {
            self.browserBackend = BrowserBackendProcessRunner(
                workspaceLease: processLease)
        } else {
            // Preserve the pre-existing single fake-runner injection behavior.
            self.browserBackend = InjectedShellBrowserBackendRunner(
                shell: resolvedNetworkStructuredShell)
        }
        if let documentBackend {
            self.documentBackend = documentBackend
        } else {
            self.documentBackend = DocumentBackendProcessRunner(
                workspaceLease: processLease)
        }
        self.terminal = terminal
        if let processGit = git as? ProcessGitService {
            self.git = processGit.scoped(to: processLease)
        } else {
            self.git = git
        }
        self.messenger = messenger
        self.agentManager = agentManager
        self.workTaskManager = workTaskManager
        self.goalManager = goalManager
        self.runController = runController
        self.imageGenerator = imageGenerator
        self.sessionNaming = sessionNaming
        self.executionID = executionID
        self.mcpAvailability = mcpAvailability
        self.authorization = authorization
    }
}

// MARK: - Tool

public protocol Tool: Sendable {
    static var descriptor: ToolDescriptor { get }
    /// Stable host-facing permission family. This can deliberately differ
    /// from the exact operation in `PermissionIntent.action`; for example,
    /// `write_file` and `apply_patch` are two operations in one
    /// `filesystem.edit` capability family.
    static var canonicalPermission: String? { get }
    /// Tool-specific semantic validation that runs before permission review.
    /// JSON Schema remains the provider-facing shape check; this hook enforces
    /// nested operation matrices and cross-field invariants without widening
    /// the generic schema interpreter.
    func validateArguments(_ args: ToolArgs) throws
    func touchedPaths(_ args: ToolArgs) -> [String]
    func risksNetwork(_ args: ToolArgs) -> Bool
    /// Build the structured authorization input for this exact invocation.
    /// `workspaceRoot` is context only; it is not an approval or a replacement
    /// for CapabilityLease / WorkspaceLease enforcement in AgentKernel.
    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent
    /// Instance-descriptor-aware permission derivation for dynamic
    /// registrations. Existing static tools keep using the overload above.
    func permissionIntent(_ args: ToolArgs,
                          descriptor: ToolDescriptor,
                          workspaceRoot: URL) -> PermissionIntent
    /// Bounded semantic fields for the reviewer. The returned value is
    /// redacted by `PermissionActionPreview` and never substitutes for the raw
    /// argument digest used by host validation.
    func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview?
    /// Instance-descriptor-aware reviewer preview for dynamic registrations.
    func permissionActionPreview(_ args: ToolArgs,
                                 descriptor: ToolDescriptor) -> PermissionActionPreview?
    /// Secret-safe material used to bind the in-memory invocation to its
    /// immutable authorization snapshot. Most tools use the normalized raw
    /// JSON. Tools that accept secret-like interactive bytes may instead
    /// return a structural identity that deliberately omits those bytes.
    func authorizationArgumentIdentity(_ args: ToolArgs) -> String
    func execute(_ args: ToolArgs, in context: ToolContext) async throws -> ToolObservation
}

public extension Tool {
    static var canonicalPermission: String? { nil }
    func validateArguments(_ args: ToolArgs) throws {}
    func touchedPaths(_ args: ToolArgs) -> [String] { [] }
    func risksNetwork(_ args: ToolArgs) -> Bool { false }
    func permissionIntent(_ args: ToolArgs, workspaceRoot: URL) -> PermissionIntent {
        permissionIntent(
            args,
            descriptor: Self.descriptor,
            workspaceRoot: workspaceRoot)
    }

    func permissionIntent(_ args: ToolArgs,
                          descriptor: ToolDescriptor,
                          workspaceRoot: URL) -> PermissionIntent {
        var intent = PermissionIntent.derived(
            toolName: descriptor.name,
            sideEffect: descriptor.sideEffect,
            touchedPaths: touchedPaths(args),
            risksNetwork: risksNetwork(args))
        guard let object = Self.permissionArgumentObject(args) else { return intent }

        if descriptor.name == "run_shell",
           case .string(let command)? = object["command"] {
            intent.resources.append(PermissionResource(kind: .command, value: command))
        }
        if descriptor.name.hasPrefix("git_") {
            intent.resources.append(PermissionResource(kind: .git, value: workspaceRoot.path))
            for key in ["remote", "branch", "base", "name", "startPoint"] {
                if case .string(let value)? = object[key] {
                    intent.metadata[key] = .string(value)
                }
            }
        }
        if descriptor.name.hasPrefix("browser_") || descriptor.name == "web_fetch" {
            for key in ["url", "startURL"] {
                if case .string(let value)? = object[key] {
                    intent.resources.append(PermissionResource(kind: .url, value: value))
                }
            }
            if case .string(let query)? = object["query"] {
                intent.metadata["query"] = .string(query)
            }
        }
        return intent
    }

    func permissionActionPreview(_ args: ToolArgs) -> PermissionActionPreview? {
        permissionActionPreview(args, descriptor: Self.descriptor)
    }

    func permissionActionPreview(_ args: ToolArgs,
                                 descriptor: ToolDescriptor) -> PermissionActionPreview? {
        guard let object = Self.permissionArgumentObject(args) else { return nil }
        let semanticKeys = [
            "command", "content", "diff", "question", "objective", "reason",
            "role_hint", "roleHint", "expected_deliverable", "expectedDeliverable",
            "prompt", "query", "url", "startURL", "host", "port", "server",
            "tool", "to", "name", "path", "model", "work_task_id",
        ]
        var fields: [String: String] = [:]
        for key in semanticKeys {
            guard let value = object[key] else { continue }
            switch value {
            case .string(let string):
                fields[key] = string
            case .number(let number):
                fields[key] = String(number)
            case .bool(let value):
                fields[key] = String(value)
            case .null, .array, .object:
                continue
            }
        }
        guard !fields.isEmpty else { return nil }
        return PermissionActionPreview(kind: descriptor.name, fields: fields)
    }

    func authorizationArgumentIdentity(_ args: ToolArgs) -> String { args.raw }

    private static func permissionArgumentObject(_ args: ToolArgs) -> [String: JSONValue]? {
        guard let data = args.raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = decoded else { return nil }
        return object
    }
}

/// One authoritative model-visible tool entry. The concrete tool supplies both
/// its schema and executor; `grantingCapabilities` records which lease
/// capability aliases may expose that concrete entry in a scoped registry.
/// Tool-neutral evidence envelope used by AgentKernel immediately before a
/// final answer is committed. Domain modules keep ownership of the mechanical
/// replay implementation; AgentKernel only preserves current-turn identity
/// and invokes this exact registration-owned closure.
public struct ToolGroundingEvidence: Equatable, Sendable {
    public let toolName: String
    public let evidenceID: String
    public let knowledgeBase: String
    public let knowledgeBaseRevision: String
    public let retrievalSnapshot: String
    public let retrievalSnapshotRevision: String
    public let textSHA256: String
    public let evidenceURI: String
    public let structuredEvidence: JSONValue

    public init(toolName: String,
                evidenceID: String,
                knowledgeBase: String,
                knowledgeBaseRevision: String,
                retrievalSnapshot: String,
                retrievalSnapshotRevision: String,
                textSHA256: String,
                evidenceURI: String,
                structuredEvidence: JSONValue) {
        self.toolName = toolName
        self.evidenceID = evidenceID
        self.knowledgeBase = knowledgeBase
        self.knowledgeBaseRevision = knowledgeBaseRevision
        self.retrievalSnapshot = retrievalSnapshot
        self.retrievalSnapshotRevision = retrievalSnapshotRevision
        self.textSHA256 = textSHA256
        self.evidenceURI = evidenceURI
        self.structuredEvidence = structuredEvidence
    }
}

public typealias ToolGroundingEvidenceRevalidator = @Sendable (
    ToolGroundingEvidence
) async throws -> Void

public struct ToolRegistration: Sendable {
    /// The exact instance-level descriptor advertised, authorized, and
    /// executed by this registration. Dynamic tools must supply this value
    /// explicitly; static tools use the compatibility initializer below.
    public let descriptor: ToolDescriptor
    public let tool: any Tool
    public let canonicalPermission: String?
    public let grantingCapabilities: Set<ToolCapability>
    public let requiredCommunication: ToolCommunicationRequirement
    public let requiredDelegation: ToolDelegationRequirement
    /// Exact MCP authority embedded in permission and durable execution
    /// evidence. Ordinary registrations keep this nil.
    public let mcpAuthorization: MCPToolAuthorizationSnapshot?
    /// Invocation-specific MCP resource routes selected from normalized
    /// arguments before permission review. Fixed aggregate resource tools use
    /// this seam because one registration can select one or many servers.
    private let mcpResourceAuthorizationResolver:
        (@Sendable (
            ToolArgs
        ) throws -> MCPResourceInvocationAuthorizationSnapshot?)?
    private let usesStaticToolMetadata: Bool
    private let argumentValidator:
        @Sendable (ToolArgs) throws -> Void
    private let argumentValidationFailureBuilder:
        (@Sendable (String) -> ToolObservation)?
    public let groundingEvidenceRevalidator:
        ToolGroundingEvidenceRevalidator?

    /// Compatibility initializer for the existing static tool surface.
    public init(tool: any Tool,
                grantingCapabilities: Set<ToolCapability> = [],
                requiredCommunication: ToolCommunicationRequirement = .none,
                requiredDelegation: ToolDelegationRequirement = .none) {
        self.init(
            descriptor: type(of: tool).descriptor,
            tool: tool,
            canonicalPermission: type(of: tool).canonicalPermission,
            grantingCapabilities: grantingCapabilities,
            requiredCommunication: requiredCommunication,
            requiredDelegation: requiredDelegation,
            mcpAuthorization: nil,
            mcpResourceAuthorizationResolver: nil,
            argumentValidator: { try tool.validateArguments($0) },
            argumentValidationFailureBuilder: nil,
            groundingEvidenceRevalidator: nil,
            usesStaticToolMetadata: true)
    }

    /// Registers one executor under an exact instance-level descriptor.
    ///
    /// Callers that construct dynamic registrations must also construct a
    /// registry with a fresh, immutable `registryVersion`.
    public init(descriptor: ToolDescriptor,
                tool: any Tool,
                canonicalPermission: String? = nil,
                grantingCapabilities: Set<ToolCapability> = [],
                requiredCommunication: ToolCommunicationRequirement = .none,
                requiredDelegation: ToolDelegationRequirement = .none,
                mcpAuthorization: MCPToolAuthorizationSnapshot? = nil,
                mcpResourceAuthorizationResolver:
                    (@Sendable (
                        ToolArgs
                    ) throws -> MCPResourceInvocationAuthorizationSnapshot?)?
                        = nil,
                argumentValidator:
                    @escaping @Sendable (ToolArgs) throws -> Void = { _ in },
                argumentValidationFailureBuilder:
                    (@Sendable (String) -> ToolObservation)? = nil,
                groundingEvidenceRevalidator:
                    ToolGroundingEvidenceRevalidator? = nil) {
        self.init(
            descriptor: descriptor,
            tool: tool,
            canonicalPermission: canonicalPermission,
            grantingCapabilities: grantingCapabilities,
            requiredCommunication: requiredCommunication,
            requiredDelegation: requiredDelegation,
            mcpAuthorization: mcpAuthorization,
            mcpResourceAuthorizationResolver:
                mcpResourceAuthorizationResolver,
            argumentValidator: argumentValidator,
            argumentValidationFailureBuilder:
                argumentValidationFailureBuilder,
            groundingEvidenceRevalidator:
                groundingEvidenceRevalidator,
            usesStaticToolMetadata: false)
    }

    private init(descriptor: ToolDescriptor,
                 tool: any Tool,
                 canonicalPermission: String?,
                 grantingCapabilities: Set<ToolCapability>,
                 requiredCommunication: ToolCommunicationRequirement,
                 requiredDelegation: ToolDelegationRequirement,
                 mcpAuthorization: MCPToolAuthorizationSnapshot?,
                 mcpResourceAuthorizationResolver:
                    (@Sendable (
                        ToolArgs
                    ) throws -> MCPResourceInvocationAuthorizationSnapshot?)?,
                 argumentValidator:
                    @escaping @Sendable (ToolArgs) throws -> Void,
                 argumentValidationFailureBuilder:
                    (@Sendable (String) -> ToolObservation)?,
                 groundingEvidenceRevalidator:
                    ToolGroundingEvidenceRevalidator?,
                 usesStaticToolMetadata: Bool) {
        self.descriptor = descriptor
        self.tool = tool
        self.canonicalPermission = canonicalPermission
        self.grantingCapabilities = grantingCapabilities
        self.requiredCommunication = requiredCommunication
        self.requiredDelegation = requiredDelegation
        self.mcpAuthorization = mcpAuthorization
        self.mcpResourceAuthorizationResolver =
            mcpResourceAuthorizationResolver
        self.argumentValidator = argumentValidator
        self.argumentValidationFailureBuilder =
            argumentValidationFailureBuilder
        self.groundingEvidenceRevalidator =
            groundingEvidenceRevalidator
        self.usesStaticToolMetadata = usesStaticToolMetadata
    }

    public func touchedPaths(_ args: ToolArgs) -> [String] {
        tool.touchedPaths(args)
    }

    public func risksNetwork(_ args: ToolArgs) -> Bool {
        tool.risksNetwork(args)
    }

    public func permissionIntent(_ args: ToolArgs,
                                 workspaceRoot: URL) -> PermissionIntent {
        if usesStaticToolMetadata {
            return tool.permissionIntent(args, workspaceRoot: workspaceRoot)
        }
        return tool.permissionIntent(
            args,
            descriptor: descriptor,
            workspaceRoot: workspaceRoot)
    }

    public func permissionActionPreview(
        _ args: ToolArgs
    ) -> PermissionActionPreview? {
        if usesStaticToolMetadata {
            return tool.permissionActionPreview(args)
        }
        return tool.permissionActionPreview(args, descriptor: descriptor)
    }

    public func authorizationArgumentIdentity(_ args: ToolArgs) -> String {
        tool.authorizationArgumentIdentity(args)
    }

    public func resolveMCPResourceAuthorization(
        _ args: ToolArgs
    ) throws -> MCPResourceInvocationAuthorizationSnapshot? {
        try mcpResourceAuthorizationResolver?(args)
    }

    public var requiresDynamicMCPResourceAuthorization: Bool {
        mcpResourceAuthorizationResolver != nil
    }

    public func validateArguments(_ args: ToolArgs) throws {
        try argumentValidator(args)
    }

    /// Optional typed result for a structurally valid tool call whose business
    /// arguments fail this registration's strict schema. Unknown tools and
    /// malformed outer transports remain protocol/runtime failures.
    public func argumentValidationFailure(
        message: String
    ) -> ToolObservation? {
        argumentValidationFailureBuilder?(message)
    }

    public func execute(_ args: ToolArgs,
                        in context: ToolContext) async throws -> ToolObservation {
        try await tool.execute(args, in: context)
    }
}

public enum ToolRegistryAuthorizationError: Error, Equatable, Sendable, LocalizedError {
    case unregisteredTool(String)
    case duplicateRegistration(String)
    case missingCapabilityLease(tool: String, required: [ToolCapability])
    case capabilityNotGranted(tool: String, required: [ToolCapability])
    case authorizationRegistryMismatch(expected: String, actual: String)
    case authorizationSchemaMismatch(expected: Int, actual: Int)
    case authorizationToolMismatch(expected: String, actual: String)
    case authorizationConcreteToolMismatch(expected: String, actual: String)
    case authorizationDescriptorMismatch(tool: String)
    case authorizationArgumentsMismatch(tool: String)
    case authorizationIntentMismatch(tool: String)
    case authorizationCapabilityMismatch(tool: String)
    case authorizationLeaseMismatch(tool: String)
    case authorizationInvocationMismatch(tool: String)
    case mcpGrantNotGranted(tool: String)
    case communicationNotGranted(tool: String, required: ToolCommunicationRequirement)
    case delegationNotGranted(tool: String, required: ToolDelegationRequirement)
    case leaseTaskMismatch(tool: String)

    public var errorDescription: String? {
        switch self {
        case .unregisteredTool(let tool):
            return "tool is not registered: \(tool)"
        case .duplicateRegistration(let tool):
            return "tool registration is ambiguous because the name is duplicated: \(tool)"
        case .missingCapabilityLease(let tool, let required):
            return "tool \(tool) requires an active capability lease granting one of: \(Self.names(required))"
        case .capabilityNotGranted(let tool, let required):
            return "tool \(tool) is not granted by the active capability lease; expected one of: \(Self.names(required))"
        case .authorizationRegistryMismatch(let expected, let actual):
            return "authorization registry mismatch; expected \(expected), got \(actual)"
        case .authorizationSchemaMismatch(let expected, let actual):
            return "authorization schema mismatch; expected \(expected), got \(actual)"
        case .authorizationToolMismatch(let expected, let actual):
            return "authorization tool mismatch; expected \(expected), got \(actual)"
        case .authorizationConcreteToolMismatch(let expected, let actual):
            return "authorization concrete tool mismatch; expected \(expected), got \(actual)"
        case .authorizationDescriptorMismatch(let tool):
            return "authorization descriptor fingerprint no longer matches registered tool \(tool)"
        case .authorizationArgumentsMismatch(let tool):
            return "authorization arguments no longer match the reviewed invocation for \(tool)"
        case .authorizationIntentMismatch(let tool):
            return "authorization intent no longer matches the reviewed invocation for \(tool)"
        case .authorizationCapabilityMismatch(let tool):
            return "authorization capability mapping no longer matches registered tool \(tool)"
        case .authorizationLeaseMismatch(let tool):
            return "authorization lease identity no longer matches the reviewed invocation for \(tool)"
        case .authorizationInvocationMismatch(let tool):
            return "authorization invocation identity no longer matches the current call for \(tool)"
        case .mcpGrantNotGranted(let tool):
            return "tool \(tool) is not granted by the exact active MCP grant"
        case .communicationNotGranted(let tool, let required):
            return "tool \(tool) requires communication grant \(required.rawValue)"
        case .delegationNotGranted(let tool, let required):
            return "tool \(tool) requires delegation grant \(required.rawValue)"
        case .leaseTaskMismatch(let tool):
            return "tool \(tool) is not authorized for the current task binding"
        }
    }

    private static func names(_ capabilities: [ToolCapability]) -> String {
        capabilities.map(\.rawValue).sorted().joined(separator: ", ")
    }
}

public struct ToolRegistry: Sendable {
    /// An immutable registry construction path. Dynamic registrations can only
    /// enter an existing registry through a builder whose replacement version
    /// was supplied up front.
    public struct Builder: Sendable {
        public let registryVersion: String
        private let registrations: [ToolRegistration]
        private let inheritedConflicts: Set<String>

        fileprivate init(registryVersion: String,
                         registrations: [ToolRegistration],
                         inheritedConflicts: Set<String>) {
            self.registryVersion = registryVersion
            self.registrations = registrations
            self.inheritedConflicts = inheritedConflicts
        }

        public func adding(registrations extra: [ToolRegistration]) -> Builder {
            Builder(
                registryVersion: registryVersion,
                registrations: registrations + extra,
                inheritedConflicts: inheritedConflicts)
        }

        public func adding(_ extra: [any Tool]) -> Builder {
            adding(registrations: extra.map { ToolRegistration(tool: $0) })
        }

        public func build() -> ToolRegistry {
            ToolRegistry(
                registrations: registrations,
                registryVersion: registryVersion,
                inheritedConflicts: inheritedConflicts)
        }
    }

    public let registryVersion: String
    private let registrations: [String: ToolRegistration]
    private let conflictedNames: Set<String>

    public init(
        _ tools: [any Tool],
        registryVersion: String = IntatisHostApplication.identity
            .namespacedIdentifier("standard.v1")
    ) {
        self.init(
            registrations: tools.map { ToolRegistration(tool: $0) },
            registryVersion: registryVersion)
    }

    public init(registrations: [ToolRegistration],
                registryVersion: String) {
        self.init(
            registrations: registrations,
            registryVersion: registryVersion,
            inheritedConflicts: [])
    }

    private init(registrations: [ToolRegistration],
                 registryVersion: String,
                 inheritedConflicts: Set<String>) {
        self.registryVersion = registryVersion
        var resolved: [String: ToolRegistration] = [:]
        var conflicts = inheritedConflicts
        for registration in registrations {
            let name = registration.descriptor.name
            guard !conflicts.contains(name) else { continue }
            if resolved.removeValue(forKey: name) != nil {
                conflicts.insert(name)
            } else {
                resolved[name] = registration
            }
        }
        self.registrations = resolved
        self.conflictedNames = conflicts
    }

    public func tool(named name: String) -> (any Tool)? {
        guard !conflictedNames.contains(name) else { return nil }
        return registrations[name]?.tool
    }
    public func registration(named name: String) -> ToolRegistration? {
        guard !conflictedNames.contains(name) else { return nil }
        return registrations[name]
    }
    public func all() -> [any Tool] {
        registrations.values
            .sorted { $0.descriptor.name < $1.descriptor.name }
            .map(\.tool)
    }
    public func descriptors() -> [ToolDescriptor] {
        registrations.values
            .map(\.descriptor)
            .sorted { $0.name < $1.name }
    }

    /// Resolves immutable host facts for this exact invocation. Scoped Cowork
    /// registries fail closed when their capability alias no longer belongs to
    /// the active lease; ordinary unscoped registries retain legacy behavior.
    public func resolveAuthorization(toolName: String,
                                     intent: PermissionIntent,
                                     risksNetwork: Bool,
                                     normalizedArguments: String,
                                     authorizationID: String? = nil,
                                     invocation: ToolAuthorizationInvocationContext = .init(),
                                     capabilityLease: CapabilityLease?,
                                     workspaceLease: WorkspaceLease?,
                                     targetAgentInferenceBinding: AgentInferenceBinding? = nil) throws -> ResolvedToolAuthorization {
        guard let registration = registrations[toolName] else {
            if conflictedNames.contains(toolName) {
                throw ToolRegistryAuthorizationError.duplicateRegistration(toolName)
            }
            throw ToolRegistryAuthorizationError.unregisteredTool(toolName)
        }
        let descriptor = registration.descriptor
        let granting = registration.grantingCapabilities.sorted { $0.rawValue < $1.rawValue }
        let arguments = ToolArgs(raw: normalizedArguments)
        let mcpResource = try registration
            .resolveMCPResourceAuthorization(arguments)
        let requiresLease = !granting.isEmpty
            || registration.requiredCommunication != .none
            || registration.requiredDelegation != .none
            || registration.mcpAuthorization != nil
            || registration.requiresDynamicMCPResourceAuthorization
        let membership: ToolAuthorizationMembership
        if !requiresLease {
            membership = .notRequired
        } else {
            guard let capabilityLease else {
                throw ToolRegistryAuthorizationError.missingCapabilityLease(
                    tool: toolName,
                    required: granting)
            }
            guard granting.isEmpty
                    || !registration.grantingCapabilities.isDisjoint(with: capabilityLease.tools) else {
                throw ToolRegistryAuthorizationError.capabilityNotGranted(
                    tool: toolName,
                    required: granting)
            }
            guard Self.communication(
                capabilityLease.communication,
                satisfies: registration.requiredCommunication) else {
                throw ToolRegistryAuthorizationError.communicationNotGranted(
                    tool: toolName,
                    required: registration.requiredCommunication)
            }
            guard Self.delegation(
                capabilityLease.delegation,
                satisfies: registration.requiredDelegation) else {
                throw ToolRegistryAuthorizationError.delegationNotGranted(
                    tool: toolName,
                    required: registration.requiredDelegation)
            }
            if let mcp = registration.mcpAuthorization,
               !Self.capabilityLease(
                    capabilityLease,
                    grants: mcp,
                    invocation: invocation) {
                throw ToolRegistryAuthorizationError.mcpGrantNotGranted(
                    tool: toolName)
            }
            if let mcpResource,
               !Self.capabilityLease(
                    capabilityLease,
                    grants: mcpResource,
                    invocation: invocation) {
                throw ToolRegistryAuthorizationError.mcpGrantNotGranted(
                    tool: toolName)
            }
            if let leaseTaskID = capabilityLease.taskID,
               leaseTaskID != invocation.taskID {
                throw ToolRegistryAuthorizationError.leaseTaskMismatch(tool: toolName)
            }
            membership = .granted
        }
        if let workspaceTaskID = workspaceLease?.taskID,
           workspaceTaskID != invocation.taskID {
            throw ToolRegistryAuthorizationError.leaseTaskMismatch(tool: toolName)
        }
        let authorizationArguments =
            registration.authorizationArgumentIdentity(arguments)
        return ResolvedToolAuthorization(
            authorizationID: authorizationID ?? IDGen.random(prefix: "tool-authorization"),
            registryVersion: registryVersion,
            concreteToolID: "\(registryVersion)/\(descriptor.name)",
            descriptorFingerprint: Self.descriptorFingerprint(descriptor),
            toolName: descriptor.name,
            canonicalAction: intent.action,
            canonicalPermission: registration.canonicalPermission ?? intent.action,
            actionPreview: registration.permissionActionPreview(
                ToolArgs(raw: normalizedArguments)),
            requiredCapabilities: granting,
            membership: membership,
            capabilityLeaseID: capabilityLease?.id,
            capabilityTaskID: capabilityLease?.taskID,
            workspaceLeaseID: workspaceLease?.id,
            workspaceAccess: workspaceLease?.access,
            workspaceRootIdentity: workspaceLease?.rootIdentity,
            invocation: invocation,
            normalizedArgumentsDigest: Self.sha256(Data(authorizationArguments.utf8)),
            normalizedArgumentsCharacterCount: authorizationArguments.count,
            intent: intent,
            sideEffect: descriptor.sideEffect,
            risksNetwork: risksNetwork,
            replayPolicy: intent.replayPolicy,
            requiredCommunication: registration.requiredCommunication,
            requiredDelegation: registration.requiredDelegation,
            capabilityLeaseFingerprint: capabilityLease.map(Self.authorizationFingerprint),
            workspaceID: workspaceLease?.workspaceID,
            workspaceTaskID: workspaceLease?.taskID,
            workspaceRootPath: workspaceLease?.rootPath,
            workspaceLeaseFingerprint: workspaceLease.map(Self.authorizationFingerprint),
            targetAgentInferenceBinding: targetAgentInferenceBinding,
            mcp: registration.mcpAuthorization,
            mcpResource: mcpResource)
    }

    /// Rechecks the immutable authorization identity against the exact
    /// registry entry and invocation that are about to execute. The registry
    /// is currently a value type, but keeping this check at the executor
    /// boundary prevents a future mutable registry or decoded/forwarded
    /// snapshot from silently widening an approval.
    public func validateAuthorizationSnapshot(
        _ authorization: ResolvedToolAuthorization,
        toolName: String,
        normalizedArguments: String,
        intent: PermissionIntent,
        risksNetwork: Bool,
        invocation: ToolAuthorizationInvocationContext? = nil,
        capabilityLease: CapabilityLease? = nil,
        workspaceLease: WorkspaceLease? = nil
    ) throws {
        guard authorization.schemaVersion == 1 else {
            throw ToolRegistryAuthorizationError.authorizationSchemaMismatch(
                expected: 1,
                actual: authorization.schemaVersion)
        }
        guard authorization.registryVersion == registryVersion else {
            throw ToolRegistryAuthorizationError.authorizationRegistryMismatch(
                expected: registryVersion,
                actual: authorization.registryVersion)
        }
        guard authorization.toolName == toolName else {
            throw ToolRegistryAuthorizationError.authorizationToolMismatch(
                expected: toolName,
                actual: authorization.toolName)
        }
        let expectedConcreteToolID = "\(registryVersion)/\(toolName)"
        guard authorization.concreteToolID == expectedConcreteToolID else {
            throw ToolRegistryAuthorizationError.authorizationConcreteToolMismatch(
                expected: expectedConcreteToolID,
                actual: authorization.concreteToolID)
        }
        guard let registration = registrations[toolName] else {
            if conflictedNames.contains(toolName) {
                throw ToolRegistryAuthorizationError.duplicateRegistration(toolName)
            }
            throw ToolRegistryAuthorizationError.unregisteredTool(toolName)
        }
        let descriptor = registration.descriptor
        guard authorization.descriptorFingerprint == Self.descriptorFingerprint(descriptor),
              authorization.sideEffect == descriptor.sideEffect else {
            throw ToolRegistryAuthorizationError.authorizationDescriptorMismatch(tool: toolName)
        }
        let arguments = ToolArgs(raw: normalizedArguments)
        let authorizationArguments =
            registration.authorizationArgumentIdentity(arguments)
        guard authorization.normalizedArgumentsDigest == Self.sha256(Data(authorizationArguments.utf8)),
              authorization.normalizedArgumentsCharacterCount == authorizationArguments.count else {
            throw ToolRegistryAuthorizationError.authorizationArgumentsMismatch(tool: toolName)
        }
        let expectedCanonicalPermission = registration.canonicalPermission ?? intent.action
        let expectedPreview = registration.permissionActionPreview(
            arguments)
        let expectedMCPResource = try registration
            .resolveMCPResourceAuthorization(arguments)
        guard authorization.intent == intent,
              authorization.canonicalAction == intent.action,
              authorization.canonicalPermission == expectedCanonicalPermission,
              authorization.actionPreview == expectedPreview,
              authorization.risksNetwork == risksNetwork,
              authorization.replayPolicy == intent.replayPolicy,
              authorization.mcp == registration.mcpAuthorization,
              authorization.mcpResource == expectedMCPResource else {
            throw ToolRegistryAuthorizationError.authorizationIntentMismatch(tool: toolName)
        }
        let required = registration.grantingCapabilities.sorted { $0.rawValue < $1.rawValue }
        guard authorization.requiredCapabilities == required,
              authorization.requiredCommunication == registration.requiredCommunication,
              authorization.requiredDelegation == registration.requiredDelegation else {
            throw ToolRegistryAuthorizationError.authorizationCapabilityMismatch(tool: toolName)
        }
        let requiresLease = !required.isEmpty
            || registration.requiredCommunication != .none
            || registration.requiredDelegation != .none
            || registration.mcpAuthorization != nil
            || registration.requiresDynamicMCPResourceAuthorization
        guard authorization.membership == (requiresLease ? .granted : .notRequired) else {
            throw ToolRegistryAuthorizationError.authorizationCapabilityMismatch(tool: toolName)
        }
        let pinsCapabilityLease = authorization.capabilityLeaseID != nil
            || authorization.capabilityTaskID != nil
            || authorization.capabilityLeaseFingerprint != nil
        if requiresLease || pinsCapabilityLease, capabilityLease == nil {
            throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
        }
        if let capabilityLease {
            guard authorization.capabilityLeaseID == capabilityLease.id,
                  authorization.capabilityTaskID == capabilityLease.taskID,
                  authorization.capabilityLeaseFingerprint == Self.authorizationFingerprint(capabilityLease),
                  (required.isEmpty || !registration.grantingCapabilities.isDisjoint(with: capabilityLease.tools)),
                  Self.communication(capabilityLease.communication,
                                     satisfies: registration.requiredCommunication),
                  Self.delegation(capabilityLease.delegation,
                                  satisfies: registration.requiredDelegation) else {
                throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
            }
            if let mcp = registration.mcpAuthorization {
                let resolvedInvocation = invocation
                    ?? ToolAuthorizationInvocationContext(
                        sessionID: authorization.sessionID,
                        agent: authorization.agent,
                        taskID: authorization.taskID,
                        rootTaskID: authorization.rootTaskID,
                        parentTaskID: authorization.parentTaskID,
                        attempt: authorization.attempt,
                        toolCallID: authorization.toolCallID,
                        taskObjective: authorization.taskObjective)
                guard Self.capabilityLease(
                    capabilityLease,
                    grants: mcp,
                    invocation: resolvedInvocation) else {
                    throw ToolRegistryAuthorizationError.mcpGrantNotGranted(
                        tool: toolName)
                }
            }
            if let mcpResource = expectedMCPResource {
                let resolvedInvocation = invocation
                    ?? ToolAuthorizationInvocationContext(
                        sessionID: authorization.sessionID,
                        agent: authorization.agent,
                        taskID: authorization.taskID,
                        rootTaskID: authorization.rootTaskID,
                        parentTaskID: authorization.parentTaskID,
                        attempt: authorization.attempt,
                        toolCallID: authorization.toolCallID,
                        taskObjective: authorization.taskObjective)
                guard Self.capabilityLease(
                    capabilityLease,
                    grants: mcpResource,
                    invocation: resolvedInvocation) else {
                    throw ToolRegistryAuthorizationError.mcpGrantNotGranted(
                        tool: toolName)
                }
            }
        }
        let pinsWorkspaceLease = authorization.workspaceLeaseID != nil
            || authorization.workspaceID != nil
            || authorization.workspaceTaskID != nil
            || authorization.workspaceRootPath != nil
            || authorization.workspaceAccess != nil
            || authorization.workspaceRootIdentity != nil
            || authorization.workspaceLeaseFingerprint != nil
        if pinsWorkspaceLease, workspaceLease == nil {
            throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
        }
        if let workspaceLease {
            guard authorization.workspaceLeaseID == workspaceLease.id,
                  authorization.workspaceID == workspaceLease.workspaceID,
                  authorization.workspaceTaskID == workspaceLease.taskID,
                  authorization.workspaceRootPath == workspaceLease.rootPath,
                  authorization.workspaceAccess == workspaceLease.access,
                  authorization.workspaceRootIdentity == workspaceLease.rootIdentity,
                  authorization.workspaceLeaseFingerprint == Self.authorizationFingerprint(workspaceLease) else {
                throw ToolRegistryAuthorizationError.authorizationLeaseMismatch(tool: toolName)
            }
        }
        let pinsInvocation = authorization.sessionID != nil
            || authorization.agent != nil
            || authorization.taskID != nil
            || authorization.rootTaskID != nil
            || authorization.parentTaskID != nil
            || authorization.attempt != nil
            || authorization.toolCallID != nil
            || authorization.taskObjective != nil
        if pinsInvocation, invocation == nil {
            throw ToolRegistryAuthorizationError.authorizationInvocationMismatch(tool: toolName)
        }
        if let invocation {
            guard authorization.sessionID == invocation.sessionID,
                  authorization.agent == invocation.agent,
                  authorization.taskID == invocation.taskID,
                  authorization.rootTaskID == invocation.rootTaskID,
                  authorization.parentTaskID == invocation.parentTaskID,
                  authorization.attempt == invocation.attempt,
                  authorization.toolCallID == invocation.toolCallID,
                  authorization.taskObjective == invocation.taskObjective else {
                throw ToolRegistryAuthorizationError.authorizationInvocationMismatch(tool: toolName)
            }
        }
    }

    public static func authorizationFingerprint(_ lease: CapabilityLease) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let mcpGrants = lease.mcpGrants
            .sorted { $0.grantID.rawValue < $1.grantID.rawValue }
            .compactMap { try? encoder.encode($0) }
            .map { $0.base64EncodedString() }
            .joined(separator: "\u{1f}")
        let fields = [
            "capability-lease-v2",
            lease.id.rawValue,
            lease.taskID?.rawValue ?? "",
            lease.tools.map(\.rawValue).sorted().joined(separator: "\u{1f}"),
            communicationFingerprint(lease.communication),
            delegationFingerprint(lease.delegation),
            lease.expiresAtTaskCompletion ? "1" : "0",
            mcpGrants,
        ]
        return sha256(Data(framed(fields).utf8))
    }

    public static func authorizationFingerprint(_ lease: WorkspaceLease) -> String {
        let identity = lease.rootIdentity.map {
            framed([
                $0.canonicalPath,
                String($0.deviceID),
                String($0.fileID),
            ])
        } ?? ""
        let fields = [
            "workspace-lease-v1",
            lease.id.rawValue,
            lease.workspaceID.rawValue,
            lease.taskID?.rawValue ?? "",
            lease.rootPath,
            identity,
            lease.access.rawValue,
            lease.allowedPathRules.map(\.pattern).sorted().joined(separator: "\u{1f}"),
            lease.deniedPatterns.sorted().joined(separator: "\u{1f}"),
            lease.expiresAtTaskCompletion ? "1" : "0",
        ]
        return sha256(Data(framed(fields).utf8))
    }

    /// Stable secret-free identity used to bind a reviewed control-plane
    /// action to the exact target inference route. Raw endpoint/options and
    /// credential references are intentionally absent from this protocol type.
    public static func authorizationFingerprint(_ binding: AgentInferenceBinding) -> String {
        let fields = [
            binding.inferenceProfileID.rawValue,
            binding.inferenceProfileRevision.rawValue,
            binding.inferenceConnectionID.rawValue,
            binding.inferenceConnectionRevision.rawValue,
            binding.modelID.rawValue,
            binding.variantID ?? "",
            binding.trustDomain ?? "",
            binding.egressClassification ?? "",
            binding.safeRouteLabel ?? "",
            binding.immutableDefinitionFingerprint,
        ]
        return sha256(Data(framed(fields).utf8))
    }

    public static func authorizationDigest(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    public static func capabilityLease(
        _ lease: CapabilityLease,
        grants capabilities: [ToolCapability],
        communication requirement: ToolCommunicationRequirement,
        delegation delegationRequirement: ToolDelegationRequirement
    ) -> Bool {
        let capabilityMatch = capabilities.isEmpty
            || !Set(capabilities).isDisjoint(with: lease.tools)
        return capabilityMatch
            && communication(lease.communication, satisfies: requirement)
            && delegation(lease.delegation, satisfies: delegationRequirement)
    }

    private static func capabilityLease(
        _ lease: CapabilityLease,
        grants snapshot: MCPToolAuthorizationSnapshot,
        invocation: ToolAuthorizationInvocationContext
    ) -> Bool {
        guard snapshot.rawCatalogRevision.rawValue.isEmpty == false,
              snapshot.agentCatalogViewRevision.rawValue.isEmpty == false,
              snapshot.bindingID.rawValue.isEmpty == false,
              snapshot.schemaHash.isEmpty == false,
              snapshot.authorityFingerprint.isEmpty == false else {
            return false
        }
        return lease.mcpGrants.contains { grant in
            grant.grantID == snapshot.grantID
                && grant.attachmentID == snapshot.attachmentID
                && grant.server == snapshot.server
                && grant.agentID == invocation.agent
                && grant.grantFingerprint == snapshot.grantFingerprint
                && grant.authorityFingerprint
                    == snapshot.authorityFingerprint
                && grant.revocationGeneration
                    == snapshot.revocationGeneration
                && grant.grants(.tools)
                && grant.isActive()
                && grant.filter.tools.allows(snapshot.remoteToolName)
        }
    }

    private static func capabilityLease(
        _ lease: CapabilityLease,
        grants snapshot:
            MCPResourceInvocationAuthorizationSnapshot,
        invocation: ToolAuthorizationInvocationContext
    ) -> Bool {
        guard snapshot.schemaVersion == 1,
              !snapshot.operation.isEmpty,
              !snapshot.routes.isEmpty else {
            return false
        }
        return snapshot.routes.allSatisfy { route in
            guard route.capabilityLeaseID == lease.id,
                  route.capabilityTaskID == lease.taskID,
                  route.agentID == invocation.agent,
                  !route.serverAlias.isEmpty,
                  !route.grantFingerprint.isEmpty,
                  !route.rawCatalogRevision.rawValue.isEmpty,
                  !route.agentCatalogViewRevision.rawValue.isEmpty,
                  !route.bindingID.rawValue.isEmpty,
                  !route.authorityFingerprint.isEmpty,
                  !route.resourcePolicyFingerprint.isEmpty else {
                return false
            }
            return lease.mcpGrants.contains { grant in
                grant.grantID == route.grantID
                    && grant.attachmentID == route.attachmentID
                    && grant.server == route.server
                    && grant.agentID == route.agentID
                    && grant.capabilityLeaseID
                        == route.capabilityLeaseID
                    && grant.taskID == route.capabilityTaskID
                    && grant.grantFingerprint
                        == route.grantFingerprint
                    && grant.authorityFingerprint
                        == route.authorityFingerprint
                    && grant.revocationGeneration
                        == route.revocationGeneration
                    && grant.grants(.resources)
                    && grant.isActive()
            }
        }
    }

    private static func framed(_ fields: [String]) -> String {
        fields.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func communicationFingerprint(_ grant: CommunicationGrant) -> String {
        switch grant {
        case .none:
            return "none"
        case .replyOnly:
            return "reply-only"
        case .selectedAgents(let agents):
            return "selected:" + agents.map(\.rawValue).sorted().joined(separator: "\u{1f}")
        case .taskGroup(let group):
            return "task-group:" + group.rawValue
        case .anyAgentInThread:
            return "any-agent-in-thread"
        }
    }

    private static func delegationFingerprint(_ grant: DelegationGrant) -> String {
        switch grant {
        case .none:
            return "none"
        case .granted(let budget):
            return "granted:\(budget.maxTasks):\(budget.maxDepth)"
        }
    }

    private static func communication(
        _ grant: CommunicationGrant,
        satisfies requirement: ToolCommunicationRequirement
    ) -> Bool {
        switch requirement {
        case .none:
            return true
        case .initiate:
            switch grant {
            case .selectedAgents, .taskGroup, .anyAgentInThread:
                return true
            case .none, .replyOnly:
                return false
            }
        case .reply:
            if case .none = grant { return false }
            return true
        }
    }

    private static func delegation(
        _ grant: DelegationGrant,
        satisfies requirement: ToolDelegationRequirement
    ) -> Bool {
        switch requirement {
        case .none:
            return true
        case .granted:
            if case .granted = grant { return true }
            return false
        }
    }

    private static func descriptorFingerprint(_ descriptor: ToolDescriptor) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let schema = (try? encoder.encode(descriptor.parameters)) ?? Data()
        var material = Data(descriptor.name.utf8)
        material.append(0)
        material.append(Data(descriptor.description.utf8))
        material.append(0)
        material.append(Data(descriptor.sideEffect.rawValue.utf8))
        material.append(0)
        material.append(Data(descriptor.modelSpecKind.rawValue.utf8))
        material.append(0)
        material.append(Data(Self.optionalBool(descriptor.strict).utf8))
        material.append(0)
        material.append(Data(Self.optionalBool(descriptor.deferLoading).utf8))
        material.append(0)
        material.append(Data(String(descriptor.supportsParallelCalls).utf8))
        material.append(0)
        material.append(schema)
        if let outputSchema = descriptor.outputSchema {
            material.append(0)
            material.append((try? encoder.encode(outputSchema)) ?? Data())
        }
        return sha256(material)
    }

    private static func optionalBool(_ value: Bool?) -> String {
        switch value {
        case .none:
            return "unset"
        case .some(true):
            return "true"
        case .some(false):
            return "false"
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A new registry with extra tools added (e.g. Cowork's `ask_agent`).
    ///
    /// This compatibility API is intentionally limited to static `Tool`
    /// values. Dynamic `ToolRegistration`s must use the explicit-version
    /// overload or builder below so a catalog/schema change cannot retain an
    /// old authorization identity.
    public func adding(_ extra: [any Tool]) -> ToolRegistry {
        ToolRegistry(
            registrations: Array(registrations.values)
                + extra.map { ToolRegistration(tool: $0) },
            registryVersion: registryVersion,
            inheritedConflicts: conflictedNames)
    }

    /// Adds static tools while replacing the immutable registry identity.
    public func adding(_ extra: [any Tool],
                       registryVersion newRegistryVersion: String) -> ToolRegistry {
        rebuilding(registryVersion: newRegistryVersion)
            .adding(extra)
            .build()
    }

    /// Adds instance-level registrations while replacing the immutable
    /// registry identity. There is deliberately no overload that omits the
    /// replacement version.
    public func adding(registrations extra: [ToolRegistration],
                       registryVersion newRegistryVersion: String) -> ToolRegistry {
        rebuilding(registryVersion: newRegistryVersion)
            .adding(registrations: extra)
            .build()
    }

    /// Starts an immutable rebuild from this registry under a required,
    /// caller-computed replacement version.
    public func rebuilding(registryVersion newRegistryVersion: String) -> Builder {
        Builder(
            registryVersion: newRegistryVersion,
            registrations: Array(registrations.values),
            inheritedConflicts: conflictedNames)
    }

    /// Starts an empty immutable registry builder.
    public static func builder(registryVersion: String) -> Builder {
        Builder(
            registryVersion: registryVersion,
            registrations: [],
            inheritedConflicts: [])
    }

    /// The production read/write/Git/document/browser tool set. Raw `run_shell`
    /// stays implemented for isolated tests/future helper processes but is not
    /// model-exposed because arbitrary commands cannot declare exact touched
    /// paths for WorkspaceLease denied-pattern enforcement.
    public static func standard(
        includesTerminal: Bool = false,
        hostedWebSearch: (any HostedWebSearchToolService)? = nil
    ) -> ToolRegistry {
        var tools: [any Tool] = [
            ReadFileTool(), ListFilesTool(), SearchTextTool(), WriteFileTool(),
            ApplyPatchTool(), GitStatusTool(), GitDiffTool(),
            GitStagedDiffTool(), GitInfoTool(), GitRecentCommitsTool(),
            GitDiffBaseTool(), GitBranchTool(), GitCreateBranchTool(),
            GitStageTool(), GitUnstageTool(), GitCommitTool(),
            GitApplyPatchCheckTool(), GitApplyPatchTool(), GitStagePatchTool(),
            GitUnstagePatchTool(), GitRevertPatchTool(), GitWorktreeListTool(),
            GitWorktreeCreateTool(), GitWorktreeRemoveTool(),
            GitRemotesTool(), GitFetchTool(), GitPullFastForwardTool(),
            GitPushTool(), GitSwitchBranchTool(),
            InspectPDFTool(), ReadPDFTool(),
            ReadDOCXTool(), ContinueDOCXReadTool(),
            ReadPPTXTool(), ContinuePPTXReadTool(),
            ReadXLSXTool(), ContinueXLSXReadTool(),
            ReadHTMLTool(), ContinueHTMLReadTool(),
            ReadEPUBTool(), ContinueEPUBReadTool(),
            OCRPDFTool(), PDFRenderPageTool(),
            CompileLaTeXTool(), GenerateImageTool(), EditImageTool(),
            WebFetchTool(), BrowserDiagnosticsTool(), BrowserProfilesTool(), BrowserProfileDeleteTool(), BrowserHistoryTool(),
            BrowserNavigateTool(), BrowserSnapshotTool(), BrowserHandoffTool(), BrowserClickTool(),
            BrowserReloadTool(), BrowserBackTool(), BrowserForwardTool(),
            BrowserTypeTool(), BrowserSubmitTool(), BrowserSelectOptionTool(),
            BrowserPressKeyTool(), BrowserScrollTool(), BrowserWaitTool(), BrowserScreenshotTool(),
            BrowserUploadFileTool(), BrowserDownloadTool(), BrowserDownloadsTool(),
            BrowserSearchTool(), RenameSessionTool(),
        ]
        if includesTerminal {
            tools.append(ExecCommandTool())
            tools.append(WriteStdinTool())
        }
        var registrations = tools.map { ToolRegistration(tool: $0) }
        registrations.append(contentsOf: ExactDocumentToolCatalog.exportRegistrations())
        registrations.append(contentsOf: ExactDocumentToolCatalog.writeRegistrations())
        if let hostedWebSearch {
            registrations.append(ToolRegistration(
                tool: HostedWebSearchTool(service: hostedWebSearch),
                grantingCapabilities: [.hostedWebSearch]))
        }
        // The exact document surface replaces the legacy aggregate tools.
        // Provider-hosted search remains a distinct network tool.
        // Keep the replacement identity explicit so a durable authorization
        // issued for an old catalog can never validate against this one.
        return ToolRegistry(
            registrations: registrations,
            registryVersion: IntatisHostApplication.identity
                .namespacedIdentifier("standard.v5"))
    }
}

// MARK: - Small JSON-Schema helpers

enum Schema {
    static let string = JSONValue.object(["type": .string("string")])
    static let nonEmptyString = boundedString(minLength: 1)
    static let integer = JSONValue.object(["type": .string("integer")])
    static let boolean = JSONValue.object(["type": .string("boolean")])

    static func boundedString(minLength: Int? = nil, maxLength: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("string")]
        if let minLength { schema["minLength"] = .number(Double(minLength)) }
        if let maxLength { schema["maxLength"] = .number(Double(maxLength)) }
        return .object(schema)
    }

    static func boundedInteger(minimum: Int? = nil, maximum: Int? = nil) -> JSONValue {
        var schema: [String: JSONValue] = ["type": .string("integer")]
        if let minimum { schema["minimum"] = .number(Double(minimum)) }
        if let maximum { schema["maximum"] = .number(Double(maximum)) }
        return .object(schema)
    }

    static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }
}
