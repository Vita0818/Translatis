import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The recorded-file runtime and disk-backed HTTP body construction are adapted
// from the first-party Flotis AudioRecorder/TranscriptionAdapterRegistry/
// OpenAICompatibleTranscriber pipeline. Intatis keeps only the single-model
// batch path and binds it to the host-owned exact transcription route.

public let maximumTranscriptionUploadBytes = 25 * 1_024 * 1_024

public enum TranscriptionAudioFileFormat: String, Equatable, Sendable {
    case m4a
    case wav

    public var fileExtension: String { rawValue }

    public var mimeType: String {
        switch self {
        case .m4a:
            return "audio/mp4"
        case .wav:
            return "audio/wav"
        }
    }
}

/// The single recorded-file runtime selected before microphone access. These
/// are host defaults, not a second user-facing settings surface.
public struct RecordedFileTranscriptionConfiguration: Equatable, Sendable {
    public let format: TranscriptionAudioFileFormat
    public let sampleRate: Int
    public let channels: Int
    public let maximumRecordingDurationSeconds: Int?
    public let stopLeadSeconds: Int
    public let maximumUploadBytes: Int?

    public init(
        format: TranscriptionAudioFileFormat,
        sampleRate: Int,
        channels: Int,
        maximumRecordingDurationSeconds: Int?,
        stopLeadSeconds: Int,
        maximumUploadBytes: Int?
    ) {
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
        self.maximumRecordingDurationSeconds =
            maximumRecordingDurationSeconds
        self.stopLeadSeconds = stopLeadSeconds
        self.maximumUploadBytes = maximumUploadBytes
    }
}

public struct ConfiguredTranscriptionRuntime: Equatable, Sendable {
    public let model: ModelRef
    public let audio: RecordedFileTranscriptionConfiguration

    public init(
        model: ModelRef,
        audio: RecordedFileTranscriptionConfiguration
    ) {
        self.model = model
        self.audio = audio
    }
}

public struct TranscriptionRequest: Sendable {
    public var model: ModelID
    public var audio: Data
    public var filename: String
    public var mime: String

    public init(
        model: ModelID,
        audio: Data,
        filename: String = "audio.m4a",
        mime: String = "audio/m4a"
    ) {
        self.model = model
        self.audio = audio
        self.filename = filename
        self.mime = mime
    }
}

public struct TranscriptionFileRequest: Sendable {
    public var model: ModelID
    public var fileURL: URL

    public init(model: ModelID, fileURL: URL) {
        self.model = model
        self.fileURL = fileURL
    }
}

/// `Capability.realtime_transcription` (the current composer runtime is a
/// bounded recorded-file transcription; realtime transport can remain a
/// separate future adapter).
public protocol TranscriptionProvider: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> String
    func transcribeFile(
        _ request: TranscriptionFileRequest
    ) async throws -> String
}

public extension TranscriptionProvider {
    /// Compatibility path for lightweight/test providers that only implement
    /// the original in-memory API.
    func transcribeFile(
        _ request: TranscriptionFileRequest
    ) async throws -> String {
        let data = try Data(
            contentsOf: request.fileURL,
            options: .mappedIfSafe)
        return try await transcribe(
            TranscriptionRequest(
                model: request.model,
                audio: data,
                filename: request.fileURL.lastPathComponent,
                mime: TranscriptionFileSupport.mimeType(
                    for: request.fileURL)))
    }
}

public enum TranscriptionRequestEncoding: Equatable, Sendable {
    case multipartFormData
    case jsonBase64
}

/// OpenAI-compatible `/audio/transcriptions`. Exact OpenRouter routes can use
/// its JSON `input_audio` form; compatible routes retain multipart upload.
public struct OpenAITranscriptionProvider: TranscriptionProvider {
    private let endpoint: ProviderEndpoint
    private let apiKey: String
    private let http: HTTPDataClient
    private let runtimePolicy: ProviderRuntimePolicy
    private let requestEncoding: TranscriptionRequestEncoding

    public init(
        endpoint: ProviderEndpoint,
        apiKey: String,
        http: HTTPDataClient,
        runtimePolicy: ProviderRuntimePolicy = .nonStreaming,
        requestEncoding: TranscriptionRequestEncoding = .multipartFormData
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
        self.requestEncoding = requestEncoding
    }

    private struct Response: Decodable {
        let text: String
    }

    public func transcribe(
        _ request: TranscriptionRequest
    ) async throws -> String {
        let input = try TranscriptionInputFile.create(
            audio: request.audio,
            filename: request.filename,
            mime: request.mime)
        defer { try? FileManager.default.removeItem(at: input) }
        return try await transcribeFile(
            TranscriptionFileRequest(
                model: request.model,
                fileURL: input))
    }

