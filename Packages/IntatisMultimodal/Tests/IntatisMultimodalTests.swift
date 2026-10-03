import XCTest
import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisArtifacts
import IntatisConversation
@testable import IntatisMultimodal

private struct FakeImage: ImageGenerationProvider {
    let images: [GeneratedImage]
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage] { images }
}

private struct FakeTranscribe: TranscriptionProvider {
    let text: String
    func transcribe(_ request: TranscriptionRequest) async throws -> String { text }
}

private final class FakeVideo: VideoGenerationProvider, @unchecked Sendable {
    private var polls: [VideoJobStatus]
    private var i = 0
    private let lock = NSLock()
    init(_ polls: [VideoJobStatus]) { self.polls = polls }
    func submit(_ request: VideoRequest) async throws -> String { "job1" }
    func poll(_ jobID: String) async throws -> VideoJobStatus {
        lock.withLock {
            let status = polls[min(i, polls.count - 1)]
            i += 1
            return status
        }
    }
}

final class IntatisMultimodalTests: XCTestCase {

    private func setup() throws -> (EventLog, ArtifactStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mm-\(UUID().uuidString)", isDirectory: true)
        let log = try EventLog(session: SessionID(rawValue: "mm"), fileURL: root.appendingPathComponent("events.jsonl"))
        let store = try ArtifactStore(root: root.appendingPathComponent("artifacts"))
        return (log, store, root)
    }

    func testGenerateImageStoresArtifactAndEmitsEvent() async throws {
        let (log, store, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MultimodalService(log: log, store: store)
        let provider = FakeImage(images: [GeneratedImage(data: Data("PNG".utf8), mime: "image/png")])
        let ref = try await service.generateImage(using: provider, model: ModelID(rawValue: "img"), prompt: "a cat")
        let storedData = try await store.data(for: ref.id)
        let eventTypes = await log.replay().map { $0.event.type }
        XCTAssertEqual(ref.kind, .image)
        XCTAssertEqual(storedData, Data("PNG".utf8))
        XCTAssertTrue(eventTypes.contains(.artifactAdded))
    }

    func testTranscribeStoresTranscript() async throws {
        let (log, store, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MultimodalService(log: log, store: store)
        let (text, ref) = try await service.transcribe(using: FakeTranscribe(text: "hello"),
                                                        model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3]))
        let storedData = try await store.data(for: ref.id)
        XCTAssertEqual(text, "hello")
        XCTAssertEqual(ref.kind, .transcript)
        XCTAssertEqual(String(decoding: storedData, as: UTF8.self), "hello")
    }

    func testGenerateVideoEmitsProgressThenArtifact() async throws {
        let (log, store, root) = try setup()
        defer { try? FileManager.default.removeItem(at: root) }
        let service = MultimodalService(log: log, store: store)
        let provider = FakeVideo([
            VideoJobStatus(state: .running, progress: 0.5),
            VideoJobStatus(state: .completed, progress: 1.0, resultData: Data("MP4".utf8)),
        ])
        let ref = try await service.generateVideo(using: provider,
                                                  request: VideoRequest(model: ModelID(rawValue: "vid"), prompt: "ocean"),
                                                  pollInterval: 1_000)
        XCTAssertEqual(ref.kind, .video)
        let types = await log.replay().map { $0.event.type }
        XCTAssertTrue(types.contains(.artifactProgress))
        XCTAssertTrue(types.contains(.artifactAdded))
    }
}
