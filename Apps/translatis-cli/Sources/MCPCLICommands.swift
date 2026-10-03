#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("TranslatisCLI requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisAgentKernel
import IntatisCore
import IntatisConversation
import IntatisMCP
import IntatisMCPStdio
import IntatisProtocol
import IntatisCodexRuntime

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private struct MCPCLIRejectingTestEventSink: MCPBrokerEventSink {
    func appendMCPBrokerEvent(_ event: Event) async throws {
        throw MCPTaskRuntimeError.persistenceFailed
    }

    func appendMCPBrokerEvents(_ events: [Event]) async throws {
        throw MCPTaskRuntimeError.persistenceFailed
    }
}

struct MCPCLIParsedArguments: Sendable {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    init(_ input: ArraySlice<String>) throws {
        var iterator = input.makeIterator()
        while let item = iterator.next() {
            guard item.hasPrefix("--") else {
                positionals.append(item)
                continue
            }
            let body = String(item.dropFirst(2))
            if let separator = body.firstIndex(of: "=") {
                let name = String(body[..<separator])
                let value = String(body[body.index(
                    after: separator)...])
                values[name, default: []].append(value)
                continue
            }
            if Self.booleanFlags.contains(body) {
                flags.insert(body)
                continue
            }
            guard let value = iterator.next(),
                  !value.hasPrefix("--") else {
                throw MCPCLIError.missingOptionValue(body)
            }
            values[body, default: []].append(value)
        }
        let forbidden = [
            "bearer-token", "password", "client-secret",
            "secret", "token", "bearer-secret",
            "bearer-stdin", "oauth-client-secret",
            "oauth-client-secret-stdin",
        ]
        if let found = forbidden.first(where: {
            values[$0] != nil
        }) {
            throw MCPCLIError.plaintextSecretArgument(found)
        }
    }

    func value(_ name: String) -> String? {
        values[name]?.last
    }

    func all(_ name: String) -> [String] {
        values[name] ?? []
    }

    func required(_ name: String) throws -> String {
        guard let value = value(name), !value.isEmpty else {
            throw MCPCLIError.missingRequiredOption(name)
        }
        return value
    }

    private static let booleanFlags: Set<String> = [
        "json", "required", "optional", "parallel",
        "serial", "bearer-secret", "bearer-stdin",
        "clear-bearer", "oauth-client-secret",
        "oauth-client-secret-stdin",
        "clear-oauth-client-secret",
        "clear-oauth-client-id", "clear-oauth-scopes",
        "disable-oauth", "clear-headers",
        "clear-environment", "deny-network",
        "clear-helpers", "clear-args", "clear-cwd",
        "system-trust", "clear-required-capabilities",
        "clear-tool-approvals",
        "clear-tool-allow", "clear-tool-deny",
        "clear-resource-allow", "clear-resource-deny",
        "clear-prompt-allow", "clear-prompt-deny",
        "clear-completion-allow",
        "clear-completion-deny",
        "secret-stdin", "include-disabled",
        "replace-conflicts", "yes", "force",
        "allow-dynamic-registration", "no-open",
        "allow-insecure-loopback-development-http",
        "disallow-insecure-loopback-development-http",
    ]
}

enum MCPCLIError:
    Error, LocalizedError, Equatable {
    case missingSubcommand
    case unknownSubcommand(String)
    case missingOptionValue(String)
    case missingRequiredOption(String)
    case plaintextSecretArgument(String)
    case invalidOption(String)
    case confirmationRequired
    case secretInputUnavailable
    case secretMismatch
    case serverHasNoOAuth
    case durableLeaseRequired(String)

    var errorDescription: String? {
        switch self {
        case .missingSubcommand:
            return "missing MCP subcommand; run `\(IntatisHostApplication.identity.commandName) mcp help`"
        case .unknownSubcommand(let value):
            return "unknown MCP subcommand '\(value)'"
        case .missingOptionValue(let name):
            return "--\(name) requires a value"
        case .missingRequiredOption(let name):
            return "missing required option --\(name)"
        case .plaintextSecretArgument(let name):
            return "--\(name) is forbidden because secrets must not be placed in argv; use the documented secure input channel"
        case .invalidOption(let value):
            return "invalid MCP option: \(value)"
        case .confirmationRequired:
            return "this operation requires --yes"
        case .secretInputUnavailable:
            return "secure secret input is unavailable"
        case .secretMismatch:
            return "the two passphrases did not match"
        case .serverHasNoOAuth:
            return "the selected MCP server has no OAuth configuration"
        case .durableLeaseRequired(let detail):
            return "an exact live durable MCP lease is required: \(detail)"
        }
    }
}

