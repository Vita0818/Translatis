import Foundation
import IntatisMCP
import IntatisProtocol
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class MCPOAuthTests: XCTestCase {
    func testDiscoveryUsesChallengePRMThenRFC8414OIDCOrder()
        async throws
    {
        let client = OAuthScriptHTTPClient([
            .init(
                path: "/challenge-prm",
                response: jsonResponse([
                    "resource": "https://mcp.example.test/mcp",
                    "authorization_servers": [
                        "https://auth.example.test/tenant"
                    ],
                    "scopes_supported": ["read", "write"],
                ])),
            .init(
                path:
                    "/.well-known/oauth-authorization-server/tenant",
                response: .init(
                    statusCode: 404,
                    headers: ["Content-Type": "application/json"],
                    body: Data())),
            .init(
                path: "/.well-known/openid-configuration/tenant",
                response: authorizationMetadataResponse(
                    issuer: "https://auth.example.test/tenant")),
        ])
        let coordinator = makeCoordinator(client: client).coordinator
        let challenge = MCPOAuthChallenge(
            statusCode: 401,
            resourceMetadataURL: URL(
                string:
                    "https://mcp.example.test/challenge-prm"),
            requiredScopes: ["read"],
            errorCode: "insufficient_scope")

        let result = try await coordinator.discover(
            endpoint: URL(
                string: "https://mcp.example.test/mcp")!,
            configuredResource: URL(
                string: "https://mcp.example.test/mcp")!,
            challenge: challenge)
        XCTAssertEqual(
            result.protectedResourceMetadataURL.path,
            "/challenge-prm")
        XCTAssertEqual(
            result.authorizationServerMetadataURL.path,
            "/.well-known/openid-configuration/tenant")
        let requests = await client.requests()
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/challenge-prm",
                "/.well-known/oauth-authorization-server/tenant",
                "/.well-known/openid-configuration/tenant",
            ])
    }

    func testDiscoveryRejectsCrossOriginChallengeMetadata() async throws {
        let client = OAuthScriptHTTPClient([])
        let coordinator = makeCoordinator(client: client).coordinator
        let challenge = MCPOAuthChallenge(
            statusCode: 401,
            resourceMetadataURL: URL(
                string: "https://attacker.example/prm"),
            requiredScopes: [],
            errorCode: nil)
        do {
            _ = try await coordinator.discover(
                endpoint: URL(
                    string: "https://mcp.example.test/mcp")!,
                configuredResource: URL(
                    string: "https://mcp.example.test/mcp")!,
                challenge: challenge)
            XCTFail("Expected origin rejection")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .originMismatch)
        }
        let rejectedRequests = await client.requests()
        XCTAssertTrue(rejectedRequests.isEmpty)
    }

    func testLoginBuildsPKCEStateNonceResourceAndStoresOnlyHandle()
        async throws
    {
        let client = OAuthScriptHTTPClient([
            .init(
                path: "/token",
                response: jsonResponse([
                    "access_token": "access-secret",
                    "refresh_token": "refresh-secret",
                    "token_type": "Bearer",
                    "expires_in": 3600,
                    "scope": "read",
                ])),
        ])
        let components = makeCoordinator(client: client)
        let config = try oauthConfiguration(
            clientID: "registered-client",
            scopes: ["read"])
        let attempt = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: config,
            discovery: discoveryFixture(),
            redirectPolicy: .ephemeralIPv4(port: 51_423))
        let query = queryItems(attempt.authorizationURL)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertNotNil(query["code_challenge"])
        XCTAssertNotNil(query["state"])
        XCTAssertNotNil(query["nonce"])
        XCTAssertEqual(
            query["resource"],
            "https://mcp.example.test/mcp")
        XCTAssertEqual(query["scope"], "read")
        XCTAssertFalse(
            attempt.description.contains(query["state"] ?? "never"))

        let callback = URL(
            string:
                "\(attempt.redirectURI.absoluteString)?code=auth-code&state=\(query["state"]!)")!
        let handle = try await components.coordinator.completeLogin(
            attempt,
            callbackURL: callback)
        XCTAssertEqual(handle.generation.rawValue, 1)
        XCTAssertEqual(handle.scopes, ["read"])
        XCTAssertFalse(handle.description.contains("access-secret"))
        XCTAssertFalse(handle.description.contains("refresh-secret"))
        let encoded = String(
            decoding: try JSONEncoder().encode(handle),
            as: UTF8.self)
        XCTAssertFalse(encoded.contains("access-secret"))
        XCTAssertFalse(encoded.contains("refresh-secret"))

        let connection = MCPConnectionGeneration(
            rawValue: "mcpcnx_oauth")
        let provider = MCPOAuthAuthorizationProvider(
            vault: components.vault,
            handle: handle,
            connectionGeneration: connection)
        let header = try await provider.authorizationHeader(
            for: URL(
                string: "https://mcp.example.test/mcp")!,
            connectionGeneration: connection)
        XCTAssertEqual(header, "Bearer access-secret")
        do {
            _ = try await provider.authorizationHeader(
                for: URL(
                    string: "https://other.example/mcp")!,
                connectionGeneration: connection)
            XCTFail("Expected audience fence")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .authorityMismatch)
        }
    }

    func testWrongStateConsumesAttemptAndLateCallbackCannotReviveIt()
        async throws
    {
        let client = OAuthScriptHTTPClient([])
        let components = makeCoordinator(client: client)
        let attempt = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: try oauthConfiguration(
                clientID: "registered-client"),
            discovery: discoveryFixture(),
            redirectPolicy: .ephemeralIPv4(port: 51_424))
        let wrong = URL(
            string:
                "\(attempt.redirectURI.absoluteString)?code=auth-code&state=wrong")!
        do {
            _ = try await components.coordinator.completeLogin(
                attempt,
                callbackURL: wrong)
            XCTFail("Expected state rejection")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .stateMismatch)
        }
        let state = queryItems(attempt.authorizationURL)["state"]!
        let late = URL(
            string:
                "\(attempt.redirectURI.absoluteString)?code=auth-code&state=\(state)")!
        do {
            _ = try await components.coordinator.completeLogin(
                attempt,
                callbackURL: late)
            XCTFail("Expected stale generation")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .staleLoginGeneration)
        }
        let lateRequests = await client.requests()
        XCTAssertTrue(lateRequests.isEmpty)
    }

    func testNewLoginGenerationInvalidatesOlderAttempt() async throws {
        let client = OAuthScriptHTTPClient([])
        let components = makeCoordinator(client: client)
        let config = try oauthConfiguration(
            clientID: "registered-client")
        let first = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: config,
            discovery: discoveryFixture(),
            redirectPolicy: .ephemeralIPv4(port: 51_425))
        let second = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: config,
            discovery: discoveryFixture(),
            redirectPolicy: .ephemeralIPv4(port: 51_426))
        XCTAssertGreaterThan(second.generation, first.generation)
        let state = queryItems(first.authorizationURL)["state"]!
        do {
            _ = try await components.coordinator.completeLogin(
                first,
                callbackURL: URL(
                    string:
                        "\(first.redirectURI.absoluteString)?code=x&state=\(state)")!)
            XCTFail("Expected stale generation")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .staleLoginGeneration)
        }
    }

    func testRefreshIsSingleFlightAndPreservesOldRefreshToken()
        async throws
    {
        let client = OAuthScriptHTTPClient([
            .init(
                path: "/token",
                delayNanoseconds: 50_000_000,
                response: jsonResponse([
                    "access_token": "access-two",
                    "token_type": "Bearer",
                    "scope": "read",
                ])),
            .init(
                path: "/token",
                response: jsonResponse([
                    "access_token": "access-three",
                    "token_type": "Bearer",
                    "scope": "read",
                ])),
        ])
        let components = makeCoordinator(client: client)
        let authority = try MCPOAuthAuthorityIdentity(
            serverID: .init(rawValue: "mcpserver_oauth"),
            canonicalOrigin: "https://mcp.example.test",
            canonicalResource:
                "https://mcp.example.test/mcp",
            accountReference: .init(rawValue: "account_one"),
            clientID: "registered-client")
        let original = try await components.vault.storeToken(
            authority: authority,
            accessToken: "access-one",
            refreshToken: "refresh-one",
            tokenType: "Bearer",
            scopes: ["read"],
            expiresAt: Date().addingTimeInterval(-60),
            authorizationServer: URL(
                string: "https://auth.example.test")!,
            clientID: "registered-client",
            generation: .init(rawValue: 1))
        async let first = components.coordinator.refresh(
            original,
            discovery: discoveryFixture())
        async let second = components.coordinator.refresh(
            original,
            discovery: discoveryFixture())
        let (one, two) = try await (first, second)
        XCTAssertEqual(one, two)
        XCTAssertEqual(one.generation.rawValue, 2)
        let singleFlightRequests = await client.requests()
        XCTAssertEqual(singleFlightRequests.count, 1)
        let oldProvider = MCPOAuthAuthorizationProvider(
            vault: components.vault,
            handle: original,
            connectionGeneration: .init(
                rawValue: "mcpcnx_old_oauth"))
        do {
            _ = try await oldProvider.authorizationHeader(
                for: URL(
                    string: "https://mcp.example.test/mcp")!,
                connectionGeneration: .init(
                    rawValue: "mcpcnx_old_oauth"))
            XCTFail("Refresh must retire the old token generation")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .staleCredentialGeneration)
        }

        let three = try await components.coordinator.refresh(
            one,
            discovery: discoveryFixture())
        XCTAssertEqual(three.generation.rawValue, 3)
        let requests = await client.requests()
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let body = String(
                decoding: request.httpBody ?? Data(),
                as: UTF8.self)
            XCTAssertTrue(body.contains("refresh_token=refresh-one"))
            XCTAssertTrue(
                body.contains(
                    "resource=https%3A%2F%2Fmcp.example.test%2Fmcp"))
        }

        try await components.coordinator.logout(
            three,
            discovery: nil)
        let exists = try await components.vault.tokenExists(three)
        XCTAssertFalse(exists)
    }

    func testClientIDMetadataDocumentPrecedesDynamicRegistration()
        async throws
    {
        let client = OAuthScriptHTTPClient([])
        let components = makeCoordinator(client: client)
        let document = URL(
            string: "https://client.example/intatis.json")!
        let attempt = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: try oauthConfiguration(clientID: nil),
            discovery: discoveryFixture(
                supportsClientMetadataDocument: true,
                registrationEndpoint:
                    "https://auth.example.test/register"),
            redirectPolicy: .ephemeralIPv4(port: 51_427),
            loginPolicy: .init(
                allowDynamicClientRegistration: true,
                clientMetadataDocumentURL: document))
        XCTAssertEqual(
            queryItems(attempt.authorizationURL)["client_id"],
            document.absoluteString)
        let metadataDocumentRequests = await client.requests()
        XCTAssertTrue(metadataDocumentRequests.isEmpty)
    }

    func testDynamicRegistrationRequiresExplicitPolicyAndPersists()
        async throws
    {
        let client = OAuthScriptHTTPClient([
            .init(
                path: "/register",
                response: jsonResponse([
                    "client_id": "dynamic-client",
                    "client_secret": "dynamic-secret",
                    "token_endpoint_auth_method":
                        "client_secret_basic",
                ])),
        ])
        let components = makeCoordinator(client: client)
        let discovery = discoveryFixture(
            supportsClientMetadataDocument: false,
            registrationEndpoint:
                "https://auth.example.test/register")
        do {
            _ = try await components.coordinator.beginLogin(
                serverID: .init(rawValue: "mcpserver_oauth"),
                accountReference: .init(rawValue: "account_one"),
                configuration: try oauthConfiguration(clientID: nil),
                discovery: discovery,
                redirectPolicy: .ephemeralIPv4(port: 51_428))
            XCTFail("Expected DCR policy gate")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .clientRegistrationRequired)
        }

        let attempt = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: try oauthConfiguration(clientID: nil),
            discovery: discovery,
            redirectPolicy: .ephemeralIPv4(port: 51_428),
            loginPolicy: .init(
                allowDynamicClientRegistration: true))
        XCTAssertEqual(
            queryItems(attempt.authorizationURL)["client_id"],
            "dynamic-client")
        let registrationRequests = await client.requests()
        XCTAssertEqual(registrationRequests.count, 1)
        let rawStore = await components.store.allRawValues()
        XCTAssertEqual(rawStore.count, 1)
        XCTAssertFalse(
            String(
                decoding:
                    try JSONEncoder().encode(
                        attempt.authorizationURL.absoluteString),
                as: UTF8.self
            ).contains("dynamic-secret"))
    }

    func testScopeStepUpUsesOnlyExplicitChallengeScopes() async throws {
        let components = makeCoordinator(
            client: OAuthScriptHTTPClient([]))
        let scopes = try await components.coordinator.stepUpScopes(
            current: ["read"],
            challenge: .init(
                statusCode: 403,
                resourceMetadataURL: nil,
                requiredScopes: ["write:item"],
                errorCode: "insufficient_scope"))
        XCTAssertEqual(scopes, ["read", "write:item"])
        do {
            _ = try await components.coordinator.stepUpScopes(
                current: scopes,
                challenge: .init(
                    statusCode: 403,
                    resourceMetadataURL: nil,
                    requiredScopes: [],
                    errorCode: nil))
            XCTFail("Expected empty challenge rejection")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .invalidScopeChallenge)
        }
    }

    func testLoopbackPolicyRejectsWildcardAndTokenAudienceMismatch()
        async throws
    {
        let client = OAuthScriptHTTPClient([
            .init(
                path: "/token",
                response: jsonResponse([
                    "access_token": fakeJWT(
                        audience: "https://other.example/resource"),
                    "token_type": "Bearer",
                ])),
        ])
        let components = makeCoordinator(client: client)
        do {
            _ = try await components.coordinator.beginLogin(
                serverID: .init(rawValue: "mcpserver_oauth"),
                accountReference: .init(rawValue: "account_one"),
                configuration: try oauthConfiguration(
                    clientID: "registered-client"),
                discovery: discoveryFixture(),
                redirectPolicy: .registered(
                    URL(
                        string:
                            "http://0.0.0.0:51429/callback")!))
            XCTFail("Expected wildcard bind rejection")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .invalidLoopbackRedirect)
        }

        let attempt = try await components.coordinator.beginLogin(
            serverID: .init(rawValue: "mcpserver_oauth"),
            accountReference: .init(rawValue: "account_one"),
            configuration: try oauthConfiguration(
                clientID: "registered-client"),
            discovery: discoveryFixture(),
            redirectPolicy: .registered(
                URL(
                    string:
                        "http://[::1]:51429/callback")!),
            loginPolicy: .init(
                registeredRedirectURIs: [
                    URL(
                        string:
                            "http://[::1]:51429/callback")!
                ]))
        let state = queryItems(attempt.authorizationURL)["state"]!
        do {
            _ = try await components.coordinator.completeLogin(
                attempt,
                callbackURL: URL(
                    string:
                        "\(attempt.redirectURI.absoluteString)?code=x&state=\(state)")!)
            XCTFail("Expected audience mismatch")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(error, .audienceMismatch)
        }
    }

    func testLoopbackListenerBindsExactAddressAndReturnsBoundedCallback()
        async throws
    {
        let listener: MCPOAuthLoopbackCallbackListener
        do {
            listener = try MCPOAuthLoopbackCallbackListener.bind(
                host: .ipv4,
                port: 0,
                callbackPath: "/oauth/callback")
        } catch MCPOAuthLoopbackListenerError.bindPermissionDenied {
            throw XCTSkip(
                "The outer test sandbox denies local listening sockets.")
        }
        XCTAssertEqual(listener.redirectURI.host, "127.0.0.1")
        XCTAssertNotEqual(listener.redirectURI.port, 0)

        async let callback = listener.waitForCallback(
            maximumRequestBytes: 8 * 1_024,
            readTimeoutSeconds: 5)
        var components = URLComponents(
            url: listener.redirectURI,
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "code", value: "one-time-code"),
            .init(name: "state", value: "opaque-state"),
        ]
        let (_, response) = try await URLSession.shared.data(
            from: components.url!)
        XCTAssertEqual(
            (response as? HTTPURLResponse)?.statusCode,
            200)
        let received = try await callback
        XCTAssertEqual(received.path, "/oauth/callback")
        XCTAssertEqual(
            queryItems(received)["state"],
            "opaque-state")
    }

    private func makeCoordinator(
        client: OAuthScriptHTTPClient
    ) -> (
        coordinator: MCPOAuthCoordinator,
        vault: MCPOAuthCredentialVault,
        store: OAuthMemorySecretStore
    ) {
        let store = OAuthMemorySecretStore()
        let vault = MCPOAuthCredentialVault(secretStore: store)
        return (
            MCPOAuthCoordinator(
                httpClient: client,
                vault: vault,
                secretStore: store),
            vault,
            store)
    }

    private func oauthConfiguration(
        clientID: String?,
        scopes: [String] = []
    ) throws -> MCPOAuthConfiguration {
        try MCPOAuthConfiguration(
            enabled: true,
            canonicalResource:
                "https://mcp.example.test/mcp",
            clientID: clientID,
            scopes: scopes,
            accountReference:
                .init(rawValue: "account_one"))
    }

    private func discoveryFixture(
        supportsClientMetadataDocument: Bool = true,
        registrationEndpoint: String? = nil
    ) -> MCPOAuthDiscoveryResult {
        let resource = URL(
            string: "https://mcp.example.test/mcp")!
        let issuer = URL(
            string: "https://auth.example.test")!
        return MCPOAuthDiscoveryResult(
            canonicalResource: resource,
            protectedResourceMetadataURL: URL(
                string:
                    "https://mcp.example.test/.well-known/oauth-protected-resource/mcp")!,
            protectedResourceMetadata: .init(
                resource: resource.absoluteString,
                authorizationServers: [issuer],
                scopesSupported: ["read", "write"]),
            authorizationServerMetadataURL: URL(
                string:
                    "https://auth.example.test/.well-known/oauth-authorization-server")!,
            authorizationServerMetadata: .init(
                issuer: issuer,
                authorizationEndpoint: URL(
                    string: "https://auth.example.test/authorize")!,
                tokenEndpoint: URL(
                    string: "https://auth.example.test/token")!,
                registrationEndpoint: registrationEndpoint.flatMap(
                    URL.init(string:)),
                revocationEndpoint: URL(
                    string: "https://auth.example.test/revoke"),
                codeChallengeMethodsSupported: ["S256"],
                tokenEndpointAuthMethodsSupported: [
                    "none", "client_secret_basic",
                ],
                clientIDMetadataDocumentSupported:
                    supportsClientMetadataDocument))
    }

    private func queryItems(_ url: URL) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues:
                (URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false)?
                    .queryItems ?? []).compactMap {
                        guard let value = $0.value else { return nil }
                        return ($0.name, value)
                    })
    }

    private func eventually(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + timeoutNanoseconds
        while !(await condition()) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Condition did not become true")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private struct OAuthScriptStep: Sendable {
    let path: String
    let delayNanoseconds: UInt64
    let response: MCPOAuthHTTPResponse

    init(
        path: String,
        delayNanoseconds: UInt64 = 0,
        response: MCPOAuthHTTPResponse
    ) {
        self.path = path
        self.delayNanoseconds = delayNanoseconds
        self.response = response
    }
}

