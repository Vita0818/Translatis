import XCTest
import IntatisCore
@testable import IntatisProviders

private struct FakeDataClient: HTTPDataClient {
    let response: Data
    let status: Int
    var headers: [String: String] = [
        "content-type": "application/json",
    ]
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) { (response, status) }
    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        HTTPDataResponse(data: response, status: status, headers: headers)
    }
}

private final class CapturingDataClient: HTTPDataClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.image-edit-http")
    private let response: Data
    private let status: Int
    private let headers: [String: String]
    private var requests: [URLRequest] = []

    init(
        response: Data,
        status: Int = 200,
        headers: [String: String] = [
            "content-type": "application/json",
        ]
    ) {
        self.response = response
        self.status = status
        self.headers = headers
    }

    var lastRequest: URLRequest? {
        queue.sync { requests.last }
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        queue.sync { requests.append(request) }
        return (response, status)
    }

    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        queue.sync { requests.append(request) }
        return HTTPDataResponse(
            data: response,
            status: status,
            headers: headers)
    }
}

private final class SequencedDataClient: HTTPDataClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.sequenced-data")
    private var index = 0
    private let responses: [HTTPDataResponse]

    init(responses: [(data: Data, status: Int)]) {
        self.responses = responses.map { HTTPDataResponse(data: $0.data, status: $0.status) }
    }

    init(responses: [HTTPDataResponse]) {
        self.responses = responses
    }

    var attemptCount: Int {
        queue.sync { index }
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let response = next()
        return (response.data, response.status)
    }

    func sendResponse(_ request: URLRequest) async throws -> HTTPDataResponse {
        next()
    }

    private func next() -> HTTPDataResponse {
        queue.sync {
            let value = responses[min(index, responses.count - 1)]
            index += 1
            return value
        }
    }
}

private struct DelayedDataClient: HTTPDataClient {
    let delayNanoseconds: UInt64

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        return (Data(#"{"text":"late"}"#.utf8), 200)
    }
}

private struct FixedSecret: SecretResolver {
    let key: String
    func secret(for ref: KeychainRef) async throws -> String { key }
}

private let ep = ProviderEndpoint(id: "e", baseURL: URL(string: "https://example.test/v1")!,
                                  apiKeyRef: KeychainRef(service: "s", account: "a"), wire: .openai)
private let nonHTTPBaseEndpoint = ProviderEndpoint(id: "bad-base",
                                                   baseURL: URL(fileURLWithPath: "/tmp/intatis-provider"),
                                                   apiKeyRef: KeychainRef(service: "s", account: "a"),
                                                   wire: .openai)

final class IntatisProvidersMultimodalTests: XCTestCase {