actor MCPCLIContext {
    let hostProfile: MCPProductHostProfile
    let secretStore: MCPCLIEncryptedSecretStore
    let oauth: MCPCLIOAuthCoordinator
    let management: MCPManagementService
    nonisolated let root: URL
    let catalogStore: MCPServerCatalogStore
    let resolveSecret: MCPProductionSecretResolver
    private var interactiveSessionLogs:
        [SessionID: EventLog] = [:]
    private var nativeCodexRootAgents:
        [SessionID: AgentID] = [:]

    init(root explicitRoot: URL? = nil) {
        #if os(macOS)
        hostProfile = .macCLI
        #else
        hostProfile = .linuxCLI
        #endif
        let root = explicitRoot?.standardizedFileURL
            ?? IntatisHostApplication.identity
                .userConfigurationDirectory(
                    homeDirectory:
                        FileManager.default.homeDirectoryForCurrentUser)
        self.root = root
        let store = MCPCLIEncryptedSecretStore(
            fileURL: root.appendingPathComponent(
                "mcp-secrets-v1.enc"))
        secretStore = store
        let oauth = MCPCLIOAuthCoordinator(
            secretStore: store,
            accounts: MCPCLIOAuthAccountStore(
                fileURL: root.appendingPathComponent(
                    MCPCLIOAuthAccountStore.fileName)))
        self.oauth = oauth
        let catalogStore = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent(
                MCPServerCatalogStore.fileName),
            precommitVerifier:
                MCPStdioPreparedDefinitionPrecommitVerifier())
        self.catalogStore = catalogStore
        let journal = MCPCatalogOperationJournalStore(
            fileURL: root.appendingPathComponent(
                MCPCatalogOperationJournalStore.fileName))
        let resolve: MCPProductionSecretResolver = {
            try await store.resolve($0)
        }
        resolveSecret = resolve
        let payloads = MCPSecretBackedBrokerPayloadStore(
            secretStore: store)
        let testOutputRedactor =
            MCPResolvedSecretRedactor()
        let issuer = MCPStdioLaunchTicketIssuer {
            request in
            guard request.purpose == .isolatedTest else {
                throw MCPManagedPipeError
                    .authorizationBindingMismatch
            }
            let environment =
                try await MCPStdioEnvironmentResolver.resolve(
                    request.configuration,
                    secretResolver: resolve)
            return MCPStdioHostAuthorization(
                decisionID:
                    IDGen.random(prefix: "mcpdecision"),
                operationID: request.operationID,
                authorityFingerprint:
                    request.authority.fingerprint,
                launchArtifactFingerprint:
                    request.configuration.launchArtifact
                        .fingerprint,
                workspaceLeaseID:
                    request.workspaceLease.id,
                expiresAt:
                    Date().addingTimeInterval(30),
                resolvedEnvironment: environment)
        }
        let stdio = MCPManagedStdioProductionFactory(
            ticketIssuer: issuer,
            secretRedactionRegistrar:
                testOutputRedactor
        ) { definition, identity, _ in
            try MCPIsolatedTestWorkspace.context(
                definition: definition,
                identity: identity)
        }
        let services:
            MCPProductionConnectionServicesProvider = {
                _, _, _ in
                MCPProductionConnectionServices(
                    remoteTaskServices:
                        MCPProductionRemoteTaskServices(
                            events:
                                MCPCLIRejectingTestEventSink(),
                            payloadStore: payloads))
            }
        let tester = MCPProductionConfigurationTester(
            hostProfile: hostProfile,
            clientVersion: IntatisHostApplication.identity
                .temporaryPrefix("cli"),
            resolveSecret: resolve,
            secretRedactionRegistrar:
                testOutputRedactor,
            outputSanitizer:
                testOutputRedactor,
            buildStdio: stdio.transportBuilder(),
            buildOAuth: oauth.providerBuilder(),
            services: services,
            testWorkspace: {
                try MCPIsolatedTestWorkspace.lease(for: $0)
            })
        management = MCPManagementService(
            catalogStore: catalogStore,
            testJournal: journal,
            hostProfile: hostProfile,
            testExecutor: { try await tester.run($0) })
    }

    func unlockSecrets(createIfMissing: Bool) async throws {
        if await secretStore.isUnlocked { return }
        let exists = FileManager.default.fileExists(
            atPath: secretStore.fileURL.path)
        if exists {
            var passphrase = try MCPCLISecureInput.read(
                prompt: "MCP credential-store passphrase: ")
            defer { passphrase.resetBytes(
                in: 0..<passphrase.count) }
            try await secretStore.unlock(
                passphrase: passphrase)
            return
        }
        guard createIfMissing else {
            throw MCPSecretStoreError.notInitialized
        }
        var first = try MCPCLISecureInput.read(
            prompt:
                "Create MCP credential-store passphrase: ")
        defer { first.resetBytes(in: 0..<first.count) }
        var second = try MCPCLISecureInput.read(
            prompt: "Confirm passphrase: ")
        defer { second.resetBytes(in: 0..<second.count) }
        guard first == second else {
            throw MCPCLIError.secretMismatch
        }
        try await secretStore.initialize(
            passphrase: first)
    }

    func codexRuntimeConfiguration(
        log: EventLog,
        agentID: AgentID,
        capabilityLeaseID: CapabilityLeaseID,
        taskID: TaskID? = nil
    ) async throws -> CodexRuntimeMCPConfiguration {
        let state = try await MCPDurableSessionState.load(from: log)
        return try await CodexRuntimeMCPProjector.project(
            catalog: try await catalogStore.load(),
            attachments: Array(state.attachments.values),
            grants: state.grants(
                agentID: agentID,
                capabilityLeaseID: capabilityLeaseID,
                taskID: taskID),
            consents: Array(state.consents.values),
            resolveSecret: resolveSecret)
    }

    func bindInteractiveSessionLog(
        _ log: EventLog,
        nativeCodexRootAgentID: AgentID? = nil
    ) async throws {
        let sessionID = await log.sessionID
        if let existing =
                interactiveSessionLogs[sessionID],
           ObjectIdentifier(existing)
                != ObjectIdentifier(log) {
            throw IntatisError.config(
                "The exact interactive MCP session is already bound to another EventLog.")
        }
        if let nativeCodexRootAgentID {
            if let existing = nativeCodexRootAgents[sessionID],
               existing != nativeCodexRootAgentID {
                throw IntatisError.config(
                    "The exact interactive MCP session is already bound to another native Codex root Agent.")
            }
            nativeCodexRootAgents[sessionID] =
                nativeCodexRootAgentID
        }
        interactiveSessionLogs[sessionID] = log
    }

    func nativeCodexRootAgent(
        for rawSessionID: String
    ) -> AgentID? {
        nativeCodexRootAgents[
            SessionID(rawValue: rawSessionID)]
    }

    func unbindInteractiveSessionLog(
        _ log: EventLog
    ) async {
        let sessionID = await log.sessionID
        guard let existing =
                interactiveSessionLogs[sessionID],
              ObjectIdentifier(existing)
                == ObjectIdentifier(log)
        else { return }
        interactiveSessionLogs.removeValue(
            forKey: sessionID)
        nativeCodexRootAgents.removeValue(
            forKey: sessionID)
    }

    func sessionLog(_ rawSession: String) throws -> EventLog {
        let session = SessionID(rawValue: rawSession)
        if let interactive =
                interactiveSessionLogs[session] {
            return interactive
        }
        if rawSession.hasPrefix("cowork_cli_") {
            let key = String(
                rawSession.dropFirst(
                    "cowork_cli_".count))
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true)
            let legacyDirectory = support
                .appendingPathComponent(
                    IntatisHostApplication.identity.name,
                    isDirectory: true)
                .appendingPathComponent(
                    "cli",
                    isDirectory: true)
                .appendingPathComponent(
                    "cowork_\(key)",
                    isDirectory: true)
            let legacyFile = legacyDirectory
                .appendingPathComponent("events.jsonl")
            if FileManager.default.fileExists(
                atPath: legacyFile.path) {
                return try EventLog(
                    session: session,
                    fileURL: legacyFile)
            }
        }
        let directory = root
            .appendingPathComponent(
                "sessions",
                isDirectory: true)
            .appendingPathComponent(
                rawSession,
                isDirectory: true)
        return try EventLog(
            session: session,
            fileURL: directory.appendingPathComponent(
                "events.jsonl"))
    }
}

enum MCPCLISecureInput {
    static func read(prompt: String) throws -> Data {
        let terminal = open("/dev/tty", O_RDWR)
        guard terminal >= 0,
              isatty(terminal) == 1 else {
            if terminal >= 0 {
                _ = close(terminal)
            }
            throw MCPCLIError.secretInputUnavailable
        }
        _ = close(terminal)
        guard let pointer = getpass(prompt) else {
            throw MCPCLIError.secretInputUnavailable
        }
        let value = String(cString: pointer)
        guard !value.isEmpty else {
            throw MCPCLIError.secretInputUnavailable
        }
        return Data(value.utf8)
    }

    static func readStandardInput(
        maximumBytes: Int = MCPSecretStoreLimits.maximumSecretBytes
    ) throws -> Data {
        guard isatty(STDIN_FILENO) != 1 else {
            throw MCPCLIError.secretInputUnavailable
        }
        var data = FileHandle.standardInput.readDataToEndOfFile()
        while data.last == 0x0A || data.last == 0x0D {
            data.removeLast()
        }
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw MCPCLIError.secretInputUnavailable
        }
        return data
    }
}

func runMCPCommand(
    _ raw: ArraySlice<String>,
    context explicitContext:
        MCPCLIContext? = nil
) async throws {
    guard let command = raw.first else {
        throw MCPCLIError.missingSubcommand
    }
    if command == "help" || command == "--help"
        || command == "-h" {
        printMCPHelp()
        return
    }
    let arguments = try MCPCLIParsedArguments(
        raw.dropFirst())
    let context =
        explicitContext ?? MCPCLIContext()
    try await validateNativeCodexMCPCommand(
        command,
        context: context,
        arguments: arguments)
    switch command {
    case "list":
        try await listMCP(context, arguments)
    case "status":
        try await runMCPCLIShippingCommand(
            command,
            context: context,
            arguments: arguments)
    case "get":
        try await getMCP(context, arguments)
    case "add":
        try await addMCP(context, arguments)
    case "edit":
        try await editMCP(context, arguments)
    case "remove":
        try await removeMCP(context, arguments)
    case "enable":
        try await toggleMCP(context, arguments, enabled: true)
    case "disable":
        try await toggleMCP(context, arguments, enabled: false)
    case "test":
        try await testMCP(context, arguments)
    case "duplicate":
        try await duplicateMCP(context, arguments)
    case "doctor":
        try await doctorMCP(context, arguments)
    case "import":
        try await importMCP(context, arguments)
    case "export":
        try await exportMCP(context, arguments)
    case "attach":
        try await attachMCP(context, arguments)
    case "detach":
        try await detachMCP(context, arguments)
    case "approval":
        try await approvalMCP(context, arguments)
    case "grant":
        try await grantMCP(context, arguments)
    case "revoke":
        try await revokeMCP(context, arguments)
    case "auth":
        try await authMCP(context, arguments)
    case "connect", "disconnect", "refresh", "reload",
            "inspect", "tools", "resources", "prompts":
        try await runMCPCLIShippingCommand(
            command,
            context: context,
            arguments: arguments)
    default:
        throw MCPCLIError.unknownSubcommand(command)
    }
}

