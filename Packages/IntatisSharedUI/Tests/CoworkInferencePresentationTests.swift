#if canImport(SwiftUI)
import XCTest
import IntatisCore
import IntatisProtocol
@testable import IntatisSharedUI

final class CoworkInferencePresentationTests: XCTestCase {
    func testLegacyInitializerKeepsPermissionProfileCompatibility() {
        let agent = CoworkAgentInfo(
            id: "main",
            name: "main",
            workspace: "/workspace",
            model: "gpt-test",
            profile: "reviewed")

        XCTAssertEqual(agent.permissionProfile, "reviewed")
        XCTAssertEqual(agent.profile, "reviewed")
        XCTAssertEqual(agent.inferenceResolution, .legacy)
        XCTAssertTrue(agent.inferenceResolution.requiresAttention)
        XCTAssertEqual(agent.inferenceDisplayLabel, "Legacy · gpt-test")
    }

    func testResolvedInferencePresentationKeepsOnlySafeLabels() {
        let ref = InferenceProfileRef(
            inferenceProfileID: InferenceProfileID(rawValue: "profile-safe"),
            inferenceProfileRevision: InferenceProfileRevision(rawValue: "rev-1"))
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "gpt-test",
            permissionProfile: "read_only",
            inferenceProfileLabel: "Local · GPT Test · high",
            inferenceProfileRef: ref,
            inferenceConnectionLabel: "Local",
            inferenceVariant: "high",
            inferenceResolution: .resolved)

