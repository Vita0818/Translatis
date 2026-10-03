import Foundation
import IntatisCore
import IntatisProtocol
import MCP

public enum MCPClientSessionState: Equatable, Sendable {
    case idle
    case initializing
    case ready(MCPNegotiatedProtocolVersion)
    case stopping
    case stopped
    case failed(String)
}

public enum MCPClientSessionError: Error, Equatable, LocalizedError, Sendable {
    case alreadyStarted
    case notReady
    case stopped
    case unsupportedConfiguredProtocolVersion(String)
    case sdkProtocolCoverageMismatch
    case serverSelectedProtocolVersionOutsideProfile(
        selected: String,
        requested: String,
        profile: String)
    case missingRequiredCapabilities([String])
    case initializeTimedOut(milliseconds: Int)
    case requestTimedOut(method: String, milliseconds: Int)
    case initializeCancelled
    case requestCancelled(method: String)
    case taskCreationTimedOut(method: String, milliseconds: Int)
    case taskCreationCancelled(method: String)
    case staleGeneration
    case serverInstructionsTooLarge
    case invalidInboundCapabilitySurface(String)
    case inboundCallbackServicesUnavailable(String)
    case missingCallbackAuthorityFingerprint
    case invalidProgressRequestParameters
    case requestCorrelationMismatch

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "the MCP client session has already been started"
        case .notReady:
            return "the MCP client session is not ready"
        case .stopped:
            return "the MCP client session is stopped"
        case .unsupportedConfiguredProtocolVersion(let value):
            return "unsupported configured MCP protocol version: \(value)"
        case .sdkProtocolCoverageMismatch:
            return "the pinned MCP SDK does not cover the configured protocol set"
        case .serverSelectedProtocolVersionOutsideProfile(
            let selected,
            let requested,
            let profile):
            return "server selected MCP protocol \(selected), outside \(profile) request \(requested)"
        case .missingRequiredCapabilities(let values):
            return "MCP server is missing required capabilities: \(values.joined(separator: ", "))"
        case .initializeTimedOut(let milliseconds):
            return "MCP initialize timed out after \(milliseconds) ms"
        case .requestTimedOut(let method, let milliseconds):
            return "MCP request \(method) timed out after \(milliseconds) ms"
        case .initializeCancelled:
            return "MCP initialize was cancelled"
        case .requestCancelled(let method):
            return "MCP request \(method) was cancelled"
        case .taskCreationTimedOut(let method, let milliseconds):
            return "task-augmented MCP request \(method) timed out after \(milliseconds) ms before a remote task ID was received"
        case .taskCreationCancelled(let method):
            return "task-augmented MCP request \(method) was cancelled before a remote task ID was received"
        case .staleGeneration:
            return "a retired MCP connection generation produced a late result"
        case .serverInstructionsTooLarge:
            return "MCP server instructions exceed the bounded client limit"
        case .invalidInboundCapabilitySurface(let reason):
            return "invalid MCP inbound capability surface: \(reason)"
        case .inboundCallbackServicesUnavailable(let feature):
            return "MCP inbound callback services are unavailable for \(feature)"
        case .missingCallbackAuthorityFingerprint:
            return "MCP callbacks require an exact authority fingerprint"
        case .invalidProgressRequestParameters:
            return "MCP request parameters cannot carry exact progress metadata"
        case .requestCorrelationMismatch:
            return "the MCP SDK changed the exact outbound request ID"
        }
    }
}

public enum MCPSanitizedExternalErrorCategory:
    String, Equatable, Sendable
{
    case jsonRPC = "json_rpc"
    case transport
    case urlElicitationRequired =
        "url_elicitation_required"
}

/// Typed, secret-free replacement for an SDK error whose message originated
/// outside the trust boundary. The raw SDK error is deliberately not retained:
/// otherwise `localizedDescription`, reflection, UI, CLI, or a durable
/// diagnostic could recover the original server-controlled message.
public struct MCPSanitizedExternalError:
    Error, Equatable, LocalizedError, Sendable
{
    public let operation: String
    public let category:
        MCPSanitizedExternalErrorCategory
    public let jsonRPCCode: Int
    public let summary: String

    init(
        operation: String,
        category:
            MCPSanitizedExternalErrorCategory,
        jsonRPCCode: Int,
        summary: String
    ) {
        self.operation =
            String(operation.prefix(128))
        self.category = category
        self.jsonRPCCode = jsonRPCCode
        self.summary =
            String(summary.prefix(512))
    }

    public var errorDescription: String? {
        "MCP \(operation) failed (\(category.rawValue), JSON-RPC \(jsonRPCCode)): \(summary)"
    }
}

