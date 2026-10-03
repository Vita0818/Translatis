import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisTools

struct MCPCLIProcessOwnerKey:
    Hashable, Sendable
{
    let catalogRootPath: String
    let sessionID: SessionID

    init(
        catalogRoot: URL,
        sessionID: SessionID
    ) {
        catalogRootPath =
            catalogRoot.standardizedFileURL.path
        self.sessionID = sessionID
    }
}

/// The CLI-process counterpart of the macOS app's exact-session runtime owner.
///
/// A non-interactive command still creates and drains a temporary owner before
/// the process exits. Interactive Code/Cowork installs one retained owner here,
/// so every `/mcp` control command and every provider dispatch in that process
/// reaches the same connection pool and generation set.
actor MCPCLIProcessRuntimeOwners {
    static let shared =
        MCPCLIProcessRuntimeOwners()

    private var runtimes:
        [MCPCLIProcessOwnerKey:
            MCPCLIShippingRuntimeHandle] = [:]

    func runtime(
        for key: MCPCLIProcessOwnerKey
    ) -> MCPCLIShippingRuntimeHandle? {
        runtimes[key]
    }

    /// Returns the retained runtime. If another actor installed the same exact
    /// owner while the candidate was being built, the candidate is drained and
    /// the existing owner wins.
    func retain(
        _ candidate:
            MCPCLIShippingRuntimeHandle,
        for key: MCPCLIProcessOwnerKey
    ) async -> MCPCLIShippingRuntimeHandle {
        if let existing = runtimes[key] {
            _ = await candidate.shutdown(
                reason:
                    "duplicate CLI MCP session owner was not retained")
            return existing
        }
        runtimes[key] = candidate
        return candidate
    }

    @discardableResult
    func shutdown(
        _ key: MCPCLIProcessOwnerKey,
        reason: String
    ) async -> MCPRuntimeShutdownReport? {
        guard let runtime =
                runtimes.removeValue(forKey: key)
        else { return nil }
        return await runtime.shutdown(reason: reason)
    }

    func shutdownAll(reason: String) async {
        let retained = Array(runtimes.values)
        runtimes.removeAll()
        await withTaskGroup(of: Void.self) {
            group in
            for runtime in retained {
                group.addTask {
                    _ = await runtime.shutdown(
                        reason: reason)
                }
            }
            await group.waitForAll()
        }
    }

    func retainedOwnerCount() -> Int {
        runtimes.count
    }
}

struct MCPCLIInteractiveRuntimeOwner:
    Sendable
{
    let key: MCPCLIProcessOwnerKey
    let context: MCPCLIContext
    let log: EventLog
    let runtime: MCPCLIShippingRuntimeHandle

    func shutdown(reason: String) async {
        _ = await MCPCLIProcessRuntimeOwners.shared
            .shutdown(key, reason: reason)
        await context.unbindInteractiveSessionLog(
            log)
    }
}

extension MCPCLIContext {
    nonisolated func processOwnerKey(
        sessionID: SessionID
    ) -> MCPCLIProcessOwnerKey {
        MCPCLIProcessOwnerKey(
            catalogRoot: root,
            sessionID: sessionID)
    }

    func retainedRuntime(
        sessionID: SessionID
    ) async -> MCPCLIShippingRuntimeHandle? {
        await MCPCLIProcessRuntimeOwners.shared
            .runtime(
                for: processOwnerKey(
                    sessionID: sessionID))
    }

    func retainRuntime(
        log: EventLog,
        workspaceRoot: URL
    ) async throws
        -> MCPCLIInteractiveRuntimeOwner
    {
        let sessionID = await log.sessionID
        let key = processOwnerKey(
            sessionID: sessionID)
        if let existing =
                await MCPCLIProcessRuntimeOwners
                    .shared.runtime(for: key) {
            return MCPCLIInteractiveRuntimeOwner(
                key: key,
                context: self,
                log: log,
                runtime: existing)
        }
        let candidate = try await makeShippingRuntime(
            log: log,
            workspaceRoot: workspaceRoot,
            allowsInteractiveConsent: true)
        let retained =
            await MCPCLIProcessRuntimeOwners.shared
                .retain(candidate, for: key)
        return MCPCLIInteractiveRuntimeOwner(
            key: key,
            context: self,
            log: log,
            runtime: retained)
    }
}

