import Foundation
import IntatisCore

// Event payloads for v0.4 (Multimodal). Generated images / videos / transcripts
// land in the artifact store; these events announce them and report progress for
// long-running jobs (ARCHITECTURE.md §3.5, §3.6, §5.4).

/// A new artifact is available. `path` is an absolute file path on this machine
/// so a client can load it directly. `kind` mirrors `ArtifactKind` (kept as a
/// string here so Protocol stays independent of the Artifacts module).
public struct ArtifactAddedPayload: Codable, Equatable, Sendable {
    public var artifactId: ArtifactID
    public var kind: String
    public var mime: String
    public var path: String
    public var producedBy: String?
    public var prompt: String?
    public init(artifactId: ArtifactID, kind: String, mime: String, path: String,
                producedBy: String? = nil, prompt: String? = nil) {
        self.artifactId = artifactId
        self.kind = kind
        self.mime = mime
        self.path = path
        self.producedBy = producedBy
        self.prompt = prompt
    }
}

/// Progress for a long-running generation job (e.g. video). `progress` is 0…1.
public struct ArtifactProgressPayload: Codable, Equatable, Sendable {
    public var artifactId: ArtifactID
    public var progress: Double
    public var state: String   // queued / running / completed / failed
    public init(artifactId: ArtifactID, progress: Double, state: String) {
        self.artifactId = artifactId
        self.progress = progress
        self.state = state
    }
}