public struct MCPClientSessionConfiguration: Sendable {
    public let server: MCPServerReference
    public let generation: MCPConnectionGeneration
    public let profile: MCPProtocolProfile
    public let maximumProtocolVersion: MCPProtocolVersion
    public let requiredCapabilities: Set<MCPGrantedCapability>
    public let startupTimeoutMilliseconds: Int
    public let callTimeoutMilliseconds: Int
    public let maximumInstructionsBytes: Int
    public let clientName: String
    public let clientVersion: String
    public let authorizedRoots: MCPAuthorizedRootsSnapshot?
    public let catalogNotificationSink:
        (any MCPCatalogNotificationSink)?
    public let callbackCapabilities: MCPClientCallbackCapabilities
    public let callbackAuthorityFingerprint: String?
    public let inboundServicesFactory:
        (any MCPClientInboundServicesFactory)?
    public let remoteTaskStatusSink: (any MCPRemoteTaskStatusSink)?
    public let outputSanitizer:
        any MCPToolResultSanitizer
    public let inboundNotificationSink:
        (any MCPInboundNotificationSink)?
    public let inboundNotificationPolicy:
        MCPInboundNotificationPolicy

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        profile: MCPProtocolProfile,
        maximumProtocolVersion: MCPProtocolVersion? = nil,
        requiredCapabilities: Set<MCPGrantedCapability> = [],
        startupTimeoutMilliseconds: Int = 30_000,
        callTimeoutMilliseconds: Int = 60_000,
        maximumInstructionsBytes: Int = 64 * 1_024,
        clientName: String = IntatisHostApplication.identity.fileNameStem,
        clientVersion: String,
        authorizedRoots: MCPAuthorizedRootsSnapshot? = nil,
        catalogNotificationSink:
            (any MCPCatalogNotificationSink)? = nil,
        callbackCapabilities: MCPClientCallbackCapabilities = .none,
        callbackAuthorityFingerprint: String? = nil,
        inboundServicesFactory:
            (any MCPClientInboundServicesFactory)? = nil,
        remoteTaskStatusSink: (any MCPRemoteTaskStatusSink)? = nil,
        outputSanitizer:
            any MCPToolResultSanitizer =
                MCPConservativeToolResultSanitizer(),
        inboundNotificationSink:
            (any MCPInboundNotificationSink)? = nil,
        inboundNotificationPolicy:
            MCPInboundNotificationPolicy = .init()
    ) {
        self.server = server
        self.generation = generation
        self.profile = profile
        self.maximumProtocolVersion =
            maximumProtocolVersion ?? profile.defaultMaximumVersion
        self.requiredCapabilities = requiredCapabilities
        self.startupTimeoutMilliseconds = max(100, startupTimeoutMilliseconds)
        self.callTimeoutMilliseconds = max(100, callTimeoutMilliseconds)
        self.maximumInstructionsBytes = max(1_024, maximumInstructionsBytes)
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.authorizedRoots = authorizedRoots
        self.catalogNotificationSink = catalogNotificationSink
        self.callbackCapabilities = callbackCapabilities
        self.callbackAuthorityFingerprint = callbackAuthorityFingerprint
        self.inboundServicesFactory = inboundServicesFactory
        self.remoteTaskStatusSink = remoteTaskStatusSink
        self.outputSanitizer = outputSanitizer
        self.inboundNotificationSink =
            inboundNotificationSink
        self.inboundNotificationPolicy =
            inboundNotificationPolicy
    }
}

public struct MCPExternalServerInstructions: Equatable, Sendable {
    public let server: MCPServerReference
    public let generation: MCPConnectionGeneration
    public let text: String

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        text: String
    ) {
        self.server = server
        self.generation = generation
        self.text = text
    }
}

public struct MCPClientHandshake: Sendable {
    public let server: MCPServerReference
    public let generation: MCPConnectionGeneration
    public let negotiatedVersion: MCPNegotiatedProtocolVersion
    public let capabilities: MCPNegotiatedCapabilitySet
    public let serverName: String
    public let serverVersion: String
    public let instructions: MCPExternalServerInstructions?

    public init(
        server: MCPServerReference,
        generation: MCPConnectionGeneration,
        negotiatedVersion: MCPNegotiatedProtocolVersion,
        capabilities: MCPNegotiatedCapabilitySet,
        serverName: String,
        serverVersion: String,
        instructions: MCPExternalServerInstructions?
    ) {
        self.server = server
        self.generation = generation
        self.negotiatedVersion = negotiatedVersion
        self.capabilities = capabilities
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.instructions = instructions
    }
}