    public func transcribeFile(
        _ request: TranscriptionFileRequest
    ) async throws -> String {
        let file = try TranscriptionFileSupport.validateAudioFile(
            request.fileURL,
            maximumBytes: maximumTranscriptionUploadBytes)
        try Task.checkCancellation()

        let body: TranscriptionBodyFile
        switch requestEncoding {
        case .multipartFormData:
            body = try TranscriptionBodyFile.multipart(
                fields: [
                    (name: "model", value: request.model.rawValue),
                    (name: "response_format", value: "json"),
                ],
                fileURL: file.url,
                mimeType: TranscriptionFileSupport.mimeType(
                    for: file.url))
        case .jsonBase64:
            body = try TranscriptionBodyFile.jsonBase64(
                model: request.model.rawValue,
                fileURL: file.url,
                format: file.fileExtension)
        }
        defer { try? FileManager.default.removeItem(at: body.url) }

        var urlRequest = URLRequest(
            url: try endpoint.validatedBaseURLAppendingPathComponent(
                "audio/transcriptions",
                operation: "transcription"))
        ProviderRuntime.apply(runtimePolicy, to: &urlRequest)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            body.contentType,
            forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            "\(body.byteCount)",
            forHTTPHeaderField: "Content-Length")
        urlRequest.setValue(
            ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
            forHTTPHeaderField: "Authorization")

        try Task.checkCancellation()
        let response = try await ProviderRuntime.sendUploadResponse(
            urlRequest,
            fromFile: body.url,
            via: http,
            policy: runtimePolicy,
            operation: "transcription")
        try TranscriptionFileSupport.validateJSONResponse(response)
        do {
            return try JSONDecoder().decode(
                Response.self,
                from: response.data).text
        } catch {
            throw ProviderErrorFormatting.invalidResponsePayload(
                response.data,
                operation: "transcription",
                expected:
                    "OpenAI-compatible transcription JSON with text",
                underlying: error)
        }
    }
}

private enum TranscriptionTemporaryFiles {
    static var inputPrefix: String {
        IntatisHostApplication.identity.storageName
            + "-Transcription-Input-"
    }
    static var bodyPrefix: String {
        IntatisHostApplication.identity.storageName
            + "-Transcription-Body-"
    }
    private static let staleAge: TimeInterval = 24 * 60 * 60

    static func removeStaleFiles(withPrefix prefix: String) {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.standardizedFileURL
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .creationDateKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles]) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-staleAge)
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            guard file.deletingLastPathComponent().standardizedFileURL
                    == directory,
                  let values = try? file.resourceValues(forKeys: [
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                  ]),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  let timestamp = values.contentModificationDate
                    ?? values.creationDate,
                  timestamp < cutoff else {
                continue
            }
            try? manager.removeItem(at: file)
        }
    }

    static func createURL(prefix: String, extension fileExtension: String)
        -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)\(UUID().uuidString).\(fileExtension)",
            isDirectory: false)
    }

    static func createOwnerOnlyFile(
        at url: URL,
        contents: Data? = nil
    ) throws {
        let manager = FileManager.default
        guard manager.createFile(
            atPath: url.path,
            contents: contents,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw IntatisError.io(
                "could not create the temporary transcription file")
        }
        do {
            try manager.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: url.path)
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
    }
}

private enum TranscriptionInputFile {
    static func create(
        audio: Data,
        filename: String,
        mime: String
    ) throws -> URL {
        TranscriptionTemporaryFiles.removeStaleFiles(
            withPrefix: TranscriptionTemporaryFiles.inputPrefix)
        let fileExtension = TranscriptionFileSupport.fileExtension(
            filename: filename,
            mime: mime)
        let url = TranscriptionTemporaryFiles.createURL(
            prefix: TranscriptionTemporaryFiles.inputPrefix,
            extension: fileExtension)
        try TranscriptionTemporaryFiles.createOwnerOnlyFile(
            at: url,
            contents: audio)
        return url
    }
}

private struct TranscriptionBodyFile {
    let url: URL
    let byteCount: Int
    let contentType: String

