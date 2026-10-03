import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import IntatisCore
import IntatisProviders
import IntatisTools
@testable import IntatisAgentKernel

private final class ImageEditCapturingHTTP: HTTPDataClient, @unchecked Sendable {
    private let queue = DispatchQueue(label: "intatis.tests.image-edit-service-http")
    private let response: Data
    private var requests: [URLRequest] = []

    init(response: Data) {
        self.response = response
    }

    var lastRequest: URLRequest? {
        queue.sync { requests.last }
    }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        queue.sync { requests.append(request) }
        return (response, 200)
    }
}

private struct ImageEditFixedSecret: SecretResolver {
    func secret(for ref: KeychainRef) async throws -> String { "test-key" }
}

final class ProviderImageGenerationToolServiceTests: XCTestCase {
    func testEditImageUsesConfiguredImageModelAndWritesWorkspaceOutput() async throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("intatis-image-edit-service-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: workspace,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let endpoint = ProviderEndpoint(
            id: "images",
            baseURL: URL(string: "https://images.example.test/v1")!,
            apiKeyRef: KeychainRef(service: "test", account: "images"),
            wire: .openai)
        var models = ResolvedModels(
            chat: ModelRef(endpoint: "images", model: ModelID(rawValue: "chat-model")))
        models.imageGen = ModelRef(
            endpoint: "images",
            model: ModelID(rawValue: "configured-image-model"))
        let encoded = Data("EDITED".utf8).base64EncodedString()
        let http = ImageEditCapturingHTTP(
            response: Data("{\"data\":[{\"b64_json\":\"\(encoded)\"}]}".utf8))
        let registry = ProviderRegistry(
            config: ProviderConfig(endpoints: [endpoint], models: models),
            resolver: ImageEditFixedSecret(),
            dataClient: http)
        let service = ProviderImageGenerationToolService(registry: registry)

        let observation = try await service.editImage(
            image: Data("PNGDATA".utf8),
            filename: "input.png",
            mime: "image/png",
            prompt: "make it warmer",
            outputPath: "art/edited.png",
            workspaceRoot: workspace)

        XCTAssertEqual(observation.changedFiles, ["art/edited.png"])
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("art/edited.png")),
                       Data("EDITED".utf8))
        let body = String(
            decoding: try XCTUnwrap(http.lastRequest?.httpBody),
            as: UTF8.self)
        XCTAssertTrue(body.contains("configured-image-model"))
        XCTAssertFalse(body.contains("chat-model"))
    }
}