/// One initialized MCP client generation. The session owns the SDK client and
/// its transport and never publishes a handshake until initialize validation
/// and `notifications/initialized` have both completed.
public actor MCPClientSession {
    public nonisolated let outputSanitizer:
        any MCPToolResultSanitizer
    private let configuration: MCPClientSessionConfiguration
    private let transport: any Transport
    private let client: Client
    private let advertisedCapabilities: Client.Capabilities
    private var lifecycleState: MCPClientSessionState = .idle
    private var handshakeValue: MCPClientHandshake?
    private var inboundServices: MCPClientInboundServices?
    private var inboundNotificationBroker:
        MCPInboundNotificationBroker?
    private var retired = false

    public init(
        configuration: MCPClientSessionConfiguration,
        transport: any Transport
    ) {
        self.configuration = configuration
        self.transport = transport
        self.outputSanitizer =
            configuration.outputSanitizer
        self.advertisedCapabilities =
            SDKPatchCompatibility.makeCapabilityProbe(
                profile: configuration.profile,
                callbacks: configuration.callbackCapabilities)
        self.client = Client(
            name: configuration.clientName,
            version: configuration.clientVersion,
            capabilities: advertisedCapabilities,
            configuration: .strict)
    }

    public func state() -> MCPClientSessionState {
        lifecycleState
    }

    public func handshake() -> MCPClientHandshake? {
        handshakeValue
    }

    @discardableResult
    public func start() async throws -> MCPClientHandshake {
        guard lifecycleState == .idle else {
            if lifecycleState == .stopped { throw MCPClientSessionError.stopped }
            throw MCPClientSessionError.alreadyStarted
        }
        lifecycleState = .initializing
        let negotiation: MCPProtocolNegotiationRequest
        do {
            negotiation = try MCPProtocolNegotiationPolicy.request(
                profile: configuration.profile,
                configuredMaximum: configuration.maximumProtocolVersion)
        } catch {
            lifecycleState = .failed(safeReason(error))
            throw error
        }

        let result: Initialize.Result
        do {
            try await installInboundSurface()
            let advertisedCapabilities = self.advertisedCapabilities
            let requiredCapabilities = configuration.requiredCapabilities
            let maximumInstructionsBytes =
                configuration.maximumInstructionsBytes
            result = try await race(
                timeoutMilliseconds: configuration.startupTimeoutMilliseconds,
                operation: {
                    try await self.client.connect(
                        transport: self.transport,
                        requestedProtocolVersion: negotiation.requestedVersion.rawValue,
                        allowedProtocolVersions: negotiation.allowedVersions,
                        validateInitializeResult: { result in
                            _ = try negotiation.validateSelectedVersion(
                                result.protocolVersion)
                            let capabilities = MCPNegotiatedCapabilitySet(
                                server: result.capabilities,
                                client: advertisedCapabilities)
                            try capabilities.validateRequired(
                                requiredCapabilities)
                            if let instructions = result.instructions {
                                guard instructions.utf8.count
                                        <= maximumInstructionsBytes else {
                                    throw MCPClientSessionError
                                        .serverInstructionsTooLarge
                                }
                            }
                        })
                },
                onTimeout: {
                    // Initialize never sends notifications/cancelled. Retiring
                    // the exact transport generation resumes the SDK pending
                    // request and fences any late initialize response.
                    await self.client.disconnect()
                },
                onCancellation: {
                    await self.client.disconnect()
                },
                timeoutError: .initializeTimedOut(
                    milliseconds: configuration.startupTimeoutMilliseconds),
                cancellationError: .initializeCancelled)
        } catch {
            retired = true
            await inboundNotificationBroker?
                .retireGeneration()
            await client.disconnect()
            let boundaryError =
                sanitizedBoundaryError(
                    error,
                    operation: "initialize")
            lifecycleState = .failed(
                safeReason(boundaryError))
            throw boundaryError
        }

        do {
            guard !retired else { throw MCPClientSessionError.staleGeneration }
            let negotiated = try negotiation.validateSelectedVersion(
                result.protocolVersion)
            let capabilities = MCPNegotiatedCapabilitySet(
                server: result.capabilities,
                client: advertisedCapabilities)
            try capabilities.validateRequired(
                configuration.requiredCapabilities)
            try await configureServerLoggingIfNeeded(
                serverCapabilities: result.capabilities)

            let instructions: MCPExternalServerInstructions?
            if let rawInstructions = result.instructions {
                guard rawInstructions.utf8.count
                        <= configuration.maximumInstructionsBytes else {
                    throw MCPClientSessionError.serverInstructionsTooLarge
                }
                let sanitizedInstructions =
                    try outputSanitizer
                        .sanitizeMCPText(rawInstructions)
                guard sanitizedInstructions.utf8.count
                        <= configuration.maximumInstructionsBytes else {
                    throw MCPClientSessionError.serverInstructionsTooLarge
                }
                instructions = MCPExternalServerInstructions(
                    server: configuration.server,
                    generation: configuration.generation,
                    text: sanitizedInstructions)
            } else {
                instructions = nil
            }

            let handshake = MCPClientHandshake(
                server: configuration.server,
                generation: configuration.generation,
                negotiatedVersion: negotiated,
                capabilities: capabilities,
                serverName: result.serverInfo.name,
                serverVersion: result.serverInfo.version,
                instructions: instructions)
            handshakeValue = handshake
            lifecycleState = .ready(negotiated)
            return handshake
        } catch {
            retired = true
            await inboundNotificationBroker?
                .retireGeneration()
            await client.disconnect()
            let boundaryError =
                sanitizedBoundaryError(
                    error,
                    operation: "initialize")
            lifecycleState = .failed(
                safeReason(boundaryError))
            throw boundaryError
        }
    }

    /// Performs an ordinary non-task MCP request. Timeout and caller
    /// cancellation both send the exact request-ID cancellation notification
    /// while the generation remains live, then stop waiting locally.
    public func perform<M: MCP.Method>(
        _ request: MCP.Request<M>,
        timeoutMilliseconds: Int? = nil
    ) async throws -> M.Result {
        guard !retired else { throw MCPClientSessionError.staleGeneration }
        guard case .ready = lifecycleState else {
            throw lifecycleState == .stopped
                ? MCPClientSessionError.stopped
                : MCPClientSessionError.notReady
        }

        let tracked:
            MCPTrackedRequestContext<M.Result>
        do {
            tracked = try await beginRequest(
                request)
        } catch {
            throw sanitizedBoundaryError(
                error,
                operation: request.method)
        }
        let context = tracked.context
        let progressToken = tracked.progressToken
        let broker = inboundNotificationBroker
        let timeout = max(
            100,
            timeoutMilliseconds ?? configuration.callTimeoutMilliseconds)
        do {
            let value = try await race(
                timeoutMilliseconds: timeout,
                operation: { try await context.value },
                onTimeout: {
                    if let progressToken {
                        await broker?.finishRequest(
                            progressToken: progressToken,
                            phase: .timedOut)
                    }
                    // Client.cancelRequest removes the pending continuation
                    // before attempting the advisory wire notification.
                    try? await self.client.cancelRequest(
                        context.requestID,
                        reason: "\(IntatisHostApplication.identity.name) request timed out")
                },
                onCancellation: {
                    if let progressToken {
                        await broker?.finishRequest(
                            progressToken: progressToken,
                            phase: .cancelled)
                    }
                    try? await self.client.cancelRequest(
                        context.requestID,
                        reason: "\(IntatisHostApplication.identity.name) request cancelled")
                },
                timeoutError: .requestTimedOut(
                    method: request.method,
                    milliseconds: timeout),
                cancellationError: .requestCancelled(
                    method: request.method))
            if let progressToken {
                await broker?.finishRequest(
                    progressToken: progressToken,
                    phase: .succeeded)
            }
            return value
        } catch {
            if let progressToken {
                await broker?.finishRequest(
                    progressToken: progressToken,
                    phase: Self.progressPhase(for: error))
            }
            if error is CancellationError {
                throw MCPClientSessionError
                    .requestCancelled(
                        method: request.method)
            }
            throw sanitizedBoundaryError(
                error,
                operation: request.method)
        }
    }

    /// Performs the initial request for a server-owned experimental Task.
    ///
    /// Before the immediate CreateTaskResult arrives there is no legitimate
    /// remote task ID to cancel. Timeout/caller cancellation therefore retires
    /// the exact connection generation and never sends
    /// `notifications/cancelled` or fabricates `tasks/cancel`.
    public func performTaskAugmented<M: MCP.Method>(
        _ request: MCP.Request<M>,
        timeoutMilliseconds: Int? = nil
    ) async throws -> M.Result {
        guard !retired else { throw MCPClientSessionError.staleGeneration }
        guard configuration.profile == .standardExtended else {
            throw MCPTaskRuntimeError.unsupportedProfile
        }
        guard case .ready = lifecycleState else {
            throw lifecycleState == .stopped
                ? MCPClientSessionError.stopped
                : MCPClientSessionError.notReady
        }

        let tracked:
            MCPTrackedRequestContext<M.Result>
        do {
            tracked = try await beginRequest(
                request)
        } catch {
            throw sanitizedBoundaryError(
                error,
                operation: request.method)
        }
        let context = tracked.context
        let progressToken = tracked.progressToken
        let broker = inboundNotificationBroker
        let timeout = max(
            100,
            timeoutMilliseconds ?? configuration.callTimeoutMilliseconds)
        do {
            let value = try await race(
                timeoutMilliseconds: timeout,
                operation: { try await context.value },
                onTimeout: {
                    if let progressToken {
                        await broker?.finishRequest(
                            progressToken: progressToken,
                            phase: .timedOut)
                    }
                    await self.retireUnmappedTaskGeneration(
                        method: request.method)
                },
                onCancellation: {
                    if let progressToken {
                        await broker?.finishRequest(
                            progressToken: progressToken,
                            phase: .cancelled)
                    }
                    await self.retireUnmappedTaskGeneration(
                        method: request.method)
                },
                timeoutError: .taskCreationTimedOut(
                    method: request.method,
                    milliseconds: timeout),
                cancellationError: .taskCreationCancelled(
                    method: request.method))
            if let progressToken {
                await broker?.finishRequest(
                    progressToken: progressToken,
                    phase: .succeeded)
            }
            return value
        } catch {
            if let progressToken {
                await broker?.finishRequest(
                    progressToken: progressToken,
                    phase: Self.progressPhase(for: error))
            }
            if error is CancellationError {
                throw MCPClientSessionError
                    .taskCreationCancelled(
                        method: request.method)
            }
            throw sanitizedBoundaryError(
                error,
                operation: request.method)
        }
    }

    public func ping(timeoutMilliseconds: Int? = nil) async throws {
        _ = try await perform(
            Ping.request(),
            timeoutMilliseconds: timeoutMilliseconds)
    }

    public func notifyRootsChanged() async throws {
        guard configuration.profile == .standardExtended else {
            throw MCPContentOperationError.profileRequiresStandardExtended
        }
        guard !retired, case .ready = lifecycleState else {
            throw MCPClientSessionError.notReady
        }
        do {
            try await client.notifyRootsChanged()
        } catch {
            throw sanitizedBoundaryError(
                error,
                operation:
                    "notifications/roots/list_changed")
        }
    }

    /// Idempotent, bounded-by-transport shutdown. Managed transports own their
    /// read/write/process tasks and must not return from disconnect until those
    /// tasks and the process tree are drained.
    public func shutdown() async {
        if lifecycleState == .stopped { return }
        retired = true
        lifecycleState = .stopping
        if let hostedTasks = inboundServices?.hostedTasks {
            await hostedTasks.shutdown()
        }
        if let elicitation = inboundServices?.elicitation {
            await elicitation.retireGeneration()
        }
        await inboundNotificationBroker?
            .retireGeneration()
        await client.disconnect()
        inboundServices = nil
        inboundNotificationBroker = nil
        handshakeValue = nil
        lifecycleState = .stopped
    }

    private func safeReason(_ error: Error) -> String {
        let value = (error as? LocalizedError)?.errorDescription
            ?? String(describing: type(of: error))
        guard let sanitized =
                try? outputSanitizer
                    .sanitizeMCPText(value)
        else {
            return String(
                String(describing:
                    type(of: error))
                    .prefix(512))
        }
        return String(sanitized.prefix(512))
    }

    private func sanitizedBoundaryError(
        _ error: Error,
        operation: String
    ) -> Error {
        if error is MCPSanitizedExternalError {
            return error
        }
        guard let external = error as? MCPError else {
            return error
        }
        let category:
            MCPSanitizedExternalErrorCategory
        switch external {
        case .connectionClosed,
             .transportError:
            category = .transport
        case .urlElicitationRequired:
            category =
                .urlElicitationRequired
        default:
            category = .jsonRPC
        }
        return MCPSanitizedExternalError(
            operation: operation,
            category: category,
            jsonRPCCode: external.code,
            summary: safeReason(external))
    }

    private func beginRequest<M: MCP.Method>(
        _ request: MCP.Request<M>
    ) async throws -> MCPTrackedRequestContext<M.Result> {
        guard request.method == M.name else {
            throw MCPClientSessionError
                .requestCorrelationMismatch
        }
        guard let broker = inboundNotificationBroker else {
            return MCPTrackedRequestContext(
                context: try await client.send(request),
                progressToken: nil)
        }
        let progressToken = try await broker.registerRequest(
            requestID: request.id,
            method: request.method)
        do {
            let parameters =
                try MCPProgressTrackedMethod<M>.Parameters(
                    base: request.params,
                    progressToken: progressToken)
            let trackedRequest =
                MCPProgressTrackedMethod<M>.request(
                    id: request.id,
                    parameters)
            let context = try await client.send(
                trackedRequest)
            guard context.requestID == request.id else {
                await broker.finishRequest(
                    progressToken: progressToken,
                    phase: .failed)
                throw MCPClientSessionError
                    .requestCorrelationMismatch
            }
            return MCPTrackedRequestContext(
                context: context,
                progressToken: progressToken)
        } catch {
            await broker.finishRequest(
                progressToken: progressToken,
                phase: .failed)
            throw error
        }
    }

    private func configureServerLoggingIfNeeded(
        serverCapabilities: RemoteServerCapabilities
    ) async throws {
        guard serverCapabilities.logging != nil,
              let broker = inboundNotificationBroker else {
            return
        }
        let request = SetLoggingLevel.request(.init(
            level: configuration
                .inboundNotificationPolicy
                .minimumLoggingLevel))
        let tracked = try await beginRequest(request)
        let context = tracked.context
        guard let progressToken = tracked.progressToken else {
            throw MCPClientSessionError
                .requestCorrelationMismatch
        }
        let timeout = configuration.callTimeoutMilliseconds
        do {
            _ = try await race(
                timeoutMilliseconds: timeout,
                operation: { try await context.value },
                onTimeout: {
                    await broker.finishRequest(
                        progressToken: progressToken,
                        phase: .timedOut)
                    try? await self.client.cancelRequest(
                        context.requestID,
                        reason:
                            "\(IntatisHostApplication.identity.name) logging configuration timed out")
                },
                onCancellation: {
                    await broker.finishRequest(
                        progressToken: progressToken,
                        phase: .cancelled)
                    try? await self.client.cancelRequest(
                        context.requestID,
                        reason:
                            "\(IntatisHostApplication.identity.name) logging configuration cancelled")
                },
                timeoutError: .requestTimedOut(
                    method: request.method,
                    milliseconds: timeout),
                cancellationError: .requestCancelled(
                    method: request.method))
            await broker.finishRequest(
                progressToken: progressToken,
                phase: .succeeded)
        } catch {
            await broker.finishRequest(
                progressToken: progressToken,
                phase: Self.progressPhase(for: error))
            if error is CancellationError {
                throw MCPClientSessionError
                    .requestCancelled(
                        method: request.method)
            }
            throw error
        }
    }

    private nonisolated static func progressPhase(
        for error: Error
    ) -> MCPInboundProgressPhase {
        if error is CancellationError {
            return .cancelled
        }
        guard let sessionError =
                error as? MCPClientSessionError else {
            return .failed
        }
        switch sessionError {
        case .requestTimedOut, .taskCreationTimedOut:
            return .timedOut
        case .requestCancelled, .taskCreationCancelled,
             .initializeCancelled:
            return .cancelled
        default:
            return .failed
        }
    }

    private func retireUnmappedTaskGeneration(method: String) async {
        guard !retired else { return }
        retired = true
        lifecycleState = .failed(
            "unmapped task generation retired during \(method)")
        await inboundNotificationBroker?
            .retireGeneration()
        await client.disconnect()
    }

    private func installInboundSurface() async throws {
        try configuration.callbackCapabilities.validate(
            for: configuration.profile)
        let callbacks = configuration.callbackCapabilities
        if configuration.remoteTaskStatusSink != nil
            || configuration.inboundNotificationSink != nil {
            guard let fingerprint =
                    configuration.callbackAuthorityFingerprint?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                  !fingerprint.isEmpty else {
                throw MCPClientSessionError
                    .missingCallbackAuthorityFingerprint
            }
        }
        if let sink = configuration.inboundNotificationSink {
            let authority = MCPCallbackAuthorityContext(
                server: configuration.server,
                connectionGeneration: configuration.generation,
                authorityFingerprint:
                    configuration.callbackAuthorityFingerprint ?? "",
                profile: configuration.profile)
            let broker = MCPInboundNotificationBroker(
                authority: authority,
                policy: configuration.inboundNotificationPolicy,
                sanitizer: outputSanitizer,
                sink: sink)
            inboundNotificationBroker = broker
            await client.onNotification(
                LogMessageNotification.self
            ) { message in
                await broker.receiveLog(message.params)
            }
            await client.onNotification(
                ProgressNotification.self
            ) { message in
                await broker.receiveProgress(message.params)
            }
            await client.onNotification(
                CancelledNotification.self
            ) { message in
                await broker.receiveCancellation(message.params)
            }
        }
        if callbacks.isEmpty {
            guard configuration.inboundServicesFactory == nil else {
                throw MCPClientSessionError
                    .invalidInboundCapabilitySurface(
                        "a callback factory was supplied for an empty surface")
            }
        } else {
            guard let authorityFingerprint =
                    configuration.callbackAuthorityFingerprint?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                  !authorityFingerprint.isEmpty else {
                throw MCPClientSessionError
                    .missingCallbackAuthorityFingerprint
            }
            guard let factory = configuration.inboundServicesFactory else {
                throw MCPClientSessionError
                    .inboundCallbackServicesUnavailable("configured surface")
            }
            let authority = MCPCallbackAuthorityContext(
                server: configuration.server,
                connectionGeneration: configuration.generation,
                authorityFingerprint: authorityFingerprint,
                profile: configuration.profile)
            let services = try await factory.makeInboundServices(
                authority: authority,
                capabilities: callbacks,
                taskNotifications: MCPWireTaskNotificationSink(
                    client: client))
            try Self.validate(
                services: services,
                capabilities: callbacks)
            inboundServices = services
            await installCallbackHandlers(
                services: services,
                capabilities: callbacks)
        }

        let server = configuration.server
        let generation = configuration.generation
        if let sink = configuration.catalogNotificationSink {
            await client.onNotification(
                ToolListChangedNotification.self
            ) { _ in
                await sink.catalogListChanged(
                    server: server,
                    generation: generation,
                    kind: .tools)
            }
            await client.onNotification(
                ResourceListChangedNotification.self
            ) { _ in
                await sink.catalogListChanged(
                    server: server,
                    generation: generation,
                    kind: .resources)
            }
            await client.onNotification(
                PromptListChangedNotification.self
            ) { _ in
                await sink.catalogListChanged(
                    server: server,
                    generation: generation,
                    kind: .prompts)
            }
            await client.onNotification(
                ResourceUpdatedNotification.self
            ) { message in
                await sink.subscribedResourceUpdated(
                    server: server,
                    generation: generation,
                    uri: message.params.uri)
            }
        }

        if configuration.profile == .standardExtended {
            let roots = configuration.authorizedRoots?.roots ?? []
            await client.withRootsHandler {
                roots.map {
                    Root(uri: $0.uri, name: $0.name)
                }
            }
        }

        if let sink = configuration.remoteTaskStatusSink,
           configuration.profile == .standardExtended {
            let authorityFingerprint =
                configuration.callbackAuthorityFingerprint ?? ""
            let authority = MCPCallbackAuthorityContext(
                server: server,
                connectionGeneration: generation,
                authorityFingerprint: authorityFingerprint,
                profile: configuration.profile)
            await client.onNotification(
                TaskStatusNotification.self
            ) { message in
                await sink.remoteTaskStatusChanged(
                    authority: authority,
                    task: message.params)
            }
        }
    }

    private func installCallbackHandlers(
        services: MCPClientInboundServices,
        capabilities: MCPClientCallbackCapabilities
    ) async {
        if let sampling = services.sampling {
            let hostedTasks = services.hostedTasks
            await client.withSamplingHandler { parameters in
                if parameters.task != nil {
                    guard capabilities.taskSampling,
                          let hostedTasks else {
                        throw MCPTaskRuntimeError.capabilityMissing
                    }
                    return try await hostedTasks.createSamplingTask(
                        parameters: parameters,
                        broker: sampling)
                }
                return try await sampling.handle(parameters)
            }
        }

        if let elicitation = services.elicitation {
            let hostedTasks = services.hostedTasks
            await client.withElicitationHandler { parameters in
                if Self.taskMetadata(parameters) != nil {
                    guard capabilities.taskElicitation,
                          let hostedTasks else {
                        throw MCPTaskRuntimeError.capabilityMissing
                    }
                    return try await hostedTasks.createElicitationTask(
                        parameters: parameters,
                        broker: elicitation)
                }
                return try await elicitation.handle(parameters)
            }
            if capabilities.URLElicitation {
                await client.onNotification(
                    ElicitationCompleteNotification.self
                ) { message in
                    _ = await elicitation.markURLCompleted(
                        elicitationID: message.params.elicitationId)
                }
            }
        }

        if let hostedTasks = services.hostedTasks {
            await client.withMethodHandler(GetTask.self) { parameters in
                try await hostedTasks.get(taskID: parameters.taskId)
            }
            await client.withMethodHandler(GetTaskPayload.self) { parameters in
                try await hostedTasks.result(taskID: parameters.taskId)
            }
            if capabilities.taskList {
                await client.withMethodHandler(ListTasks.self) { parameters in
                    try await hostedTasks.list(cursor: parameters.cursor)
                }
            }
            if capabilities.taskCancel {
                await client.withMethodHandler(CancelTask.self) { parameters in
                    try await hostedTasks.cancel(taskID: parameters.taskId)
                }
            }
        }
    }

    private static func validate(
        services: MCPClientInboundServices,
        capabilities: MCPClientCallbackCapabilities
    ) throws {
        guard !capabilities.samplingTools || services.sampling != nil else {
            throw MCPClientSessionError
                .inboundCallbackServicesUnavailable("sampling")
        }
        guard !capabilities.hasElicitation
                || services.elicitation != nil else {
            throw MCPClientSessionError
                .inboundCallbackServicesUnavailable("elicitation")
        }
        guard !capabilities.hasTasks || services.hostedTasks != nil else {
            throw MCPClientSessionError
                .inboundCallbackServicesUnavailable("tasks")
        }
    }

    private static func taskMetadata(
        _ parameters: CreateElicitation.Parameters
    ) -> MCPTaskMetadata? {
        switch parameters {
        case .form(let form):
            return form.task
        case .url(let URLParameters):
            return URLParameters.task
        }
    }
}