struct MCPCLIInteractiveCodeSession:
    Sendable
{
    let owner: MCPCLIInteractiveRuntimeOwner
    let agentID: AgentID
    let capabilityLease: CapabilityLease
    let workspaceLease: WorkspaceLease

    var log: EventLog { owner.log }
    var sessionID: SessionID {
        owner.runtime.sessionID
    }

    func liveSession()
        -> MCPCLILiveSession
    {
        MCPCLILiveSession(
            agentID: agentID,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease,
            runtime: owner.runtime,
            processRetained: true)
    }

    func shutdown(reason: String) async {
        await owner.shutdown(reason: reason)
    }
}

func makeMCPCLIInteractiveCodeSession(
    context: MCPCLIContext,
    workspace: URL,
    sessionID: SessionID = .new(),
    agentID: AgentID =
        AgentID(rawValue: "cli"),
    additionalCapabilities: Set<ToolCapability> = []
) async throws -> MCPCLIInteractiveCodeSession {
    let log = try await context.sessionLog(
        sessionID.rawValue)
    return try await makeMCPCLIInteractiveCodeSession(
        context: context,
        workspace: workspace,
        log: log,
        agentID: agentID,
        additionalCapabilities: additionalCapabilities)
}

func makeMCPCLIInteractiveCodeSession(
    context: MCPCLIContext,
    workspace: URL,
    log: EventLog,
    agentID: AgentID =
        AgentID(rawValue: "cli"),
    additionalCapabilities: Set<ToolCapability> = []
) async throws -> MCPCLIInteractiveCodeSession {
    let canonicalWorkspace =
        workspace.resolvingSymlinksInPath()
            .standardizedFileURL
    guard let rootIdentity =
            WorkspaceRootIdentity.capture(
                rootPath: canonicalWorkspace.path)
    else {
        throw IntatisError.permissionDenied(
            "The CLI Code workspace identity cannot be proven.")
    }
    try await context.bindInteractiveSessionLog(log)
    var capabilityLease =
        CapabilityLease.worker(
            workspaceAccess: .readWrite)
    capabilityLease.tools.formUnion(additionalCapabilities)
    capabilityLease.expiresAtTaskCompletion =
        false
    let workspaceLease = WorkspaceLease(
        rootPath: canonicalWorkspace.path,
        rootIdentity: rootIdentity,
        access: .readWrite,
        expiresAtTaskCompletion: false)
    do {
        _ = try await log.append([
            .workspaceLeaseGranted(
                WorkspaceLeaseGrantedPayload(
                    agent: agentID,
                    lease: workspaceLease)),
            .capabilityLeaseCreated(
                CapabilityLeaseCreatedPayload(
                    agent: agentID,
                    lease: capabilityLease)),
        ])
        let owner = try await context.retainRuntime(
            log: log,
            workspaceRoot: canonicalWorkspace)
        return MCPCLIInteractiveCodeSession(
            owner: owner,
            agentID: agentID,
            capabilityLease: capabilityLease,
            workspaceLease: workspaceLease)
    } catch {
        await context.unbindInteractiveSessionLog(log)
        throw error
    }
}

struct MCPCLIInteractiveCodeActivation:
    Sendable
{
    let context: MCPCLIContext
    let session: MCPCLIInteractiveCodeSession
}