private func validateNativeCodexMCPCommand(
    _ command: String,
    context: MCPCLIContext,
    arguments: MCPCLIParsedArguments
) async throws {
    guard let sessionID = arguments.value("session"),
          let rootAgent = await context.nativeCodexRootAgent(
            for: sessionID) else {
        return
    }
    let rootOnlyCommands: Set<String> = [
        "grant", "connect", "status", "inspect", "tools",
        "resources", "prompts", "refresh", "disconnect",
    ]
    guard rootOnlyCommands.contains(command) else { return }
    if let requestedAgent = arguments.value("agent"),
       AgentID(rawValue: requestedAgent) != rootAgent {
        throw MCPCLIError.invalidOption(
            "native Codex MCP access is restricted to the exact session-root Agent \(rootAgent.rawValue)")
    }
    if arguments.value("task") != nil {
        throw MCPCLIError.invalidOption(
            "native Codex MCP access cannot target a task or child Agent")
    }
}

private func listMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let records = try await context.management.inventory()
    if args.flags.contains("json") {
        try writeJSON(records)
        return
    }
    if records.isEmpty {
        out("No MCP servers configured.\n")
        return
    }
    for record in records {
        out(
            "\(record.alias)\t\(record.serverID.rawValue)\t\(record.transport?.rawValue ?? "unknown")\t\(record.setupStatus.rawValue)\t\(record.protocolProfile?.rawValue ?? "unknown")\n")
    }
}

private func getMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let value = try serverValue(args)
    let definition = try await context.management.definition(
        serverOrAlias: value)
    if args.flags.contains("json") {
        try writeJSON(definition)
    } else {
        let config = definition.configuration
        let loopbackDevelopmentHTTP: String
        if case .streamableHTTP(let http) =
                config.transport {
            loopbackDevelopmentHTTP = String(
                http
                    .allowInsecureLoopbackDevelopmentHTTP)
        } else {
            loopbackDevelopmentHTTP = "n/a"
        }
        out("""
        alias/id  : \(value)
        server    : \(definition.reference.serverID.rawValue)
        revision  : \(definition.reference.serverRevision.rawValue)
        name      : \(config.displayName)
        transport : \(config.transport.kind.rawValue)
        profile   : \(config.protocolProfile.rawValue)
        maximum   : \(config.maximumProtocolVersion.rawValue)
        required  : \(config.required)
        approval  : \(config.approvalPolicy.serverDefault.rawValue)
        insecure loopback development HTTP: \(loopbackDevelopmentHTTP)
        source    : \(config.provenance.sourceKind.rawValue) / \(config.provenance.sourceLabel)

        """)
    }
}

private func addMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    try args.validateConfigurationOptions(
        editing: false)
    let alias = try args.required("alias")
    let name = args.value("name") ?? alias
    let serverID = args.value("server-id")
        .map { MCPServerID(rawValue: $0) } ?? .new()
    let built =
        try await buildMCPCLIConfiguration(
            context: context,
            arguments: args,
            existing: nil,
            serverID: serverID,
            displayName: name,
            sourceLabel: IntatisHostApplication.identity
                .temporaryPrefix("cli"))
    var committed = false
    do {
        let prepared =
            try await context.management.prepare(
                alias: alias,
                configuration:
                    built.configuration)
        let authorization =
            try MCPCLITestAuthorization(
                args,
                action: "add \(alias)",
                configurations: [
                    prepared.definition
                        .configuration,
                ])
        let definition =
            try await context.management
                .testAndSavePrepared(
                    prepared,
                    authorization:
                        authorization)
        committed = true
        try emitResult(
            definition,
            json:
                args.flags.contains("json"),
            message:
                "Tested and saved \(alias) at \(definition.reference.serverRevision.rawValue).")
    } catch {
        if !committed {
            await removeMCPCLIConfigurationSecrets(
                built.createdSecretReferences,
                context: context)
        }
        throw error
    }
}

private func editMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    try args.validateConfigurationOptions(
        editing: true)
    let value = try serverValue(args)
    let existing = try await context.management.definition(
        serverOrAlias: value)
    let old = existing.configuration
    let alias: String
    if let requested =
            args.value("alias") {
        alias = requested
    } else {
        alias = try await MCPCLIAlias(
            definition: existing,
            context: context)
    }
    let built =
        try await buildMCPCLIConfiguration(
            context: context,
            arguments: args,
            existing: old,
            serverID: old.serverID,
            displayName:
                args.value("name")
                ?? old.displayName,
            sourceLabel:
                IntatisHostApplication.identity
                    .temporaryPrefix("cli-edit"))
    var committed = false
    do {
        let prepared =
            try await context.management.prepare(
                alias: alias,
                configuration:
                    built.configuration)
        let saved =
            try await context.management
                .testAndSavePrepared(
                    prepared,
                    authorization:
                        MCPCLITestAuthorization(
                            args,
                            action:
                                "edit \(alias)",
                            configurations: [
                                prepared
                                    .definition
                                    .configuration,
                            ]))
        committed = true
        try emitResult(
            saved,
            json:
                args.flags.contains("json"),
            message:
                "Tested and saved a new immutable revision.")
    } catch {
        if !committed {
            await removeMCPCLIConfigurationSecrets(
                built.createdSecretReferences,
                context: context)
        }
        throw error
    }
}

private func removeMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    guard args.flags.contains("yes") else {
        throw MCPCLIError.confirmationRequired
    }
    let catalog = try await context.management.deleteCurrent(
        serverOrAlias: try serverValue(args))
    try emitResult(
        catalog,
        json: args.flags.contains("json"),
        message:
            "Current revision tombstoned; audit history retained.")
}

private func toggleMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments,
    enabled: Bool
) async throws {
    let catalog = try await context.management.setEnabled(
        serverOrAlias: try serverValue(args),
        enabled: enabled)
    try emitResult(
        catalog,
        json: args.flags.contains("json"),
        message: enabled ? "MCP server enabled." : "MCP server disabled.")
}

private func testMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    if configurationUsesSecret(
        definition.configuration) {
        try await context.unlockSecrets(createIfMissing: false)
    }
    let alias = try await MCPCLIAlias(
        definition: definition,
        context: context)
    let prepared = try await context.management.prepare(
        alias: alias,
        configuration:
            definition.configuration)
    let result = try await context.management.test(
        prepared,
        authorization:
            MCPCLITestAuthorization(
                args,
                action: "test \(alias)",
                configurations: [
                    prepared.definition.configuration,
                ]))
    try emitResult(
        result,
        json: args.flags.contains("json"),
        message:
            "Test \(result.terminal.rawValue): \(result.sanitizedReasonCode)")
}

