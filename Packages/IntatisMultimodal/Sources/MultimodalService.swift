import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisArtifacts
import IntatisConversation

/// Runs multimodal generation/transcription tasks: it calls the provider, writes
/// the result into the `ArtifactStore`, and announces it on the event log
/// (ARCHITECTURE.md §3.6, spec §9 — results become artifacts, not plain text).
/// Providers are passed in per call so the app can resolve them from the registry
/// and tests can inject fakes.
public actor MultimodalService {
    private let log: EventLog
    private let store: ArtifactStore

    public init(log: EventLog, store: ArtifactStore) {
        self.log = log
        self.store = store
    }

    /// Generate an image and store it. Returns the first artifact.
    @discardableResult
    public func generateImage(using provider: ImageGenerationProvider,
                              model: ModelID,
                              prompt: String,
                              size: String = "1024x1024") async throws -> ArtifactRef {
        let images = try await provider.generate(ImageRequest(model: model, prompt: prompt, size: size))
        guard !images.isEmpty else { throw IntatisError.provider("no image returned") }
        var first: ArtifactRef?
        for image in images {
            let ext = image.mime.hasSuffix("png") ? "png" : (image.mime.hasSuffix("jpeg") ? "jpg" : "img")
            let ref = try await store.add(kind: .image, mime: image.mime, data: image.data,
                                          ext: ext, producedBy: model.rawValue, prompt: prompt)
            if first == nil { first = ref }
            await announce(ref, producedBy: model.rawValue, prompt: prompt)
        }
        return first!
    }

    /// Transcribe audio. Stores the transcript as an artifact and returns the text.
    @discardableResult
    public func transcribe(using provider: TranscriptionProvider,
                           model: ModelID,
                           audio: Data,
                           filename: String = "audio.m4a",
                           mime: String = "audio/m4a") async throws -> (text: String, artifact: ArtifactRef) {
        let text = try await provider.transcribe(
            TranscriptionRequest(model: model, audio: audio, filename: filename, mime: mime))
        let ref = try await store.add(kind: .transcript, mime: "text/plain",
                                      data: Data(text.utf8), ext: "txt", producedBy: model.rawValue)
        await announce(ref, producedBy: model.rawValue, prompt: nil)
        return (text, ref)
    }

    /// Submit a video job and poll to completion, emitting progress events.
    @discardableResult
    public func generateVideo(using provider: VideoGenerationProvider,
                              request: VideoRequest,
                              pollInterval: UInt64 = 500_000_000,
                              maxPolls: Int = 240) async throws -> ArtifactRef {
        let jobID = try await provider.submit(request)
        let pendingID = ArtifactID.new()
        try? await log.append(.artifactProgress(ArtifactProgressPayload(artifactId: pendingID, progress: 0, state: "queued")))

        for _ in 0..<maxPolls {
            let status = try await provider.poll(jobID)
            try? await log.append(.artifactProgress(ArtifactProgressPayload(
                artifactId: pendingID, progress: status.progress, state: status.state.rawValue)))
            switch status.state {
            case .completed:
                guard let data = status.resultData else { throw IntatisError.provider("video completed without data") }
                let ref = try await store.add(kind: .video, mime: status.mime, data: data,
                                              ext: "mp4", producedBy: request.model.rawValue, prompt: request.prompt)
                await announce(ref, producedBy: request.model.rawValue, prompt: request.prompt)
                return ref
            case .failed:
                throw IntatisError.provider("video generation failed")
            case .queued, .running:
                try? await Task.sleep(nanoseconds: pollInterval)
            }
        }
        throw IntatisError.provider("video generation timed out")
    }

    private func announce(_ ref: ArtifactRef, producedBy: String?, prompt: String?) async {
        try? await log.append(.artifactAdded(ArtifactAddedPayload(
            artifactId: ref.id, kind: ref.kind.rawValue, mime: ref.mime,
            path: store.absoluteURL(for: ref).path, producedBy: producedBy, prompt: prompt)))
    }
}