private actor OAuthScriptHTTPClient: MCPOAuthHTTPClient {
    private var steps: [OAuthScriptStep]
    private var recorded: [URLRequest] = []

    init(_ steps: [OAuthScriptStep]) {
        self.steps = steps
    }

    func send(
        _ request: URLRequest,
        allowedOrigin: String
    ) async throws -> MCPOAuthHTTPResponse {
        guard let url = request.url,
              !steps.isEmpty else {
            throw OAuthTestError.unexpectedRequest
        }
        let expected = steps.removeFirst()
        guard url.path == expected.path,
              allowedOrigin.hasPrefix(
                "\(url.scheme!)://\(url.host!)") else {
            throw OAuthTestError.unexpectedRequest
        }
        recorded.append(request)
        if expected.delayNanoseconds > 0 {
            try await Task.sleep(
                nanoseconds: expected.delayNanoseconds)
        }
        return expected.response
    }

    func requests() -> [URLRequest] {
        recorded
    }
}

private actor OAuthMemorySecretStore: MCPSecretStore {
    nonisolated let storageClass =
        MCPSecretStorageClass.hostOwned
    private var values: [String: Data] = [:]
    private var sources: [String: String] = [:]
    private var sequence = 0

    func store(
        _ secret: Data,
        sourceBindingFingerprint: String?
    ) async throws -> MCPSecretReference {
        sequence += 1
        let identifier = "mcp:test:\(sequence)"
        values[identifier] = secret
        sources[identifier] = sourceBindingFingerprint ?? ""
        return try MCPSecretReference(
            storageClass: storageClass,
            identifier: identifier,
            sourceBindingFingerprint: sourceBindingFingerprint)
    }

    func resolve(
        _ reference: MCPSecretReference
    ) async throws -> Data {
        guard reference.storageClass == storageClass,
              sources[reference.identifier]
                == (reference.sourceBindingFingerprint ?? ""),
              let value = values[reference.identifier] else {
            throw MCPSecretStoreError.notFound
        }
        return value
    }

    func replace(
        _ secret: Data,
        for reference: MCPSecretReference
    ) async throws {
        _ = try await resolve(reference)
        values[reference.identifier] = secret
    }

    func remove(
        _ reference: MCPSecretReference
    ) async throws {
        _ = try await resolve(reference)
        values[reference.identifier] = nil
        sources[reference.identifier] = nil
    }

    func contains(
        _ reference: MCPSecretReference
    ) async throws -> Bool {
        values[reference.identifier] != nil
    }

    func allRawValues() -> [Data] {
        Array(values.values)
    }
}

