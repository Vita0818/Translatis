#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#else
#error("IntatisAgentKernel requires CryptoKit or swift-crypto")
#endif
import Foundation
import IntatisArtifacts
import IntatisMCP
import IntatisProtocol

/// Production bridge from untrusted MCP tool/resource content into one exact
/// session's owner-only `ArtifactStore`.
///
/// The caller owns the store lifetime. Tool and resource converters for a
/// session must receive the same sink so every binary/oversized block is
/// committed under that session before its reference reaches the model.
public struct MCPArtifactStoreToolSink:
    MCPToolArtifactSink, Sendable
{
    public let store: ArtifactStore

    public init(store: ArtifactStore) {
        self.store = store
    }

    public init(root: URL) throws {
        store = try ArtifactStore(root: root)
    }

    public func storeMCPToolArtifact(
        _ data: Data,
        mimeType: String?,
        provenance: MCPContentProvenance
    ) async throws -> MCPStoredToolArtifact {
        let mime = Self.canonicalMIMEType(mimeType)
        let reference = try await store.add(
            kind: Self.artifactKind(for: mime),
            mime: mime,
            data: data,
            ext: Self.fileExtension(for: mime),
            producedBy: Self.provenanceSummary(
                provenance))
        // ArtifactStore already performs durable readback around both blob and
        // index commits. This exact-byte read additionally proves that the
        // returned ID resolves to the bytes whose hash enters MCP provenance.
        let persisted = try await store.data(
            for: reference.id)
        guard persisted == data else {
            throw MCPToolExecutionError.artifactWriteFailed
        }
        return MCPStoredToolArtifact(
            artifactID: reference.id,
            byteCount: data.count,
            sha256: Self.sha256(data))
    }

    private static func canonicalMIMEType(
        _ raw: String?
    ) -> String {
        guard let raw else {
            return "application/octet-stream"
        }
        let value = raw
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(
                in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty,
              value.utf8.count <= 256,
              value.filter({ $0 == "/" }).count == 1,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(
                    charactersIn:
                        "abcdefghijklmnopqrstuvwxyz0123456789!#$&^_.+-/")
                    .contains($0)
              }) else {
            return "application/octet-stream"
        }
        return value
    }

    private static func artifactKind(
        for mime: String
    ) -> ArtifactKind {
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        return .fileAttachment
    }

    private static func fileExtension(
        for mime: String
    ) -> String {
        switch mime {
        case "text/plain": return "txt"
        case "text/markdown": return "md"
        case "application/json": return "json"
        case "application/pdf": return "pdf"
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "audio/mpeg": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/ogg": return "ogg"
        case "video/mp4": return "mp4"
        default: return "bin"
        }
    }

    private static func provenanceSummary(
        _ value: MCPContentProvenance
    ) -> String {
        String([
            "mcp",
            value.sourceKind.rawValue,
            value.server.serverID.rawValue,
            value.server.serverRevision.rawValue,
            value.connectionGeneration.rawValue,
            value.bindingID.rawValue,
        ].joined(separator: ":").prefix(1_024))
    }

    private static func sha256(_ data: Data)
        -> String
    {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