private struct MCPTrackedRequestContext<Value: Sendable & Decodable>:
    Sendable
{
    let context: RequestContext<Value>
    let progressToken: ProgressToken?
}

/// Type-preserving outgoing request wrapper that inserts the connection-owned
/// progress token while retaining any caller-provided `_meta` fields.
private enum MCPProgressTrackedMethod<Base: MCP.Method>:
    MCP.Method
{
    static var name: String { Base.name }
    typealias Result = Base.Result

    struct Parameters: Codable, Hashable, Sendable {
        let value: Value

        init(
            base: Base.Parameters,
            progressToken: ProgressToken
        ) throws {
            guard case .object(var object) =
                    try Value(base) else {
                throw MCPClientSessionError
                    .invalidProgressRequestParameters
            }
            var metadata: [String: Value]
            if let existing = object["_meta"] {
                guard case .object(let fields) = existing else {
                    throw MCPClientSessionError
                        .invalidProgressRequestParameters
                }
                metadata = fields
            } else {
                metadata = [:]
            }
            switch progressToken {
            case .string(let value):
                metadata["progressToken"] = .string(value)
            case .integer(let value):
                metadata["progressToken"] = .int(value)
            }
            object["_meta"] = .object(metadata)
            value = .object(object)
        }

        init(from decoder: Decoder) throws {
            value = try Value(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
}

private struct MCPWireTaskNotificationSink:
    MCPClientTaskNotificationSink, Sendable
{
    let client: Client

    func notifyClientHostedTaskStatus(_ task: MCPTaskWire) async {
        try? await client.notify(TaskStatusNotification.message(task))
    }
}

private enum MCPRequestRaceOutcome<Value: Sendable>: Sendable {
    case value(Result<Value, Error>)
    case timedOut
    case cancelled
    case ignored
}

private final class MCPRequestRaceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

private func race<Value: Sendable>(
    timeoutMilliseconds: Int,
    operation: @escaping @Sendable () async throws -> Value,
    onTimeout: @escaping @Sendable () async -> Void,
    onCancellation: @escaping @Sendable () async -> Void,
    timeoutError: MCPClientSessionError,
    cancellationError: MCPClientSessionError
) async throws -> Value {
    let gate = MCPRequestRaceGate()
    let nanoseconds = UInt64(max(1, timeoutMilliseconds)) * 1_000_000
    let result: Result<Value, Error> = await withTaskGroup(
        of: MCPRequestRaceOutcome<Value>.self,
        returning: Result<Value, Error>.self
    ) { group in
        group.addTask {
            let result: Result<Value, Error>
            do {
                result = .success(try await operation())
            } catch {
                if Task.isCancelled, gate.claim() {
                    await onCancellation()
                    return .cancelled
                }
                result = .failure(error)
            }
            return gate.claim() ? .value(result) : .ignored
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                guard gate.claim() else { return .ignored }
                await onTimeout()
                return .timedOut
            } catch {
                guard gate.claim() else { return .ignored }
                await onCancellation()
                return .cancelled
            }
        }

        var terminal: MCPRequestRaceOutcome<Value>?
        while let next = await group.next() {
            switch next {
            case .ignored:
                continue
            default:
                terminal = next
                group.cancelAll()
            }
            if terminal != nil { break }
        }
        // The cancellation action resumes the SDK request continuation, so
        // draining both children is bounded and leaves no unowned task.
        while await group.next() != nil {}

        switch terminal {
        case .value(let result):
            return result
        case .timedOut:
            return .failure(timeoutError)
        case .cancelled:
            return .failure(cancellationError)
        case .ignored, .none:
            return .failure(cancellationError)
        }
    }
    return try result.get()
}