private enum OAuthTestError: Error {
    case unexpectedRequest
}

private func jsonResponse(
    _ object: [String: Any]
) -> MCPOAuthHTTPResponse {
    MCPOAuthHTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "application/json"],
        body: try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]))
}

private func authorizationMetadataResponse(
    issuer: String
) -> MCPOAuthHTTPResponse {
    jsonResponse([
        "issuer": issuer,
        "authorization_endpoint":
            "https://auth.example.test/authorize",
        "token_endpoint": "https://auth.example.test/token",
        "registration_endpoint":
            "https://auth.example.test/register",
        "revocation_endpoint":
            "https://auth.example.test/revoke",
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],
        "client_id_metadata_document_supported": true,
    ])
}

private func fakeJWT(audience: String) -> String {
    func encode(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(encode(["alg": "none"])).\(encode(["aud": audience])).signature"
}

private func oauthPreparedConfiguration(
    name: String
) throws -> MCPServerConfiguration {
    let account =
        MCPAccountReference(
            rawValue: "mcpaccount_staged")
    let oauth = try MCPOAuthConfiguration(
        enabled: true,
        canonicalResource:
            "https://mcp.example.test/mcp",
        clientID: "staged-client",
        scopes: ["mcp.read"],
        accountReference: account)
    return try MCPServerConfiguration(
        serverID:
            MCPServerID(
                rawValue:
                    "mcpserver_oauth_staged"),
        displayName: name,
        approvalPolicy:
            MCPApprovalPolicy(serverDefault: .prompt),
        timeouts: MCPServerTimeouts(),
        filters: MCPServerFilters(),
        transport: .streamableHTTP(
            try MCPHTTPServerConfiguration(
                endpoint:
                    "https://mcp.example.test/mcp",
                oauth: oauth)),
        environmentReference:
            MCPEnvironmentReference(
                rawValue:
                    "mcpenv_oauth_staged"),
        provenance: MCPConfigurationProvenance(
            sourceKind: .intatisUser,
            sourceLabel: "oauth-staged-tests"))
}

private func oauthPrepared(
    name: String,
    catalog: MCPServerCatalog
) throws -> MCPPreparedServerConfiguration {
    let configuration =
        try oauthPreparedConfiguration(name: name)
    return try MCPPreparedServerConfiguration.plan(
        alias: "oauth-staged",
        staging: MCPConfigurationStaging(
            configuration: configuration),
        catalog: catalog)
}

private func oauthPreparedResult(
    _ prepared: MCPPreparedServerConfiguration
) throws -> MCPConfigurationTestResult {
    try MCPConfigurationTestResult(
        challenge: prepared.staging.challenge,
        terminal: .succeeded,
        testedIdentityFingerprint:
            prepared.staging
                .expectedTestedIdentityFingerprint,
        sanitizedReasonCode: "ok")
}

private func oauthStagedToken(
    prepared: MCPPreparedServerConfiguration,
    vault: MCPOAuthCredentialVault
) async throws -> MCPOAuthTokenHandle {
    let authority = try MCPOAuthAuthorityIdentity(
        serverID:
            prepared.expectedServerReference.serverID,
        canonicalOrigin:
            "https://mcp.example.test",
        canonicalResource:
            "https://mcp.example.test/mcp",
        accountReference:
            MCPAccountReference(
                rawValue:
                    "mcpaccount_staged"),
        clientID: "staged-client")
    return try await vault.storeToken(
        authority: authority,
        accessToken: "staged-access-token",
        refreshToken: "staged-refresh-token",
        tokenType: "Bearer",
        scopes: ["mcp.read"],
        expiresAt: nil,
        authorizationServer:
            URL(string:
                "https://auth.example.test")!,
        clientID: "staged-client",
        generation:
            MCPOAuthCredentialGeneration(
                rawValue: 1),
        stagingBinding:
            MCPOAuthStagingBinding(
                prepared: prepared))
}

extension MCPOAuthTests {
    func testOAuthEditRevisionTwoStagesTestsSavesAndActivatesExactly()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-oauth-edit-r2-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent(
                "catalog.json"))
        let first = try oauthPrepared(
            name: "Revision One",
            catalog: try await store.load())
        let firstCatalog = try await store.savePrepared(
            first,
            proof: first.accept(
                oauthPreparedResult(first))).catalog
        let second = try oauthPrepared(
            name: "Revision Two",
            catalog: firstCatalog)
        XCTAssertEqual(
            second.definition.revisionOrdinal,
            2)
        let secrets = OAuthMemorySecretStore()
        let vault = MCPOAuthCredentialVault(
            secretStore: secrets)
        let staged = try await oauthStagedToken(
            prepared: second,
            vault: vault)
        let testProvider =
            MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: staged,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue:
                            "mcpconn_edit_r2_test"),
                expectedServerReference:
                    second.expectedServerReference,
                stagedTestPreparationFingerprint:
                    second.preparationFingerprint)
        let testHeader =
            try await testProvider.authorizationHeader(
                for: URL(string:
                    "https://mcp.example.test/mcp")!,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue:
                            "mcpconn_edit_r2_test"))
        XCTAssertEqual(
            testHeader,
            "Bearer staged-access-token")
        let proof = try second.accept(
            oauthPreparedResult(second))
        let secondCatalog = try await store.savePrepared(
            second,
            proof: proof).catalog
        let active = try await vault.activateStagedToken(
            staged,
            prepared: second,
            proof: proof,
            publishedCatalog: secondCatalog)
        XCTAssertTrue(
            active.isActive(
                for:
                    second.expectedServerReference))
        XCTAssertFalse(
            active.isActive(
                for:
                    first.expectedServerReference))
    }

    func testStagedCredentialIsTestOnlyUntilExactRevisionActivation()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-oauth-staged-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let catalogStore = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent(
                "catalog.json"))
        let prepared = try oauthPrepared(
            name: "Revision One",
            catalog: try await catalogStore.load())
        let proof = try prepared.accept(
            oauthPreparedResult(prepared))
        let secrets = OAuthMemorySecretStore()
        let vault = MCPOAuthCredentialVault(
            secretStore: secrets)
        let staged = try await oauthStagedToken(
            prepared: prepared,
            vault: vault)
        XCTAssertFalse(staged.isActive)

        let ordinary = MCPOAuthAuthorizationProvider(
            vault: vault,
            handle: staged,
            connectionGeneration:
                MCPConnectionGeneration(
                    rawValue: "mcpconn_ordinary"),
            expectedServerReference:
                prepared.expectedServerReference)
        do {
            _ = try await ordinary.authorizationHeader(
                for: URL(string:
                    "https://mcp.example.test/mcp")!,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue:
                            "mcpconn_ordinary"))
            XCTFail("inactive staged token unexpectedly authorized")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(
                error,
                .stagedCredentialInactive)
        }

        let testProvider =
            MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: staged,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue: "mcpconn_test"),
                expectedServerReference:
                    prepared.expectedServerReference,
                stagedTestPreparationFingerprint:
                    prepared.preparationFingerprint)
        let testHeader =
            try await testProvider.authorizationHeader(
                for: URL(string:
                    "https://mcp.example.test/mcp")!,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue: "mcpconn_test"))
        XCTAssertEqual(
            testHeader,
            "Bearer staged-access-token")

        let receipt = try await catalogStore.savePrepared(
            prepared,
            proof: proof)
        let active = try await vault.activateStagedToken(
            staged,
            prepared: prepared,
            proof: proof,
            publishedCatalog: receipt.catalog)
        XCTAssertTrue(active.isActive(
            for: prepared.expectedServerReference))
        let activeProvider =
            MCPOAuthAuthorizationProvider(
                vault: vault,
                handle: active,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue: "mcpconn_active"),
                expectedServerReference:
                    prepared.expectedServerReference)
        let activeHeader =
            try await activeProvider.authorizationHeader(
                for: URL(string:
                    "https://mcp.example.test/mcp")!,
                connectionGeneration:
                    MCPConnectionGeneration(
                        rawValue:
                            "mcpconn_active"))
        XCTAssertEqual(
            activeHeader,
            "Bearer staged-access-token")
    }

    func testCASConflictCannotActivateAndFutureOrdinalCannotInherit()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-oauth-conflict-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL: root.appendingPathComponent(
                "catalog.json"))
        let initial = try await store.load()
        let stale = try oauthPrepared(
            name: "Stale Revision One",
            catalog: initial)
        let winner = try oauthPrepared(
            name: "Winning Revision One",
            catalog: initial)
        let secrets = OAuthMemorySecretStore()
        let vault = MCPOAuthCredentialVault(
            secretStore: secrets)
        let token = try await oauthStagedToken(
            prepared: stale,
            vault: vault)
        let staleProof = try stale.accept(
            oauthPreparedResult(stale))
        let winnerReceipt = try await store.savePrepared(
            winner,
            proof: winner.accept(
                oauthPreparedResult(winner)))

        do {
            _ = try await store.savePrepared(
                stale,
                proof: staleProof)
            XCTFail("stale OAuth plan unexpectedly saved")
        } catch let error as MCPServerCatalogError {
            XCTAssertEqual(
                error,
                .compareAndSwapConflict(
                    expected: 0,
                    actual: 1))
        }
        do {
            _ = try await vault.activateStagedToken(
                token,
                prepared: stale,
                proof: staleProof,
                publishedCatalog:
                    winnerReceipt.catalog)
            XCTFail("conflicted staged token unexpectedly activated")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(
                error,
                .stagedCredentialMismatch)
        }

        let future = try oauthPrepared(
            name: "Future Revision Two",
            catalog: winnerReceipt.catalog)
        XCTAssertNotEqual(
            future.expectedServerReference,
            stale.expectedServerReference)
        do {
            _ = try await vault.activateStagedToken(
                token,
                prepared: future,
                proof: future.accept(
                    oauthPreparedResult(future)),
                publishedCatalog:
                    winnerReceipt.catalog)
            XCTFail("future ordinal inherited staged token")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(
                error,
                .stagedCredentialMismatch)
        }
        try await vault.discardStagedToken(token)
        let tokenExists =
            try await vault.tokenExists(token)
        XCTAssertFalse(tokenExists)
    }

    func testStagedActivationRejectsCredentialAuthorityOutsidePreparedHTTPConfig()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-oauth-authority-mismatch-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let store = MCPServerCatalogStore(
            fileURL:
                root.appendingPathComponent(
                    "catalog.json"))
        let prepared = try oauthPrepared(
            name: "Exact HTTP Authority",
            catalog: try await store.load())
        let proof = try prepared.accept(
            oauthPreparedResult(prepared))
        let vault = MCPOAuthCredentialVault(
            secretStore: OAuthMemorySecretStore())
        let mismatchedAuthority =
            try MCPOAuthAuthorityIdentity(
                serverID:
                    prepared.expectedServerReference.serverID,
                canonicalOrigin:
                    "https://mcp.example.test",
                canonicalResource:
                    "https://mcp.example.test/other-resource",
                accountReference:
                    MCPAccountReference(
                        rawValue:
                            "mcpaccount_staged"),
                clientID: "staged-client")
        let staged = try await vault.storeToken(
            authority: mismatchedAuthority,
            accessToken: "staged-access-token",
            refreshToken: nil,
            tokenType: "Bearer",
            scopes: ["mcp.read"],
            expiresAt: nil,
            authorizationServer:
                URL(string:
                    "https://auth.example.test")!,
            clientID: "staged-client",
            generation:
                MCPOAuthCredentialGeneration(
                    rawValue: 1),
            stagingBinding:
                MCPOAuthStagingBinding(
                    prepared: prepared))
        let published = try await store.savePrepared(
            prepared,
            proof: proof).catalog

        do {
            _ = try await vault.activateStagedToken(
                staged,
                prepared: prepared,
                proof: proof,
                publishedCatalog: published)
            XCTFail("mismatched OAuth authority unexpectedly activated")
        } catch let error as MCPOAuthError {
            XCTAssertEqual(
                error,
                .stagedCredentialMismatch)
        }
    }
}