/// Shipping CLI Code owns this lazy gate for the lifetime of one REPL log.
///
/// Constructing the gate is inert. It neither creates the MCP context/runtime
/// nor appends Agent leases. An exact owner is created only after the same
/// EventLog contains a durable attachment or the user explicitly invokes
/// `/mcp`.
actor MCPCLIInteractiveCodeHost {
    let log: EventLog
    let workspace: URL
    let agentID: AgentID
    let additionalCapabilities: Set<ToolCapability>

    private let suppliedContext: MCPCLIContext?
    private var activation:
        MCPCLIInteractiveCodeActivation?
    private var activationTask:
        Task<MCPCLIInteractiveCodeActivation, Error>?
    private var acceptsActivation = true

    init(
        log: EventLog,
        workspace: URL,
        context: MCPCLIContext? = nil,
        agentID: AgentID =
            AgentID(rawValue: "cli"),
        additionalCapabilities: Set<ToolCapability> = []
    ) {
        self.log = log
        self.workspace = workspace
        suppliedContext = context
        self.agentID = agentID
        self.additionalCapabilities = additionalCapabilities
    }

    func activationIfAttached()
        async throws
        -> MCPCLIInteractiveCodeActivation?
    {
        if let activation { return activation }
        let state = try await MCPDurableSessionState
            .load(from: log)
        guard !state.attachments.isEmpty else {
            return nil
        }
        return try await activate()
    }

    func activate()
        async throws
        -> MCPCLIInteractiveCodeActivation
    {
        guard acceptsActivation else {
            throw IntatisError.config(
                "The CLI Code MCP host is shutting down.")
        }
        if let activation { return activation }
        if let activationTask {
            return try await finishActivation(
                activationTask)
        }

        let context =
            suppliedContext ?? MCPCLIContext()
        let log = self.log
        let workspace = self.workspace
        let agentID = self.agentID
        let additionalCapabilities = self.additionalCapabilities
        let task =
            Task<MCPCLIInteractiveCodeActivation, Error> {
                let session =
                    try await makeMCPCLIInteractiveCodeSession(
                        context: context,
                        workspace: workspace,
                        log: log,
                        agentID: agentID,
                        additionalCapabilities: additionalCapabilities)
                return MCPCLIInteractiveCodeActivation(
                    context: context,
                    session: session)
            }
        activationTask = task
        return try await finishActivation(task)
    }

    func isActivated() -> Bool {
        activation != nil
    }

    func shutdown(reason: String) async {
        acceptsActivation = false
        let pending = activationTask
        activationTask = nil
        pending?.cancel()

        var active = activation
        activation = nil
        if active == nil, let pending {
            active = try? await pending.value
        }
        guard let active else { return }
        await active.session.shutdown(reason: reason)
    }

    private func finishActivation(
        _ task:
            Task<MCPCLIInteractiveCodeActivation, Error>
    ) async throws -> MCPCLIInteractiveCodeActivation {
        do {
            let value = try await task.value
            activation = value
            activationTask = nil
            return value
        } catch {
            activationTask = nil
            throw error
        }
    }
}

struct MCPCLIInteractiveCoworkActivation:
    Sendable
{
    let context: MCPCLIContext
    let owner: MCPCLIInteractiveRuntimeOwner
}

