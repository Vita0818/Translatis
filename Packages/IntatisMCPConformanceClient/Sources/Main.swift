import Foundation
import IntatisMCP
import IntatisProtocol
import MCP

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

@main
private enum IntatisMCPConformanceClient {
    static func main() async {
        do {
            let invocation = try Invocation.parse(
                arguments: CommandLine.arguments,
                environment: ProcessInfo.processInfo.environment)
            try await Runner(invocation: invocation).run()
        } catch {
            let summary = (error as? LocalizedError)?.errorDescription
                ?? String(describing: type(of: error))
            FileHandle.standardError.write(
                Data("Translatis MCP conformance client failed: \(summary)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
}

private struct Invocation {
    let profile: MCPProtocolProfile
    let scenario: String
    let endpoint: URL
    let context: [String: Any]

    static func parse(
        arguments: [String],
        environment: [String: String]
    ) throws -> Invocation {
        guard arguments.count == 3 else {
            throw HarnessError.invalidInvocation
        }
        let profile: MCPProtocolProfile
        switch arguments[1] {
        case MCPProtocolProfile.codexCompat.rawValue:
            profile = .codexCompat
        case MCPProtocolProfile.standardExtended.rawValue:
            profile = .standardExtended
        default:
            throw HarnessError.invalidProfile
        }
        guard let scenario = environment["MCP_CONFORMANCE_SCENARIO"],
              !scenario.isEmpty,
              let rawEndpoint = URL(string: arguments[2]) else {
            throw HarnessError.invalidInvocation
        }
        let endpoint = try normalizeLoopbackURL(rawEndpoint)
        let context: [String: Any]
        if let raw = environment["MCP_CONFORMANCE_CONTEXT"] {
            guard let data = raw.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data)
                    as? [String: Any] else {
                throw HarnessError.invalidContext
            }
            context = object
        } else {
            context = [:]
        }
        return Invocation(
            profile: profile,
            scenario: scenario,
            endpoint: endpoint,
            context: context)
    }
}

private struct Runner {
    let invocation: Invocation

    func run() async throws {
        switch invocation.scenario {
        case "initialize":
            try await runBasic(.initialize)
        case "tools_call":
            try await runBasic(.addNumbers)
        case "sse-retry":
            guard invocation.profile == .standardExtended else {
                throw HarnessError.scenarioOutsideProfile
            }
            try await runBasic(.reconnect)
        case "elicitation-sep1034-client-defaults":
            guard invocation.profile == .standardExtended else {
                throw HarnessError.scenarioOutsideProfile
            }
            try await runBasic(.elicitationDefaults)
        case "translatis/task-complete":
            try await runTaskAugmented(.complete)
        case "translatis/task-timeout":
            try await runTaskAugmented(.timeout)
        case "translatis/task-cancel":
            try await runTaskAugmented(.cancel)
        case let name where name.hasPrefix("auth/"):
            try await runOAuth()
        default:
            // The official runner and this adapter must advance together.
            // Silently treating an unknown scenario as a smoke pass would make
            // an SDK upgrade look conformant without executing the scenario.
            throw HarnessError.unknownScenario(invocation.scenario)
        }
    }

    private func runBasic(_ behavior: BasicBehavior) async throws {
        let resources = try await ConformanceResources.make()
        defer { resources.remove() }
        let generation = newGeneration()
        let callbacks: MCPClientCallbackCapabilities
        let factory: (any MCPClientInboundServicesFactory)?
        if behavior == .elicitationDefaults {
            callbacks = MCPClientCallbackCapabilities(
                formElicitation: true)
            factory = MCPBrokerInboundServicesFactory(
                events: resources.events,
                payloadStore: resources.payloads,
                elicitation: MCPElicitationHostServices(
                    policy: MCPElicitationPolicy(formEnabled: true),
                    reviewer: DefaultApplyingElicitationReviewer()))
        } else {
            callbacks = .none
            factory = nil
        }

        let session = try makeSession(
            generation: generation,
            authorization: MCPNoHTTPAuthorization(),
            callbacks: callbacks,
            inboundFactory: factory)
        do {
            _ = try await session.start()
            let listed: ListTools.Result = try await session.perform(
                ListTools.request(.init()))
            switch behavior {
            case .initialize:
                break
            case .addNumbers:
                guard listed.tools.contains(where: {
                    $0.name == "add_numbers"
                }) else {
                    throw HarnessError.expectedToolMissing("add_numbers")
                }
                let _: CallTool.Result = try await session.perform(
                    CallTool.request(.init(
                        name: "add_numbers",
                        arguments: ["a": 19, "b": 23])))
            case .reconnect:
                guard listed.tools.contains(where: {
                    $0.name == "test_reconnection"
                }) else {
                    throw HarnessError.expectedToolMissing(
                        "test_reconnection")
                }
                let _: CallTool.Result = try await session.perform(
                    CallTool.request(.init(
                        name: "test_reconnection",
                        arguments: [:])),
                    timeoutMilliseconds: 5_000)
            case .elicitationDefaults:
                guard listed.tools.contains(where: {
                    $0.name == "test_client_elicitation_defaults"
                }) else {
                    throw HarnessError.expectedToolMissing(
                        "test_client_elicitation_defaults")
                }
                let _: CallTool.Result = try await session.perform(
                    CallTool.request(.init(
                        name: "test_client_elicitation_defaults",
                        arguments: [:])),
                    timeoutMilliseconds: 5_000)
            }
            await session.shutdown()
        } catch {
            await session.shutdown()
            throw error
        }
    }

    private func runOAuth() async throws {
        guard Self.oauthScenarios.contains(invocation.scenario) else {
            throw HarnessError.unknownScenario(invocation.scenario)
        }
        if invocation.profile == .codexCompat {
            guard Self.codexOAuthScenarios.contains(invocation.scenario) else {
                throw HarnessError.scenarioOutsideProfile
            }
        }

        let resources = try await ConformanceResources.make()
        defer { resources.remove() }
        let oauth = try await OAuthResources.make(
            endpoint: invocation.endpoint,
            scenario: invocation.scenario,
            context: invocation.context,
            directory: resources.directory)

        var currentScopes: Set<String> = []
        var authorizationAttempts = 0
        var session = try makeSession(
            generation: newGeneration(),
            authorization: MCPNoHTTPAuthorization())
        do {
            do {
                _ = try await session.start()
            } catch {
                guard let challenge = normalizedChallenge(error) else {
                    throw error
                }
                await session.shutdown()
                let authenticated = try await oauth.authenticate(
                    challenge: challenge,
                    currentScopes: currentScopes,
                    attempt: authorizationAttempts + 1)
                currentScopes = authenticated.scopes
                authorizationAttempts += 1
                session = try makeSession(
                    generation: authenticated.generation,
                    authorization: authenticated.provider)
                _ = try await session.start()
            }

            while true {
                do {
                    let listed: ListTools.Result = try await session.perform(
                        ListTools.request(.init()))
                    guard listed.tools.contains(where: {
                        $0.name == "test-tool"
                    }) else {
                        throw HarnessError.expectedToolMissing("test-tool")
                    }
                    break
                } catch {
                    guard let challenge = normalizedChallenge(error),
                          authorizationAttempts < 3 else {
                        throw error
                    }
                    await session.shutdown()
                    let authenticated = try await oauth.authenticate(
                        challenge: challenge,
                        currentScopes: currentScopes,
                        attempt: authorizationAttempts + 1)
                    currentScopes = authenticated.scopes
                    authorizationAttempts += 1
                    session = try makeSession(
                        generation: authenticated.generation,
                        authorization: authenticated.provider)
                    _ = try await session.start()
                }
            }

            while true {
                do {
                    let _: CallTool.Result = try await session.perform(
                        CallTool.request(.init(
                            name: "test-tool",
                            arguments: [:])))
                    break
                } catch {
                    guard let challenge = normalizedChallenge(error),
                          authorizationAttempts < 3 else {
                        throw error
                    }
                    await session.shutdown()
                    let authenticated = try await oauth.authenticate(
                        challenge: challenge,
                        currentScopes: currentScopes,
                        attempt: authorizationAttempts + 1)
                    currentScopes = authenticated.scopes
                    authorizationAttempts += 1
                    session = try makeSession(
                        generation: authenticated.generation,
                        authorization: authenticated.provider)
                    _ = try await session.start()
                }
            }
            await session.shutdown()
        } catch {
            await session.shutdown()
            throw error
        }
    }

    private func runTaskAugmented(
        _ behavior: TaskBehavior
    ) async throws {
        guard invocation.profile == .standardExtended else {
            throw HarnessError.scenarioOutsideProfile
        }
        let resources = try await ConformanceResources.make()
        defer { resources.remove() }
        let generation = newGeneration()
        let authority = MCPRemoteTaskAuthority(
            server: Self.server,
            connectionGeneration: generation,
            authorityFingerprint: String(repeating: "a", count: 64))
        let manager = MCPRemoteTaskManager(
            authority: authority,
            profile: .standardExtended,
            supportsGetAndResult: false,
            supportsCancel: false,
            policy: MCPTaskRuntimePolicy(
                minimumPollIntervalMilliseconds: 50,
                maximumPollIntervalMilliseconds: 100),
            events: resources.events,
            payloadStore: resources.payloads)
        let callbacks = MCPClientCallbackCapabilities.complete(
            for: .standardExtended)
        let inboundFactory = MCPBrokerInboundServicesFactory(
            events: resources.events,
            payloadStore: resources.payloads,
            sampling: MCPSamplingHostServices(
                policy: MCPSamplingPolicy(enabled: false),
                reviewer: MCPDenyAllSamplingReviewService(),
                inference: RejectingSamplingInference()),
            elicitation: MCPElicitationHostServices(
                policy: MCPElicitationPolicy(),
                reviewer: MCPDenyAllElicitationReviewService()))
        let session = try makeSession(
            generation: generation,
            authorization: MCPNoHTTPAuthorization(),
            callbacks: callbacks,
            inboundFactory: inboundFactory)
        let client = MCPClientSessionConnectionClient(
            session: session,
            remoteTaskManager: manager)
        do {
            _ = try await client.startup(
                profile: .standardExtended,
                maximumProtocolVersion: .v2025_11_25)
            switch behavior {
            case .complete:
                let result = try await client
                    .callToolTaskAugmentedAndAwait(
                        name: "long_task",
                        arguments: [:],
                        ttlMilliseconds: 60_000,
                        originatingToolCallID: "conformance-call",
                        timeoutMilliseconds: 5_000)
                guard result.content.contains(where: {
                    if case .text(let text) = $0 {
                        return text == "task complete"
                    }
                    return false
                }) else {
                    throw HarnessError.unexpectedTaskResult
                }
            case .timeout:
                var unexpectedlySucceeded = false
                do {
                    _ = try await client.callToolTaskAugmentedAndAwait(
                        name: "long_task",
                        arguments: [:],
                        ttlMilliseconds: 60_000,
                        originatingToolCallID: "conformance-timeout",
                        timeoutMilliseconds: 450)
                    unexpectedlySucceeded = true
                } catch {
                    // Timeout is expected; the peer runner separately asserts
                    // that tasks/cancel was sent after the task was mapped.
                }
                if unexpectedlySucceeded {
                    throw HarnessError.expectedTaskFailure
                }
            case .cancel:
                let operation = Task {
                    try await client.callToolTaskAugmentedAndAwait(
                        name: "long_task",
                        arguments: [:],
                        ttlMilliseconds: 60_000,
                        originatingToolCallID: "conformance-cancel",
                        timeoutMilliseconds: 5_000)
                }
                try await Task.sleep(nanoseconds: 250_000_000)
                operation.cancel()
                do {
                    _ = try await operation.value
                    throw HarnessError.expectedTaskFailure
                } catch is CancellationError {
                    break
                } catch {
                    throw HarnessError.unexpectedTaskCancellation
                }
            }
            await client.shutdownAndDrain(reason: "conformance complete")
        } catch {
            await client.shutdownAndDrain(reason: "conformance failed")
            throw error
        }
    }

    private func makeSession(
        generation: MCPConnectionGeneration,
        authorization: any MCPHTTPAuthorizationProviding,
        callbacks: MCPClientCallbackCapabilities = .none,
        inboundFactory:
            (any MCPClientInboundServicesFactory)? = nil
    ) throws -> MCPClientSession {
        let configuration = try conformanceHTTPConfiguration(
            invocation.endpoint)
        let transport = try MCPStreamableHTTPTransport(
            configuration: configuration,
            generation: generation,
            authorizationProvider: authorization,
            requestTimeoutMilliseconds: 10_000,
            shutdownTimeoutMilliseconds: 1_000,
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        return MCPClientSession(
            configuration: MCPClientSessionConfiguration(
                server: Self.server,
                generation: generation,
                profile: invocation.profile,
                startupTimeoutMilliseconds: 10_000,
                callTimeoutMilliseconds: 10_000,
                clientName: "translatis-conformance-client",
                clientVersion: "1.0.0",
                callbackCapabilities: callbacks,
                callbackAuthorityFingerprint:
                    callbacks.isEmpty
                        ? nil : String(repeating: "c", count: 64),
                inboundServicesFactory: inboundFactory),
            transport: transport)
    }

    private func normalizedChallenge(
        _ error: Error
    ) -> MCPOAuthChallenge? {
        guard case .authenticationRequired(let challenge) =
                error as? MCPHTTPTransportError else {
            return nil
        }
        return MCPOAuthChallenge(
            statusCode: challenge.statusCode,
            resourceMetadataURL: challenge.resourceMetadataURL.flatMap {
                try? normalizeLoopbackURL($0)
            },
            requiredScopes: challenge.requiredScopes,
            errorCode: challenge.errorCode,
            sideEffectsUncertain: challenge.sideEffectsUncertain)
    }

    private func newGeneration() -> MCPConnectionGeneration {
        MCPConnectionGeneration(
            rawValue:
                "mcpcnx_conformance_\(UUID().uuidString.lowercased())")
    }

    private static let server = MCPServerReference(
        serverID: MCPServerID(rawValue: "mcp_conformance_server"),
        serverRevision: MCPServerRevision(
            rawValue: "mcpsrvrev_conformance_0_1_16"))

    private static let codexOAuthScenarios: Set<String> = [
        "auth/token-endpoint-auth-basic",
        "auth/token-endpoint-auth-post",
        "auth/token-endpoint-auth-none",
    ]

    private static let oauthScenarios: Set<String> =
        codexOAuthScenarios.union([
            "auth/metadata-default",
            "auth/metadata-var1",
            "auth/metadata-var2",
            "auth/metadata-var3",
            "auth/basic-cimd",
            "auth/scope-from-www-authenticate",
            "auth/scope-from-scopes-supported",
            "auth/scope-omitted-when-undefined",
            "auth/scope-step-up",
            "auth/scope-retry-limit",
            "auth/pre-registration",
        ])
}

private enum BasicBehavior {
    case initialize
    case addNumbers
    case reconnect
    case elicitationDefaults
}

private enum TaskBehavior {
    case complete
    case timeout
    case cancel
}

private struct ConformanceResources {
    let directory: URL
    let events: ConformanceEventSink
    let payloads: MCPSecretBackedBrokerPayloadStore

    static func make() async throws -> ConformanceResources {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "translatis-mcp-conformance-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let store = MCPCLIEncryptedSecretStore(
            fileURL: directory.appendingPathComponent("secrets.bin"))
        try await store.initialize(
            passphrase: Data(
                "translatis-conformance-disposable-key".utf8))
        let events = try ConformanceEventSink(
            fileURL: directory.appendingPathComponent("events.jsonl"))
        return ConformanceResources(
            directory: directory,
            events: events,
            payloads: MCPSecretBackedBrokerPayloadStore(
                secretStore: store))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ConformanceEventSink: MCPBrokerEventSink {
    private let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        guard FileManager.default.createFile(
            atPath: fileURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]) else {
            throw HarnessError.persistenceFailed
        }
    }

    func appendMCPBrokerEvent(_ event: Event) async throws {
        try append([event])
    }

    func appendMCPBrokerEvents(_ events: [Event]) async throws {
        try append(events)
    }

    private func append(_ events: [Event]) throws {
        var bytes = Data()
        for _ in events {
            // The disposable harness records a durable lifecycle edge without
            // copying callback payloads into ordinary diagnostics. Production
            // hosts persist the typed Event through their EventLog adapter.
            bytes.append(
                Data(#"{"event":"mcp_broker_event"}"#.utf8))
            bytes.append(0x0a)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }
}

private struct DefaultApplyingElicitationReviewer:
    MCPElicitationReviewService
{
    func reviewElicitation(
        _ presentation: MCPElicitationPresentation
    ) async throws -> MCPElicitationReview {
        guard case .form(let form) = presentation.parameters else {
            return .decline(reasonCode: "conformance_form_only")
        }
        var content: [String: Value] = [:]
        for (name, schema) in form.requestedSchema.properties {
            guard case .object(let fields) = schema,
                  let defaultValue = fields["default"] else {
                continue
            }
            content[name] = defaultValue
        }
        return .accept(content: content)
    }
}

private struct RejectingSamplingInference:
    MCPSamplingInferenceService
{
    func createSamplingMessage(
        parameters _: CreateSamplingMessage.Parameters,
        inferenceBinding _: AgentInferenceBinding
    ) async throws -> CreateSamplingMessage.Result {
        throw HarnessError.unexpectedInboundCallback
    }
}

private struct OAuthResources {
    struct Authentication {
        let provider: MCPOAuthAuthorizationProvider
        let generation: MCPConnectionGeneration
        let scopes: Set<String>
    }

    let endpoint: URL
    let scenario: String
    let configuration: MCPOAuthConfiguration
    let coordinator: MCPOAuthCoordinator
    let vault: MCPOAuthCredentialVault
    let redirectURI: URL

    static func make(
        endpoint: URL,
        scenario: String,
        context: [String: Any],
        directory: URL
    ) async throws -> OAuthResources {
        let store = MCPCLIEncryptedSecretStore(
            fileURL: directory.appendingPathComponent("oauth-secrets.bin"))
        try await store.initialize(
            passphrase: Data(
                "translatis-oauth-conformance-key".utf8))
        let vault = MCPOAuthCredentialVault(secretStore: store)
        let base = MCPURLSessionOAuthHTTPClient(
            egressAuthorizer: MCPExactOriginEgressPolicy(
                allowsLoopback: true))
        let coordinator = MCPOAuthCoordinator(
            httpClient: LoopbackMetadataRewritingOAuthHTTPClient(base: base),
            vault: vault,
            secretStore: store)

        var clientID: String?
        var secretReference: MCPSecretReference?
        if scenario == "auth/pre-registration" {
            guard let id = context["client_id"] as? String,
                  let secret = context["client_secret"] as? String else {
                throw HarnessError.invalidContext
            }
            clientID = id
            secretReference = try await store.store(
                Data(secret.utf8),
                sourceBindingFingerprint:
                    String(repeating: "d", count: 64))
        }
        let configuration = try conformanceOAuthConfiguration(
            endpoint: endpoint,
            clientID: clientID,
            clientSecretReference: secretReference)
        return OAuthResources(
            endpoint: endpoint,
            scenario: scenario,
            configuration: configuration,
            coordinator: coordinator,
            vault: vault,
            redirectURI: URL(
                string: "http://127.0.0.1:39001/callback")!)
    }

    func authenticate(
        challenge: MCPOAuthChallenge,
        currentScopes: Set<String>,
        attempt: Int
    ) async throws -> Authentication {
        guard (1...3).contains(attempt) else {
            throw HarnessError.oauthRetryLimit
        }
        let discovery = try await coordinator.discover(
            endpoint: endpoint,
            configuredResource: endpoint,
            challenge: challenge)
        let challengeScopes = challenge.requiredScopes
        let discoveredScopes = Set(
            discovery.protectedResourceMetadata.scopesSupported ?? [])
        let requested: Set<String>
        if !challengeScopes.isEmpty {
            requested = currentScopes.union(challengeScopes)
        } else if currentScopes.isEmpty {
            requested = discoveredScopes
        } else {
            requested = currentScopes
        }

        let metadataDocument = scenario == "auth/basic-cimd"
            ? URL(
                string:
                    "https://conformance-test.local/client-metadata.json")
            : nil
        let policy = MCPOAuthLoginPolicy(
            allowDynamicClientRegistration:
                scenario != "auth/basic-cimd"
                    && scenario != "auth/pre-registration",
            clientMetadataDocumentURL: metadataDocument,
            registeredRedirectURIs: [redirectURI])
        let login = try await coordinator.beginLogin(
            serverID: MCPServerID(
                rawValue: "mcp_conformance_server"),
            accountReference: MCPAccountReference(
                rawValue: "mcpacct_conformance"),
            configuration: configuration,
            discovery: discovery,
            redirectPolicy: .registered(redirectURI),
            loginPolicy: policy,
            requiredScopes: requested)
        let callback = try await fetchAuthorizationRedirect(
            login.authorizationURL,
            expectedRedirect: redirectURI)
        let token = try await coordinator.completeLogin(
            login,
            callbackURL: callback)
        let generation = MCPConnectionGeneration(
            rawValue:
                "mcpcnx_conformance_auth_\(UUID().uuidString.lowercased())")
        return Authentication(
            provider: MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: token,
                connectionGeneration: generation),
            generation: generation,
            scopes: token.scopes)
    }
}

private struct LoopbackMetadataRewritingOAuthHTTPClient:
    MCPOAuthHTTPClient
{
    let base: any MCPOAuthHTTPClient

    func send(
        _ request: URLRequest,
        allowedOrigin: String
    ) async throws -> MCPOAuthHTTPResponse {
        var normalized = request
        if let url = request.url {
            normalized.url = try normalizeLoopbackURL(url)
        }
        let normalizedOrigin = try canonicalOrigin(
            normalized.url ?? request.url!)
        let response = try await base.send(
            normalized,
            allowedOrigin: normalizedOrigin)
        guard let contentType = response.headers.first(where: {
            $0.key.caseInsensitiveCompare("Content-Type")
                == .orderedSame
        })?.value,
              contentType.lowercased().contains("application/json"),
              let body = String(data: response.body, encoding: .utf8) else {
            return response
        }
        let rewritten = body.replacingOccurrences(
            of: "http://localhost:",
            with: "http://127.0.0.1:")
        return MCPOAuthHTTPResponse(
            statusCode: response.statusCode,
            headers: response.headers,
            body: Data(rewritten.utf8))
    }
}

private final class NoRedirectDelegate:
    NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func fetchAuthorizationRedirect(
    _ authorizationURL: URL,
    expectedRedirect: URL
) async throws -> URL {
    let normalized = try normalizeLoopbackURL(authorizationURL)
    guard normalized.scheme?.lowercased() == "http",
          normalized.host == "127.0.0.1" else {
        throw HarnessError.unsafeAuthorizationURL
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    let session = URLSession(
        configuration: configuration,
        delegate: NoRedirectDelegate(),
        delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (_, rawResponse) = try await session.data(from: normalized)
    guard let response = rawResponse as? HTTPURLResponse,
          (300..<400).contains(response.statusCode),
          let location = response.value(
            forHTTPHeaderField: "Location"),
          let callback = URL(string: location),
          try canonicalOrigin(callback)
            == canonicalOrigin(expectedRedirect) else {
        throw HarnessError.invalidAuthorizationRedirect
    }
    return callback
}

private struct HTTPConfigurationWire: Codable {
    let endpoint: String
    let canonicalOrigin: String
    let allowInsecureLoopbackDevelopmentHTTP: Bool
    let headers: [String: MCPConfiguredValue]
    let bearerTokenReference: MCPSecretReference?
    let oauth: MCPOAuthConfiguration?
    let redirectPolicy: MCPHTTPRedirectPolicy
    let proxyPolicy: MCPHTTPProxyPolicy
    let tlsPolicy: MCPTLSPolicy
}

private func conformanceHTTPConfiguration(
    _ endpoint: URL
) throws -> MCPHTTPServerConfiguration {
    // Production catalog construction remains HTTPS-only. The official
    // conformance runner intentionally binds an ephemeral cleartext loopback
    // peer, so this development-only executable decodes a loopback-only wire
    // value after independently enforcing the exact numeric host.
    guard endpoint.scheme?.lowercased() == "http",
          endpoint.host == "127.0.0.1" else {
        throw HarnessError.nonLoopbackFixture
    }
    let wire = HTTPConfigurationWire(
        endpoint: endpoint.absoluteString,
        canonicalOrigin: try canonicalOrigin(endpoint),
        allowInsecureLoopbackDevelopmentHTTP: true,
        headers: [:],
        bearerTokenReference: nil,
        oauth: nil,
        redirectPolicy: .sameOriginOnly,
        proxyPolicy: .direct,
        tlsPolicy: .systemTrust)
    return try JSONDecoder().decode(
        MCPHTTPServerConfiguration.self,
        from: JSONEncoder().encode(wire))
}

private struct OAuthConfigurationWire: Codable {
    let enabled: Bool
    let canonicalResource: String
    let clientID: String?
    let clientSecretReference: MCPSecretReference?
    let scopes: [String]
    let accountReference: MCPAccountReference?
}

private func conformanceOAuthConfiguration(
    endpoint: URL,
    clientID: String?,
    clientSecretReference: MCPSecretReference?
) throws -> MCPOAuthConfiguration {
    let wire = OAuthConfigurationWire(
        enabled: true,
        canonicalResource: endpoint.absoluteString,
        clientID: clientID,
        clientSecretReference: clientSecretReference,
        scopes: [],
        accountReference: MCPAccountReference(
            rawValue: "mcpacct_conformance"))
    return try JSONDecoder().decode(
        MCPOAuthConfiguration.self,
        from: JSONEncoder().encode(wire))
}

private func normalizeLoopbackURL(_ url: URL) throws -> URL {
    guard var components = URLComponents(
        url: url,
        resolvingAgainstBaseURL: false),
          let host = components.host?.lowercased(),
          host == "localhost" || host == "127.0.0.1",
          components.user == nil, components.password == nil else {
        throw HarnessError.nonLoopbackFixture
    }
    components.host = "127.0.0.1"
    guard let normalized = components.url else {
        throw HarnessError.nonLoopbackFixture
    }
    return normalized
}

private func canonicalOrigin(_ url: URL) throws -> String {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http",
          url.host == "127.0.0.1",
          let port = url.port else {
        throw HarnessError.nonLoopbackFixture
    }
    return "\(scheme)://127.0.0.1:\(port)"
}

private enum HarnessError: Error, LocalizedError {
    case invalidInvocation
    case invalidProfile
    case invalidContext
    case unknownScenario(String)
    case scenarioOutsideProfile
    case expectedToolMissing(String)
    case nonLoopbackFixture
    case persistenceFailed
    case oauthRetryLimit
    case unsafeAuthorizationURL
    case invalidAuthorizationRedirect
    case unexpectedTaskResult
    case expectedTaskFailure
    case unexpectedTaskCancellation
    case unexpectedInboundCallback

    var errorDescription: String? {
        switch self {
        case .invalidInvocation:
            return "expected <codex-compat|standard-extended> <server-url>"
        case .invalidProfile:
            return "unknown MCP conformance profile"
        case .invalidContext:
            return "invalid official conformance scenario context"
        case .unknownScenario(let value):
            return "unknown or unimplemented official scenario \(value)"
        case .scenarioOutsideProfile:
            return "official scenario is outside the selected MCP profile"
        case .expectedToolMissing(let name):
            return "official fixture did not publish expected tool \(name)"
        case .nonLoopbackFixture:
            return "official conformance fixture must be exact loopback HTTP"
        case .persistenceFailed:
            return "conformance lifecycle evidence could not be persisted"
        case .oauthRetryLimit:
            return "OAuth authorization retry limit reached"
        case .unsafeAuthorizationURL:
            return "OAuth authorization URL left the loopback fixture"
        case .invalidAuthorizationRedirect:
            return "OAuth authorization redirect was invalid"
        case .unexpectedTaskResult:
            return "task-augmented tools/call returned an unexpected result"
        case .expectedTaskFailure:
            return "task-augmented timeout/cancel scenario unexpectedly succeeded"
        case .unexpectedTaskCancellation:
            return "task-augmented cancellation did not surface as cancellation"
        case .unexpectedInboundCallback:
            return "the task fixture attempted an unrelated inbound callback"
        }
    }
}
