import Foundation
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

private final class InferenceCapturingHTTP: HTTPByteStreaming, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    func stream(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(Data("data: [DONE]\n\n".utf8))
            continuation.finish()
        }
    }
}

private actor MutableInferenceSecretResolver: SecretResolver {
    private var values: [String: String]
    private var calls = 0

    init(values: [String: String]) {
        self.values = values
    }

    func secret(for ref: KeychainRef) async throws -> String {
        calls += 1
        guard let value = values[ref.account] else {
            throw IntatisError.config("test credential is unavailable")
        }
        return value
    }

    func set(_ value: String, for account: String) {
        values[account] = value
    }

    func callCount() -> Int { calls }
}

private actor InferenceCatalogConcurrentStartGate {
    private let participantCount: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            guard waiters.count == participantCount else { return }
            let ready = waiters
            waiters.removeAll(keepingCapacity: false)
            ready.forEach { $0.resume() }
        }
    }
}

final class InferenceCatalogStoreResolverTests: XCTestCase {
    func testStoreAtomicallyPersistsOwnerOnlyAndRetainsOldRevisions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("catalog.json")
        let store = InferenceCatalogStore(fileURL: fileURL)

        let first = try await store.reconcile(makeDraft(
            profiles: [profileDraft(id: "profile", connection: "route", effort: "low")]))
        let oldRef = try XCTUnwrap(first.currentProfileRef(
            for: InferenceProfileID(rawValue: "profile")))
        let second = try await store.reconcile(makeDraft(
            profiles: [profileDraft(id: "profile", connection: "route", effort: "high")]))

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o600)
        let lockURL = root.appendingPathComponent(".catalog.json.lock")
        let lockAttributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let lockPermissions = try XCTUnwrap(
            lockAttributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(lockPermissions, 0o600)
        XCTAssertEqual(second.catalog.connections.count, 1)
        XCTAssertEqual(second.catalog.profiles.count, 2)
        XCTAssertEqual(try second.resolve(oldRef).profile.effectiveRequestOptions["reasoning_effort"],
                       .string("low"))

        let reloaded = try await InferenceCatalogStore(fileURL: fileURL).loadSnapshot()
        XCTAssertEqual(reloaded.catalog, second.catalog)
        XCTAssertEqual(try reloaded.resolve(oldRef).profile.effectiveRequestOptions["reasoning_effort"],
                       .string("low"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testConcurrentStoreInstancesRetainEveryImmutableRevisionWithoutCollisions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("catalog.json")
        let variants = (0..<32).map { "concurrent-\($0)" }
        let stores = variants.map { _ in InferenceCatalogStore(fileURL: fileURL) }
        let drafts = variants.map { variant in
            makeDraft(profiles: [profileDraft(
                id: "shared-profile",
                connection: "route",
                effort: variant)])
        }
        let gate = InferenceCatalogConcurrentStartGate(participantCount: variants.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (store, draft) in zip(stores, drafts) {
                group.addTask {
                    await gate.wait()
                    _ = try await store.reconcile(draft)
                }
            }
            try await group.waitForAll()
        }

        let snapshot = try await InferenceCatalogStore(fileURL: fileURL).loadSnapshot()
        let definitions = snapshot.catalog.profiles.filter {
            $0.profileRef.inferenceProfileID.rawValue == "shared-profile"
        }
        let revisions = definitions.map(\.profileRef.inferenceProfileRevision.rawValue)
        XCTAssertEqual(definitions.count, variants.count)
        XCTAssertEqual(Set(revisions).count, variants.count)
        XCTAssertEqual(Set(revisions), Set((1...variants.count).map(String.init)))
        XCTAssertEqual(Set(definitions.compactMap(\.variantID)), Set(variants))
        XCTAssertEqual(
            Set(definitions.compactMap { definition -> String? in
                guard case .string(let value) = definition.effectiveRequestOptions["reasoning_effort"]
                else { return nil }
                return value
            }),
            Set(variants))
    }

    func testSymbolicLinkLockIsRejectedWithoutFollowingOrLeakingPath() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("catalog.json")
        let protectedURL = root.appendingPathComponent("protected")
        let protectedData = Data("must remain unchanged".utf8)
        try protectedData.write(to: protectedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: protectedURL.path)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".catalog.json.lock"),
            withDestinationURL: protectedURL)

        do {
            _ = try await InferenceCatalogStore(fileURL: fileURL).reconcile(makeDraft(
                profiles: [profileDraft(id: "profile", connection: "route", effort: "low")]))
            XCTFail("symbolic-link lock unexpectedly followed")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .storeIO)
            XCTAssertFalse(error.localizedDescription.contains(root.path))
            XCTAssertFalse(error.localizedDescription.contains(fileURL.path))
        }
        XCTAssertEqual(try Data(contentsOf: protectedURL), protectedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testExistingLockWithNonOwnerOnlyPermissionsFailsClosed() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("catalog.json")
        let lockURL = root.appendingPathComponent(".catalog.json.lock")
        try Data().write(to: lockURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o640)],
            ofItemAtPath: lockURL.path)

        do {
            _ = try await InferenceCatalogStore(fileURL: fileURL).reconcile(makeDraft(
                profiles: [profileDraft(id: "profile", connection: "route", effort: "low")]))
            XCTFail("insecure lock permissions unexpectedly accepted")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .storeIO)
            XCTAssertFalse(error.localizedDescription.contains(root.path))
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: lockURL.path)
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        XCTAssertEqual(permissions, 0o640)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCorruptedStoreFailsClosedAndIsNotReplaced() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("catalog.json")
        let corrupted = Data("not a catalog".utf8)
        try corrupted.write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path)
        let store = InferenceCatalogStore(fileURL: fileURL)

        do {
            _ = try await store.loadSnapshot()
            XCTFail("corrupted catalog unexpectedly loaded")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .storeCorrupted)
            XCTAssertFalse(error.localizedDescription.contains(fileURL.path))
        }
        do {
            _ = try await store.reconcile(makeDraft(
                profiles: [profileDraft(id: "profile", connection: "route", effort: "low")]))
            XCTFail("corrupted catalog was unexpectedly replaced")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .storeCorrupted)
        }
        XCTAssertEqual(try Data(contentsOf: fileURL), corrupted)
    }

    func testStoreRejectsUnsupportedSchemaAndInsecurePermissions() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("catalog.json")
        let unsupported = InferenceCatalog(
            schemaVersion: InferenceCatalog.currentSchemaVersion + 1,
            connections: [],
            profiles: [])
        try JSONEncoder().encode(unsupported).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path)

        do {
            _ = try await InferenceCatalogStore(fileURL: fileURL).loadSnapshot()
            XCTFail("unsupported catalog unexpectedly loaded")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .unsupportedSchemaVersion)
        }

        try JSONEncoder().encode(InferenceCatalog.empty).write(to: fileURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fileURL.path)
        do {
            _ = try await InferenceCatalogStore(fileURL: fileURL).loadSnapshot()
            XCTFail("insecure catalog unexpectedly loaded")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .storeInsecurePermissions)
            XCTAssertFalse(error.localizedDescription.contains(fileURL.path))
        }
    }

    func testExactResolverKeepsSameModelVariantsIsolated() async throws {
        let lowID = InferenceProfileID(rawValue: "low")
        let highID = InferenceProfileID(rawValue: "high")
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(profiles: [
            profileDraft(id: lowID.rawValue, connection: "route", effort: "low"),
            profileDraft(id: highID.rawValue, connection: "route", effort: "high"),
        ]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: ["ROUTE_KEY": "shared-secret"])
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(snapshot: snapshot, resolver: secrets, http: http)

        let low = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: lowID)))
        let high = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: highID)))
        let lowProvider = try XCTUnwrap(low.provider as? OpenAIWireProvider)
        let highProvider = try XCTUnwrap(high.provider as? OpenAIWireProvider)
        XCTAssertEqual(lowProvider.runtimePolicy, .agentStreaming)
        XCTAssertEqual(highProvider.runtimePolicy, .agentStreaming)
        XCTAssertEqual(lowProvider.runtimePolicy.requestTimeoutSeconds, 180)
        try await performRequest(low)
        try await performRequest(high)

        let requests = http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try requestBody(requests[0])["reasoning_effort"], .string("low"))
        XCTAssertEqual(try requestBody(requests[1])["reasoning_effort"], .string("high"))
        XCTAssertEqual(requests[0].url, requests[1].url)
        XCTAssertEqual(low.model, high.model)
        XCTAssertNotEqual(low.binding.inferenceProfileRef, high.binding.inferenceProfileRef)
    }

    func testExactAgentInferenceCarriesHostedSearchOnSameProfileRevision()
        async throws
    {
        let profileID = InferenceProfileID(
            rawValue: "hosted-search-profile")
        let profile = InferenceProfileDraft(
            inferenceProfileID: profileID,
            inferenceConnectionID: InferenceConnectionID(
                rawValue: "route"),
            modelID: ModelID(rawValue: "search/model"),
            declaredCapabilities: [
                .chat,
                .toolCalling,
                .hostedWebSearch,
            ],
            safeRouteLabel: "Hosted search route")
        let catalog = try InferenceCatalogReconciler.reconcile(
            draft: makeDraft(
                profiles: [profile],
                requestAdapter: .openRouter))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let resolver = MutableInferenceSecretResolver(
            values: ["ROUTE_KEY": "shared-secret"])
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver: resolver,
            http: InferenceCapturingHTTP())

        let resolved = try await registry.agentInference(
            for: XCTUnwrap(snapshot.currentProfileRef(for: profileID)))
        let hosted = try XCTUnwrap(resolved.hostedWebSearch)

        XCTAssertEqual(hosted.model, resolved.model)
        XCTAssertEqual(hosted.model.rawValue, "search/model")
        XCTAssertEqual(
            hosted.configuration.dialect,
            .openRouterServerTool)
        XCTAssertEqual(
            hosted.configuration.unsupportedBehavior,
            .failClosed)
        XCTAssertEqual(hosted.configuration.toolChoice, .required)
        XCTAssertEqual(
            try XCTUnwrap(resolved.provider as? OpenAIWireProvider)
                .endpoint.id,
            try XCTUnwrap(hosted.provider as? OpenAIWireProvider)
                .endpoint.id)

        let credentialCallsBeforeCodex = await resolver.callCount()
        let codexRoute = try await registry.codexRuntimeRoute(
            for: resolved.binding)
        let credentialCallsAfterCodex = await resolver.callCount()
        XCTAssertEqual(codexRoute.responses.model, resolved.model)
        XCTAssertEqual(
            codexRoute.responses.requestAdapter,
            .openRouter)
        XCTAssertEqual(
            try XCTUnwrap(codexRoute.hostedWebSearch).model,
            resolved.model)
        XCTAssertEqual(
            credentialCallsAfterCodex,
            credentialCallsBeforeCodex + 1)
    }

    func testConcurrentExactProfilesNeverCrossTalkRequestOptions() async throws {
        let lowID = InferenceProfileID(rawValue: "low-concurrent")
        let highID = InferenceProfileID(rawValue: "high-concurrent")
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(profiles: [
            profileDraft(id: lowID.rawValue, connection: "route", effort: "low"),
            profileDraft(id: highID.rawValue, connection: "route", effort: "high"),
        ]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: ["ROUTE_KEY": "shared-secret"])
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(snapshot: snapshot, resolver: secrets, http: http)
        let low = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: lowID)))
        let high = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: highID)))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                let resolved = index.isMultiple(of: 2) ? low : high
                group.addTask {
                    let request = AgentRequest(
                        model: resolved.model,
                        messages: [.user("concurrent")],
                        tools: [])
                    for try await _ in resolved.provider.stream(request) {}
                }
            }
            try await group.waitForAll()
        }

        let efforts = try http.requests.map { try XCTUnwrap(requestBody($0)["reasoning_effort"]) }
        XCTAssertEqual(efforts.filter { $0 == .string("low") }.count, 20)
        XCTAssertEqual(efforts.filter { $0 == .string("high") }.count, 20)
    }

    func testExactAgentProfileCanonicalizesSDKReasoningAliasAtWireBoundary()
        async throws {
        let profileID =
            InferenceProfileID(
                rawValue: "sdk-reasoning-alias")
        let profile = InferenceProfileDraft(
            inferenceProfileID: profileID,
            inferenceConnectionID:
                InferenceConnectionID(
                    rawValue: "route"),
            modelID:
                ModelID(
                    rawValue: "same/model"),
            profileRequestOptions: [
                "reasoningEffort":
                    .string("xhigh"),
                "provider": .object([
                    "only": .array([
                        .string("deepseek"),
                    ]),
                    "allow_fallbacks": .bool(false),
                    "require_parameters": .bool(true),
                ]),
            ],
            declaredCapabilities: [
                .chat,
                .toolCalling,
            ])
        let catalog =
            try InferenceCatalogReconciler.reconcile(
                draft: makeDraft(
                    profiles: [profile],
                    requestAdapter:
                        .openAICompatible))
        let snapshot =
            try InferenceCatalogSnapshot(
                catalog: catalog)
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver:
                MutableInferenceSecretResolver(
                    values: [
                        "ROUTE_KEY":
                            "host-secret",
                    ]),
            http: http)
        let resolved =
            try await registry.agentInference(
                for: XCTUnwrap(
                    snapshot.currentProfileRef(
                        for: profileID)))
        let frozenProfile =
            try snapshot.resolve(
                resolved.binding
                    .inferenceProfileRef)
                .profile

        XCTAssertEqual(
            frozenProfile
                .effectiveRequestOptions[
                    "reasoningEffort"],
            .string("xhigh"))
        XCTAssertNil(
            frozenProfile
                .effectiveRequestOptions[
                    "reasoning_effort"])

        try await performRequest(resolved)

        let body = try requestBody(
            XCTUnwrap(http.requests.first))
        XCTAssertEqual(
            body["reasoning_effort"],
            .string("xhigh"))
        XCTAssertNil(body["reasoningEffort"])
        XCTAssertEqual(
            body["provider"],
            .object([
                "only": .array([
                    .string("deepseek"),
                ]),
                "allow_fallbacks": .bool(false),
                "require_parameters": .bool(true),
            ]))
    }

    func testHostOwnedRequestFieldsAndOutputCeilingClampApprovedProfileOptions() async throws {
        let profileID = InferenceProfileID(rawValue: "host-owned-fields")
        let profile = InferenceProfileDraft(
            inferenceProfileID: profileID,
            inferenceConnectionID: InferenceConnectionID(rawValue: "route"),
            modelID: ModelID(rawValue: "same/model"),
            profileRequestOptions: [
                "max_tokens": .number(99_999),
                "max_completion_tokens": .number(99_999),
                "max_output_tokens": .number(99_999),
                "max_new_tokens": .number(99_999),
                "maxTokens": .number(99_999),
                "MAX-COMPLETION-TOKENS": .number(99_999),
                "Max_Output_Tokens": .number(99_999),
                "max.new.tokens": .number(99_999),
            ],
            declaredCapabilities: [.chat, .toolCalling])
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(profiles: [profile]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver: MutableInferenceSecretResolver(values: ["ROUTE_KEY": "host-secret"]),
            http: http)
        let resolved = try await registry.agentInference(
            for: XCTUnwrap(snapshot.currentProfileRef(for: profileID)))

        try await performRequest(resolved, maxOutputTokens: 64)

        let request = try XCTUnwrap(http.requests.first)
        let body = try requestBody(request)
        XCTAssertEqual(body["model"], .string("same/model"))
        XCTAssertEqual(body["messages"], .array([
            .object(["role": .string("user"), "content": .string("test")]),
        ]))
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["stream"], .bool(true))
        XCTAssertEqual(body["max_tokens"], .number(64))
        XCTAssertNil(body["max_completion_tokens"])
        XCTAssertNil(body["max_output_tokens"])
        XCTAssertNil(body["max_new_tokens"])
        XCTAssertNil(body["maxTokens"])
        XCTAssertNil(body["MAX-COMPLETION-TOKENS"])
        XCTAssertNil(body["Max_Output_Tokens"])
        XCTAssertNil(body["max.new.tokens"])
        XCTAssertEqual(body["n"], .number(1))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer host-secret")
    }

    func testExactResolverKeepsSameModelConnectionsAndCredentialsIsolated() async throws {
        let firstConnection = connectionDraft(
            id: "first",
            baseURL: URL(string: "https://first.example.test/v1")!,
            credentialAccount: "FIRST_KEY")
        let secondConnection = connectionDraft(
            id: "second",
            baseURL: URL(string: "https://second.example.test/v1")!,
            credentialAccount: "SECOND_KEY")
        let firstID = InferenceProfileID(rawValue: "first-profile")
        let secondID = InferenceProfileID(rawValue: "second-profile")
        let draft = InferenceCatalogDraft(
            connections: [firstConnection, secondConnection],
            profiles: [
                profileDraft(id: firstID.rawValue, connection: "first", effort: "low"),
                profileDraft(id: secondID.rawValue, connection: "second", effort: "high"),
            ])
        let catalog = try InferenceCatalogReconciler.reconcile(draft: draft)
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: [
            "FIRST_KEY": "first-secret",
            "SECOND_KEY": "second-secret",
        ])
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(snapshot: snapshot, resolver: secrets, http: http)

        let first = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: firstID)))
        let second = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: secondID)))
        try await performRequest(first)
        try await performRequest(second)

        let requests = http.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.host, "first.example.test")
        XCTAssertEqual(requests[1].url?.host, "second.example.test")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer first-secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer second-secret")
        XCTAssertEqual(try requestBody(requests[0])["reasoning_effort"], .string("low"))
        XCTAssertEqual(try requestBody(requests[1])["reasoning_effort"], .string("high"))
    }

    func testMissingExactRevisionFailsBeforeSecretOrNetworkAccess() async throws {
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(
            profiles: [profileDraft(id: "profile", connection: "route", effort: "low")]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: ["ROUTE_KEY": "secret"])
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(snapshot: snapshot, resolver: secrets, http: http)
        let missing = InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: "profile"),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: "missing"))

        do {
            _ = try await registry.agentInference(for: missing)
            XCTFail("missing revision unexpectedly resolved")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .unresolvedProfile)
        }
        let secretCallCount = await secrets.callCount()
        XCTAssertEqual(secretCallCount, 0)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testSecretValueRotationWithStableReferenceDoesNotRequireRebind() async throws {
        let profileID = InferenceProfileID(rawValue: "profile")
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(
            profiles: [profileDraft(id: profileID.rawValue, connection: "route", effort: "high")]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: ["ROUTE_KEY": "old-secret"])
        let http = InferenceCapturingHTTP()
        let registry = makeRegistry(snapshot: snapshot, resolver: secrets, http: http)
        let ref = try XCTUnwrap(snapshot.currentProfileRef(for: profileID))

        let beforeRotation = try await registry.agentInference(for: ref)
        await secrets.set("new-secret", for: "ROUTE_KEY")
        let afterRotation = try await registry.agentInference(for: beforeRotation.binding)
        try await performRequest(beforeRotation)
        try await performRequest(afterRotation)

        XCTAssertEqual(beforeRotation.binding, afterRotation.binding)
        let requests = http.requests
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old-secret")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer new-secret")
        let secretCallCount = await secrets.callCount()
        XCTAssertEqual(secretCallCount, 2)
    }

    func testCapabilityMismatchFailsBeforeSecretResolution() async throws {
        let profileID = InferenceProfileID(rawValue: "chat-only")
        let profile = InferenceProfileDraft(
            inferenceProfileID: profileID,
            inferenceConnectionID: InferenceConnectionID(rawValue: "route"),
            modelID: ModelID(rawValue: "same/model"),
            declaredCapabilities: [.chat])
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeDraft(profiles: [profile]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let secrets = MutableInferenceSecretResolver(values: ["ROUTE_KEY": "secret"])
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver: secrets,
            http: InferenceCapturingHTTP())

        do {
            _ = try await registry.agentInference(for: XCTUnwrap(snapshot.currentProfileRef(for: profileID)))
            XCTFail("chat-only profile unexpectedly resolved for tool calling")
        } catch {
            XCTAssertEqual(error as? InferenceCatalogError, .incompatibleProfileCapability)
        }
        let secretCallCount = await secrets.callCount()
        XCTAssertEqual(secretCallCount, 0)
    }

    func testExactProfileCapabilityControlsResolvedProviderToolSearch()
        async throws {
        let supportedID =
            InferenceProfileID(
                rawValue: "search-supported")
        let unsupportedID =
            InferenceProfileID(
                rawValue: "search-unsupported")
        let catalog =
            try InferenceCatalogReconciler.reconcile(
                draft: makeDraft(profiles: [
                    InferenceProfileDraft(
                        inferenceProfileID:
                            supportedID,
                        inferenceConnectionID:
                            InferenceConnectionID(
                                rawValue: "route"),
                        modelID:
                            ModelID(
                                rawValue: "same/model"),
                        declaredCapabilities: [
                            .chat,
                            .toolCalling,
                            .toolSearch,
                        ]),
                    InferenceProfileDraft(
                        inferenceProfileID:
                            unsupportedID,
                        inferenceConnectionID:
                            InferenceConnectionID(
                                rawValue: "route"),
                        modelID:
                            ModelID(
                                rawValue: "same/model"),
                        declaredCapabilities: [
                            .chat,
                            .toolCalling,
                        ]),
                ]))
        let snapshot =
            try InferenceCatalogSnapshot(
                catalog: catalog)
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver:
                MutableInferenceSecretResolver(
                    values: [
                        "ROUTE_KEY": "secret",
                    ]),
            http: InferenceCapturingHTTP())

        let supported =
            try await registry.agentInference(
                for: XCTUnwrap(
                    snapshot.currentProfileRef(
                        for: supportedID)))
        let unsupported =
            try await registry.agentInference(
                for: XCTUnwrap(
                    snapshot.currentProfileRef(
                        for: unsupportedID)))

        XCTAssertEqual(
            supported.provider
                .toolCallingCapabilities,
            .responsesToolSearch)
        XCTAssertEqual(
            unsupported.provider
                .toolCallingCapabilities,
            .chatCompletionsOnly)
    }

    func testExactResolverCarriesModelContextPolicyAtomically()
        async throws {
        let profileID =
            InferenceProfileID(
                rawValue: "context-policy")
        let policy =
            AgentModelContextPolicy(
                contextWindowTokens: 100_000,
                autoCompactTokenLimit: 80_000,
                compHash: "context-v1")
        let catalog =
            try InferenceCatalogReconciler.reconcile(
                draft: makeDraft(profiles: [
                    InferenceProfileDraft(
                        inferenceProfileID:
                            profileID,
                        inferenceConnectionID:
                            InferenceConnectionID(
                                rawValue: "route"),
                        modelID:
                            ModelID(
                                rawValue: "same/model"),
                        modelContextPolicy:
                            policy,
                        declaredCapabilities: [
                            .chat,
                            .toolCalling,
                        ]),
                ]))
        let snapshot =
            try InferenceCatalogSnapshot(
                catalog: catalog)
        let registry = makeRegistry(
            snapshot: snapshot,
            resolver:
                MutableInferenceSecretResolver(
                    values: [
                        "ROUTE_KEY": "secret",
                    ]),
            http: InferenceCapturingHTTP())

        let resolved =
            try await registry.agentInference(
                for: XCTUnwrap(
                    snapshot.currentProfileRef(
                        for: profileID)))

        XCTAssertEqual(
            resolved.modelContextPolicy,
            policy)
        XCTAssertEqual(
            resolved.modelContextPolicy
                .resolvedAutoCompactTokenLimit,
            80_000)
    }

    func testVisibleAgentRouteAttachesContextPolicyOnlyForOneExactBaseProfile()
        async throws
    {
        let policy = AgentModelContextPolicy(
            contextWindowTokens: 120_000,
            autoCompactTokenLimit: 96_000,
            compHash: "route-context-v1")
        let catalog = try InferenceCatalogReconciler.reconcile(
            draft: makeDraft(profiles: [
                InferenceProfileDraft(
                    inferenceProfileID:
                        InferenceProfileID(rawValue: "base"),
                    inferenceConnectionID:
                        InferenceConnectionID(rawValue: "route"),
                    modelID: ModelID(rawValue: "same/model"),
                    modelContextPolicy: policy,
                    declaredCapabilities: [.chat, .toolCalling]),
            ]))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [
                    ProviderEndpoint(
                        id: "route",
                        baseURL:
                            URL(string:
                                "https://route.example.test/v1")!,
                        apiKeyRef:
                            .environment("ROUTE_KEY"),
                        wire: .openai),
                ],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "route",
                        model: ModelID(rawValue: "same/model")))),
            resolver:
                MutableInferenceSecretResolver(
                    values: ["ROUTE_KEY": "secret"]),
            http: InferenceCapturingHTTP(),
            inferenceCatalogSnapshot: snapshot)

        let route = try await registry.defaultAgentRuntimeRoute()

        XCTAssertEqual(route.model, ModelID(rawValue: "same/model"))
        XCTAssertEqual(route.modelContextPolicy, policy)
        let provider = try XCTUnwrap(
            route.provider as? OpenAIWireProvider)
        XCTAssertEqual(provider.runtimePolicy, .agentStreaming)
    }

    func testAmbiguousBaseProfilesKeepVisibleAgentCompactionDisabled()
        async throws
    {
        let policy = AgentModelContextPolicy(
            contextWindowTokens: 120_000)
        let profiles = ["base-a", "base-b"].map { profileID in
            InferenceProfileDraft(
                inferenceProfileID:
                    InferenceProfileID(rawValue: profileID),
                inferenceConnectionID:
                    InferenceConnectionID(rawValue: "route"),
                modelID: ModelID(rawValue: "same/model"),
                modelContextPolicy: policy,
                declaredCapabilities: [.chat, .toolCalling])
        }
        let catalog = try InferenceCatalogReconciler.reconcile(
            draft: makeDraft(profiles: profiles))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [
                    ProviderEndpoint(
                        id: "route",
                        baseURL:
                            URL(string:
                                "https://route.example.test/v1")!,
                        apiKeyRef:
                            .environment("ROUTE_KEY"),
                        wire: .openai),
                ],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "route",
                        model: ModelID(rawValue: "same/model")))),
            resolver:
                MutableInferenceSecretResolver(
                    values: ["ROUTE_KEY": "secret"]),
            http: InferenceCapturingHTTP(),
            inferenceCatalogSnapshot: snapshot)

        let route = try await registry.defaultAgentRuntimeRoute()

        XCTAssertEqual(route.model, ModelID(rawValue: "same/model"))
        XCTAssertEqual(route.modelContextPolicy, .unspecified)
    }

    func testCurrentCodexRouteNeverBorrowsHostedSearchFromStaleCatalog()
        async throws
    {
        let profile = InferenceProfileDraft(
            inferenceProfileID:
                InferenceProfileID(rawValue: "stale-search"),
            inferenceConnectionID:
                InferenceConnectionID(rawValue: "route"),
            modelID: ModelID(rawValue: "same/model"),
            declaredCapabilities: [
                .chat,
                .toolCalling,
                .hostedWebSearch,
            ])
        let catalog = try InferenceCatalogReconciler.reconcile(
            draft: makeDraft(
                profiles: [profile],
                requestAdapter: .openRouter))
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let currentEndpoint = ProviderEndpoint(
            id: "route",
            baseURL:
                URL(string: "https://current.example.test/v1")!,
            apiKeyRef: .environment("CURRENT_KEY"),
            wire: .openai,
            requestAdapter: .openAICompatible,
            modelCapabilities: [
                "same/model": [.toolCalling, .hostedWebSearch],
            ])
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [currentEndpoint],
                models: ResolvedModels(
                    chat: ModelRef(
                        endpoint: "route",
                        model: ModelID(rawValue: "same/model")))),
            resolver: MutableInferenceSecretResolver(values: [
                "CURRENT_KEY": "current-secret",
                "ROUTE_KEY": "stale-secret",
            ]),
            http: InferenceCapturingHTTP(),
            inferenceCatalogSnapshot: snapshot)

        let legacyProjection = try await registry
            .defaultAgentRuntimeRoute()
        let codex = try await registry.codexRuntimeRoute()

        XCTAssertEqual(
            legacyProjection.hostedWebSearch?.configuration.dialect,
            .openRouterServerTool)
        XCTAssertEqual(
            codex.responses.baseURL,
            currentEndpoint.baseURL)
        XCTAssertEqual(
            codex.responses.requestAdapter,
            .openAICompatible)
        XCTAssertNil(codex.hostedWebSearch)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-inference-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeDraft(
        profiles: [InferenceProfileDraft],
        requestAdapter:
            ProviderRequestAdapter =
                .legacyOpenAIWire
    ) -> InferenceCatalogDraft {
        InferenceCatalogDraft(
            connections: [connectionDraft(
                id: "route",
                baseURL: URL(string: "https://route.example.test/v1")!,
                credentialAccount: "ROUTE_KEY",
                requestAdapter:
                    requestAdapter)],
            profiles: profiles)
    }

    private func connectionDraft(id: String,
                                 baseURL: URL,
                                 credentialAccount: String,
                                 requestAdapter:
                                     ProviderRequestAdapter =
                                         .legacyOpenAIWire)
        -> InferenceConnectionDraft
    {
        InferenceConnectionDraft(
            inferenceConnectionID: InferenceConnectionID(rawValue: id),
            wire: .openai,
            requestAdapter:
                requestAdapter,
            baseURL: baseURL,
            credentialRef: .environment(credentialAccount),
            trust: InferenceConnectionTrust(
                trustDomain: "direct",
                egressClassification: "external"))
    }

    private func profileDraft(id: String,
                              connection: String,
                              effort: String) -> InferenceProfileDraft {
        InferenceProfileDraft(
            inferenceProfileID: InferenceProfileID(rawValue: id),
            inferenceConnectionID: InferenceConnectionID(rawValue: connection),
            modelID: ModelID(rawValue: "same/model"),
            variantID: effort,
            variantRequestOptions: ["reasoning_effort": .string(effort)],
            declaredCapabilities: [.chat, .toolCalling],
            safeRouteLabel: "Test route")
    }

    private func makeRegistry(snapshot: InferenceCatalogSnapshot,
                              resolver: SecretResolver,
                              http: HTTPByteStreaming) -> ProviderRegistry {
        let legacyRef = ModelRef(endpoint: "legacy", model: ModelID(rawValue: "legacy"))
        return ProviderRegistry(
            config: ProviderConfig(endpoints: [], models: ResolvedModels(chat: legacyRef)),
            resolver: resolver,
            http: http,
            inferenceCatalogSnapshot: snapshot)
    }

    private func performRequest(_ resolved: ResolvedInferenceProfile,
                                maxOutputTokens: Int? = nil) async throws {
        let request = AgentRequest(
            model: resolved.model,
            messages: [.user("test")],
            tools: [],
            maxOutputTokens: maxOutputTokens)
        for try await _ in resolved.provider.stream(request) {}
    }

    private func requestBody(_ request: URLRequest) throws -> [String: JSONValue] {
        let data = try XCTUnwrap(request.httpBody)
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        guard case .object(let object) = value else {
            throw IntatisError.decoding("test request body was not an object")
        }
        return object
    }
}
