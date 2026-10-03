#if canImport(SwiftUI)
import Foundation
import IntatisArtifacts
import IntatisCore
import IntatisProviders
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// One attachment staged in a composer before its `user_message` is durable.
/// The binary is already preserved in the session ArtifactStore; the draft
/// keeps only presentation metadata and the stable artifact identity.
public struct IntatisComposerDraftAttachment: Identifiable, Equatable, Sendable {
    public var id: ArtifactID
    public var name: String
    public var mime: String

    public init(id: ArtifactID, name: String, mime: String) {
        self.id = id
        self.name = name
        self.mime = mime
    }
}

/// Immutable bytes read from a user-selected URL while its security scope is
/// active. Keeping URL access here lets Chat and Cowork share the same import
/// behavior without making either view model retain a bookmark or file handle.
public struct IntatisComposerAttachmentFile: Equatable, Sendable {
    public var name: String
    public var data: Data
    public var mime: String

    public init(name: String, data: Data, mime: String) {
        self.name = name
        self.data = data
        self.mime = mime
    }
}

public enum IntatisComposerAttachmentFileReader {
    public static func read(_ url: URL) throws -> IntatisComposerAttachmentFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        #if canImport(UniformTypeIdentifiers)
        let mime: String
        switch url.pathExtension.lowercased() {
        case "png":
            mime = "image/png"
        case "jpg", "jpeg":
            mime = "image/jpeg"
        default:
            let type = UTType(filenameExtension: url.pathExtension)
            mime = type?.preferredMIMEType ?? "application/octet-stream"
        }
        #else
        let mime = "application/octet-stream"
        #endif
        return IntatisComposerAttachmentFile(
            name: url.lastPathComponent,
            data: data,
            mime: mime)
    }
}

public enum IntatisComposerAttachmentResolutionError: LocalizedError, Sendable {
    case missing(ArtifactID)
    case unsupported(ArtifactID, mime: String, surface: String)
    case unreadable(ArtifactID, message: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let id):
            return "Attachment \(id.rawValue) is no longer available in this session."
        case .unsupported(let id, let mime, let surface):
            return "Attachment \(id.rawValue) uses \(mime), but \(surface) currently accepts image attachments only. The submitted file remains preserved locally."
        case .unreadable(let id, let message):
            return "Attachment \(id.rawValue) could not be read: \(message)"
        }
    }

    public var code: String {
        switch self {
        case .missing: return "attachment_missing"
        case .unsupported: return "attachment_type_unsupported"
        case .unreadable: return "attachment_unreadable"
        }
    }

    public var retryable: Bool {
        switch self {
        case .missing, .unsupported: return false
        case .unreadable: return true
        }
    }
}

/// Shared session attachment storage and provider-input recovery used by the
/// macOS Chat and Cowork composers. Artifact IDs, never base64 bytes, are the
/// durable EventLog representation.
public struct IntatisComposerAttachmentStore: Sendable {
    private let store: ArtifactStore

    public init(store: ArtifactStore) {
        self.store = store
    }

    public func preserve(
        _ file: IntatisComposerAttachmentFile
    ) async throws -> IntatisComposerDraftAttachment {
        try Task.checkCancellation()
        let ref = try await store.addAttachment(
            name: file.name,
            data: file.data,
            mime: file.mime)

        // A submitted payload can retain only the ArtifactID, so do not expose
        // the draft until the index and blob can be read back coherently.
        let verifiedRef = await store.ref(for: ref.id)
        let verifiedData = try await store.data(for: ref.id)
        guard verifiedRef == ref,
              verifiedData == file.data else {
            throw IntatisError.io("attachment read-back verification failed")
        }
        try Task.checkCancellation()
        return IntatisComposerDraftAttachment(
            id: ref.id,
            name: file.name,
            mime: file.mime)
    }

    public func imageAttachments(
        for ids: [ArtifactID],
        surface: String
    ) async throws -> [ImageAttachment] {
        var result: [ImageAttachment] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            try Task.checkCancellation()
            guard let ref = await store.ref(for: id) else {
                throw IntatisComposerAttachmentResolutionError.missing(id)
            }
            guard ref.mime.hasPrefix("image/") else {
                throw IntatisComposerAttachmentResolutionError.unsupported(
                    id,
                    mime: ref.mime,
                    surface: surface)
            }
            let data: Data
            do {
                data = try await store.data(for: id)
            } catch {
                throw IntatisComposerAttachmentResolutionError.unreadable(
                    id,
                    message: error.localizedDescription)
            }
            result.append(.base64(
                mime: ref.mime,
                base64: data.base64EncodedString()))
        }
        return result
    }
}
#endif
