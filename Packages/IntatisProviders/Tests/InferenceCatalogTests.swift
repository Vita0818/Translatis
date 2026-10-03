import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

final class InferenceCatalogTests: XCTestCase {
    private let connectionID = InferenceConnectionID(rawValue: "gateway-primary")
    private let profileID = InferenceProfileID(rawValue: "coding-high")

    func testShallowMergePreservesApprovedOptionsAndReplacesNestedObjects() throws {
        let merged = try InferenceRequestOptionMerge.shallowMerge([
            [
                "provider": .object([
                    "allow_fallbacks": .bool(true),
                    "order": .array([.string("one"), .string("two")]),
                ]),
                "service_tier": .string("standard"),
            ],
            [
                "provider": .object(["allow_fallbacks": .bool(false)]),
                "top_k": .number(7),
            ],
            ["reasoning": .object(["effort": .string("high")])],
            ["service_tier": .string("priority")],
        ])

        XCTAssertEqual(merged["provider"], .object(["allow_fallbacks": .bool(false)]))
        XCTAssertEqual(merged["top_k"], .number(7))
        XCTAssertEqual(merged["reasoning"], .object(["effort": .string("high")]))
        XCTAssertEqual(merged["service_tier"], .string("priority"))
    }

    func testDeepMergeMatchesOpenCodePlainObjectOverlay() throws {
        let merged = try InferenceRequestOptionMerge.deepMerge([
            [
                "provider": .object([
                    "only": .array([
                        .string("one"),
                        .string("two"),
                    ]),
                    "allow_fallbacks": .bool(true),
                    "max_price": .object([
                        "prompt": .number(1),
                        "completion": .number(1),
                    ]),
                ]),
            ],
            [
                "provider": .object([
                    "only": .array([
                        .string("three"),
                    ]),
                    "require_parameters":
                        .bool(true),
                    "max_price": .object([
                        "completion": .number(2),
                    ]),
                ]),
            ],
        ])

        XCTAssertEqual(
            merged["provider"],
            .object([
                "only": .array([
                    .string("three"),
                ]),
                "allow_fallbacks": .bool(true),
                "require_parameters": .bool(true),
                "max_price": .object([
                    "prompt": .number(1),
                    "completion": .number(2),
                ]),
            ]))
    }