private func duplicateMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let source = try serverValue(args)
    let alias = try args.required("alias")
    let staging = try await context.management
        .duplicateDraft(
            serverOrAlias: source,
            newServerID: args.value("server-id")
                .map { MCPServerID(rawValue: $0) }
                ?? .new(),
            displayName: args.value("name"))
    let prepared = try await context.management.prepare(
        alias: alias,
        configuration: staging.configuration)
    let saved = try await context.management
        .testAndSavePrepared(
            prepared,
            authorization:
                MCPCLITestAuthorization(
                    args,
                    action: "duplicate \(alias)",
                    configurations: [
                        prepared.definition.configuration,
                    ]))
    try emitResult(
        saved,
        json: args.flags.contains("json"),
        message: "Tested and saved duplicate \(alias).")
}

private func doctorMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let findings = try await context.management.doctor()
    if args.flags.contains("json") {
        try writeJSON(findings)
    } else {
        for finding in findings {
            out(
                "\(finding.severity.rawValue)\t\(finding.code)\t\(finding.serverID?.rawValue ?? "-")\t\(finding.summary)\n")
        }
    }
    if findings.contains(where: { $0.severity == .error }) {
        throw MCPCLIProcessExit(code: 1)
    }
}

private func importMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let path = try args.required("file")
    let format = try importFormat(args)
    let parsed = try await context.management.importPreview(
        at: URL(fileURLWithPath: path),
        format: format)
    if args.flags.contains("json") {
        try writeJSON(parsed.preview.issues)
    }
    guard parsed.preview.canProceedToResolution else {
        throw MCPImportError.previewHasBlockingIssues
    }
    defer {
        Task { await parsed.secretStaging.discard() }
    }
    let catalog = try await context.management.catalog()
    let planned = try MCPImportPlanner.plan(
        preview: parsed.preview,
        catalog: catalog)
    guard planned.conflicts.isEmpty
            || args.flags.contains("replace-conflicts") else {
        throw MCPImportError.unresolvedConflict
    }
    if !args.flags.contains("yes") {
        if !args.flags.contains("json") {
            out(
                "Import preview: \(parsed.preview.proposals.count) proposal(s), \(planned.conflicts.count) conflict(s), \(parsed.preview.secretDescriptors.count) staged secret(s). No catalog or credential changes were made; rerun with --yes after review.\n")
        }
        return
    }
    let decisions = Dictionary(
        uniqueKeysWithValues:
            planned.conflicts.map {
                ($0.proposalID,
                 MCPImportConflictDecision.replaceExisting(
                    $0.existingServerID))
            })
    let proposals = try planned.resolving(
        decisions,
        catalog: catalog)
    var secretReferences:
        [String: MCPSecretReference] = [:]
    if !parsed.preview.secretDescriptors.isEmpty {
        try await context.unlockSecrets(
            createIfMissing: true)
        secretReferences = try await parsed.secretStaging
            .migrate(to: context.secretStore)
    }
    var drafts:
        [(alias: String, configuration: MCPServerConfiguration)] = []
    for proposal in proposals {
        let artifact: LaunchArtifactIdentity?
        let helperArtifacts:
            [LaunchArtifactIdentity]
        switch proposal.transport {
        case .stdio(let stdio):
            // Imported argv is untrusted and is never mined for scripts,
            // packages, interpreters, or helpers. The caller must declare
            // every launch-closure artifact explicitly with the same flags as
            // `mcp add`/`edit`.
            artifact = try MCPCLILaunchArtifact(
                command: stdio.command,
                args: args)
            helperArtifacts =
                try MCPCLIHelperArtifacts(
                    args.all("helper"))
        case .streamableHTTP:
            artifact = nil
            helperArtifacts = []
        }
        let imported = try proposal.makeConfiguration(
            resolution: MCPImportedServerResolution(
                launchArtifact: artifact,
                secretReferences: secretReferences,
                environmentReference:
                    MCPEnvironmentReference(
                        rawValue:
                            "mcpenv_cli_import"),
                protocolProfile:
                    try profileValue(args),
                allowInsecureLoopbackDevelopmentHTTP:
                    args.flags.contains(
                        "allow-insecure-loopback-development-http")))
        let configuration =
            try MCPCLIConfiguration(
                imported,
                replacingHelperArtifacts:
                    helperArtifacts)
        drafts.append((
            alias: proposal.alias,
            configuration: configuration))
    }
    let prepared =
        try await context.management.prepareBatch(drafts)
    let saved = try await context.management
        .testAndSavePreparedBatch(
            prepared,
            authorization:
                MCPCLITestAuthorization(
                    args,
                    action:
                        "import \(prepared.count) server(s)",
                    configurations:
                        prepared.map {
                            $0.definition.configuration
                        }),
            importMarker:
                try parsed.preview.importMarker())
    try emitResult(
        saved,
        json: args.flags.contains("json"),
        message:
            "Tested and atomically imported \(saved.count) MCP server(s).")
}

private func exportMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let data = try await context.management
        .exportSanitized(
            includeDisabled:
                args.flags.contains("include-disabled"))
    if let path = args.value("file") {
        try data.write(
            to: URL(fileURLWithPath: path),
            options: .atomic)
    } else {
        try FileHandle.standardOutput.write(contentsOf: data)
        out("\n")
    }
}

private func attachMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let session = try args.required("session")
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    let revision = newPolicyRevision()
    let attachment = MCPServerAttachment(
        server: definition.reference,
        policy: MCPAttachmentPolicy(
            revision: revision,
            required: args.flags.contains("required"),
            approvalMode: try approvalValue(args),
            parallelCalls: args.flags.contains("parallel"),
            filter: MCPCatalogFilter(
                revision: revision)),
        source: .user)
    let log = try await context.sessionLog(session)
    _ = try await log.append(.mcpServerAttached(.init(
        attachment: attachment,
        actorAgentID: args.value("agent").map {
            AgentID(rawValue: $0)
        })))
    try emitResult(
        attachment,
        json: args.flags.contains("json"),
        message:
            "Attached \(definition.configuration.displayName) to \(session); no connection was created.")
}

private func detachMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let session = try args.required("session")
    let log = try await context.sessionLog(session)
    let state = try await mcpSessionState(log)
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    guard let attachment = state.attachments.values.first(
        where: { $0.server.serverID
            == definition.reference.serverID }) else {
        throw MCPManagementError.serverNotFound(
            definition.reference.serverID.rawValue)
    }
    let payload = MCPServerDetachedPayload(
        attachmentID: attachment.attachmentID,
        server: attachment.server,
        reason: .user,
        revocationGeneration: newRevocationGeneration(),
        actorAgentID: args.value("agent").map {
            AgentID(rawValue: $0)
        })
    _ = try await log.append(.mcpServerDetached(payload))
    try emitResult(
        payload,
        json: args.flags.contains("json"),
        message: "Detached MCP server from \(session).")
}

private func approvalMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    guard args.positionals.first == "set" else {
        throw MCPCLIError.invalidOption(
            "usage: mcp approval set --session ... --server ... --approval ...")
    }
    let session = try args.required("session")
    let log = try await context.sessionLog(session)
    let state = try await mcpSessionState(log)
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    guard let attachment = state.attachments.values.first(
        where: { $0.server.serverID
            == definition.reference.serverID }) else {
        throw MCPManagementError.serverNotFound(
            definition.reference.serverID.rawValue)
    }
    let policy =
        try updatedMCPCLIAttachmentPolicy(
            args,
            existing: attachment.policy)
    let payload = MCPAttachmentPolicyUpdatedPayload(
        attachmentID: attachment.attachmentID,
        server: attachment.server,
        previousRevision: attachment.policy.revision,
        policy: policy,
        revocationGeneration: newRevocationGeneration(),
        actorAgentID: args.value("agent").map {
            AgentID(rawValue: $0)
        })
    _ = try await log.append(
        .mcpAttachmentPolicyUpdated(payload))
    try emitResult(
        payload,
        json: args.flags.contains("json"),
        message: "Updated attachment approval policy.")
}

