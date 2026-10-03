import Foundation
import IntatisCore

public struct VideoRequest: Sendable {
    public var model: ModelID
    public var prompt: String
    public var seconds: Int
    public init(model: ModelID, prompt: String, seconds: Int = 4) {
        self.model = model
        self.prompt = prompt
        self.seconds = seconds
    }
}

public enum VideoJobState: String, Sendable {
    case queued, running, completed, failed
}

public struct VideoJobStatus: Sendable {
    public var state: VideoJobState
    public var progress: Double          // 0…1
    public var resultData: Data?         // mp4 bytes when completed
    public var mime: String
    public init(state: VideoJobState, progress: Double, resultData: Data? = nil, mime: String = "video/mp4") {
        self.state = state
        self.progress = progress
        self.resultData = resultData
        self.mime = mime
    }
}

/// `Capability.video_generation`. There is no single standard wire for video, so
/// v0.4 defines the submit/poll abstraction only; a concrete provider is injected
/// (a fake in tests, a real one when configured). The `MultimodalService` drives
/// the polling loop and emits `artifact_progress` events.
public protocol VideoGenerationProvider: Sendable {
    func submit(_ request: VideoRequest) async throws -> String      // job id
    func poll(_ jobID: String) async throws -> VideoJobStatus
}