    func testImageGenParsesBase64() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let json = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: json, status: 200))
        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].data, Data("PNGDATA".utf8))
        XCTAssertEqual(images[0].mime, "image/png")
    }

    func testImageGenHTTPErrorThrows() async {
        let body = Data(#"{"error":{"message":"temporary upstream failure","code":"server_error"}}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 500))
        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("HTTP 500 should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTP 500 Internal Server Error"))
            XCTAssertTrue(error.localizedDescription.contains("retry later"))
            XCTAssertTrue(error.localizedDescription.contains("temporary upstream failure"))
        }
    }

    func testImageGenUnexpectedSuccessPayloadThrowsActionableError() async {
        let body = Data(#"{"error":{"message":"image model does not support b64_json","code":"bad_response_format"}}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("unexpected successful payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("image generation returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("data[].b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("Provider said: image model does not support b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("bad_response_format"))
        }
    }

    func testImageGenMissingBase64UsesPreviewNotProviderSaid() async {
        let body = Data(#"{"data":[{"url":"https://cdn.example/image.png"}]}"#.utf8)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "m"), prompt: "x"))
            XCTFail("missing b64_json should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("image generation returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("data[].b64_json"))
            XCTAssertTrue(error.localizedDescription.contains("Preview:"))
            XCTAssertTrue(error.localizedDescription.contains(#""url":"#))
            XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
        }
    }

    func testImageGenRejectsNonHTTPBaseURLBeforeTransport() async {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let json = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let provider = OpenAIImageProvider(endpoint: nonHTTPBaseEndpoint,
                                           apiKey: "k",
                                           http: FakeDataClient(response: json, status: 200))

        do {
            _ = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "x"))
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-base'"))
            XCTAssertTrue(error.localizedDescription.contains("Base URL scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("image generation"))
        }
    }

    func testImageGenRetriesTransientHTTPStatusThenParsesBase64() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let success = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = SequencedDataClient(responses: [
            (Data(#"{"error":{"message":"busy"}}"#.utf8), 503),
            (success, 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))

        XCTAssertEqual(images.first?.data, Data("PNGDATA".utf8))
        XCTAssertEqual(client.attemptCount, 2)
    }

    func testImageGenUsesRetryAfterHeaderFromDataResponse() async throws {
        let b64 = Data("PNGDATA".utf8).base64EncodedString()
        let success = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = SequencedDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"error":{"message":"request rate exceeded","type":"rate_limit_error","code":"rate_limit_exceeded"}}"#.utf8),
                status: 429,
                headers: ["retry-after": "0"]),
            HTTPDataResponse(data: success, status: 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0.25,
                                                 maxRetryDelaySeconds: 2,
                                                 maxRetryAfterDelaySeconds: 1))

        let images = try await provider.generate(ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))

        XCTAssertEqual(images.first?.data, Data("PNGDATA".utf8))
        XCTAssertEqual(client.attemptCount, 2)
    }

    func testImageGenHardUsageLimitDoesNotRetryAndPreservesTypedError() async {
        let client = SequencedDataClient(responses: [
            HTTPDataResponse(
                data: Data(#"{"error":{"message":"No credits remain.","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8),
                status: 429),
            HTTPDataResponse(data: Data(#"{"data":[]}"#.utf8), status: 200),
        ])
        let provider = OpenAIImageProvider(
            endpoint: ep,
            apiKey: "k",
            http: client,
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 2,
                                                 requestTimeoutSeconds: 1,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        do {
            _ = try await provider.generate(
                ImageRequest(model: ModelID(rawValue: "image-model"), prompt: "a cat"))
            XCTFail("expected hard provider usage limit")
        } catch let error as ProviderUsageLimitError {
            XCTAssertEqual(error.signal, "insufficient_quota")
            XCTAssertEqual(error.statusCode, 429)
            XCTAssertTrue(error.localizedDescription.contains("hard usage limit"))
            XCTAssertEqual(client.attemptCount, 1)
        } catch {
            XCTFail("expected ProviderUsageLimitError, got \(type(of: error)): \(error)")
        }
    }

    func testImageEditSendsMultipartReferenceAndParsesBase64() async throws {
        let b64 = Data("EDITED-PNG".utf8).base64EncodedString()
        let response = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = CapturingDataClient(response: response)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: client)

        let image = try await provider.edit(ImageEditRequest(
            model: ModelID(rawValue: "image-model"),
            prompt: "make the sky warmer",
            image: Data("PNGDATA".utf8),
            filename: "input.png",
            mime: "image/png"))

        XCTAssertEqual(image.data, Data("EDITED-PNG".utf8))
        XCTAssertEqual(image.mime, "image/png")
        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/images/edits")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?
            .hasPrefix("multipart/form-data; boundary=intatis-image-edit-") == true)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\nimage-model"))
        XCTAssertTrue(body.contains("name=\"image[]\"; filename=\"input.png\""))
        XCTAssertTrue(body.contains("Content-Type: image/png\r\n\r\nPNGDATA"))
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nmake the sky warmer"))
        XCTAssertFalse(body.contains("name=\"response_format\""))
    }

    func testDallE2ImageEditRequestsBase64Response() async throws {
        let b64 = Data("EDITED-PNG".utf8).base64EncodedString()
        let response = Data("{\"data\":[{\"b64_json\":\"\(b64)\"}]}".utf8)
        let client = CapturingDataClient(response: response)
        let provider = OpenAIImageProvider(endpoint: ep, apiKey: "k", http: client)

        _ = try await provider.edit(ImageEditRequest(
            model: ModelID(rawValue: "dall-e-2"),
            prompt: "change it",
            image: Data("PNGDATA".utf8)))

        let body = String(
            decoding: try XCTUnwrap(client.lastRequest?.httpBody),
            as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\nb64_json"))
    }

    func testTranscriptionParsesText() async throws {
        let json = Data(#"{"text":"hello world"}"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep, apiKey: "k", http: FakeDataClient(response: json, status: 200))
        let text = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3])))
        XCTAssertEqual(text, "hello world")
    }

    func testCompatibleTranscriptionBuildsDiskBackedMultipartWAVRequest()
        async throws {
        let client = CapturingDataClient(
            response: Data(#"{"text":"fixture accepted"}"#.utf8))
        let provider = OpenAITranscriptionProvider(
            endpoint: ep,
            apiKey: "unit-test-key",
            http: client)

        let text = try await provider.transcribe(
            TranscriptionRequest(
                model: ModelID(rawValue: "whisper-test"),
                audio: Data("RIFF-unit-test-wave".utf8),
                filename: "sample.wav",
                mime: "audio/wav"))

        XCTAssertEqual(text, "fixture accepted")
        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.test/v1/audio/transcriptions")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer unit-test-key")
        XCTAssertTrue(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=IntatisBoundary-")
                == true)
        let body = try XCTUnwrap(request.httpBody)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"model\""))
        XCTAssertTrue(bodyText.contains("whisper-test"))
        XCTAssertTrue(bodyText.contains("name=\"response_format\""))
        XCTAssertTrue(bodyText.contains("name=\"file\""))
        XCTAssertTrue(bodyText.contains(".wav\""))
        XCTAssertTrue(bodyText.contains("Content-Type: audio/wav"))
        XCTAssertNotNil(body.range(of: Data("RIFF".utf8)))
    }

    func testOpenRouterRuntimeUsesWAVAndJSONBase64Request() async throws {
        let openRouterEndpoint = ProviderEndpoint(
            id: "openrouter",
            baseURL: URL(string: "https://openrouter.ai/api/v1")!,
            apiKeyRef: KeychainRef(service: "s", account: "a"),
            wire: .openai,
            requestAdapter: .openRouter)
        let model = ModelRef(
            endpoint: "openrouter",
            model: ModelID(rawValue: "x-ai/grok-stt-1.0"))
        var models = ResolvedModels(
            chat: ModelRef(
                endpoint: "openrouter",
                model: ModelID(rawValue: "chat-model")))
        models.transcription = model
        let client = CapturingDataClient(
            response: Data(#"{"text":"openrouter accepted"}"#.utf8))
        let registry = ProviderRegistry(
            config: ProviderConfig(
                endpoints: [openRouterEndpoint],
                models: models),
            resolver: FixedSecret(key: "openrouter-test-key"),
            dataClient: client)

        let resolvedRuntime = try await registry
            .configuredTranscriptionRuntime()
        let runtime = try XCTUnwrap(resolvedRuntime)
        XCTAssertEqual(runtime.model, model)
        XCTAssertEqual(runtime.audio.format, .wav)
        XCTAssertEqual(runtime.audio.sampleRate, 16_000)
        XCTAssertEqual(runtime.audio.channels, 1)
        XCTAssertEqual(runtime.audio.maximumRecordingDurationSeconds, 120)
        XCTAssertEqual(
            runtime.audio.maximumUploadBytes,
            maximumTranscriptionUploadBytes)

        let provider = try await registry.transcriptionProvider(for: model)
        let text = try await provider.transcribe(
            TranscriptionRequest(
                model: model.model,
                audio: Data("RIFF-openrouter-wave".utf8),
                filename: "sample.wav",
                mime: "audio/wav"))
        XCTAssertEqual(text, "openrouter accepted")

        let request = try XCTUnwrap(client.lastRequest)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "x-ai/grok-stt-1.0")
        let inputAudio = try XCTUnwrap(
            json["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "wav")
        let encoded = try XCTUnwrap(inputAudio["data"] as? String)
        XCTAssertEqual(
            Data(base64Encoded: encoded),
            Data("RIFF-openrouter-wave".utf8))
        XCTAssertNil(json["file"])
    }

    func testTranscriptionRejectsNonJSONSuccessContentType() async {
        let provider = OpenAITranscriptionProvider(
            endpoint: ep,
            apiKey: "k",
            http: FakeDataClient(
                response: Data(#"{"text":"not accepted"}"#.utf8),
                status: 200,
                headers: ["content-type": "text/plain"]))
        do {
            _ = try await provider.transcribe(
                TranscriptionRequest(
                    model: ModelID(rawValue: "whisper"),
                    audio: Data([1, 2, 3])))
            XCTFail("non-JSON Content-Type should fail")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("Content-Type"))
        }
    }

    func testTranscriptionTimeoutHasActionableMessage() async {
        let provider = OpenAITranscriptionProvider(
            endpoint: ep,
            apiKey: "k",
            http: DelayedDataClient(delayNanoseconds: 2_000_000_000),
            runtimePolicy: ProviderRuntimePolicy(maxAttempts: 1,
                                                 requestTimeoutSeconds: 0.01,
                                                 initialRetryDelaySeconds: 0,
                                                 maxRetryDelaySeconds: 0))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"), audio: Data([1, 2, 3])))
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription timed out"))
            XCTAssertTrue(error.localizedDescription.contains("endpoint"))
        }
    }

    func testTranscriptionUnexpectedSuccessPayloadThrowsActionableError() async {
        let body = Data(#"{"error":{"message":"audio format unsupported","code":"bad_audio"}}"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep,
                                                   apiKey: "k",
                                                   http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("unexpected successful payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("transcription JSON with text"))
            XCTAssertTrue(error.localizedDescription.contains("Provider said: audio format unsupported"))
            XCTAssertTrue(error.localizedDescription.contains("bad_audio"))
        }
    }

    func testTranscriptionHTMLSuccessPayloadUsesPreviewNotProviderSaid() async {
        let body = Data(#"<html><body>upstream proxy returned HTML</body></html>"#.utf8)
        let provider = OpenAITranscriptionProvider(endpoint: ep,
                                                   apiKey: "k",
                                                   http: FakeDataClient(response: body, status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("HTML success payload should throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("transcription returned a response that did not match"))
            XCTAssertTrue(error.localizedDescription.contains("transcription JSON with text"))
            XCTAssertTrue(error.localizedDescription.contains("Preview: <html><body>upstream proxy returned HTML"))
            XCTAssertFalse(error.localizedDescription.contains("Provider said:"))
        }
    }

    func testTranscriptionRejectsNonHTTPBaseURLBeforeTransport() async {
        let provider = OpenAITranscriptionProvider(
            endpoint: nonHTTPBaseEndpoint,
            apiKey: "k",
            http: FakeDataClient(response: Data(#"{"text":"hello"}"#.utf8), status: 200))

        do {
            _ = try await provider.transcribe(TranscriptionRequest(model: ModelID(rawValue: "whisper"),
                                                                   audio: Data([1, 2, 3])))
            XCTFail("expected invalid provider endpoint error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("invalid provider endpoint 'bad-base'"))
            XCTAssertTrue(error.localizedDescription.contains("Base URL scheme 'file' is not supported"))
            XCTAssertTrue(error.localizedDescription.contains("transcription"))
        }
    }

    func testRegistryResolvesImageProvider() async throws {
        var models = ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "c")))
        models.imageGen = ModelRef(endpoint: "e", model: ModelID(rawValue: "image-model"))
        let registry = ProviderRegistry(config: ProviderConfig(endpoints: [ep], models: models),
                                        resolver: FixedSecret(key: "k"),
                                        dataClient: FakeDataClient(response: Data(), status: 200))
        let provider = try await registry.defaultImageProvider()
        XCTAssertNotNil(provider)
        let editor = try await registry.defaultImageEditingProvider()
        XCTAssertNotNil(editor)
    }

    func testRegistryNilWhenNoImageModelConfigured() async throws {
        let models = ResolvedModels(chat: ModelRef(endpoint: "e", model: ModelID(rawValue: "c")))
        let registry = ProviderRegistry(config: ProviderConfig(endpoints: [ep], models: models),
                                        resolver: FixedSecret(key: "k"))
        let provider = try await registry.defaultImageProvider()
        XCTAssertNil(provider)
        let editor = try await registry.defaultImageEditingProvider()
        XCTAssertNil(editor)
    }

    func testRegistryReturnsExactConfiguredTranscriptionReference() async throws {
        var models = ResolvedModels(
            chat: ModelRef(
                endpoint: "e",
                model: ModelID(rawValue: "chat-model")))
        let expected = ModelRef(
            endpoint: "e",
            model: ModelID(rawValue: "whisper-test"))
        models.transcription = expected
        let registry = ProviderRegistry(
            config: ProviderConfig(endpoints: [ep], models: models),
            resolver: FixedSecret(key: "k"))

        let resolved = try await registry
            .configuredTranscriptionModelRef()
        XCTAssertEqual(resolved, expected)
    }

    func testRegistryHasNoHiddenTranscriptionFallback() async throws {
        let models = ResolvedModels(
            chat: ModelRef(
                endpoint: "e",
                model: ModelID(rawValue: "chat-model")))
        let registry = ProviderRegistry(
            config: ProviderConfig(endpoints: [ep], models: models),
            resolver: FixedSecret(key: "k"))

        let resolved = try await registry
            .configuredTranscriptionModelRef()
        XCTAssertNil(resolved)
    }
}
