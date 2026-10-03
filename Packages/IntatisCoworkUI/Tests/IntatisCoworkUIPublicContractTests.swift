#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisCoworkUI
import IntatisSharedUI
import XCTest

final class IntatisCoworkUIPublicContractTests: XCTestCase {
    func testPublicContractIsPresentationOnly() {
        XCTAssertEqual(
            IntatisCoworkUIContract.publicAPIMajorVersion,
            1)
        _ = IntatisCoworkContentView.self
        _ = IntatisCoworkContentState.self
        _ = IntatisCoworkContentActions.self
        _ = IntatisCoworkThreadSource.self

        _ = IntatisCoworkContentActions(
            onSend: {},
            onResolvePermission: { _ in },
            onSubmitUserInput: { _ in })

        let pendingInput = IntatisUserInputPresentation(
            id: "request-1",
            requesterName: "Research",
            questions: [
                IntatisUserInputQuestionPresentation(
                    id: "choice",
                    question: "Choose a direction",
                    options: [
                        IntatisUserInputOptionPresentation(
                            label: "A",
                            description: "First direction"),
                        IntatisUserInputOptionPresentation(
                            label: "B",
                            description: "Second direction"),
                    ],
                    allowsOther: true),
            ])
        let state = IntatisCoworkContentState(
            sessionID: SessionID(rawValue: "session-1"),
            sessionTitle: "Fixture",
            agents: [],
            pendingPermission: nil,
            summary: .init(),
            project: .init(),
            isWorking: false,
            isAcceptingSubmission: true,
            pendingUserInput: pendingInput)
        XCTAssertEqual(state.pendingUserInput, pendingInput)
    }

    func testPackageAndAppKeepRuntimeOutsideUIProduct()
        throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()

        let manifest = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let targetStart = try XCTUnwrap(manifest.range(
            of: ".target(\n            name: \"IntatisCoworkUI\","))
        let targetEnd = try XCTUnwrap(manifest.range(
            of: "path: \"Packages/IntatisCoworkUI/Sources\"",
            range: targetStart.upperBound..<manifest.endIndex))
        let target = manifest[
            targetStart.lowerBound..<targetEnd.upperBound]
        XCTAssertTrue(target.contains("IntatisSharedUI"))
        XCTAssertTrue(target.contains("IntatisConversation"))
        for forbidden in [
            "IntatisCodexRuntime",
            "IntatisAgentKernel",
            "\"IntatisCowork\",",
            "IntatisTools",
            "IntatisPermission",
            "IntatisMCP",
        ] {
            XCTAssertFalse(
                target.contains(forbidden),
                "UI target must not depend on \(forbidden)")
        }

        let uiSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "Packages/IntatisCoworkUI/Sources/IntatisCoworkContentView.swift"),
            encoding: .utf8)
        for forbidden in [
            "CoworkViewModel",
            "CodexAppServerSession",
            "ProviderRegistry",
            "dynamicTools",
        ] {
            XCTAssertFalse(uiSource.contains(forbidden))
        }
        let appSources = repositoryRoot
            .appendingPathComponent(
                "Apps/TranslatisMac/Sources",
                isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: appSources
                .appendingPathComponent("CoworkViewModel.swift")
                .path))

        let app = try String(
            contentsOf: appSources
                .appendingPathComponent("TranslatisMacApp.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(
            app.range(of: "struct CoworkSessionView: View"))
        let end = try XCTUnwrap(
            app.range(
                of: "#if canImport(AppKit)",
                range: start.upperBound..<app.endIndex))
        let host = app[start.lowerBound..<end.lowerBound]
        XCTAssertTrue(host.contains("IntatisCoworkContentView("))
        XCTAssertFalse(host.contains("CoworkShell("))
    }
}
#endif
