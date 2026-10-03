import XCTest
import IntatisCore
import IntatisMCP
import IntatisProtocol
@testable import IntatisAgentKernel

final class AgentToolOutputLoweringTests: XCTestCase {
    func testStructuredResultLowersTextJSONAndImagesInSourceOrder() throws {
        let first = ArtifactID(rawValue: "art_first")
        let second = ArtifactID(rawValue: "art_second")
        let result = MCPStructuredToolResult(
            content: [
                MCPContentBlock(kind: .text, text: "observed"),
                MCPContentBlock(
                    kind: .imageReference,
                    artifactID: first,
                    mimeType: "image/png",
                    byteCount: 10,
                    sha256: String(repeating: "a", count: 64)),
                MCPContentBlock(
                    kind: .structuredJSON,
                    structuredJSON: .object([
                        "z": .number(2),
                        "a": .number(1),
                    ])),
                MCPContentBlock(
                    kind: .imageReference,
                    artifactID: second,
                    mimeType: "image/jpeg",
                    byteCount: 20,
                    sha256: String(repeating: "b", count: 64)),
            ],
            structuredContent: .object([
                "ignored": .string("must not be duplicated"),
            ]))

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "must not be used")

        XCTAssertEqual(lowered.output, "observed\n{\"a\":1,\"z\":2}")
        XCTAssertEqual(
            lowered.imageReferences.map(\.artifactID),
            [first, second])
    }

    func testReferencePresentationsReuseMCPConverterFormatWithoutMetadata()
        throws
    {
        let result = MCPStructuredToolResult(
            content: [
                MCPContentBlock(
                    kind: .text,
                    text: "Authorization: Bearer text-secret-value"),
                MCPContentBlock(
                    kind: .structuredJSON,
                    structuredJSON: .object([
                        "api_key": .string("sk-structuredsecret123"),
                    ])),
                MCPContentBlock(
                    kind: .resourceLink,
                    text: "password=metadata-secret",
                    uri: "https://example.test/item?token=resource-secret"),
                MCPContentBlock(
                    kind: .embeddedResourceReference,
                    text: "secret=embedded-secret",
                    uri: "mcp://embedded?api_key=uri-secret"),
                MCPContentBlock(
                    kind: .artifactReference,
                    text: "client_secret=artifact-metadata",
                    artifactID: ArtifactID(
                        rawValue: "sk-artifactsecret123")),
            ],
            structuredContent: .object([
                "password": .string("must-not-use-structured-content"),
            ]))

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "must-not-use-observation")

        for secret in [
            "text-secret-value",
            "sk-structuredsecret123",
            "metadata-secret",
            "resource-secret",
            "embedded-secret",
            "uri-secret",
            "sk-artifactsecret123",
            "artifact-metadata",
            "must-not-use-structured-content",
            "must-not-use-observation",
        ] {
            XCTAssertFalse(lowered.output.contains(secret), secret)
        }
        XCTAssertTrue(lowered.output.contains("Authorization: [REDACTED]"))
        XCTAssertTrue(lowered.output.contains("\"api_key\":\"[REDACTED]\""))
        XCTAssertTrue(lowered.output.contains(
            MCPToolResultPresentation.resource(
                uri: "https://example.test/item?token=[REDACTED]")))
        XCTAssertTrue(lowered.output.contains(
            MCPToolResultPresentation.embeddedResource(
                uri: "mcp://embedded?api_key=[REDACTED]")))
        XCTAssertTrue(lowered.output.contains(
            MCPToolResultPresentation.textArtifact(
                artifactID: "[REDACTED_TOKEN]")))
        XCTAssertFalse(lowered.output.contains("password="))
        XCTAssertFalse(lowered.output.contains("secret="))
        XCTAssertFalse(lowered.output.contains("client_secret="))
        XCTAssertTrue(lowered.imageReferences.isEmpty)
    }

    func testStructuredTextIsBoundedByUTF8BytesAfterSanitization() throws {
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(
                kind: .text,
                text: "api_key=sk-boundedsecret123 "
                    + String(repeating: "🙂", count: 17_000)),
        ])

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "unused")

        XCTAssertLessThanOrEqual(
            lowered.output.utf8.count,
            AgentCanonicalToolOutput.maximumTextBytes)
        XCTAssertTrue(lowered.output.hasPrefix("api_key=[REDACTED] "))
        XCTAssertFalse(lowered.output.contains("sk-boundedsecret123"))
    }

    func testPureImageOutputDoesNotInventPlaceholderText() throws {
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(
                kind: .imageReference,
                artifactID: ArtifactID(rawValue: "art_image"),
                mimeType: "image/png",
                byteCount: 1,
                sha256: String(repeating: "0", count: 64)),
        ])

        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "[legacy image placeholder]")

        XCTAssertEqual(lowered.output, "")
        XCTAssertEqual(lowered.imageReferences.count, 1)
    }

    func testAudioFailsWithStableUnsupportedCode() {
        let result = MCPStructuredToolResult(content: [
            MCPContentBlock(
                kind: .audioReference,
                artifactID: ArtifactID(rawValue: "art_audio"),
                mimeType: "audio/wav",
                byteCount: 10,
                sha256: String(repeating: "c", count: 64)),
        ])

        XCTAssertThrowsError(try AgentCanonicalToolOutput.lower(
            structuredResult: result,
            legacyObservation: "audio")) { error in
            XCTAssertEqual(
                (error as? AgentToolOutputLoweringError)?.stableCode,
                "media_output_unsupported")
        }
    }

    func testStructuredEmptyResultUsesStableText() throws {
        let lowered = try AgentCanonicalToolOutput.lower(
            structuredResult: MCPStructuredToolResult(content: []),
            legacyObservation: "legacy placeholder")

        XCTAssertEqual(lowered.output, "MCP tool returned no content.")
        XCTAssertTrue(lowered.imageReferences.isEmpty)
    }
}