func updatedMCPCLIAttachmentPolicy(
    _ args: MCPCLIParsedArguments,
    existing: MCPAttachmentPolicy
) throws -> MCPAttachmentPolicy {
    let allowedValues: Set<String> = [
        "session", "server", "approval",
        "agent",
    ]
    let allowedFlags: Set<String> = [
        "json", "required", "optional",
        "parallel", "serial",
    ]
    let unknown =
        Set(args.values.keys)
            .subtracting(allowedValues)
            .union(
                args.flags.subtracting(
                    allowedFlags))
    if let option = unknown.sorted().first {
        throw MCPCLIError.invalidOption(
            "unknown --\(option) for approval set")
    }
    for name in allowedValues
        where args.all(name).count > 1
    {
        throw MCPCLIError.invalidOption(
            "--\(name) may be supplied only once")
    }
    guard args.positionals == ["set"] else {
        throw MCPCLIError.invalidOption(
            "usage: mcp approval set --session ... --server ...")
    }
    guard !(args.flags.contains("required")
            && args.flags.contains("optional")),
          !(args.flags.contains("parallel")
            && args.flags.contains("serial"))
    else {
        throw MCPCLIError.invalidOption(
            "required/optional and parallel/serial flags are mutually exclusive")
    }
    let required: Bool
    if args.flags.contains("required") {
        required = true
    } else if args.flags.contains("optional") {
        required = false
    } else {
        required = existing.required
    }
    let parallel: Bool
    if args.flags.contains("parallel") {
        parallel = true
    } else if args.flags.contains("serial") {
        parallel = false
    } else {
        parallel =
            existing.parallelCalls
    }
    let approval: MCPApprovalMode
    if let raw = args.value("approval") {
        guard let parsed =
                MCPApprovalMode(
                    rawValue: raw) else {
            throw MCPCLIError.invalidOption(
                "approval")
        }
        approval = parsed
    } else {
        approval =
            existing.approvalMode
    }
    let revision = newPolicyRevision()
    return MCPAttachmentPolicy(
        revision: revision,
        required: required,
        approvalMode: approval,
        parallelCalls: parallel,
        filter: MCPCatalogFilter(
            revision: revision,
            tools: existing.filter.tools,
            resources:
                existing.filter.resources,
            prompts:
                existing.filter.prompts,
            completions:
                existing.filter.completions))
}

private func grantMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let session = try args.required("session")
    let agent = AgentID(rawValue: try args.required("agent"))
    let log = try await context.sessionLog(session)
    let state = try await mcpSessionState(log)
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    guard let attachment = state.attachments.values.first(
        where: { $0.server.serverID
            == definition.reference.serverID }) else {
        throw MCPManagementError.serverNotFound(
            definition.reference.serverID.rawValue)
    }
    let requestedTaskID = args.value("task").map {
        TaskID(rawValue: $0)
    }
    let nativeCodexRootAgent =
        await context.nativeCodexRootAgent(
            for: session)
    let usesNativeCodexInteractive =
        nativeCodexRootAgent != nil
            || args.flags.contains(
                "native-interactive")
    if let nativeCodexRootAgent {
        guard agent == nativeCodexRootAgent,
              requestedTaskID == nil else {
            throw MCPCLIError.invalidOption(
                "native Codex MCP access is restricted to the exact session-root Agent \(nativeCodexRootAgent.rawValue)")
        }
    }
    if usesNativeCodexInteractive,
       requestedTaskID != nil {
        throw MCPCLIError.invalidOption(
            "native Codex MCP access cannot target a task or child Agent")
    }
    if usesNativeCodexInteractive,
       args.value("ttl-seconds") != nil {
        throw MCPCLIError.invalidOption(
            "native Codex MCP access cannot use --ttl-seconds")
    }
    let capabilityMatches =
        state.capabilityLeases.values.filter {
            state.capabilityLeaseAgents[$0.id] == agent
                && $0.taskID == requestedTaskID
        }
    guard capabilityMatches.count == 1,
          let capabilityLease = capabilityMatches.first
    else {
        throw MCPCLIError.durableLeaseRequired(
            "expected one capability lease for agent \(agent.rawValue) and task \(requestedTaskID?.rawValue ?? "session-root"), found \(capabilityMatches.count)")
    }
    let workspaceMatches =
        state.workspaceLeases.values.filter {
            state.workspaceLeaseAgents[$0.id] == agent
                && $0.taskID == requestedTaskID
                && $0.rootIdentity?
                    .matchesCurrentDirectory(
                        rootPath: $0.rootPath) == true
        }
    guard workspaceMatches.count == 1,
          let agentWorkspaceLease =
            workspaceMatches.first
    else {
        throw MCPCLIError.durableLeaseRequired(
            "expected one current workspace lease for agent \(agent.rawValue) and task \(requestedTaskID?.rawValue ?? "session-root"), found \(workspaceMatches.count)")
    }
    let mcpWorkspaceLease =
        try MCPProductionStdioWorkspaceLease.derive(
            from: agentWorkspaceLease)
    let durable = try await MCPDurableSessionState.load(
        from: log)
    let rootIdentity = try MCPCLIUnwrap(
        mcpWorkspaceLease.rootIdentity,
        detail: "workspace root identity")
    let runtimeFingerprint = MCPHostDigest.sha256([
        IntatisHostApplication.identity.temporaryPrefix(
            "cli-mcp-runtime-v1"),
        session,
        mcpWorkspaceLease.rootPath,
        MCPHostDigest.workspaceRootIdentity(
            rootIdentity),
    ])
    let workspacePolicyFingerprint =
        MCPConnectionIdentityBuilder
            .workspaceLeasePolicyFingerprint(
                mcpWorkspaceLease)
    let requestedCapabilities = try (args.value("capabilities")
        ?? (usesNativeCodexInteractive
            ? CodexRuntimeMCPProjector
                .requiredNativeSurfaceCapabilities
                .map(\.rawValue)
                .sorted()
                .joined(separator: ",")
            : "tools,resources,prompts,completions"))
        .split(separator: ",")
        .map(String.init)
        .map { value -> MCPGrantedCapability in
            guard let capability =
                    MCPGrantedCapability(rawValue: value) else {
                throw MCPCLIError.invalidOption(
                    "capabilities")
            }
            return capability
        }
    let capabilities: [MCPGrantedCapability]
    if usesNativeCodexInteractive {
        let requested = Set(requestedCapabilities)
        try CodexRuntimeMCPProjector
            .validateNativeSurfaceAuthority(
                capabilities: requested,
                expiresAt: nil)
        capabilities = requested.sorted {
            $0.rawValue < $1.rawValue
        }
    } else {
        capabilities = requestedCapabilities
    }
    let filterRevision = newPolicyRevision()
    let revocation = newRevocationGeneration()
    let rootsPolicyRevision =
        durable.rootsPolicyRevision
            ?? attachment.policy.filter.revision
    let networkPolicyRevision =
        durable.networkPolicyRevision
            ?? attachment.policy.revision
    let sandboxProfileRevision =
        attachment.policy.revision
    let sandboxPolicyFingerprint =
        MCPConnectionIdentityBuilder
            .sandboxPolicyFingerprint(
                hostProfile: context.hostProfile,
                transport:
                    definition.configuration.transport.kind,
                sandboxProfileRevision:
                    sandboxProfileRevision,
                networkPolicyRevision:
                    networkPolicyRevision,
                workspaceLeasePolicyFingerprint:
                    workspacePolicyFingerprint)
    let requirement =
        try MCPConnectionIdentityBuilder.build(
            definition: definition,
            inputs: MCPConnectionAuthorityInputs(
                sessionID: SessionID(rawValue: session),
                agentID: agent,
                attachment: attachment,
                capabilityLeaseID:
                    capabilityLease.id,
                capabilityTaskID:
                    capabilityLease.taskID,
                workspaceLeaseID:
                    mcpWorkspaceLease.id,
                workspaceRootIdentityFingerprint:
                    MCPHostDigest
                        .workspaceRootIdentity(
                            rootIdentity),
                workspaceLeasePolicyFingerprint:
                    workspacePolicyFingerprint,
                accountReference:
                    definition.configuration.transport
                        .oauthAccountReference,
                rootsPolicyRevision:
                    rootsPolicyRevision,
                networkPolicyRevision:
                    networkPolicyRevision,
                sandboxProfileRevision:
                    sandboxProfileRevision,
                sandboxPolicyFingerprint:
                    sandboxPolicyFingerprint,
                revocationGeneration: revocation,
                hostProfile: context.hostProfile,
                runtimeIdentityFingerprint:
                    runtimeFingerprint))
    let authority =
        requirement.identity.authority.fingerprint
    let fingerprint = mcpCLISHA256(Data(
        [
            attachment.attachmentID.rawValue,
            definition.reference.serverRevision.rawValue,
            agent.rawValue,
            capabilities.map(\.rawValue).sorted()
                .joined(separator: ","),
            authority,
            revocation.rawValue,
        ].joined(separator: "|").utf8))
    let grant = MCPGrant(
        attachmentID: attachment.attachmentID,
        server: attachment.server,
        agentID: agent,
        capabilityLeaseID:
            capabilityLease.id,
        taskID: capabilityLease.taskID,
        capabilities: capabilities,
        filter: MCPCatalogFilter(
            revision: filterRevision),
        approvalModeCeiling: try approvalValue(args),
        authorityFingerprint: authority,
        grantFingerprint: fingerprint,
        revocationGeneration: revocation,
        expiresAt: usesNativeCodexInteractive
            ? nil
            : args.value("ttl-seconds").flatMap {
                Int($0)
            }.map {
                Date().addingTimeInterval(TimeInterval($0))
            })
    _ = try await log.append(
        .mcpGrantGranted(.init(grant: grant)))
    try emitResult(
        grant,
        json: args.flags.contains("json"),
        message: usesNativeCodexInteractive
            ? "Granted the exact Codex Native Interactive MCP surface to \(agent.rawValue)."
            : "Granted exact MCP capabilities to \(agent.rawValue).")
}

