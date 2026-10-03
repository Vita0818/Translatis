import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisProviders

final class AgentModelContextPolicyTests: XCTestCase {
    func testCodexDerivedThresholdsUseNinetyAndNinetyFivePercent() {
        let policy = AgentModelContextPolicy(
            contextWindowTokens: 100_000)

        XCTAssertEqual(policy.resolvedContextWindowTokens, 100_000)
        XCTAssertEqual(policy.resolvedAutoCompactTokenLimit, 90_000)
        XCTAssertEqual(policy.hardUsableContextWindowTokens, 95_000)
        XCTAssertEqual(
            policy.automaticCompactionTriggerTokens,
            90_000)
        XCTAssertTrue(policy.isAutomaticCompactionEnabled)
    }

    func testExplicitAutoCompactLimitIsClampedAgainstResolvedWindow() {
        XCTAssertEqual(
            AgentModelContextPolicy(
                contextWindowTokens: 100_000,
                autoCompactTokenLimit: 96_000)
                .resolvedAutoCompactTokenLimit,
            90_000)
        XCTAssertEqual(
            AgentModelContextPolicy(
                contextWindowTokens: 100_000,
                autoCompactTokenLimit: 80_000)
                .resolvedAutoCompactTokenLimit,
            80_000)
        XCTAssertEqual(
            AgentModelContextPolicy(
                autoCompactTokenLimit: 42_000)
                .resolvedAutoCompactTokenLimit,
            42_000)
        XCTAssertEqual(
            AgentModelContextPolicy(
                autoCompactTokenLimit: 960_000)
                .resolvedAutoCompactTokenLimit,
            900_000)
    }

    func testUnspecifiedMetadataUsesProductDefaultWindow() {
        let policy = AgentModelContextPolicy.unspecified

        XCTAssertEqual(policy.resolvedContextWindowTokens, 1_000_000)
        XCTAssertEqual(policy.resolvedAutoCompactTokenLimit, 900_000)
        XCTAssertEqual(policy.hardUsableContextWindowTokens, 950_000)
        XCTAssertEqual(
            policy.automaticCompactionTriggerTokens,
            900_000)
        XCTAssertTrue(policy.isAutomaticCompactionEnabled)
    }

    func testMaximumContextIsCodexFallbackForResolvedWindow() {
        let policy = AgentModelContextPolicy(
            maxContextWindowTokens: 200_000,
            effectiveContextWindowPercent: 80)

        XCTAssertEqual(policy.resolvedContextWindowTokens, 200_000)
        XCTAssertEqual(policy.resolvedAutoCompactTokenLimit, 180_000)
        XCTAssertEqual(policy.hardUsableContextWindowTokens, 160_000)
        XCTAssertEqual(
            policy.automaticCompactionTriggerTokens,
            160_000)
    }

    func testMetadataParserPrefersCodexSnakeCaseAndReadsOpenCodeLimit() {
        let codex = AgentModelContextPolicy(configurationMetadata: [
            "context_window": .number(128_000),
            "max_context_window": .number(256_000),
            "auto_compact_token_limit": .number(100_000),
            "effective_context_window_percent": .number(92),
            "comp_hash": .string("compact-compatible-v1"),
            "limit": .object(["context": .number(64_000)]),
        ])

        XCTAssertEqual(codex.contextWindowTokens, 128_000)
        XCTAssertEqual(codex.maxContextWindowTokens, 256_000)
        XCTAssertEqual(codex.resolvedAutoCompactTokenLimit, 100_000)
        XCTAssertEqual(codex.hardUsableContextWindowTokens, 117_760)
        XCTAssertEqual(codex.compHash, "compact-compatible-v1")

        let openCode = AgentModelContextPolicy(configurationMetadata: [
            "limit": .object(["context": .number(200_000)]),
        ])
        XCTAssertEqual(openCode.contextWindowTokens, 200_000)
        XCTAssertEqual(openCode.resolvedAutoCompactTokenLimit, 180_000)
    }

    func testMetadataParserIgnoresGuessedOrNonIntegralValues() {
        let policy = AgentModelContextPolicy(configurationMetadata: [
            "context_window": .string("128000"),
            "max_context_window": .number(64_000.5),
            "auto_compact_token_limit": .bool(true),
            "effective_context_window_percent": .number(101),
            "comp_hash": .string(" invalid "),
            "limit": .object(["context": .string("200000")]),
        ])

        XCTAssertEqual(policy, .unspecified)
        XCTAssertEqual(
            policy.automaticCompactionTriggerTokens,
            900_000)
        XCTAssertTrue(policy.isAutomaticCompactionEnabled)
    }

