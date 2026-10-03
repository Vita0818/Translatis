import Foundation
import IntatisConversation
import IntatisMCP
import IntatisProtocol

/// Atomically revokes every still-live EventLog consent whose exact immutable
/// server reference was invalidated by a global catalog publication.
public struct MCPEventLogCatalogConsentRevoker:
    MCPCatalogConsentRevoker, Sendable
{
    public let log: EventLog

    public init(log: EventLog) {
        self.log = log
    }

    public func revokeConsents(
        _ revocations:
            [MCPCatalogReferenceRevocation]
    ) async throws {
        guard !revocations.isEmpty else { return }
        var byReference:
            [MCPServerReference:
                MCPCatalogReferenceRevocation] = [:]
        for revocation in revocations
            where byReference[revocation.reference] == nil
        {
            byReference[revocation.reference] =
                revocation
        }
        let frozenByReference = byReference
        _ = try await log.appendSessionStateTransaction {
            history in
            let state =
                MCPDurableSessionState.project(history)
            return state.consents.values
                .compactMap {
                    consent -> Event? in
                    guard let revocation =
                            frozenByReference[
                                consent.server]
                    else { return nil }
                    return .mcpConsentRevoked(
                        MCPConsentRevokedPayload(
                            consentID:
                                consent.consentID,
                            kind: consent.kind,
                            server: consent.server,
                            attachmentID:
                                consent.attachmentID,
                            reason: revocation.reason,
                            revocationGeneration:
                                revocation
                                    .replacementGeneration))
                }
                .sorted {
                    lhs, rhs in
                    Self.consentID(lhs)
                        < Self.consentID(rhs)
                }
        }
    }

    private static func consentID(
        _ event: Event
    ) -> String {
        guard case .mcpConsentRevoked(let payload) =
                event
        else { return "" }
        return payload.consentID.rawValue
    }
}