private func revokeMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let session = try args.required("session")
    let grantID = MCPGrantID(
        rawValue: try args.required("grant"))
    let log = try await context.sessionLog(session)
    let state = try await mcpSessionState(log)
    guard let grant = state.grants[grantID] else {
        throw MCPCLIError.invalidOption("grant")
    }
    let payload = MCPGrantRevokedPayload(
        grantID: grant.grantID,
        server: grant.server,
        attachmentID: grant.attachmentID,
        agentID: grant.agentID,
        reason: .user,
        revocationGeneration: newRevocationGeneration())
    _ = try await log.append(.mcpGrantRevoked(payload))
    try emitResult(
        payload,
        json: args.flags.contains("json"),
        message: "Revoked MCP grant.")
}

private struct MCPCLIOAuthStatus:
    Codable, Sendable
{
    let server: MCPServerReference
    let displayName: String
    let resource: String
    let configuredAccount: MCPAccountReference?
    let activeCredential:
        MCPCLIOAuthAccountSummary?
}

private func confirmOAuthOperation(
    _ args: MCPCLIParsedArguments,
    action: String
) throws {
    guard !args.flags.contains("yes") else {
        return
    }
    guard isatty(STDIN_FILENO) == 1 else {
        throw MCPCLIError.confirmationRequired
    }
    out("\(action)? [y/N] ")
    let answer = readLine()?
        .trimmingCharacters(
            in: .whitespacesAndNewlines)
        .lowercased()
    guard answer == "y" || answer == "yes" else {
        throw MCPCLIError.confirmationRequired
    }
}

private func authMCP(
    _ context: MCPCLIContext,
    _ args: MCPCLIParsedArguments
) async throws {
    let operation = args.positionals.first ?? "status"
    let definition = try await context.management.definition(
        serverOrAlias: try serverValue(args))
    guard case .streamableHTTP(let http) =
            definition.configuration.transport,
          let oauth = http.oauth, oauth.enabled else {
        throw MCPCLIError.serverHasNoOAuth
    }
    switch operation {
    case "status":
        let active =
            try await context.oauth.activeSummary(
                definition: definition)
        let status = MCPCLIOAuthStatus(
            server: definition.reference,
            displayName:
                definition.configuration.displayName,
            resource: oauth.canonicalResource,
            configuredAccount:
                oauth.accountReference,
            activeCredential: active)
        if args.flags.contains("json") {
            try writeJSON(status)
        } else {
            out(
                "OAuth \(active == nil ? "login required" : "active") for \(definition.configuration.displayName) (\(definition.reference.serverRevision.rawValue)).\n")
        }
    case "login":
        try confirmOAuthOperation(
            args,
            action:
                "sign in to \(definition.configuration.displayName) for \(oauth.canonicalResource)")
        try await context.unlockSecrets(
            createIfMissing: true)
        let alias = try await MCPCLIAlias(
            definition: definition,
            context: context)
        let prepared =
            try await context.management.prepare(
                alias: alias,
                configuration:
                    definition.configuration)
        do {
            try await context.oauth.loginStaged(
                prepared: prepared,
                allowDynamicClientRegistration:
                    args.flags.contains(
                        "allow-dynamic-registration"),
                openBrowser:
                    !args.flags.contains("no-open"))
            let result =
                try await context.management.test(
                    prepared,
                    authorization:
                        MCPCLITestAuthorization(
                            args,
                            action:
                                "OAuth login Test \(alias)",
                            configurations: [
                                prepared.definition
                                    .configuration,
                            ]))
            guard result.terminal == .succeeded else {
                throw MCPManagementError
                    .configurationTestFailed(
                        result.sanitizedReasonCode)
            }
            let proof = try prepared.accept(result)
            let receipt =
                try await context.management
                    .savePreparedReceipt(
                        prepared,
                        proof: proof)
            let summary =
                try await context.oauth
                    .activateStagedLogin(
                        prepared: prepared,
                        proof: proof,
                        publishedCatalog:
                            receipt.catalog)
            try emitResult(
                summary,
                json: args.flags.contains("json"),
                message:
                    "OAuth login activated for exact MCP revision \(summary.server.serverRevision.rawValue).")
        } catch {
            do {
                try await context.oauth
                    .discardStagedLogin(
                        prepared: prepared)
            } catch {
                errOut(
                    "warning: staged OAuth credential cleanup failed: \(error.localizedDescription)\n")
            }
            throw error
        }
    case "logout":
        try confirmOAuthOperation(
            args,
            action:
                "revoke OAuth authority for \(definition.configuration.displayName)")
        try await context.unlockSecrets(
            createIfMissing: false)
        try await context.oauth.logout(
            definition: definition)
        let result = [
            "server":
                definition.reference.serverID.rawValue,
            "revision":
                definition.reference
                    .serverRevision.rawValue,
            "status": "logged_out",
        ]
        try emitResult(
            result,
            json: args.flags.contains("json"),
            message:
                "OAuth authority revoked and credential removed.")
    default:
        throw MCPCLIError.invalidOption("auth operation")
    }
}

