import XCTest
import MCP
@testable import IntatisMCP
@testable import IntatisMCPStdio

final class SDKPatchCompatibilityTests: XCTestCase {
    func testPinnedSDKIdentityAndProtocolVersions() {
        XCTAssertEqual(OfficialMCPSDKPin.version, "0.12.1")
        XCTAssertEqual(
            OfficialMCPSDKPin.revision,
            "a0ae212ebf6eab5f754c3129608bc5557637e605"
        )
        XCTAssertTrue(
            SDKPatchCompatibility.sdkSupportedProtocolVersions.contains(
                SDKPatchCompatibility.codexCompatibilityMaximumVersion
            )
        )
        XCTAssertTrue(
            SDKPatchCompatibility.sdkSupportedProtocolVersions.contains(
                SDKPatchCompatibility.standardExtendedMaximumVersion
            )
        )
        XCTAssertEqual(
            SDKPatchCompatibility.sdkLatestProtocolVersion,
            "2025-11-25"
        )
    }

    func testKnownSDKGapsAreExplicitAndUnique() {
        let entries = SDKPatchCompatibility.entries
        XCTAssertEqual(
            Set(entries.map(\.patchID)).count,
            entries.count,
            "Every patch/adapter entry must have one stable identity"
        )
        XCTAssertEqual(
            Set(entries.map(\.feature)).count,
            entries.count,
            "Every compatibility item must have one stable identity"
        )
        XCTAssertEqual(
            entries.first {
                $0.feature == "per_server_initialize_version"
            }?.disposition,
            .requiresPatch
        )
        XCTAssertEqual(
            entries.first {
                $0.feature == "experimental_tasks_2025_11_25"
            }?.disposition,
            .requiresPatch
        )
        XCTAssertEqual(
            Set(entries.filter { $0.patchID.hasPrefix("P") }.map(\.patchID)),
            Set((1...8).map { String(format: "P%03d", $0) })
        )
        for entry in entries {
            XCTAssertFalse(entry.upstreamFiles.isEmpty)
            XCTAssertFalse(entry.conformanceTests.isEmpty)
            XCTAssertFalse(entry.upgradeReplay.isEmpty)
        }
    }

    func testBothCapabilityProfilesCompileAgainstPinnedSDK() throws {
        let codex = SDKPatchCompatibility.makeCapabilityProbe(extended: false)
        XCTAssertNil(codex.sampling)
        XCTAssertNotNil(codex.elicitation?.form)
        XCTAssertNil(codex.elicitation?.url)
        XCTAssertNil(codex.roots)
        XCTAssertNil(codex.tasks)

        let extended = SDKPatchCompatibility.makeCapabilityProbe(extended: true)
        XCTAssertNotNil(extended.sampling?.tools)
        XCTAssertNotNil(extended.elicitation?.form)
        XCTAssertNotNil(extended.elicitation?.url)
        XCTAssertEqual(extended.roots?.listChanged, true)
        XCTAssertNotNil(extended.tasks?.list)
        XCTAssertNotNil(
            extended.tasks?.requests?.sampling?.createMessage)
        XCTAssertNotNil(
            extended.tasks?.requests?.elicitation?.create)

        XCTAssertEqual(MCPStdioLinkage.supportedTransport, "stdio")
        XCTAssertTrue(MCPStdioLinkage.requiresHostAuthorization)
        XCTAssertFalse(MCPStdioLinkage.usesShell)
        XCTAssertFalse(MCPStdioLinkage.usesPTY)
    }
}