    static func multipart(
        fields: [(name: String, value: String)],
        fileURL: URL,
        mimeType: String
    ) throws -> TranscriptionBodyFile {
        TranscriptionTemporaryFiles.removeStaleFiles(
            withPrefix: TranscriptionTemporaryFiles.bodyPrefix)
        let boundary = IntatisHostApplication.identity.storageName
            + "Boundary-\(UUID().uuidString)"
        let bodyURL = TranscriptionTemporaryFiles.createURL(
            prefix: TranscriptionTemporaryFiles.bodyPrefix,
            extension: "multipart")
        try TranscriptionTemporaryFiles.createOwnerOnlyFile(at: bodyURL)

        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            for field in fields {
                try Task.checkCancellation()
                try output.write(
                    contentsOf: Data("--\(boundary)\r\n".utf8))
                let name = sanitizeHeaderValue(field.name)
                try output.write(contentsOf: Data(
                    "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
                        .utf8))
                try output.write(contentsOf: Data(field.value.utf8))
                try output.write(contentsOf: Data("\r\n".utf8))
            }

            let filename = sanitizeHeaderValue(
                fileURL.lastPathComponent)
            try output.write(
                contentsOf: Data("--\(boundary)\r\n".utf8))
            try output.write(contentsOf: Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
                    .utf8))
            try output.write(contentsOf: Data(
                "Content-Type: \(mimeType)\r\n\r\n".utf8))

            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(
                    upToCount: 256 * 1_024),
                    !chunk.isEmpty else {
                    break
                }
                try output.write(contentsOf: chunk)
            }
            try output.write(
                contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try output.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }

        let byteCount = try fileSize(at: bodyURL)
        return TranscriptionBodyFile(
            url: bodyURL,
            byteCount: byteCount,
            contentType: "multipart/form-data; boundary=\(boundary)")
    }

    static func jsonBase64(
        model: String,
        fileURL: URL,
        format: String
    ) throws -> TranscriptionBodyFile {
        struct Payload: Encodable {
            struct InputAudio: Encodable {
                let data: String
                let format: String
            }

            let model: String
            let inputAudio: InputAudio

            enum CodingKeys: String, CodingKey {
                case model
                case inputAudio = "input_audio"
            }
        }

        TranscriptionTemporaryFiles.removeStaleFiles(
            withPrefix: TranscriptionTemporaryFiles.bodyPrefix)
        try Task.checkCancellation()
        let audio = try Data(
            contentsOf: fileURL,
            options: .mappedIfSafe)
        try Task.checkCancellation()
        let payload = Payload(
            model: model,
            inputAudio: Payload.InputAudio(
                data: audio.base64EncodedString(),
                format: format))
        let encoded = try JSONEncoder().encode(payload)
        let bodyURL = TranscriptionTemporaryFiles.createURL(
            prefix: TranscriptionTemporaryFiles.bodyPrefix,
            extension: "jsonbody")
        try TranscriptionTemporaryFiles.createOwnerOnlyFile(
            at: bodyURL,
            contents: encoded)
        return TranscriptionBodyFile(
            url: bodyURL,
            byteCount: encoded.count,
            contentType: "application/json")
    }

    private static func sanitizeHeaderValue(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
    }

    private static func fileSize(at url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey])
            .fileSize ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw IntatisError.io(
                "the temporary transcription upload file is empty")
        }
        return size
    }
}

private enum TranscriptionFileSupport {
    struct ValidatedAudioFile {
        let url: URL
        let fileExtension: String
    }

    static let allowedExtensions: Set<String> = [
        "aac", "flac", "m4a", "mp3", "mp4", "mpeg", "mpga",
        "ogg", "wav", "webm",
    ]

    static func validateAudioFile(
        _ fileURL: URL,
        maximumBytes: Int
    ) throws -> ValidatedAudioFile {
        try Task.checkCancellation()
        let url = fileURL.standardizedFileURL
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        let size = values.fileSize ?? 0
        guard url.isFileURL,
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              FileManager.default.isReadableFile(atPath: url.path),
              size > 0 else {
            throw IntatisError.provider(
                "the audio file to transcribe is missing, empty, or unreadable")
        }
        guard size <= maximumBytes else {
            throw IntatisError.provider(
                "the audio file exceeds the \(maximumBytes / 1_024 / 1_024) MB transcription upload limit")
        }
        let fileExtension = url.pathExtension.lowercased()
        guard allowedExtensions.contains(fileExtension) else {
            throw IntatisError.provider(
                "the selected audio format is not supported for transcription")
        }
        return ValidatedAudioFile(
            url: url,
            fileExtension: fileExtension)
    }

    static func fileExtension(filename: String, mime: String) -> String {
        let candidate = URL(fileURLWithPath: filename)
            .pathExtension.lowercased()
        if allowedExtensions.contains(candidate) {
            return candidate
        }
        switch mime.lowercased() {
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/mpeg":
            return "mp3"
        case "audio/flac":
            return "flac"
        case "audio/ogg":
            return "ogg"
        case "audio/webm":
            return "webm"
        case "audio/aac":
            return "aac"
        default:
            return "m4a"
        }
    }

    static func mimeType(for fileURL: URL) -> String {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3", "mpeg", "mpga":
            return "audio/mpeg"
        case "m4a", "mp4":
            return "audio/mp4"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        case "webm":
            return "audio/webm"
        case "aac":
            return "audio/aac"
        default:
            return "application/octet-stream"
        }
    }

    static func validateJSONResponse(
        _ response: HTTPDataResponse
    ) throws {
        guard let contentType = response.headers["content-type"] else {
            throw IntatisError.provider(
                "transcription response did not include a Content-Type header")
        }
        let mediaType = contentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/json" else {
            throw IntatisError.provider(
                "transcription response Content-Type must be application/json")
        }
    }
}