    func testLegacyProfileDecodeDefaultsToUnspecifiedAndKeepsLegacyEncoding() throws {
        let definition = InferenceProfileDefinition(
            profileRef: profileRef,
            connectionRef: connectionRef,
            modelID: ModelID(rawValue: "test/model"))
        let encoded = try JSONEncoder().encode(definition)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded)
                as? [String: Any])

        XCTAssertNil(object["modelContextPolicy"])
        let decoded = try JSONDecoder().decode(
            InferenceProfileDefinition.self,
            from: encoded)
        XCTAssertEqual(decoded.modelContextPolicy, .unspecified)
        XCTAssertEqual(decoded, definition)
    }

    func testUnspecifiedPolicyPreservesLegacyBindingFingerprint() throws {
        let catalog = try InferenceCatalogReconciler.reconcile(
            draft: catalogDraft(policy: .unspecified))
        let snapshot = try InferenceCatalogSnapshot(
            catalog: catalog)
        let resolution = try snapshot.resolve(
            XCTUnwrap(
                catalog.currentProfileRefs.first))

        // Fixed output of the pre-model-context fingerprint fields. An
        // unspecified additive policy must not invalidate old bindings.
        XCTAssertEqual(
            resolution.binding
                .immutableDefinitionFingerprint,
            "26b7f42a449b7f2ea78164901b96d0f375bfc787724517c8c83eface808ef307")
    }

    func testPolicyChangesProfileRevisionAndImmutableFingerprint() throws {
        let first = try InferenceCatalogReconciler.reconcile(
            draft: catalogDraft(policy: .unspecified))
        let policy = AgentModelContextPolicy(
            contextWindowTokens: 100_000,
            compHash: "context-v1")
        let second = try InferenceCatalogReconciler.reconcile(
            existing: first,
            draft: catalogDraft(policy: policy))

        XCTAssertEqual(second.profiles.count, 2)
        XCTAssertEqual(
            second.currentProfileRefs.first?
                .inferenceProfileRevision.rawValue,
            "2")
        let roundTripped = try JSONDecoder().decode(
            InferenceCatalog.self,
            from: JSONEncoder().encode(second))
        XCTAssertEqual(roundTripped, second)
        XCTAssertEqual(
            roundTripped.profiles.last?
                .modelContextPolicy,
            policy)

        let connection = try XCTUnwrap(second.connections.first)
        let original = try XCTUnwrap(first.profiles.first)
        let rewrittenInPlace = InferenceProfileDefinition(
            profileRef: original.profileRef,
            connectionRef: original.connectionRef,
            modelID: original.modelID,
            effectiveRequestOptions:
                original.effectiveRequestOptions,
            modelContextPolicy: policy,
            declaredCapabilities:
                original.declaredCapabilities,
            safeRouteLabel: original.safeRouteLabel)
        XCTAssertNotEqual(
            original.immutableDefinitionFingerprint(
                connection: connection),
            rewrittenInPlace.immutableDefinitionFingerprint(
                connection: connection))
    }

    func testInvalidProgrammaticPolicyFailsCatalogValidation() {
        XCTAssertThrowsError(
            try InferenceCatalogReconciler.reconcile(
                draft: catalogDraft(policy:
                    AgentModelContextPolicy(
                        contextWindowTokens: -1)))
        ) { error in
            XCTAssertEqual(
                error as? InferenceCatalogError,
                .invalidProfile)
        }
    }

    private var connectionRef: InferenceConnectionRef {
        InferenceConnectionRef(
            inferenceConnectionID:
                InferenceConnectionID(rawValue: "test-route"),
            inferenceConnectionRevision:
                InferenceConnectionRevision(rawValue: "1"))
    }

    private var profileRef: InferenceProfileRef {
        InferenceProfileRef(
            inferenceProfileID:
                InferenceProfileID(rawValue: "test-profile"),
            inferenceProfileRevision:
                InferenceProfileRevision(rawValue: "1"))
    }

    private func catalogDraft(
        policy: AgentModelContextPolicy
    ) -> InferenceCatalogDraft {
        InferenceCatalogDraft(
            connections: [
                InferenceConnectionDraft(
                    inferenceConnectionID:
                        connectionRef.inferenceConnectionID,
                    wire: .openai,
                    baseURL:
                        URL(string:
                            "https://example.test/v1")!,
                    credentialRef:
                        .environment("TEST_API_KEY")),
            ],
            profiles: [
                InferenceProfileDraft(
                    inferenceProfileID:
                        profileRef.inferenceProfileID,
                    inferenceConnectionID:
                        connectionRef.inferenceConnectionID,
                    modelID:
                        ModelID(rawValue: "test/model"),
                    modelContextPolicy: policy,
                    declaredCapabilities:
                        [.chat, .toolCalling]),
            ])
    }
}
