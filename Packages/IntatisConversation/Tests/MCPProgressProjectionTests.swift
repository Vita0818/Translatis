import IntatisCore
import IntatisProtocol
import XCTest
@testable import IntatisConversation

final class MCPProgressProjectionTests:
    XCTestCase
{
    func testCodeProjectionUpsertsExactProgressCard()
        throws
    {
        let server = MCPServerReference(
            serverID: MCPServerID(
                rawValue: "projection-server"),
            serverRevision: MCPServerRevision(
                rawValue: "projection-revision"))
        let generation = MCPConnectionGeneration(
            rawValue: "projection-generation")
        let reported = MCPRequestProgressPayload(
            server: server,
            connectionGeneration: generation,
            authorityFingerprint:
                String(repeating: "a", count: 64),
            requestIDFingerprint:
                "request-sha256",
            progressTokenFingerprint:
                "token-sha256",
            requestMethod: "tools/call",
            progress: 25,
            total: 100,
            phase: .reported,
            diagnostic: MCPDiagnosticSummary(
                code: "mcp_progress",
                summary: "quarter complete"))
        let succeeded = MCPRequestProgressPayload(
            server: server,
            connectionGeneration: generation,
            authorityFingerprint:
                String(repeating: "a", count: 64),
            requestIDFingerprint:
                "request-sha256",
            progressTokenFingerprint:
                "token-sha256",
            requestMethod: "tools/call",
            progress: 100,
            total: 100,
            phase: .succeeded,
            diagnostic: MCPDiagnosticSummary(
                code: "mcp_progress",
                summary: "complete"))
        let session = SessionID(
            rawValue: "projection-session")
        let projection = CodeProjection.build(
            from: [
                Envelope(
                    seq: 1,
                    session: session,
                    event: .mcpRequestProgress(
                        reported)),
                Envelope(
                    seq: 2,
                    session: session,
                    event: .mcpRequestProgress(
                        succeeded)),
            ])

        XCTAssertEqual(projection.items.count, 1)
        let item = try XCTUnwrap(
            projection.items.first)
        XCTAssertEqual(
            item.title,
            "MCP · projection-server · tools/call")
        XCTAssertTrue(item.body.contains("100%"))
        XCTAssertTrue(item.body.contains("complete"))
        XCTAssertTrue(item.complete)
    }
}
