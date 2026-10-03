import Foundation
import XCTest
import IntatisCore
@testable import IntatisProtocol

final class InferenceProfileProtocolTests: XCTestCase {
    private func binding(model: String = "gpt-5") -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "careful-coder"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: "rev_sha256_01")),
            inferenceConnectionID: InferenceConnectionID(rawValue: "openai-direct"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "conn_rev_sha256_01"),
            modelID: ModelID(rawValue: model),
            variantID: "high-reasoning",
            safeRouteLabel: "OpenAI direct",
            trustDomain: "openai-direct",
            egressClassification: "external",
            immutableDefinitionFingerprint: "sha256:non-secret-profile-identity")
    }

    func testExactProfileReferenceAndBindingRoundTrip() throws {
        let expected = binding()

        let data = try JSONEncoder().encode(expected)
        let decoded = try JSONDecoder().decode(AgentInferenceBinding.self, from: data)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.inferenceProfileID, InferenceProfileID(rawValue: "careful-coder"))
        XCTAssertEqual(decoded.inferenceProfileRevision,
                       InferenceProfileRevision(rawValue: "rev_sha256_01"))
        XCTAssertEqual(decoded.modelID, ModelID(rawValue: "gpt-5"))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "immutableDefinitionFingerprint",
            "inferenceConnectionID",
            "inferenceConnectionRevision",
            "inferenceProfileRef",
            "modelID",
            "safeRouteLabel",
            "trustDomain",
            "egressClassification",
            "variantID",
        ])
        let encoded = String(decoding: data, as: UTF8.self).lowercased()
        for forbiddenKey in ["baseurl", "chatendpoint", "apikey", "credential", "headers", "requestoptions"] {
            XCTAssertFalse(encoded.contains(forbiddenKey), "binding leaked forbidden key: \(forbiddenKey)")
        }
    }

    func testTaskContractFreezesExactBindingAndLegacyContractRemainsDecodable() throws {
        let exactBinding = binding()
        let contract = TaskContract(
            id: TaskID(rawValue: "task_profile"),
            issuer: AgentID(rawValue: "main"),
            assignee: AgentID(rawValue: "worker"),
            objective: "Inspect the workspace.",
            roleHint: "reviewer",
            expectedDeliverable: "report",
            agentInferenceBinding: exactBinding)

        let roundTripped = try JSONDecoder().decode(
            TaskContract.self,
            from: JSONEncoder().encode(contract))
        XCTAssertEqual(roundTripped.agentInferenceBinding, exactBinding)

        let legacy = #"{"id":"task_legacy_profile","kind":"agent_invocation","assignee":"worker","objective":"Inspect","roleHint":"reviewer","expectedDeliverable":"report","relatedAgents":[],"relatedTasks":[],"constraints":[]}"#
        let legacyDecoded = try JSONDecoder().decode(
            TaskContract.self,
            from: Data(legacy.utf8))
        XCTAssertNil(legacyDecoded.agentInferenceBinding)
    }

    func testAgentLifecyclePayloadsCarryBindingAndLegacyPayloadsDecodeAsUnresolved() throws {
        let exactBinding = binding(model: "same-model-different-route")
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let requested = AgentAttachRequestedPayload(
            agent: AgentID(rawValue: "worker"),
            path: "/tmp/work",
            model: exactBinding.modelID,
            profile: "reviewed",
            agentInferenceBinding: exactBinding)
        XCTAssertEqual(
            try decoder.decode(AgentAttachRequestedPayload.self, from: encoder.encode(requested))
                .agentInferenceBinding,
            exactBinding)

        let attached = AgentAttachedPayload(
            agent: AgentID(rawValue: "worker"),
            path: "/tmp/work",
            model: exactBinding.modelID,
            profile: "reviewed",
            agentInferenceBinding: exactBinding)
        XCTAssertEqual(
            try decoder.decode(AgentAttachedPayload.self, from: encoder.encode(attached))
                .agentInferenceBinding,
            exactBinding)

        let spawnRequested = AgentSpawnRequestedPayload(
            requestedBy: AgentID(rawValue: "main"),
            agent: AgentID(rawValue: "worker"),
            path: "/tmp/work",
            model: exactBinding.modelID,
            agentInferenceBinding: exactBinding)
        XCTAssertEqual(
            try decoder.decode(AgentSpawnRequestedPayload.self, from: encoder.encode(spawnRequested))
                .agentInferenceBinding,
            exactBinding)

        let spawned = AgentSpawnedPayload(
            requestedBy: AgentID(rawValue: "main"),
            agent: AgentID(rawValue: "worker"),
            path: "/tmp/work",
            model: exactBinding.modelID,
            agentInferenceBinding: exactBinding)
        XCTAssertEqual(
            try decoder.decode(AgentSpawnedPayload.self, from: encoder.encode(spawned))
                .agentInferenceBinding,
            exactBinding)

        let legacyAttach = #"{"agent":"worker","path":"/tmp/work","model":"m","profile":"reviewed"}"#
        XCTAssertNil(try decoder.decode(
            AgentAttachedPayload.self,
            from: Data(legacyAttach.utf8)).agentInferenceBinding)

        let legacySpawn = #"{"requestedBy":"main","agent":"worker","path":"/tmp/work","model":"m"}"#
        XCTAssertNil(try decoder.decode(
            AgentSpawnedPayload.self,
            from: Data(legacySpawn.utf8)).agentInferenceBinding)
    }

    func testTurnStatsSafelyAttributesExactInferenceBindingAndLegacyStatsDecode() throws {
        let exactBinding = binding()
        let turnID = TurnID(rawValue: "turn-stats")
        let responseMessageID = MessageID(rawValue: "message-stats")
        let stats = TurnStatsPayload(
            promptTokens: 10,
            completionTokens: 2,
            model: exactBinding.modelID.rawValue,
            turnID: turnID,
            responseMessageID: responseMessageID,
            agentID: AgentID(rawValue: "worker"),
            agentInferenceBinding: exactBinding)

        let decoded = try JSONDecoder().decode(
            TurnStatsPayload.self,
            from: JSONEncoder().encode(stats))
        XCTAssertEqual(decoded.agentInferenceBinding, exactBinding)
        XCTAssertEqual(decoded.turnID, turnID)
        XCTAssertEqual(decoded.responseMessageID, responseMessageID)

        let legacy = #"{"promptTokens":10,"model":"gpt-5","agentID":"worker"}"#
        let legacyDecoded = try JSONDecoder().decode(
            TurnStatsPayload.self,
            from: Data(legacy.utf8))
        XCTAssertNil(legacyDecoded.agentInferenceBinding)
        XCTAssertNil(legacyDecoded.turnID)
        XCTAssertNil(legacyDecoded.responseMessageID)
    }
}
