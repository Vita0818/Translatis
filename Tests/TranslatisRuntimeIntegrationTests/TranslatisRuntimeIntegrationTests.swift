import XCTest
import IntatisCore
import IntatisCodexRuntime

final class TranslatisRuntimeIntegrationTests: XCTestCase {
    private func configureTranslatisHost() throws -> IntatisHostApplicationIdentity {
        try IntatisHostApplication.configure(name: "Translatis")
    }

    func testProductNamespaceIsTranslatisWhileSharedContractStaysIntatis() throws {
        let identity = try configureTranslatisHost()

        XCTAssertEqual(identity.name, "Translatis")
        XCTAssertEqual(identity.storageName, "Translatis")
        XCTAssertEqual(identity.fileNameStem, "translatis")
        XCTAssertEqual(identity.fieldNameStem, "translatis")
        XCTAssertEqual(identity.environmentPrefix, "TRANSLATIS")
        XCTAssertEqual(identity.commandName, "translatis")
        XCTAssertEqual(identity.macOSProcessNameCandidates, ["Translatis", "TranslatisMac"])
        XCTAssertEqual(
            identity.macOSBundleIdentifierCandidates,
            ["com.Vita0818.Translatis", "com.Vita0818.TranslatisMac"])
        XCTAssertEqual(identity.configurationFileName, "translatis.json")
        XCTAssertEqual(identity.configurationJSONCFileName, "translatis.jsonc")
        XCTAssertEqual(
            identity.environmentVariable("CODEX_RUNTIME"),
            "TRANSLATIS_CODEX_RUNTIME")
        XCTAssertEqual(
            identity.userDefaultsKey("providerCatalog.v1"),
            "translatis.providerCatalog.v1")
        XCTAssertEqual(
            identity.namespacedIdentifier("standard.v5"),
            "translatis.standard.v5")
        XCTAssertEqual(
            identity.colonIdentifier("siliconflow-v1"),
            "translatis:siliconflow-v1")
        XCTAssertEqual(identity.temporaryPrefix("codex"), "translatis-codex")
        XCTAssertEqual(
            identity.authorizationContextFieldName,
            "__translatis_authorization_context")
        XCTAssertEqual(identity.hiddenWorkspaceDirectoryName, ".translatis")
        XCTAssertEqual(identity.knowledgeBundleDirectoryName, ".translatis-rag")
        XCTAssertEqual(identity.knowledgeStoreFileName, ".translatis-rag-store.json")
        XCTAssertEqual(identity.knowledgeSnapshotsDirectoryName, ".translatis-rag-snapshots")
        XCTAssertEqual(identity.knowledgeHostDirectoryName, ".translatis-rag-host")
        XCTAssertEqual(
            identity.keychainService("mcp"),
            "com.vitemis.translatis.mcp")

        XCTAssertTrue(identity.protectedIdentityStems.contains("translatis"))
        XCTAssertTrue(identity.protectedIdentityStems.contains("intatis"))

        XCTAssertEqual(CodexRuntimeHostContract.publicAPIMajorVersion, 1)
        XCTAssertEqual(CodexRuntimeHostContract.packageName, "Intatis")
        XCTAssertEqual(CodexRuntimeHostContract.productName, "IntatisCodexRuntime")
        XCTAssertEqual(CodexRuntimeHostContract.moduleName, "IntatisCodexRuntime")
        XCTAssertEqual(
            CodexRuntimeHostContract.pinnedRuntimeVersion,
            "0.145.0-intatis.4")
    }

    func testProductIdentityIsProcessStableAndRejectsAnIntatisSwitch() throws {
        let identity = try configureTranslatisHost()
        XCTAssertEqual(
            try IntatisHostApplication.configure(name: "Translatis"),
            identity)
        XCTAssertThrowsError(
            try IntatisHostApplication.configure(name: "Intatis")) { error in
            XCTAssertEqual(
                error as? IntatisHostApplicationIdentityError,
                .alreadyConfigured)
        }
    }
}
