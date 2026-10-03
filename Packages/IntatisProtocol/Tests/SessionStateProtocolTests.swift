import Foundation
import XCTest
import IntatisCore
@testable import IntatisProtocol

final class SessionStateProtocolTests: XCTestCase {
    func testSessionSettingsAndMigrationEventsRoundTripWithoutSecretFields() throws {
        let session = SessionID(rawValue: "cowork_phase_s")
        let binding = makeBinding()
        let privateProviderSentinel = "https://private.example.invalid/v1?token=phase-s-secret"
        let settings = CoworkSessionSettings(
            sessionID: session,
            defaultProviderID: privateProviderSentinel,
            defaultModelID: binding.modelID.rawValue,
            defaultInferenceProfileBinding: binding,
            workspaces: [
                CoworkSessionWorkspace(
                    path: "/tmp/phase-s",
                    agentName: "main",
                    isPrimary: true,
                    addedAt: Date(timeIntervalSince1970: 0)),
            ],
            codexAgentProfiles: [
                CoworkCodexAgentProfile(
                    roleName: "research",
                    description: "Research one approved scope.",
                    workspacePath: "/tmp/phase-s-research",
                    inferenceBinding: binding,
                    permissionProfile: "read_only",
                    addedAt: Date(timeIntervalSince1970: 1)),
            ],
            codexRuntimeGeneration:
                CoworkSessionSettings.currentCodexRuntimeGeneration)
        let timestamp = Date(timeIntervalSince1970: 0)
        let envelopes = [
            Envelope(
                seq: 0,
                ts: timestamp,
                session: session,
                event: .sessionSettingsUpdated(SessionSettingsUpdatedPayload(
                    revision: 1,
                    changeKind: .created,
                    kind: .cowork,
                    displayName: "Phase S",
                    cowork: settings))),
            Envelope(
                seq: 1,
                ts: timestamp,
                session: session,
                event: .sessionStorageMigrated(SessionStorageMigratedPayload(
                    migrationID: "legacy-cowork-user-defaults-v1",
                    source: .legacyCoworkUserDefaults,
                    settingsRevision: 1))),
        ]

        let encoder = Envelope.makeEncoder()
        let decoder = Envelope.makeDecoder()
        for (index, envelope) in envelopes.enumerated() {
            let data = try encoder.encode(envelope)
            let decoded = try decoder.decode(Envelope.self, from: data)
            if index == 0,
               case .sessionSettingsUpdated(let payload) = decoded.event {
                XCTAssertNil(payload.cowork?.defaultProviderID)
                XCTAssertEqual(payload.cowork?.defaultInferenceProfileBinding, binding)
                XCTAssertEqual(
                    payload.cowork?.codexAgentProfiles.first?
                        .inferenceBinding,
                    binding)
                XCTAssertEqual(
                    payload.cowork?.codexAgentProfiles.first?.roleName,
                    "research")
                XCTAssertEqual(
                    payload.cowork?.codexRuntimeGeneration,
                    CoworkSessionSettings.currentCodexRuntimeGeneration)
                XCTAssertEqual(payload.revision, 1)
            } else {
                XCTAssertEqual(decoded, envelope)
            }
            let text = String(decoding: data, as: UTF8.self).lowercased()
            XCTAssertFalse(text.contains(privateProviderSentinel.lowercased()))
            for forbidden in [
                "apikey", "authorization", "credentialref", "baseurl",
                "chatendpoint", "bookmarkdata", "requestoptions",
            ] {
                XCTAssertFalse(text.contains(forbidden), "leaked forbidden field \(forbidden)")
            }
        }
        XCTAssertEqual(envelopes[0].event.type.rawValue, "session_settings_updated")
        XCTAssertEqual(envelopes[1].event.type.rawValue, "session_storage_migrated")
    }

    func testLegacyCoworkSettingsWithoutSchemaVersionStillDecodes() throws {
        let legacy = #"{"sessionID":"cowork_legacy","mainAgentName":"main","defaultPermissionProfile":"reviewed","workspaces":[]}"#
        let decoded = try JSONDecoder().decode(
            CoworkSessionSettings.self,
            from: Data(legacy.utf8))
        XCTAssertEqual(decoded.schemaVersion, CoworkSessionSettings.currentSchemaVersion)
        XCTAssertEqual(decoded.sessionID, SessionID(rawValue: "cowork_legacy"))
        XCTAssertNil(decoded.codexRuntimeGeneration)
    }

    func testLegacySessionSettingsWithoutRenameMetadataStillDecodes() throws {
        let legacy = #"{"schemaVersion":1,"revision":2,"previousRevision":1,"changeKind":"renamed","kind":"cowork","displayName":"Legacy Name"}"#

        let decoded = try JSONDecoder().decode(
            SessionSettingsUpdatedPayload.self,
            from: Data(legacy.utf8))

        XCTAssertEqual(decoded.revision, 2)
        XCTAssertEqual(decoded.previousRevision, 1)
        XCTAssertEqual(decoded.changeKind, .renamed)
        XCTAssertEqual(decoded.displayName, "Legacy Name")
        XCTAssertNil(decoded.renameOperationID)
        XCTAssertNil(decoded.displayNameSource)
    }

    func testSessionSettingsRenameMetadataRoundTrips() throws {
        let payload = SessionSettingsUpdatedPayload(
            revision: 2,
            previousRevision: 1,
            changeKind: .renamed,
            kind: .code,
            displayName: "Reviewed Rename",
            renameOperationID: "tool-execution-42",
            displayNameSource: .modelTool)

        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            SessionSettingsUpdatedPayload.self,
            from: data)

        XCTAssertEqual(decoded, payload)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["renameOperationID"] as? String, "tool-execution-42")
        XCTAssertEqual(object["displayNameSource"] as? String, "model_tool")
    }

    private func makeBinding() -> AgentInferenceBinding {
        AgentInferenceBinding(
            inferenceProfileRef: InferenceProfileRef(
                inferenceProfileID: InferenceProfileID(rawValue: "phase-s-profile"),
                inferenceProfileRevision: InferenceProfileRevision(rawValue: "revision-1")),
            inferenceConnectionID: InferenceConnectionID(rawValue: "phase-s-connection"),
            inferenceConnectionRevision: InferenceConnectionRevision(rawValue: "connection-revision-1"),
            modelID: ModelID(rawValue: "phase-s-model"),
            safeRouteLabel: "safe route",
            trustDomain: "trusted",
            egressClassification: "external",
            immutableDefinitionFingerprint: "sha256:phase-s-safe-fingerprint")
    }
}