    func testSecretLikeOptionValidationIsRecursiveAndDoesNotEchoMaterial() {
        let rawSecret = "ghp_abcdefghijklmnopqrstuvwxyz123456"
        XCTAssertThrowsError(try InferenceRequestOptionValidation.validateNonSecret([
            "provider": .object([
                "routing": .array([
                    .object(["authorization": .string(rawSecret)]),
                ]),
            ]),
        ])) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .secretLikeRequestOptions)
            let description = error.localizedDescription
            XCTAssertFalse(description.contains(rawSecret))
            XCTAssertFalse(description.lowercased().contains("authorization"))
        }

        XCTAssertThrowsError(try InferenceRequestOptionValidation.validateNonSecret([
            "opaque": .string(rawSecret),
        ])) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .secretLikeRequestOptions)
            XCTAssertFalse(error.localizedDescription.contains(rawSecret))
        }


        for unsafe in [
            ["extra_headers": .object(["X-Custom": .string("opaque-value")])],
            ["vendor_auth": .string("opaque-value")],
            ["query_params": .object(["route": .string("private")])],
        ] as [[String: JSONValue]] {
            XCTAssertThrowsError(
                try InferenceRequestOptionValidation.validateNonSecret(unsafe)
            ) { error in
                XCTAssertEqual(error as? InferenceCatalogError, .secretLikeRequestOptions)
                XCTAssertFalse(error.localizedDescription.contains("opaque-value"))
            }
        }
    }

    func testSafeProviderSpecificOptionsAreAccepted() throws {
        XCTAssertNoThrow(try InferenceRequestOptionValidation.validateNonSecret([
            "max_tokens": .number(1024),
            "reasoning_effort": .string("xhigh"),
            "thinking": .object(["budget_tokens": .number(4096)]),
            "provider": .object([
                "allow_fallbacks": .bool(false),
                "future_routing": .object([
                    "mode": .string("provider-owned"),
                    "weights": .array([
                        .number(1),
                        .number(2),
                    ]),
                ]),
            ]),
        ]))
    }

    func testConnectionURLsRejectQueryAndFragmentBeforeCatalogPersistence() {
        let secret = "query-secret-value"
        for baseURL in [
            URL(string: "https://example.test/v1?api_key=\(secret)")!,
            URL(string: "https://example.test/v1#\(secret)")!,
        ] {
            XCTAssertThrowsError(try InferenceCatalogReconciler.reconcile(
                draft: makeCatalogDraft(baseURL: baseURL))) { error in
                XCTAssertEqual(error as? InferenceCatalogError, .invalidConnection)
                XCTAssertFalse(error.localizedDescription.contains(secret))
            }
        }

        let chatEndpoint = URL(
            string: "https://example.test/v1/chat/completions?token=\(secret)")!
        let draft = InferenceCatalogDraft(
            connections: [makeConnectionDraft(chatEndpoint: chatEndpoint)],
            profiles: [makeProfileDraft()])
        XCTAssertThrowsError(try InferenceCatalogReconciler.reconcile(draft: draft)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .invalidConnection)
            XCTAssertFalse(error.localizedDescription.contains(secret))
        }
    }

    func testUnknownAndStructuralDurableOptionsFailClosedWithoutEcho() {
        let privateValue = "my-private-routing-value-123"
        for unsafe in [
            ["opaque": .string(privateValue)],
            ["vendor_extension": .object(["mode": .string("adaptive")])],
            ["messages": .array([.string(privateValue)])],
            ["response_format": .object(["schema": .string(privateValue)])],
            ["n": .number(8)],
            ["best_of": .number(8)],
            ["reasoning": .object(["unknown_tuning_key": .number(1)])],
        ] as [[String: JSONValue]] {
            XCTAssertThrowsError(
                try InferenceRequestOptionValidation.validateNonSecret(unsafe)
            ) { error in
                XCTAssertEqual(
                    error as? InferenceCatalogError,
                    .unsupportedDurableRequestOptions)
                XCTAssertFalse(error.localizedDescription.contains(privateValue))
                XCTAssertFalse(error.localizedDescription.contains("vendor_extension"))
            }
        }
    }

    func testPresentationLabelSecretScanIsSeparateFromDurableOptionSchema() {
        XCTAssertNoThrow(
            try InferenceRequestOptionValidation.validateNoSecretLikeMaterial([
                "displayLabel": .string("OpenRouter · Model High"),
            ]))
        XCTAssertThrowsError(
            try InferenceRequestOptionValidation.validateDurableRequestOptions([
                "displayLabel": .string("OpenRouter · Model High"),
            ])) { error in
                XCTAssertEqual(
                    error as? InferenceCatalogError,
                    .unsupportedDurableRequestOptions)
            }
    }

    func testReconcileReusesSemanticallyIdenticalRevisions() throws {
        let draft = makeCatalogDraft()
        let first = try InferenceCatalogReconciler.reconcile(draft: draft)
        let second = try InferenceCatalogReconciler.reconcile(existing: first, draft: draft)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.connections.count, 1)
        XCTAssertEqual(first.profiles.count, 1)
        XCTAssertEqual(first.currentConnectionRefs.first?.inferenceConnectionRevision.rawValue, "1")
        XCTAssertEqual(first.currentProfileRefs.first?.inferenceProfileRevision.rawValue, "1")
    }

    func testRequestAdapterChangeCreatesNewConnectionAndProfileRevisions()
        throws {
        let legacy = try InferenceCatalogReconciler
            .reconcile(
                draft: makeCatalogDraft(
                    requestAdapter:
                        .legacyOpenAIWire))
        let compatible = try InferenceCatalogReconciler
            .reconcile(
                existing: legacy,
                draft: makeCatalogDraft(
                    requestAdapter:
                        .openAICompatible))

        XCTAssertEqual(compatible.connections.count, 2)
        XCTAssertEqual(compatible.profiles.count, 2)
        let current = try InferenceCatalogSnapshot(
            catalog: compatible).resolve(
                XCTUnwrap(
                    compatible.currentProfileRefs.first))
        XCTAssertEqual(
            current.connection.requestAdapter,
            .openAICompatible)
        XCTAssertEqual(
            current.profile.requestAdapter,
            .openAICompatible)
    }

    func testSchemaOneConnectionStillEncodesRequiredEmptyOptions()
        throws {
        let catalog =
            try InferenceCatalogReconciler.reconcile(
                draft: InferenceCatalogDraft(
                    connections: [
                        InferenceConnectionDraft(
                            inferenceConnectionID:
                                connectionID,
                            wire: .openai,
                            requestAdapter:
                                .openAICompatible,
                            baseURL: URL(
                                string:
                                    "https://example.test/v1")!,
                            credentialRef:
                                .environment(
                                    "TEST_API_KEY"),
                            defaultRequestOptions:
                                [:]),
                    ],
                    profiles: [
                        makeProfileDraft(),
                    ]))
        let data = try JSONEncoder().encode(catalog)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: data) as? [String: Any])
        let connections = try XCTUnwrap(
            root["connections"]
                as? [[String: Any]])
        XCTAssertNotNil(
            try XCTUnwrap(connections.first)[
                "defaultRequestOptions"])
    }

    func testProfileSemanticChangeAppendsRevisionAndRetainsOldRevision() throws {
        let first = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft(
            profileOptions: ["reasoning_effort": .string("low")]))
        let second = try InferenceCatalogReconciler.reconcile(
            existing: first,
            draft: makeCatalogDraft(profileOptions: ["reasoning_effort": .string("high")]))

        XCTAssertEqual(second.connections.count, 1)
        XCTAssertEqual(second.profiles.count, 2)
        XCTAssertEqual(second.currentProfileRefs.first?.inferenceProfileRevision.rawValue, "2")

        let snapshot = try InferenceCatalogSnapshot(catalog: second)
        let oldRef = try XCTUnwrap(first.currentProfileRefs.first)
        let old = try snapshot.resolve(oldRef)
        let currentRef = try XCTUnwrap(second.currentProfileRefs.first)
        let current = try snapshot.resolve(currentRef)
        XCTAssertEqual(old.profile.effectiveRequestOptions["reasoning_effort"], .string("low"))
        XCTAssertEqual(current.profile.effectiveRequestOptions["reasoning_effort"], .string("high"))

        let reverted = try InferenceCatalogReconciler.reconcile(
            existing: second,
            draft: makeCatalogDraft(profileOptions: ["reasoning_effort": .string("low")]))
        XCTAssertEqual(reverted.profiles.count, 2)
        XCTAssertEqual(reverted.currentProfileRefs.first, oldRef)
    }

    func testConnectionSemanticChangeAppendsConnectionAndProfileRevisions() throws {
        let first = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft(
            baseURL: URL(string: "https://first.example.test/v1")!))
        let second = try InferenceCatalogReconciler.reconcile(
            existing: first,
            draft: makeCatalogDraft(baseURL: URL(string: "https://second.example.test/v1")!))

        XCTAssertEqual(second.connections.count, 2)
        XCTAssertEqual(second.profiles.count, 2)
        XCTAssertEqual(second.currentConnectionRefs.first?.inferenceConnectionRevision.rawValue, "2")
        XCTAssertEqual(second.currentProfileRefs.first?.inferenceProfileRevision.rawValue, "2")

        let snapshot = try InferenceCatalogSnapshot(catalog: second)
        let old = try snapshot.resolve(XCTUnwrap(first.currentProfileRefs.first))
        let current = try snapshot.resolve(XCTUnwrap(second.currentProfileRefs.first))
        XCTAssertNotEqual(old.connection.connectionRef, current.connection.connectionRef)
        XCTAssertNotEqual(old.connection.baseURL, current.connection.baseURL)
    }

    func testCredentialReferenceChangeCreatesNewRouteRevisionWithoutSecretValue() throws {
        let first = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft(
            credentialRef: .environment("FIRST_KEY")))
        let second = try InferenceCatalogReconciler.reconcile(
            existing: first,
            draft: makeCatalogDraft(credentialRef: .environment("SECOND_KEY")))

        XCTAssertEqual(second.connections.count, 2)
        XCTAssertEqual(second.profiles.count, 2)
        XCTAssertEqual(second.currentConnectionRefs.first?.inferenceConnectionRevision.rawValue, "2")
    }

    func testSnapshotRequiresExactProfileRevisionAndNeverFallsBackToCurrent() throws {
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft())
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let unavailable = InferenceProfileRef(
            inferenceProfileID: profileID,
            inferenceProfileRevision: InferenceProfileRevision(rawValue: "missing"))

        XCTAssertNotNil(snapshot.currentProfileRef(for: profileID))
        XCTAssertThrowsError(try snapshot.resolve(unavailable)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .unresolvedProfile)
        }
    }

    func testResolvedBindingRevalidatesExactConnectionModelAndFingerprint() throws {
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft())
        let snapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let ref = try XCTUnwrap(catalog.currentProfileRefs.first)
        let resolution = try snapshot.resolve(ref)
        let binding = resolution.binding

        XCTAssertEqual(try snapshot.resolve(binding), resolution)
        XCTAssertEqual(binding.inferenceConnectionRevision.rawValue, "1")
        XCTAssertEqual(binding.modelID.rawValue, "vendor/model")
        XCTAssertEqual(binding.variantID, "high")
        XCTAssertEqual(binding.immutableDefinitionFingerprint.count, 64)
        XCTAssertFalse(binding.immutableDefinitionFingerprint.contains("example.test"))
        XCTAssertFalse(binding.immutableDefinitionFingerprint.contains("reasoning"))

        let mismatched = AgentInferenceBinding(
            inferenceProfileRef: binding.inferenceProfileRef,
            inferenceConnectionID: binding.inferenceConnectionID,
            inferenceConnectionRevision: binding.inferenceConnectionRevision,
            modelID: binding.modelID,
            variantID: binding.variantID,
            safeRouteLabel: binding.safeRouteLabel,
            immutableDefinitionFingerprint: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try snapshot.resolve(mismatched)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .bindingMismatch)
        }

        let trustTampered = AgentInferenceBinding(
            inferenceProfileRef: binding.inferenceProfileRef,
            inferenceConnectionID: binding.inferenceConnectionID,
            inferenceConnectionRevision: binding.inferenceConnectionRevision,
            modelID: binding.modelID,
            variantID: binding.variantID,
            safeRouteLabel: binding.safeRouteLabel,
            trustDomain: "tampered-trust-domain",
            egressClassification: binding.egressClassification,
            immutableDefinitionFingerprint: binding.immutableDefinitionFingerprint)
        XCTAssertThrowsError(try snapshot.resolve(trustTampered)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .bindingMismatch)
        }

        let egressTampered = AgentInferenceBinding(
            inferenceProfileRef: binding.inferenceProfileRef,
            inferenceConnectionID: binding.inferenceConnectionID,
            inferenceConnectionRevision: binding.inferenceConnectionRevision,
            modelID: binding.modelID,
            variantID: binding.variantID,
            safeRouteLabel: binding.safeRouteLabel,
            trustDomain: binding.trustDomain,
            egressClassification: "tampered-egress-classification",
            immutableDefinitionFingerprint: binding.immutableDefinitionFingerprint)
        XCTAssertThrowsError(try snapshot.resolve(egressTampered)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .bindingMismatch)
        }
    }

    func testFingerprintRejectsDefinitionRewrittenInPlace() throws {
        let catalog = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft(
            profileOptions: ["reasoning_effort": .string("low")]))
        let originalSnapshot = try InferenceCatalogSnapshot(catalog: catalog)
        let profileRef = try XCTUnwrap(catalog.currentProfileRefs.first)
        let oldBinding = try originalSnapshot.resolve(profileRef).binding
        let original = try XCTUnwrap(catalog.profiles.first)
        let rewritten = InferenceProfileDefinition(
            profileRef: original.profileRef,
            connectionRef: original.connectionRef,
            modelID: original.modelID,
            variantID: original.variantID,
            effectiveRequestOptions: ["reasoning_effort": .string("high")],
            declaredCapabilities: original.declaredCapabilities,
            safeRouteLabel: original.safeRouteLabel)
        let rewrittenCatalog = InferenceCatalog(
            connections: catalog.connections,
            profiles: [rewritten],
            currentConnectionRefs: catalog.currentConnectionRefs,
            currentProfileRefs: catalog.currentProfileRefs)
        let rewrittenSnapshot = try InferenceCatalogSnapshot(catalog: rewrittenCatalog)

        XCTAssertThrowsError(try rewrittenSnapshot.resolve(oldBinding)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .bindingMismatch)
        }
    }

    func testSnapshotRejectsUnsafeOptionsAndSanitizesError() {
        let connectionRef = InferenceConnectionRef(
            inferenceConnectionID: connectionID,
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "1"))
        let unsafeValue = "Bearer should-never-appear-in-errors"
        let connection = InferenceConnectionDefinition(
            connectionRef: connectionRef,
            wire: .openai,
            baseURL: URL(string: "https://private.example.test/v1")!,
            credentialRef: .environment("PRIVATE_KEY_NAME"),
            defaultRequestOptions: ["opaque": .string(unsafeValue)])
        let catalog = InferenceCatalog(
            connections: [connection],
            profiles: [],
            currentConnectionRefs: [connectionRef])

        XCTAssertThrowsError(try InferenceCatalogSnapshot(catalog: catalog)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .secretLikeRequestOptions)
            XCTAssertFalse(error.localizedDescription.contains(unsafeValue))
            XCTAssertFalse(error.localizedDescription.contains("private.example.test"))
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE_KEY_NAME"))
        }
    }

    func testCatalogCodableRoundTripPreservesEveryImmutableRevision() throws {
        let first = try InferenceCatalogReconciler.reconcile(draft: makeCatalogDraft(
            profileOptions: ["reasoning_effort": .string("low")]))
        let catalog = try InferenceCatalogReconciler.reconcile(
            existing: first,
            draft: makeCatalogDraft(profileOptions: ["reasoning_effort": .string("high")]))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(catalog)
        let decoded = try JSONDecoder().decode(InferenceCatalog.self, from: data)

        XCTAssertEqual(decoded, catalog)
        XCTAssertTrue(
            decoded.profiles.allSatisfy {
                $0.declaredCapabilities
                    .contains(.toolSearch)
            })
        let snapshot = try InferenceCatalogSnapshot(catalog: decoded)
        XCTAssertNoThrow(try snapshot.resolve(XCTUnwrap(first.currentProfileRefs.first)))
        XCTAssertNoThrow(try snapshot.resolve(XCTUnwrap(catalog.currentProfileRefs.first)))
    }

    func testDuplicateDraftIdentityAndMissingConnectionFailClosed() throws {
        let connection = makeConnectionDraft()
        let duplicate = InferenceCatalogDraft(
            connections: [connection, connection],
            profiles: [])
        XCTAssertThrowsError(try InferenceCatalogReconciler.reconcile(draft: duplicate)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .duplicateDefinition)
        }

        let missing = InferenceCatalogDraft(
            connections: [],
            profiles: [makeProfileDraft()])
        XCTAssertThrowsError(try InferenceCatalogReconciler.reconcile(draft: missing)) { error in
            XCTAssertEqual(error as? InferenceCatalogError, .unresolvedConnection)
        }
    }

    private func makeCatalogDraft(
        baseURL: URL = URL(string: "https://example.test/v1")!,
        credentialRef: KeychainRef = .environment("TEST_API_KEY"),
        profileOptions: [String: JSONValue] = [:],
        requestAdapter:
            ProviderRequestAdapter =
                .legacyOpenAIWire
    ) -> InferenceCatalogDraft {
        InferenceCatalogDraft(
            connections: [makeConnectionDraft(
                baseURL: baseURL,
                credentialRef: credentialRef,
                requestAdapter:
                    requestAdapter)],
            profiles: [makeProfileDraft(profileOptions: profileOptions)])
    }

    private func makeConnectionDraft(
        baseURL: URL = URL(string: "https://example.test/v1")!,
        chatEndpoint: URL? = nil,
        credentialRef: KeychainRef = .environment("TEST_API_KEY"),
        requestAdapter:
            ProviderRequestAdapter =
                .legacyOpenAIWire
    ) -> InferenceConnectionDraft {
        InferenceConnectionDraft(
            inferenceConnectionID: connectionID,
            wire: .openai,
            requestAdapter:
                requestAdapter,
            baseURL: baseURL,
            chatEndpoint: chatEndpoint,
            credentialRef: credentialRef,
            trust: InferenceConnectionTrust(
                trustDomain: "direct",
                egressClassification: "external"),
            defaultRequestOptions: [
                "provider": .object(["allow_fallbacks": .bool(false)]),
            ])
    }

    private func makeProfileDraft(
        profileOptions: [String: JSONValue] = [:]
    ) -> InferenceProfileDraft {
        InferenceProfileDraft(
            inferenceProfileID: profileID,
            inferenceConnectionID: connectionID,
            modelID: ModelID(rawValue: "vendor/model"),
            variantID: "high",
            modelBaseRequestOptions: [
                "temperature": .number(0.2),
                "reasoning": .object(["effort": .string("medium")]),
            ],
            variantRequestOptions: [
                "reasoning": .object(["effort": .string("high")]),
            ],
            profileRequestOptions: profileOptions,
            declaredCapabilities: [
                .toolCalling,
                .chat,
                .toolSearch,
                .toolCalling,
            ],
            safeRouteLabel: "Primary gateway")
    }
}