struct MCPCLISessionState {
    var attachments:
        [MCPAttachmentID: MCPServerAttachment] = [:]
    var grants: [MCPGrantID: MCPGrant] = [:]
    var capabilityLeases:
        [CapabilityLeaseID: CapabilityLease] = [:]
    var capabilityLeaseAgents:
        [CapabilityLeaseID: AgentID] = [:]
    var workspaceLeases:
        [WorkspaceLeaseID: WorkspaceLease] = [:]
    var workspaceLeaseAgents:
        [WorkspaceLeaseID: AgentID] = [:]
}

func mcpSessionState(
    _ log: EventLog
) async throws -> MCPCLISessionState {
    var state = MCPCLISessionState()
    for envelope in try await log.replayChecked() {
        switch envelope.event {
        case .mcpServerAttached(let payload):
            state.attachments[
                payload.attachment.attachmentID] =
                payload.attachment
        case .mcpServerDetached(let payload):
            state.attachments.removeValue(
                forKey: payload.attachmentID)
            state.grants = state.grants.filter {
                $0.value.attachmentID
                    != payload.attachmentID
            }
        case .mcpAttachmentPolicyUpdated(let payload):
            if let previous =
                    state.attachments[payload.attachmentID] {
                state.attachments[payload.attachmentID] =
                    MCPServerAttachment(
                        attachmentID:
                            previous.attachmentID,
                        server: previous.server,
                        policy: payload.policy,
                        source: previous.source,
                        sourceFingerprint:
                            previous.sourceFingerprint)
            }
        case .mcpGrantGranted(let payload):
            state.grants[payload.grant.grantID] =
                payload.grant
        case .mcpGrantRevoked(let payload):
            state.grants.removeValue(
                forKey: payload.grantID)
        case .capabilityLeaseCreated(let payload):
            if let agent = payload.agent {
                state.capabilityLeases[
                    payload.lease.id] = payload.lease
                state.capabilityLeaseAgents[
                    payload.lease.id] = agent
            }
        case .capabilityLeaseRevoked(let payload):
            state.capabilityLeases.removeValue(
                forKey: payload.leaseID)
            state.capabilityLeaseAgents.removeValue(
                forKey: payload.leaseID)
        case .workspaceLeaseGranted(let payload):
            if let agent = payload.agent {
                state.workspaceLeases[
                    payload.lease.id] = payload.lease
                state.workspaceLeaseAgents[
                    payload.lease.id] = agent
            }
        case .workspaceLeaseRevoked(let payload):
            state.workspaceLeases.removeValue(
                forKey: payload.leaseID)
            state.workspaceLeaseAgents.removeValue(
                forKey: payload.leaseID)
        default:
            break
        }
    }
    return state
}

func MCPCLIAlias(
    definition: MCPServerDefinition,
    context: MCPCLIContext
) async throws -> String {
    let catalog = try await context.management.catalog()
    guard let head = catalog.head(
        for: definition.reference.serverID),
          head.currentRevision
            == definition.reference.serverRevision
    else {
        throw MCPManagementError.currentRevisionMissing(
            definition.reference.serverID)
    }
    return head.alias
}

private func MCPCLIUnwrap<T>(
    _ value: T?,
    detail: String
) throws -> T {
    guard let value else {
        throw MCPCLIError.durableLeaseRequired(detail)
    }
    return value
}

func serverValue(
    _ args: MCPCLIParsedArguments
) throws -> String {
    if let value = args.value("server") {
        return value
    }
    if let value = args.positionals.first,
       value != "set", value != "status",
       value != "login", value != "logout" {
        return value
    }
    throw MCPCLIError.missingRequiredOption("server")
}

private func profileValue(
    _ args: MCPCLIParsedArguments
) throws -> MCPProtocolProfile {
    let raw = args.value("profile")
        ?? MCPProtocolProfile.codexCompat.rawValue
    guard let profile = MCPProtocolProfile(
        rawValue: raw) else {
        throw MCPCLIError.invalidOption("profile")
    }
    return profile
}

private func approvalValue(
    _ args: MCPCLIParsedArguments
) throws -> MCPApprovalMode {
    let raw = args.value("approval")
        ?? MCPApprovalMode.prompt.rawValue
    guard let value = MCPApprovalMode(rawValue: raw) else {
        throw MCPCLIError.invalidOption("approval")
    }
    return value
}

private func importFormat(
    _ args: MCPCLIParsedArguments
) throws -> MCPImportFormat {
    let raw = args.value("format")
        ?? MCPImportFormat.mcpJSON.rawValue
    guard let value = MCPImportFormat(rawValue: raw) else {
        throw MCPCLIError.invalidOption("format")
    }
    return value
}

func configurationUsesSecret(
    _ configuration: MCPServerConfiguration
) -> Bool {
    switch configuration.transport {
    case .stdio(let value):
        return value.environment.values.contains {
            if case .secret = $0 { return true }
            return false
        } || !value.inheritedEnvironmentReferences.isEmpty
    case .streamableHTTP(let value):
        return value.bearerTokenReference != nil
            || value.oauth?.clientSecretReference != nil
            || value.oauth?.enabled == true
            || value.headers.values.contains {
                if case .secret = $0 { return true }
                return false
            }
    }
}

private func newPolicyRevision() -> MCPPolicyRevision {
    MCPPolicyRevision(rawValue:
        IDGen.random(prefix: "mcppolicy"))
}

func MCPCLITestAuthorization(
    _ args: MCPCLIParsedArguments,
    action: String,
    configurations:
        [MCPServerConfiguration] = []
) throws -> MCPConfigurationTestAuthorization {
    for configuration in configurations {
        if let selection =
                try MCPIsolatedTestWorkspace.selection(
                    for: configuration) {
            errOut(
                "MCP Test workspace (\(selection.source.rawValue)): \(selection.rootPath)\n")
        }
    }
    if !args.flags.contains("yes") {
        guard isatty(STDIN_FILENO) == 1 else {
            throw MCPCLIError.confirmationRequired
        }
        out(
            "Run the exact isolated MCP Test for \(action)? [y/N] ")
        guard let answer = readLine()?
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
            .lowercased(),
              answer == "y" || answer == "yes" else {
            throw MCPCLIError.confirmationRequired
        }
    }
    return try MCPConfigurationTestAuthorization(
        directUserAction: true,
        callerFingerprint:
            mcpCLISHA256(
                Data([
                    IntatisHostApplication.identity.temporaryPrefix(
                        "cli-mcp-test-v1"),
                    action,
                    String(ProcessInfo.processInfo
                        .processIdentifier),
                ].joined(separator: "|").utf8)))
}

func MCPCLILaunchArtifact(
    command: String,
    args: MCPCLIParsedArguments
) throws -> LaunchArtifactIdentity {
    var inputs: [MCPLaunchArtifactInput] = [
        .init(role: .executable, path: command),
    ]
    inputs.append(contentsOf:
        args.all("interpreter").map {
            .init(role: .interpreter, path: $0)
        })
    inputs.append(contentsOf:
        args.all("script").map {
            .init(role: .script, path: $0)
        })
    inputs.append(contentsOf:
        args.all("package-entrypoint").map {
            .init(
                role: .packageEntrypoint,
                path: $0)
        })
    inputs.append(contentsOf:
        args.all("lockfile").map {
            .init(role: .lockfile, path: $0)
        })
    return try MCPLaunchArtifactIdentityVerifier
        .captureBeforeSave(inputs)
}

func MCPCLIHelperArtifacts(
    _ paths: [String]
) throws -> [LaunchArtifactIdentity] {
    try paths.map {
        try MCPLaunchArtifactIdentityVerifier
            .captureHelpersBeforeSave([
                MCPLaunchArtifactInput(
                    role: .helper,
                    path: $0),
            ])
    }
}

