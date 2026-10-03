import Foundation
import IntatisCore

/// Non-plaintext products of a session. Generated images/videos/transcripts go
/// into the artifact store rather than being inlined as chat text
/// (ARCHITECTURE.md §3.5, §9 / spec §9). v0.1 uses `fileAttachment` and
/// `transcript`; the rest are forward slots.
public enum ArtifactKind: String, Codable, Sendable {
    case transcript
    case image
    case video
    case audio
    case fileAttachment = "file_attachment"
    case diff
    case patch
    case report
}

/// Index entry describing one stored artifact. The bytes live on disk at `path`
/// (relative to the store root); this struct is what the event log and UI carry.
public struct ArtifactRef: Codable, Equatable, Sendable {
    public var id: ArtifactID
    public var kind: ArtifactKind
    public var mime: String
    /// Path relative to the store root, e.g. `blobs/art_ab12cd34.txt`.
    public var path: String
    /// Agent name or model id that produced it (nil for user uploads).
    public var producedBy: String?
    /// Generation prompt, for generated artifacts.
    public var prompt: String?
    public var createdAt: Date

    public init(id: ArtifactID,
                kind: ArtifactKind,
                mime: String,
                path: String,
                producedBy: String? = nil,
                prompt: String? = nil,
                createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.mime = mime
        self.path = path
        self.producedBy = producedBy
        self.prompt = prompt
        self.createdAt = createdAt
    }
}
