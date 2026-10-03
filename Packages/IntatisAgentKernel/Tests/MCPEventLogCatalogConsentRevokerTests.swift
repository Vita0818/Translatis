import Foundation
import IntatisConversation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import XCTest
@testable import IntatisAgentKernel

final class MCPEventLogCatalogConsentRevokerTests:
    XCTestCase
{
    func testMatchingConsentsAreAtomicallyRevokedAndUnrelatedRemain()
        async throws
    {
        let root =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "intatis-mcp-consent-revoker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let session =
            SessionID(
                rawValue:
                    "sess_catalog_consent_revoke")
        let log = try EventLog(
            session: session,
            fileURL:
                root.appendingPathComponent(
                    "events.jsonl"))
        let target = MCPServerReference(
            serverID:
                MCPServerID(
                    rawValue:
                        "mcpserver_target"),
            serverRevision:
                MCPServerRevision(
                    rawValue:
                        "mcprev_target_1"))
        let unrelated = MCPServerReference(
            serverID:
                MCPServerID(
                    rawValue:
                        "mcpserver_unrelated"),
            serverRevision:
                MCPServerRevision(
                    rawValue:
                        "mcprev_unrelated_1"))
        let targetConsent = MCPConsent(
            consentID:
                MCPConsentID(
                    rawValue:
                        "mcpconsent_target"),
            kind: .connect,
            server: target,
            attachmentID:
                MCPAttachmentID(
                    rawValue:
                        "mcpattach_target"),
            authorityFingerprint:
                "authority_target",
            environmentReference:
                MCPEnvironmentReference(
                    rawValue:
                        "mcpenv_target"),
            policyRevision:
                MCPPolicyRevision(
                    rawValue:
                        "mcppolicy_target"))
        let unrelatedConsent = MCPConsent(
            consentID:
                MCPConsentID(
                    rawValue:
                        "mcpconsent_unrelated"),
            kind: .connect,
            server: unrelated,
            attachmentID:
                MCPAttachmentID(
                    rawValue:
                        "mcpattach_unrelated"),
            authorityFingerprint:
                "authority_unrelated",
            environmentReference:
                MCPEnvironmentReference(
                    rawValue:
                        "mcpenv_unrelated"),
            policyRevision:
                MCPPolicyRevision(
                    rawValue:
                        "mcppolicy_unrelated"))
        _ = try await log.append([
            .mcpConsentGranted(
                MCPConsentGrantedPayload(
                    consent: targetConsent)),
            .mcpConsentGranted(
                MCPConsentGrantedPayload(
                    consent: unrelatedConsent)),
        ])
        let replacement =
            MCPRevocationGeneration(
                rawValue:
                    "mcprevocation_catalog_test")
        let revoker =
            MCPEventLogCatalogConsentRevoker(
                log: log)
        try await revoker.revokeConsents([
            MCPCatalogReferenceRevocation(
                reference: target,
                reason: .serverTombstoned,
                replacementGeneration:
                    replacement),
        ])

        let replay =
            try await log
                .replayForProjectionChecked()
        let state =
            MCPDurableSessionState.project(
                replay.envelopes)
        XCTAssertNil(
            state.consents[
                targetConsent.consentID])
        XCTAssertEqual(
            state.consents[
                unrelatedConsent.consentID],
            unrelatedConsent)
        XCTAssertEqual(
            state.revocationGenerations[
                targetConsent.attachmentID],
            replacement)
        let matchingEvents =
            replay.envelopes.compactMap {
                envelope
                    -> MCPConsentRevokedPayload? in
                guard case .mcpConsentRevoked(
                    let payload) =
                        envelope.event
                else { return nil }
                return payload
            }
        XCTAssertEqual(matchingEvents.count, 1)
        XCTAssertEqual(
            matchingEvents.first?.reason,
            .serverTombstoned)

        // Re-observing the same complete publication is idempotent.
        try await revoker.revokeConsents([
            MCPCatalogReferenceRevocation(
                reference: target,
                reason: .serverTombstoned,
                replacementGeneration:
                    replacement),
        ])
        let secondReplay =
            try await log
                .replayForProjectionChecked()
        XCTAssertEqual(
            secondReplay.envelopes.filter {
                if case .mcpConsentRevoked =
                        $0.event {
                    return true
                }
                return false
            }.count,
            1)
    }
}