private func MCPCLIConfiguration(
    _ configuration: MCPServerConfiguration,
    replacingHelperArtifacts helpers:
        [LaunchArtifactIdentity]
) throws -> MCPServerConfiguration {
    guard case .stdio(let stdio) =
            configuration.transport else {
        return configuration
    }
    return try MCPServerConfiguration(
        serverID: configuration.serverID,
        displayName:
            configuration.displayName,
        enabled: configuration.enabled,
        required: configuration.required,
        requiredCapabilities:
            configuration.requiredCapabilities,
        protocolProfile:
            configuration.protocolProfile,
        maximumProtocolVersion:
            configuration.maximumProtocolVersion,
        approvalPolicy:
            configuration.approvalPolicy,
        parallelCalls:
            configuration.parallelCalls,
        timeouts: configuration.timeouts,
        filters: configuration.filters,
        transport: .stdio(
            try MCPStdioServerConfiguration(
                launchArtifact:
                    stdio.launchArtifact,
                arguments: stdio.arguments,
                workingDirectory:
                    stdio.workingDirectory,
                environment:
                    stdio.environment,
                inheritedEnvironmentReferences:
                    stdio
                        .inheritedEnvironmentReferences,
                helperArtifacts: helpers,
                networkPolicy:
                    stdio.networkPolicy)),
        environmentReference:
            configuration.environmentReference,
        provenance:
            configuration.provenance)
}

private func mcpCLISHA256(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func newRevocationGeneration()
    -> MCPRevocationGeneration {
    MCPRevocationGeneration(rawValue:
        IDGen.random(prefix: "mcprevocation"))
}

func writeJSON<T: Encodable>(
    _ value: T
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(value)
    try FileHandle.standardOutput.write(contentsOf: data)
    out("\n")
}

private func emitResult<T: Encodable>(
    _ value: T,
    json: Bool,
    message: String
) throws {
    if json {
        try writeJSON(value)
    } else {
        out("\(message)\n")
    }
}

struct MCPCLIProcessExit: Error, LocalizedError {
    let code: Int32
    var errorDescription: String? {
        "MCP command failed with exit code \(code)"
    }
}

func printMCPHelp() {
    let identity = IntatisHostApplication.identity
    let help = """
    Intatis external MCP client

    INVENTORY
      translatis mcp list [--json]
      translatis mcp get --server <alias|id> [--json]
      translatis mcp add --alias <id> --name <name> (--url <https> | --command </absolute/path>) [configuration options] [--yes] [--json]
      translatis mcp edit --server <alias|id> [same mutable fields]
      translatis mcp duplicate --server <alias|id> --alias <new>
      translatis mcp enable|disable --server <alias|id>
      translatis mcp remove --server <alias|id> --yes
      translatis mcp test --server <alias|id>
      translatis mcp doctor [--json]
      translatis mcp import --file <explicit.json> [--format mcp-json|claude-json] [explicit launch-closure flags] [--replace-conflicts] [--allow-insecure-loopback-development-http]
      translatis mcp export [--file <path>] [--include-disabled]

    SESSION AUTHORITY
      translatis mcp attach --session <id> --server <alias|id> [--required] [--agent <id>]
      translatis mcp detach --session <id> --server <alias|id>
      translatis mcp approval set --session <id> --server <alias|id> [--approval <mode>] [--required|--optional] [--parallel|--serial]
      translatis mcp grant --session <id> --server <alias|id> --agent <id> [--native-interactive | --task <id> --capabilities tools,resources,prompts,...] [--ttl-seconds <seconds>]
      translatis mcp revoke --session <id> --grant <id>
      translatis mcp auth status --server <alias|id>
      translatis mcp auth login --server <alias|id> [--allow-dynamic-registration] [--no-open] [--yes]
      translatis mcp auth logout --server <alias|id> [--yes]

    LIVE SESSION OWNER
      translatis mcp status [--session <id>] [--agent <id>] [--json]
      translatis mcp connect --session <id> --agent <id> [--task <id>] [--server <alias|id>] --yes
      translatis mcp inspect|tools|resources|prompts --session <id> --agent <id> [--task <id>] [--server <alias|id>] --yes
      translatis mcp refresh|disconnect --session <id> --agent <id> [--task <id>] [--server <alias|id>]
      translatis mcp reload [--json]
      translatis exec --session <id> --agent <id> [--task <id>] --prompt <text> [--yes]

    ADD / EDIT CONFIGURATION OPTIONS
      Common:
        --profile codex-compat|standard-extended
        --maximum-protocol-version <version>
        --approval prompt|writes|auto|approve
        --tool-approval TOOL=prompt|writes|auto|approve ...
        --remove-tool-approval <tool> ... | --clear-tool-approvals
        --required | --optional
        --required-capability <capability> ... | --clear-required-capabilities
        --parallel | --serial
        --startup-timeout-ms <ms> --call-timeout-ms <ms> --shutdown-timeout-ms <ms>
        --environment-id <stable-id>
        --allow-tool|--deny-tool <name> ...
        --allow-resource|--deny-resource <name> ...
        --allow-prompt|--deny-prompt <name> ...
        --allow-completion|--deny-completion <name> ...
        --clear-tool-allow|--clear-tool-deny
        --clear-resource-allow|--clear-resource-deny
        --clear-prompt-allow|--clear-prompt-deny
        --clear-completion-allow|--clear-completion-deny

      Streamable HTTP:
        --url <https-endpoint>
        --header NAME=VALUE ... --secret-header <NAME> ...
        --secret-header-stdin <NAME> --remove-header <NAME> ... --clear-headers
        --bearer-secret | --bearer-stdin | --clear-bearer
        --oauth-resource <https-resource> [--oauth-client-id <id>]
        --oauth-scope <scope> ...
        --oauth-client-secret | --oauth-client-secret-stdin
        --clear-oauth-client-{id,secret} --clear-oauth-scopes --disable-oauth
        --redirect-policy deny|same-origin-only
        --proxy-policy direct|system-configured
        --tls-spki-pin <lowercase-sha256-hex> ... | --system-trust
        --allow-insecure-loopback-development-http
        --disallow-insecure-loopback-development-http

      Local stdio:
        --command </absolute/path> --arg <value> ... --clear-args
        --cwd </absolute/path> | --clear-cwd
        --interpreter|--script|--package-entrypoint|--lockfile <absolute-path> ...
        --helper <absolute-path> ... | --clear-helpers
        --env NAME=VALUE ... --secret-env <NAME> ...
        --secret-env-stdin <NAME> --remove-env <NAME> ... --clear-environment
        --network-origin <exact-https-origin> ... | --deny-network

    Secrets are never accepted as argv values. Options ending in `-stdin`
    consume the one bounded secret supplied on standard input; only one such
    option/value is accepted per command. Other secret options read from the
    controlling terminal with echo disabled. All secrets are stored only as
    references in the encrypted owner-only CLI credential store.
    Plain HTTP is rejected unless
    `--allow-insecure-loopback-development-http` is explicitly supplied, and
    even then only an exact loopback endpoint with the development policy is
    accepted. Imported stdio argv never infers launch artifacts: declare every
    interpreter/script/package/lockfile/helper path explicitly. Helpers are
    captured as separate exact helper artifacts, never as part of the primary
    launch artifact.
    Add/edit/import always run initialize plus complete discovery for the exact
    draft before the immutable catalog transaction commits.
    """
    out(help
        .replacingOccurrences(of: "Intatis", with: identity.name)
        .replacingOccurrences(of: "translatis", with: identity.commandName))
}