        XCTAssertEqual(agent.inferenceProfileRef, ref)
        XCTAssertEqual(agent.inferenceDisplayLabel, "Local · GPT Test · high")
    }

    func testURLAndCredentialShapedValuesNeverReachRosterLabel() {
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "sk-sensitive-token-value",
            permissionProfile: "reviewed",
            inferenceProfileLabel: "https://private.example/v1",
            inferenceConnectionLabel: "Bearer sensitive-token",
            inferenceVariant: "high",
            inferenceResolution: .resolved)

        XCTAssertEqual(agent.inferenceDisplayLabel, "high")
        XCTAssertFalse(agent.inferenceDisplayLabel?.contains("https://") == true)
        XCTAssertFalse(agent.inferenceDisplayLabel?.lowercased().contains("bearer") == true)
        XCTAssertFalse(agent.inferenceDisplayLabel?.contains("sk-sensitive") == true)
    }

    func testUnresolvedPresentationDoesNotEchoUnsafeConfiguration() {
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "https://private.example/model",
            permissionProfile: "reviewed",
            inferenceProfileLabel: "sk-sensitive-token-value",
            inferenceConnectionLabel: "https://private.example/v1",
            inferenceVariant: "secret",
            inferenceResolution: .unresolved)

        XCTAssertEqual(agent.inferenceDisplayLabel, "Inference unavailable")
        XCTAssertTrue(agent.inferenceResolution.requiresAttention)
    }

    func testDetachedAgentRemainsSelectableButHasNoRuntimeMutation() {
        let agent = CoworkAgentInfo(
            id: "worker",
            name: "worker",
            workspace: "/workspace",
            model: "gpt-test",
            permissionProfile: "reviewed",
            inferenceResolution: .resolved,
            status: "detached",
            isAttached: false,
            canRemove: false,
            isConversationSelectable: true)

        XCTAssertFalse(agent.isAttached)
        XCTAssertFalse(agent.canRemove)
        XCTAssertTrue(agent.isConversationSelectable)
        XCTAssertEqual(agent.statusLine, "detached")
    }

    func testHistoricalAgentRailUsesLazyUnfilteredRoster() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private var agentStatusList"))
        let end = try XCTUnwrap(
            source.range(
                of: "private func agentStatusRow(",
                range: start.upperBound..<source.endIndex))
        let roster = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(roster.contains("LazyVStack("))
        XCTAssertTrue(roster.contains("ForEach(agents)"))
        XCTAssertFalse(source.contains("private var visibleAgents"))
        XCTAssertTrue(source.contains("return \"minus.circle.fill\""))

        let rowStart = try XCTUnwrap(
            source.range(of: "private func agentStatusRowContent("))
        let rowEnd = try XCTUnwrap(
            source.range(
                of: "private var goalCardSection",
                range: rowStart.upperBound..<source.endIndex))
        let selectedRow = source[rowStart.lowerBound..<rowEnd.lowerBound]
        XCTAssertTrue(source.contains(".fill(accent.opacity(0.16))"))
        XCTAssertFalse(selectedRow.contains("checkmark.circle.fill"))
        XCTAssertTrue(selectedRow.contains(".font(IntatisTypography.system(.body, weight: .semibold))"))
        XCTAssertTrue(selectedRow.contains(".font(IntatisTypography.system(.callout))"))
        XCTAssertTrue(source.contains(".intatisClearLiquidGlass(cornerRadius: 22)"))
        XCTAssertTrue(source.contains("presentationStyle: .compactRail"))

        let surfaces = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertTrue(surfaces.contains(".glassEffectTransition(.identity)"))
        XCTAssertTrue(surfaces.contains(".strokeBorder("))

        let headerStart = try XCTUnwrap(source.range(of: "private func header("))
        let headerEnd = try XCTUnwrap(
            source.range(
                of: "private func resolvedHeaderActions(",
                range: headerStart.upperBound..<source.endIndex))
        let header = source[headerStart.lowerBound..<headerEnd.lowerBound]
        XCTAssertTrue(header.contains("subtitle: nil"))
        XCTAssertFalse(source.contains("\"Viewing @%@\""))
    }

    func testCoworkTranscriptKeepsOneFixedConversationGeometry() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "@ViewBuilder private func thread("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func resolvedViewportAdmission(",
                range: start.upperBound..<source.endIndex))
        let thread = source[start.lowerBound..<end.lowerBound]

        XCTAssertEqual(thread.components(separatedBy: "ScrollViewReader").count, 2)
        XCTAssertTrue(thread.contains(".frame(width: layout.contentWidth)"))
        XCTAssertTrue(thread.contains(".frame(width: layout.rawWidth)"))
        XCTAssertTrue(thread.contains("cowork.agent-thread.empty"))
        XCTAssertFalse(thread.contains(".padding(.horizontal, layout.horizontalPadding)"))
    }

    func testAppPresentsHistoricalAgentsInCreationOrder() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/CoworkViewModel.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(
            source.range(of: "private func agentPresentation("))
        let end = try XCTUnwrap(
            source.range(
                of: "private func liveAgentInfo(",
                range: start.upperBound..<source.endIndex))
        let presentation = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(
            presentation.contains("projection.historicalAgentsInCreationOrder"))
        XCTAssertTrue(presentation.contains(
            "var result = projection.historicalAgentsInCreationOrder\n            .map"))
        XCTAssertFalse(presentation.contains(
            "projection.historicalAgentsInCreationOrder\n            .sorted"))
    }

    func testCodexCoworkSettingsDeliveryAndNestedPolicyStayFailClosed()
        throws
    {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/CoworkViewModel.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(
            "profile: projectSettings.defaultPermissionProfile"))
        XCTAssertTrue(source.contains(
            "profile: self.projectSettings\n                                .defaultPermissionProfile"))
        XCTAssertTrue(source.contains("hasActiveCodexChildWork"))
        XCTAssertTrue(source.contains(
            "Wait for all Codex root and subagent work to finish"))
        XCTAssertTrue(source.contains("resetCodexRuntime()"))
        XCTAssertTrue(source.contains(
            "appendSessionStateTransaction"))

        XCTAssertTrue(source.contains(
            "deliverMessageToVerifiedCodexDescendant"))
        XCTAssertTrue(source.contains(
            "child_message_delivery_unknown"))
        XCTAssertTrue(source.contains(
            "containsNewUserMessage"))
        XCTAssertTrue(source.contains(
            "codexChildDeliveryPresentationItems"))
        XCTAssertTrue(source.contains(
            "let id = payload.eventID"))
        XCTAssertTrue(source.contains(
            "publishes: payload.textDelta == nil"))
        XCTAssertFalse(source.contains(
            "let id = \"\\(threadID):\\(payload.eventID)\""))
        XCTAssertFalse(source.contains(
            "sendMessageToVerifiedCodexDescendant"))
        let deliveryStart = try XCTUnwrap(source.range(
            of: "private func deliverMessageToVerifiedCodexDescendant("))
        let deliveryEnd = try XCTUnwrap(source.range(
            of: "private static func isUncertainCodexChildDelivery(",
            range: deliveryStart.upperBound..<source.endIndex))
        let delivery = source[
            deliveryStart.lowerBound..<deliveryEnd.lowerBound]
        XCTAssertFalse(delivery.contains("updateLocalCodexChildStatus"))

        XCTAssertTrue(source.contains(
            "effectiveCodexRosterPreset"))
        XCTAssertTrue(source.contains(
            "PermissionProfile.locked.rawValue"))
        XCTAssertTrue(source.contains(
            "currentCodexRuntimeGeneration"))
        XCTAssertTrue(source.contains(
            "normalized.codexRuntimeGeneration ="))
        XCTAssertTrue(source.contains(
            "&& !Self.containsAgentHistory(restored)"))
    }
}
#endif