/// Shipping CLI Cowork owns this lazy gate for the lifetime of its durable
/// session log.
///
/// Cowork already owns durable Agent/workspace/capability registration, so
/// activation binds the existing EventLog and retains only the MCP runtime.
/// Constructing the gate remains completely inert: no MCP context, process
/// owner, runtime, or ArtifactStore exists until a durable attachment is
/// observed, `/mcp` is invoked, or an MCP dispatch requests activation.
actor MCPCLIInteractiveCoworkHost {
    let log: EventLog
    let workspace: URL

    private let suppliedContext: MCPCLIContext?
    private var activation:
        MCPCLIInteractiveCoworkActivation?
    private var activationTask:
        Task<MCPCLIInteractiveCoworkActivation, Error>?
    private var acceptsActivation = true

    init(
        log: EventLog,
        workspace: URL,
        context: MCPCLIContext? = nil
    ) {
        self.log = log
        self.workspace = workspace
        suppliedContext = context
    }

    func activationIfAttached()
        async throws
        -> MCPCLIInteractiveCoworkActivation?
    {
        if let activation { return activation }
        let state = try await MCPDurableSessionState
            .load(from: log)
        guard !state.attachments.isEmpty else {
            return nil
        }
        return try await activate()
    }

    func activate()
        async throws
        -> MCPCLIInteractiveCoworkActivation
    {
        guard acceptsActivation else {
            throw IntatisError.config(
                "The CLI Cowork MCP host is shutting down.")
        }
        if let activation { return activation }
        if let activationTask {
            return try await finishActivation(
                activationTask)
        }

        let context =
            suppliedContext ?? MCPCLIContext()
        let log = self.log
        let workspace = self.workspace
        let task =
            Task<MCPCLIInteractiveCoworkActivation, Error> {
                try await context
                    .bindInteractiveSessionLog(log)
                do {
                    let owner =
                        try await context.retainRuntime(
                            log: log,
                            workspaceRoot: workspace)
                    return MCPCLIInteractiveCoworkActivation(
                        context: context,
                        owner: owner)
                } catch {
                    await context
                        .unbindInteractiveSessionLog(log)
                    throw error
                }
            }
        activationTask = task
        return try await finishActivation(task)
    }

    func isActivated() -> Bool {
        activation != nil
    }

    func shutdown(reason: String) async {
        acceptsActivation = false
        let pending = activationTask
        activationTask = nil
        pending?.cancel()

        var active = activation
        activation = nil
        if active == nil, let pending {
            active = try? await pending.value
        }
        guard let active else { return }
        await active.owner.shutdown(reason: reason)
    }

    private func finishActivation(
        _ task:
            Task<MCPCLIInteractiveCoworkActivation, Error>
    ) async throws
        -> MCPCLIInteractiveCoworkActivation
    {
        do {
            let value = try await task.value
            activation = value
            activationTask = nil
            return value
        } catch {
            activationTask = nil
            throw error
        }
    }
}

enum MCPCLIInteractiveCommandError:
    Error, LocalizedError, Equatable
{
    case empty
    case unterminatedQuote
    case conflictingSession
    case conflictingAgent

    var errorDescription: String? {
        switch self {
        case .empty:
            return "usage: /mcp <command> [options]"
        case .unterminatedQuote:
            return "the /mcp command contains an unterminated quote"
        case .conflictingSession:
            return "interactive /mcp commands are confined to the current exact session"
        case .conflictingAgent:
            return "interactive /mcp commands are confined to the selected exact agent"
        }
    }
}

func runInteractiveMCPCommand(
    _ commandLine: String,
    context: MCPCLIContext,
    sessionID: SessionID,
    agentID: AgentID,
    confinesAgent: Bool = true
) async throws {
    var tokens =
        try MCPCLICommandLineTokenizer.tokenize(
            commandLine)
    guard !tokens.isEmpty else {
        throw MCPCLIInteractiveCommandError.empty
    }
    let parsed = try MCPCLIParsedArguments(
        tokens.dropFirst())
    if let requested = parsed.value("session"),
       requested != sessionID.rawValue {
        throw MCPCLIInteractiveCommandError
            .conflictingSession
    }
    if confinesAgent,
       let requested = parsed.value("agent"),
       requested != agentID.rawValue {
        throw MCPCLIInteractiveCommandError
            .conflictingAgent
    }
    if parsed.value("session") == nil {
        tokens.append(contentsOf: [
            "--session", sessionID.rawValue,
        ])
    }
    if parsed.value("agent") == nil {
        tokens.append(contentsOf: [
            "--agent", agentID.rawValue,
        ])
    }
    try await runMCPCommand(
        tokens[...],
        context: context)
}

enum MCPCLICommandLineTokenizer {
    static func tokenize(
        _ input: String
    ) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false

        for character in input {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\" {
                escaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\""
                || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if escaping {
            current.append("\\")
        }
        guard quote == nil else {
            throw MCPCLIInteractiveCommandError
                .unterminatedQuote
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
