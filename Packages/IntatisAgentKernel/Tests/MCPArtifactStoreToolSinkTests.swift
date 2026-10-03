#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import Foundation
import IntatisAgentKernel
import IntatisArtifacts
import IntatisMCP
import IntatisProtocol
import XCTest

final class MCPArtifactStoreToolSinkTests:
    XCTestCase
{
    func testToolConverterSpillsLargeTextImageAndAudioWithExactProvenance()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let converter = MCPToolResultConverter(
            limits: MCPToolResultLimits(
                maximumBlocks: 8,
                maximumTextBytesPerBlock: 8,
                maximumBinaryBytesPerBlock: 1_024,
                maximumTotalBytes: 4_096,
                maximumModelTextBytes: 1_024),
            artifactSink: fixture.sink)
        let image = Data([0x89, 0x50, 0x4E, 0x47])
        let audio = Data([0x52, 0x49, 0x46, 0x46])

        let observation = try await converter.convert(
            MCPRawToolCallResult(content: [
                .text("text larger than inline limit"),
                .image(
                    base64: image.base64EncodedString(),
                    mimeType: "image/png"),
                .audio(
                    base64: audio.base64EncodedString(),
                    mimeType: "audio/wav"),
            ]),
            outputSchema: nil,
            outputSchemaHash: nil,
            provenance: fixture.provenance)

        let structured = try XCTUnwrap(
            observation.structuredResult)
        XCTAssertEqual(
            structured.content.map(\.kind),
            [
                .artifactReference,
                .imageReference,
                .audioReference,
            ])
        XCTAssertTrue(
            structured.content.allSatisfy {
                $0.provenance == fixture.provenance
                    && $0.artifactID != nil
                    && $0.sha256?.count == 64
            })
        let references = await fixture.store.list()
        XCTAssertEqual(references.count, 3)
        XCTAssertEqual(
            Set(references.map(\.kind)),
            Set([
                ArtifactKind.fileAttachment,
                .image,
                .audio,
            ]))
        XCTAssertTrue(references.allSatisfy {
            $0.producedBy?.contains(
                fixture.provenance
                    .connectionGeneration.rawValue) == true
        })
        for block in structured.content {
            let id = try XCTUnwrap(block.artifactID)
            let bytes = try await fixture.store.data(
                for: id)
            XCTAssertEqual(bytes.count, block.byteCount)
            XCTAssertEqual(
                Fixture.sha256(bytes),
                block.sha256)
        }
    }

    func testResourceConverterSpillsOversizedAndBinaryContentIntoSameStore()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let converter = MCPResourceContentConverter(
            limits: MCPResourceResultLimits(
                maximumPages: 8,
                maximumItems: 32,
                maximumContents: 8,
                maximumTextBytesPerContent: 8,
                maximumBinaryBytesPerContent: 1_024,
                maximumTotalBytes: 4_096,
                maximumCursorBytes: 128),
            artifactSink: fixture.sink)
        let binary = Data([0x00, 0x01, 0x02, 0x03])

        let observation = try await converter.convert(
            MCPRawResourceReadResult(contents: [
                try MCPRawResourceContent(
                    uri: "file:///large.txt",
                    mimeType: "text/plain",
                    text: "resource text larger than limit"),
                try MCPRawResourceContent(
                    uri: "file:///payload.bin",
                    mimeType: "application/octet-stream",
                    base64: binary.base64EncodedString()),
            ]),
            serverAlias: "fixture",
            requestedURI: "file:///fixture",
            provenance: fixture.provenance)

        XCTAssertTrue(observation.truncated)
        XCTAssertTrue(
            observation.text.contains(
                "intatis_mcp_resource_hardening"))
        let references = await fixture.store.list()
        XCTAssertEqual(references.count, 2)
        XCTAssertTrue(references.allSatisfy {
            $0.producedBy?.contains(
                fixture.provenance.bindingID.rawValue)
                == true
        })
        let storedBytes = try await references
            .asyncMap { try await fixture.store.data(for: $0.id) }
        XCTAssertEqual(
            Set(storedBytes),
            Set([
                Data("resource text larger than limit".utf8),
                binary,
            ]))
    }
}

private struct Fixture {
    let root: URL
    let store: ArtifactStore
    let sink: MCPArtifactStoreToolSink
    let provenance: MCPContentProvenance

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "intatis-mcp-artifact-\(UUID().uuidString)",
                isDirectory: true)
        store = try ArtifactStore(root: root)
        sink = MCPArtifactStoreToolSink(store: store)
        provenance = MCPContentProvenance(
            sourceKind: .tool,
            server: MCPServerReference(
                serverID: MCPServerID(
                    rawValue: "mcpserver_artifact_fixture"),
                serverRevision: MCPServerRevision(
                    rawValue: "mcprev_artifact_fixture")),
            connectionGeneration:
                MCPConnectionGeneration(
                    rawValue: "mcpconn_artifact_fixture"),
            rawCatalogRevision:
                MCPRawCatalogRevision(
                    rawValue: "mcpraw_artifact_fixture"),
            agentCatalogViewRevision:
                MCPAgentCatalogViewRevision(
                    rawValue: "mcpview_artifact_fixture"),
            bindingID: MCPBindingID(
                rawValue: "mcpbinding_artifact_fixture"),
            protocolProfile: .codexCompat,
            negotiatedProtocolVersion:
                MCPNegotiatedProtocolVersion(
                    .v2025_06_18),
            remoteName: "fixture_tool",
            environmentReference:
                MCPEnvironmentReference(
                    rawValue: "mcpenv_artifact_fixture"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func sha256(_ data: Data) -> String {
        // The production converter validates the sink's digest. Reuse a
        // one-block converter-free implementation through Crypto is avoided
        // here so this test target remains platform-neutral.
        let temporary = MCPStoredDigest(data)
        return temporary.value
    }
}

private struct MCPStoredDigest {
    let value: String

    init(_ data: Data) {
        #if canImport(CryptoKit)
        value = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        #elseif canImport(Crypto)
        value = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        #else
        value = ""
        #endif
    }
}

private extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
