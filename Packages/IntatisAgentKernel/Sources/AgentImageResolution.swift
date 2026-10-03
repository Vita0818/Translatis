import Foundation
import IntatisArtifacts
import IntatisCore
import IntatisProviders

/// One request-owned image materialized from the exact session ArtifactStore.
/// The provider attachment is ephemeral; only the descriptor fields may be
/// copied into durable model history.
public struct AgentResolvedImage: Equatable, Sendable {
    public let artifactID: ArtifactID
    public let mimeType: String
    public let byteCount: Int
    public let sha256: String
    public let attachment: ImageAttachment

    public init(
        artifactID: ArtifactID,
        mimeType: String,
        byteCount: Int,
        sha256: String,
        attachment: ImageAttachment
    ) {
        self.artifactID = artifactID
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
        self.attachment = attachment
    }
}

/// Host-injected, exact-session resolver used by AgentLoop for current input,
/// replay, and compaction. It never accepts a path or remote URL.
public typealias AgentImageResolver =
    @Sendable ([ArtifactID]) async throws -> [AgentResolvedImage]

public enum AgentImageResolution {
    /// Adapts the shared bounded Artifact resolver to the provider-neutral
    /// AgentKernel seam. The data URL is generated only inside this request.
    public static func resolver(
        store: ArtifactStore,
        policy: ArtifactImageValidationPolicy = ArtifactImageValidationPolicy()
    ) -> AgentImageResolver {
        let resolver = ArtifactImageResolver(
            store: store,
            policy: policy)
        return { ids in
            try await resolver.resolve(ids).map { image in
                AgentResolvedImage(
                    artifactID: image.artifactID,
                    mimeType: image.mimeType,
                    byteCount: image.byteCount,
                    sha256: image.sha256,
                    attachment: ImageAttachment(url: image.dataURL()))
            }
        }
    }
}
