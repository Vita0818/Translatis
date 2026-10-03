import Foundation
import IntatisCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ImageRequest: Sendable {
    public var model: ModelID
    public var prompt: String
    public var size: String
    public var n: Int
    public init(model: ModelID, prompt: String, size: String = "1024x1024", n: Int = 1) {
        self.model = model
        self.prompt = prompt
        self.size = size
        self.n = n
    }
}

public struct ImageEditRequest: Sendable {
    public var model: ModelID
    public var prompt: String
    public var image: Data
    public var filename: String
    public var mime: String

    public init(model: ModelID,
                prompt: String,
                image: Data,
                filename: String = "input.png",
                mime: String = "image/png") {
        self.model = model
        self.prompt = prompt
        self.image = image
        self.filename = filename
        self.mime = mime
    }
}

public struct GeneratedImage: Equatable, Sendable {
    public var data: Data
    public var mime: String
    public init(data: Data, mime: String) {
        self.data = data
        self.mime = mime
    }
}

/// `Capability.image_generation`.
public protocol ImageGenerationProvider: Sendable {
    func generate(_ request: ImageRequest) async throws -> [GeneratedImage]
}

/// OpenAI-compatible image editing capability. Kept separate from generation
/// so generation-only backends do not have to pretend they support references.
public protocol ImageEditingProvider: Sendable {
    func edit(_ request: ImageEditRequest) async throws -> GeneratedImage
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(Data(value.utf8))
    }
}

/// OpenAI-compatible `/images/generations` and `/images/edits` (b64 response).
public struct OpenAIImageProvider: ImageGenerationProvider, ImageEditingProvider {
    private let endpoint: ProviderEndpoint
    private let apiKey: String
    private let http: HTTPDataClient
    private let runtimePolicy: ProviderRuntimePolicy

    public init(endpoint: ProviderEndpoint,
                apiKey: String,
                http: HTTPDataClient,
                runtimePolicy: ProviderRuntimePolicy = .nonStreaming) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
        self.runtimePolicy = runtimePolicy
    }

    private struct Response: Decodable {
        struct Item: Decodable { let b64_json: String? }
        let data: [Item]
    }

    public func generate(_ request: ImageRequest) async throws -> [GeneratedImage] {
        var r = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent("images/generations",
                                                                                    operation: "image generation"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": request.model.rawValue,
            "prompt": request.prompt,
            "size": request.size,
            "n": request.n,
            "response_format": "b64_json",
        ]
        r.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await ProviderRuntime.sendData(r,
                                                      via: http,
                                                      policy: runtimePolicy,
                                                      operation: "image generation")
        return try decodeImages(data, operation: "image generation")
    }

    public func edit(_ request: ImageEditRequest) async throws -> GeneratedImage {
        guard !request.image.isEmpty else {
            throw IntatisError.decoding("image editing input is empty")
        }

        let boundary = IntatisHostApplication.identity.temporaryPrefix(
            "image-edit-\(UUID().uuidString)")
        var body = Data()
        appendTextField(name: "model", value: request.model.rawValue,
                        boundary: boundary, to: &body)
        appendFileField(name: "image[]",
                        filename: safeMultipartFilename(request.filename),
                        mime: request.mime,
                        data: request.image,
                        boundary: boundary,
                        to: &body)
        appendTextField(name: "prompt", value: request.prompt,
                        boundary: boundary, to: &body)
        // GPT Image models return base64 by default and do not accept the old
        // response_format parameter. DALL-E 2 needs it to avoid an unreviewed
        // follow-up download from a provider URL.
        if request.model.rawValue.lowercased() == "dall-e-2" {
            appendTextField(name: "response_format", value: "b64_json",
                            boundary: boundary, to: &body)
        }
        body.appendUTF8("--\(boundary)--\r\n")

        var r = URLRequest(url: try endpoint.validatedBaseURLAppendingPathComponent(
            "images/edits",
            operation: "image editing"))
        ProviderRuntime.apply(runtimePolicy, to: &r)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)",
                   forHTTPHeaderField: "Content-Type")
        r.setValue(ProviderAuthorization.bearerHeaderValue(apiKey: apiKey),
                   forHTTPHeaderField: "Authorization")
        r.httpBody = body

        let data = try await ProviderRuntime.sendData(
            r,
            via: http,
            policy: runtimePolicy,
            operation: "image editing")
        guard let image = try decodeImages(data, operation: "image editing").first else {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: "image editing",
                expected: "OpenAI-compatible image JSON with data[].b64_json")
        }
        return image
    }

    private func decodeImages(_ data: Data, operation: String) throws -> [GeneratedImage] {
        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: operation,
                expected: "OpenAI-compatible image JSON with data[].b64_json",
                underlying: error)
        }
        guard !decoded.data.isEmpty else {
            throw ProviderErrorFormatting.invalidResponsePayload(
                data,
                operation: operation,
                expected: "OpenAI-compatible image JSON with data[].b64_json")
        }
        return try decoded.data.map { item in
            guard let b64 = item.b64_json, let bytes = Data(base64Encoded: b64) else {
                throw ProviderErrorFormatting.invalidResponsePayload(
                    data,
                    operation: operation,
                    expected: "OpenAI-compatible image JSON with data[].b64_json")
            }
            return GeneratedImage(data: bytes, mime: "image/png")
        }
    }

    private func appendTextField(name: String,
                                 value: String,
                                 boundary: String,
                                 to body: inout Data) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.appendUTF8("\(value)\r\n")
    }

    private func appendFileField(name: String,
                                 filename: String,
                                 mime: String,
                                 data: Data,
                                 boundary: String,
                                 to body: inout Data) {
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.appendUTF8("Content-Type: \(mime)\r\n\r\n")
        body.append(data)
        body.appendUTF8("\r\n")
    }

    private func safeMultipartFilename(_ filename: String) -> String {
        let sanitized = filename
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return sanitized.isEmpty ? "input.png" : sanitized
    }
}
