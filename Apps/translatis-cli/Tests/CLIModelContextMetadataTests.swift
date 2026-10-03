import Foundation
import IntatisProviders
import IntatisProtocol
import XCTest
@testable import TranslatisCLI

final class CLIModelContextMetadataTests: XCTestCase {
    func testRawModelMetadataCompilesIntoEveryExactProfileWithoutEnteringWireOptions()
        async throws {
        let fixture = try makeFixture()
        defer {
            try? FileManager.default.removeItem(
                at: fixture.directory)
        }
        let config = try CLIConfig.load(
            configurationFileURL: fixture.configuration,
            environment: [:])
        let route = try XCTUnwrap(
            config.providerRoutes.first)
        let model = try XCTUnwrap(
            route.models.first)

        XCTAssertEqual(
            model.configurationMetadata[
                "context_window"],
            .number(200_000))
        XCTAssertEqual(
            model.requestOptions,
            ["temperature": .number(0.2)])
        XCTAssertEqual(
            model.declaredCapabilities,
            [.chat, .toolCalling, .visionInput])

        let profiles =
            try await CLIInferenceProfiles.load(
                config: config,
                fileURL:
                    fixture.directory
                        .appendingPathComponent(
                            "inference-catalog-v1.json"))
        for variantID in [nil, "high"] as [String?] {
            let option = try XCTUnwrap(
                profiles.option(
                    routeID: "test",
                    model: "test-model",
                    variantID: variantID))
            let resolution =
                try profiles.snapshot.resolve(
                    option.binding)
            XCTAssertEqual(
                option.declaredCapabilities,
                [.chat, .toolCalling, .visionInput])
            let policy =
                resolution.profile
                    .modelContextPolicy

            XCTAssertEqual(
                policy.contextWindowTokens,
                200_000)
            XCTAssertEqual(
                policy.maxContextWindowTokens,
                256_000)
            XCTAssertEqual(
                policy.resolvedAutoCompactTokenLimit,
                180_000)
            XCTAssertEqual(
                policy.hardUsableContextWindowTokens,
                190_000)
            XCTAssertEqual(
                policy.compHash,
                "cli-context-v1")
            XCTAssertNil(
                resolution.profile
                    .effectiveRequestOptions[
                        "context_window"])
            XCTAssertNil(
                resolution.profile
                    .effectiveRequestOptions[
                        "auto_compact_token_limit"])
            XCTAssertNil(
                resolution.profile
                    .effectiveRequestOptions[
                        "limit"])
        }
    }

    private func makeFixture() throws -> (
        directory: URL,
        configuration: URL
    ) {
        let directory =
            FileManager.default
                .temporaryDirectory
                .appendingPathComponent(
                    "translatis-cli-model-context-\(UUID().uuidString)",
                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let configuration =
            directory.appendingPathComponent(
                "translatis.json")
        let object: [String: Any] = [
            "model": "test-model",
            "provider": [
                "test": [
                    "options": [
                        "baseURL":
                            "https://example.invalid/v1",
                        "apiKey":
                            "{env:TRANSLATIS_TEST_API_KEY}",
                    ],
                    "models": [
                        "test-model": [
                            "name": "Test Model",
                            "capabilities": [
                                "vision_input",
                            ],
                            "context_window": 200_000,
                            "max_context_window": 256_000,
                            "auto_compact_token_limit":
                                190_000,
                            "effective_context_window_percent":
                                95,
                            "comp_hash":
                                "cli-context-v1",
                            "limit": [
                                "context": 128_000,
                            ],
                            "options": [
                                "temperature": 0.2,
                            ],
                            "variants": [
                                "high": [
                                    "reasoning_effort":
                                        "high",
                                ],
                            ],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys])
        try data.write(
            to: configuration,
            options: .atomic)
        return (directory, configuration)
    }
}
