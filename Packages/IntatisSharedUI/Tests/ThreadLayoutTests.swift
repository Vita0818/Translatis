#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import IntatisConversation
import IntatisCore
import IntatisProtocol
@testable import IntatisSharedUI

@MainActor
private final class WorkspaceChromeStressModel: ObservableObject {
    @Published var mode = 0
    @Published var codeInspector = true
    @Published var coworkInspector = true
    @Published var coworkSelectedAgentID = "main"
}

private struct WorkspaceChromeStressHarness: View {
    @ObservedObject var model: WorkspaceChromeStressModel
    @State private var codeInput = ""
    @State private var coworkInput = ""

    var body: some View {
        NavigationSplitView {
            VStack {
                Text("Intatis")
                Text("Chat")
                Text("Code")
                Text("Cowork")
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
        }
        .navigationTitle("")
    }

    @ViewBuilder private var detail: some View {
        switch model.mode {
        case 1:
            CodeShell(
                items: [],
                presentationScope: IntatisThreadPresentationScope(
                    kind: "code",
                    sessionID: "layout-stress-code"),
                sessionTitle: "Code",
                pending: nil,
                isWorking: false,
                workspaceName: "Workspace",
                agentState: "idle",
                showsInspector: Binding(
                    get: { model.codeInspector },
                    set: { model.codeInspector = $0 }),
                input: $codeInput,
                onSend: {},
                onResolve: { _ in })
        case 2:
            CoworkShell(
                threadSnapshot: .empty(
                    agentID: AgentID(
                        rawValue: model.coworkSelectedAgentID)),
                presentationScope: IntatisThreadPresentationScope(
                    kind: "cowork",
                    sessionID: "layout-stress-cowork"),
                sessionTitle: "Cowork",
                agents: [
                    CoworkAgentInfo(
                        id: "main",
                        name: "main",
                        workspace: "Workspace",
                        model: "Model A",
                        profile: "full"),
                    CoworkAgentInfo(
                        id: "worker",
                        name: "worker",
                        workspace: "Workspace",
                        model: "Model B",
                        profile: "read-only",
                        isAttached: false),
                ],
                pending: nil,
                summary: CoworkStatusSummary(),
                errorTexts: [],
                isWorking: false,
                showsInspector: Binding(
                    get: { model.coworkInspector },
                    set: { model.coworkInspector = $0 }),
                input: $coworkInput,
                onSend: {},
                onResolve: { _ in },
                selectedAgentID: model.coworkSelectedAgentID,
                onSelectAgent: { model.coworkSelectedAgentID = $0 })
        default:
            VStack(alignment: .leading, spacing: 8) {
                Text("Chat")
                    .font(.largeTitle)
                Spacer()
                TextField("Message", text: .constant(""))
            }
            .padding(24)
        }
    }
}

final class ThreadLayoutTests: XCTestCase {
    func testIOSComposerGlassMergeThresholdStaysBelowRowGap() {
        XCTAssertEqual(IntatisComposerControlMetrics.rowSpacing, 8)
        XCTAssertEqual(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .iOS),
            0)
        XCTAssertEqual(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .macOS),
            10)
        XCTAssertLessThan(
            IntatisComposerControlMetrics.glassEffectSpacing(for: .iOS),
            IntatisComposerControlMetrics.rowSpacing)
    }

    func testComposerUsesPlatformControlSizeWithinSharedFortyPointGeometry() {
        XCTAssertEqual(IntatisComposerControlMetrics.controlHeight, 40)
        XCTAssertEqual(
            IntatisComposerControlMetrics.iconControlSize(for: .iOS),
            .small)
        XCTAssertEqual(
            IntatisComposerControlMetrics.iconControlSize(for: .macOS),
            .regular)
    }

    func testIOSChatDismissesKeyboardOnSubmitAndInteractiveThreadDrag() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewsSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/Views.swift"),
            encoding: .utf8)
        let composerSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)

        XCTAssertTrue(viewsSource.contains(
            "#if os(iOS)\n                .scrollDismissesKeyboard(.interactively)"))
        XCTAssertTrue(composerSource.contains("Button(action: submit)"))
        XCTAssertTrue(composerSource.contains(".onSubmit {\n                submit()"))
        XCTAssertTrue(composerSource.contains(
            "#if os(iOS)\n        focused = false\n        #endif"))
        XCTAssertTrue(composerSource.contains(
            "guard stopAction == nil, canSend else { return }"))
    }

    func testSidebarOpenGestureRequiresLeadingEdgeHorizontalIntent() {
        XCTAssertTrue(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 72, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 40,
            translation: CGSize(width: 72, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 48, height: 4)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: 72, height: 64)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldOpen(
            startX: 8,
            translation: CGSize(width: -72, height: 4)))
    }

    func testSidebarCloseGestureRequiresHorizontalLeftIntent() {
        XCTAssertTrue(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -60, height: 8)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -40, height: 4)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: -60, height: 56)))
        XCTAssertFalse(IntatisSidebarGesturePolicy.shouldClose(
            translation: CGSize(width: 60, height: 4)))
    }

    func testLeadingAssistantAndAgentRowsUseTheFullAvailableWidth() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: true,
                maxWidth: 560,
                gutter: 48),
            .fullWidthLeading)
    }

    func testTrailingUserRowsKeepTheirBubbleWidthAndLeadingGutter() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: true,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: true, maxWidth: 560, gutter: 48))
    }

    func testOtherLeadingRowsKeepTheirExistingConstrainedLayout() {
        XCTAssertEqual(
            IntatisThreadBubbleWidthPolicy.resolve(
                isTrailing: false,
                fillsAvailableWidth: false,
                maxWidth: 560,
                gutter: 48),
            .constrained(isTrailing: false, maxWidth: 560, gutter: 48))
    }

    func testWindowCenteredOverlayAccountsForSidebarAndInspectorWidths() {
        let windowWidth: CGFloat = 1_200
        let sidebarWidth: CGFloat = 236
        let detailWidth = windowWidth - sidebarWidth

        let fullDetailOffset =
            IntatisWindowCenteredOverlayLayoutPolicy.horizontalOffset(
                windowWidth: windowWidth,
                detailWidth: detailWidth,
                overlaySurfaceWidth: detailWidth)
        XCTAssertEqual(fullDetailOffset, -sidebarWidth / 2)
        XCTAssertEqual(
            sidebarWidth + detailWidth / 2 + fullDetailOffset,
            windowWidth / 2)

        let inspectorWidth: CGFloat = 292
        let threadWidth = detailWidth - inspectorWidth
        let threadOffset =
            IntatisWindowCenteredOverlayLayoutPolicy.horizontalOffset(
                windowWidth: windowWidth,
                detailWidth: detailWidth,
                overlaySurfaceWidth: threadWidth)
        XCTAssertEqual(
            sidebarWidth + threadWidth / 2 + threadOffset,
            windowWidth / 2)

        XCTAssertEqual(
            IntatisWindowCenteredOverlayLayoutPolicy.horizontalOffset(
                windowWidth: nil,
                detailWidth: detailWidth,
                overlaySurfaceWidth: detailWidth),
            0)
    }

    func testUserMessagesDoNotRepeatAnIdentityHeader() {
        XCTAssertFalse(IntatisMessageHeaderPolicy.showsIdentity(for: .user))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .assistant))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .agent))
        XCTAssertTrue(IntatisMessageHeaderPolicy.showsIdentity(for: .system))
    }

    func testCodexIntermediateOutputUsesSemanticActivityAndNoSyntheticThinkingRow() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codeSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/CodeViews.swift"),
            encoding: .utf8)
        let coworkSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/CoworkViews.swift"),
            encoding: .utf8)

        XCTAssertTrue(codeSource.contains(
            "if item.messagePhase == .commentary"))
        XCTAssertTrue(codeSource.contains(
            "case .runtimeEvent:\n            runtimeEvent()"))
        XCTAssertTrue(codeSource.contains(
            "semanticActivity(activity)"))
        XCTAssertTrue(codeSource.contains(
            "IntatisLocalization.string(\"Runtime activity\")"))
        XCTAssertTrue(codeSource.contains(
            ".foregroundStyle(style.secondaryText)"))
        XCTAssertTrue(coworkSource.contains(
            "IntatisExecutionTracePresentation.displayedItems("))
        XCTAssertFalse(codeSource.contains("IntatisThreadThinkingRow("))
        XCTAssertFalse(coworkSource.contains("IntatisThreadThinkingRow("))
    }

    func testPerMessageMetricsPreserveNativeResponsesSemantics() {
        let metrics = IntatisMessageTurnMetrics(
            responsesUsage: ResponsesUsageSnapshot(
                id: "responses-usage",
                payload: ResponsesUsagePayload(
                    turnID: TurnID(rawValue: "turn"),
                    inputTokens: 1_250,
                    cachedInputTokens: 1_000,
                    cacheWriteInputTokens: 125,
                    outputTokens: 75,
                    reasoningOutputTokens: 25,
                    totalTokens: 1_325,
                    durationMs: 6_250)),
            legacyStats: nil)

        XCTAssertEqual(metrics.inputTokens, 1_250)
        XCTAssertEqual(metrics.cacheHitTokens, 1_000)
        XCTAssertEqual(metrics.cacheWriteTokens, 125)
        XCTAssertEqual(metrics.outputTokens, 75)
        XCTAssertEqual(metrics.reasoningTokens, 25)
        XCTAssertEqual(metrics.totalTokens, 1_325)
        XCTAssertEqual(metrics.durationMs, 6_250)
        XCTAssertTrue(metrics.hasAnyValue)
    }

    @MainActor
    func testMessageClipboardCopiesExactRawText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let rawText = """
        标题 **保持 Markdown**

        ```swift
        let value = "$x^2$"
        ```
        """

        XCTAssertTrue(IntatisMessageClipboard.copy(rawText, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), rawText)
    }

    func testMacReplyFooterUsesNativeResponsesMetricsAndDefersCodeCoworkContext() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func source(_ relativePath: String, root: URL) throws -> String {
            try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8)
        }

        let surfaces = try source(
            "Sources/ThreadSurfaces.swift",
            root: packageRoot)
        let footerStart = try XCTUnwrap(
            surfaces.range(of: "public struct IntatisMessageFooter: View"))
        let footerEnd = try XCTUnwrap(surfaces.range(
            of: "public struct IntatisSessionHistoryItem",
            range: footerStart.upperBound..<surfaces.endIndex))
        let footer = surfaces[footerStart.lowerBound..<footerEnd.lowerBound]
        XCTAssertTrue(footer.contains("Image(systemName: \"doc.on.doc\")"))
        XCTAssertTrue(footer.contains("metric(\"Input\""))
        XCTAssertTrue(footer.contains("metric(\"Cache Hit\""))
        XCTAssertTrue(footer.contains("metric(\"Cache Write\""))
        XCTAssertTrue(footer.contains("metric(\"Output\""))
        XCTAssertTrue(footer.contains("metric(\"Reasoning\""))
        XCTAssertTrue(footer.contains("metric(\"Total\""))
        XCTAssertTrue(footer.contains("metric(\"Duration\""))
        XCTAssertFalse(footer.contains("hand.thumbsup"))
        XCTAssertFalse(footer.contains("hand.thumbsdown"))

        let macChat = try source(
            "Apps/TranslatisMac/Sources/TranslatisChatScreen.swift",
            root: repositoryRoot)
        let code = try source("Sources/CodeViews.swift", root: packageRoot)
        let cowork = try source("Sources/CoworkViews.swift", root: packageRoot)
        let sharedChat = try source("Sources/Views.swift", root: packageRoot)
        XCTAssertTrue(macChat.contains("IntatisMessageFooter("))
        XCTAssertTrue(code.contains("IntatisMessageFooter("))
        XCTAssertTrue(macChat.contains("last.turnStats?.id"))
        XCTAssertTrue(code.contains("last?.responsesUsage?.id"))
        XCTAssertTrue(cowork.contains("last?.responsesUsage?.id"))
        XCTAssertTrue(macChat.contains("IntatisComposerContextStrip("))
        XCTAssertFalse(code.contains("IntatisComposerContextStrip("))
        XCTAssertFalse(cowork.contains("IntatisComposerContextStrip("))
        XCTAssertTrue(sharedChat.contains("IntatisComposerUsageStrip("))
        XCTAssertFalse(sharedChat.contains("IntatisMessageFooter("))
    }

    func testOnlyUserConversationRowsUseNativeLiquidGlassBubble() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        func sourceSlice(
            _ source: String,
            from startMarker: String,
            to endMarker: String
        ) throws -> Substring {
            let start = try XCTUnwrap(source.range(of: startMarker))
            let end = try XCTUnwrap(source.range(
                of: endMarker,
                range: start.upperBound..<source.endIndex))
            return source[start.lowerBound..<end.lowerBound]
        }

        let sharedChatSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/Views.swift"),
            encoding: .utf8)
        let sharedMessageRow = try sourceSlice(
            sharedChatSource,
            from: "struct MessageRow: View",
            to: "struct ComposerView: View")
        XCTAssertTrue(sharedMessageRow.contains("if message.role == .user"))
        XCTAssertTrue(sharedMessageRow.contains(
            ".intatisLiquidGlass(cornerRadius: 10)"))
        XCTAssertFalse(sharedMessageRow.contains(".intatisContentSurface("))
        XCTAssertFalse(sharedMessageRow.contains("style.accent.opacity(0.64)"))
        XCTAssertFalse(sharedMessageRow.contains("isUninterruptedAgentReply"))

        let macChatSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent(
                    "Apps/TranslatisMac/Sources/TranslatisChatScreen.swift"),
            encoding: .utf8)
        let macMessageBubble = try sourceSlice(
            macChatSource,
            from: "struct IntatisMessageBubble: View",
            to: "struct IntatisComposer: View")
        XCTAssertTrue(macMessageBubble.contains("if isUser {"))
        XCTAssertTrue(macMessageBubble.contains(
            ".intatisLiquidGlass(cornerRadius: 20)"))
        XCTAssertFalse(macMessageBubble.contains(".intatisContentSurface("))
        XCTAssertFalse(macMessageBubble.contains("userSelectionStroke"))
        XCTAssertFalse(macMessageBubble.contains("isUninterruptedAgentReply"))

        let codeSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CodeViews.swift"),
            encoding: .utf8)
        let codeBubbleContent = try sourceSlice(
            codeSource,
            from: "@ViewBuilder private func bubbleContent",
            to: "private func bubbleBody")
        XCTAssertTrue(codeBubbleContent.contains("if isUser {"))
        XCTAssertTrue(codeBubbleContent.contains(
            ".intatisLiquidGlass(cornerRadius: 20)"))
        XCTAssertFalse(codeBubbleContent.contains("item.isFailure"))
        XCTAssertFalse(codeBubbleContent.contains(".intatisContentSurface("))
        XCTAssertFalse(codeSource.contains("private func bubbleStroke(isUser:"))
        XCTAssertFalse(codeSource.contains("submissionStatusView"))
        XCTAssertFalse(codeSource.contains("submissionStatusLabel"))
    }

    func testJumpToLatestUsesNativeCircularGlassIcon() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "public struct IntatisJumpToLatestButton: View"))
        let end = try XCTUnwrap(source.range(
            of: "public enum IntatisContinuousThreadRenderingPolicy",
            range: start.upperBound..<source.endIndex))
        let buttonSource = source[start.lowerBound..<end.lowerBound]

        XCTAssertTrue(buttonSource.contains("systemImage: \"arrow.down\""))
        XCTAssertTrue(buttonSource.contains(
            ".intatisCompactIconButton(controlSize: .large)"))
        XCTAssertTrue(buttonSource.contains(".contentShape(Circle())"))
        XCTAssertTrue(buttonSource.contains(".accessibilityLabel("))
        XCTAssertTrue(buttonSource.contains(".help("))
        XCTAssertFalse(buttonSource.contains("arrow.down.to.line"))
        XCTAssertFalse(buttonSource.contains(".buttonStyle(.bordered)"))

        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let macChatSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/TranslatisChatScreen.swift"),
            encoding: .utf8)
        let codeSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/CodeViews.swift"),
            encoding: .utf8)
        let coworkSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/CoworkViews.swift"),
            encoding: .utf8)
        for source in [macChatSource, codeSource, coworkSource] {
            XCTAssertTrue(source.contains(".overlay(alignment: .bottom)"))
            XCTAssertFalse(source.contains(
                ".overlay(alignment: .bottomTrailing)"))
            XCTAssertTrue(source.contains(
                "IntatisWindowCenteredOverlayLayoutPolicy"))
        }
        XCTAssertFalse(coworkSource.contains(
            ".padding(.trailing, trailingContentMargin)"))

        let macRootSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/TranslatisMacRootView.swift"),
            encoding: .utf8)
        XCTAssertTrue(macRootSource.contains(
            "\\.intatisWindowContentWidth"))
    }

    func testMacFolderProjectsRemainAGroupingLayerOverExistingSessions() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/TranslatisMacRootView.swift"),
            encoding: .utf8)
        let appSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Apps/TranslatisMac/Sources/TranslatisMacApp.swift"),
            encoding: .utf8)

        XCTAssertTrue(rootSource.contains("private struct ProjectSidebarSection"))
        XCTAssertFalse(rootSource.contains("private struct ProjectHomeView"))
        XCTAssertTrue(rootSource.contains(
            "@State private var expandedProjectIDs: Set<ProjectID> = []"))
        XCTAssertTrue(rootSource.contains("systemName: \"chevron.right\""))
        XCTAssertTrue(rootSource.contains("if isExpanded"))
        XCTAssertFalse(rootSource.contains(".frame(maxHeight: 230)"))
        XCTAssertFalse(rootSource.contains("availableKinds"))
        XCTAssertTrue(rootSource.contains("$0.kind == selection.sessionKind"))
        XCTAssertTrue(rootSource.contains("usesOwnScrollView: false"))
        XCTAssertTrue(rootSource.contains(
            "historyTitle: IntatisLocalization.string(\"Unfiled\")"))
        XCTAssertTrue(rootSource.contains("case .chat:"))
        XCTAssertTrue(rootSource.contains("case .code:"))
        XCTAssertTrue(rootSource.contains("case .cowork:"))
        XCTAssertTrue(rootSource.contains(
            "The folder and all conversations will remain on disk."))
        XCTAssertTrue(appSource.contains("startNewProjectChatSession"))
        XCTAssertTrue(appSource.contains("makeProjectCodeViewModel"))
        XCTAssertTrue(appSource.contains("makeProjectCoworkViewModel"))
        XCTAssertTrue(appSource.contains("ProjectFolderStore.associate"))
        XCTAssertTrue(appSource.contains("expectedKind: .chat"))
        XCTAssertTrue(appSource.contains("expectedKind: .code"))
        XCTAssertTrue(appSource.contains("expectedKind: .cowork"))
        XCTAssertFalse(appSource.contains("moveProjectSessionDirectory"))
    }

    func testCoworkTasksUseCompactHeaderAndSingleStatusMarker() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)

        let sectionStart = try XCTUnwrap(source.range(
            of: "private var workTasksSection: some View"))
        let sectionEnd = try XCTUnwrap(source.range(
            of: "private func formatElapsed",
            range: sectionStart.upperBound..<source.endIndex))
        let sectionSource = source[
            sectionStart.lowerBound..<sectionEnd.lowerBound]
        XCTAssertTrue(sectionSource.contains(
            "IntatisLocalization.string(\"Tasks\")"))
        XCTAssertTrue(sectionSource.contains(
            "Text(\"\\(workTasks.completedCount)/\\(workTasks.totalCount)\")"))
        XCTAssertFalse(sectionSource.contains("Session Tasks"))
        XCTAssertFalse(sectionSource.contains("· %lld running"))

        let rowStart = try XCTUnwrap(source.range(
            of: "private struct CoworkWorkTaskRow: View"))
        let rowEnd = try XCTUnwrap(source.range(
            of: "private struct CoworkTaskLineRow: View",
            range: rowStart.upperBound..<source.endIndex))
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]
        XCTAssertTrue(rowSource.contains("systemName: \"chevron.right\""))
        XCTAssertTrue(rowSource.contains("neutralMarker"))
        XCTAssertTrue(rowSource.contains(".accessibilityValue(displayStatus)"))
        XCTAssertFalse(rowSource.contains("DisclosureGroup"))
        XCTAssertFalse(rowSource.contains("let ordinal:"))
        XCTAssertFalse(rowSource.contains("Text(displayStatus)"))
        XCTAssertFalse(rowSource.contains(".strikethrough("))
    }

    func testCoworkAgentStatusUsesLargerNativeCircularSymbols() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)

        XCTAssertTrue(source.contains(
            "rightRailSection(\"Agents\", systemImage: \"person.2.fill\")"))

        let rowStart = try XCTUnwrap(source.range(
            of: "private func agentStatusRowContent("))
        let rowEnd = try XCTUnwrap(source.range(
            of: "private var goalCardSection",
            range: rowStart.upperBound..<source.endIndex))
        let rowSource = source[rowStart.lowerBound..<rowEnd.lowerBound]
        XCTAssertTrue(rowSource.contains(
            ".symbolRenderingMode(.hierarchical)"))
        XCTAssertTrue(rowSource.contains(
            ".font(.system(size: 20, weight: .semibold))"))
        XCTAssertTrue(rowSource.contains(
            ".frame(width: 30, height: 30)"))

        let iconStart = try XCTUnwrap(source.range(
            of: "private func statusIconName(for status: String)"))
        let iconEnd = try XCTUnwrap(source.range(
            of: "private func normalizedStatus(_ status: String)",
            range: iconStart.upperBound..<source.endIndex))
        let iconSource = source[iconStart.lowerBound..<iconEnd.lowerBound]
        for systemName in [
            "exclamationmark.circle.fill",
            "ellipsis.circle.fill",
            "pause.circle.fill",
            "hourglass.circle.fill",
            "clock.fill",
            "checkmark.circle.fill",
            "xmark.circle.fill",
            "minus.circle.fill",
            "circle",
        ] {
            XCTAssertTrue(iconSource.contains("return \"\(systemName)\""))
        }
        XCTAssertFalse(iconSource.contains("play.circle.fill"))
        XCTAssertFalse(iconSource.contains("exclamationmark.triangle.fill"))
        XCTAssertFalse(iconSource.contains("gauge.with.dots.needle"))
        XCTAssertFalse(iconSource.contains("slash.circle.fill"))
    }

    func testThreadErrorsCollectEveryConversationSourceAndLeaveTranscriptClean() throws {
        let submissionID = SubmissionID(rawValue: "submission-timeout")
        let timeout = "Task timed out after 600 seconds."
        let items = [
            CodeItem(
                id: "user-timeout",
                kind: .user,
                title: "",
                body: "Read the PDF",
                isFailure: true,
                submissionID: submissionID,
                submissionStatus: .failed,
                submissionFailure: SubmissionFailure(
                    code: "timeout",
                    message: timeout,
                    retryable: true)),
            CodeItem(
                id: "partial-agent",
                kind: .agent,
                title: "main",
                body: "Partial answer remains visible.",
                complete: false,
                isFailure: true,
                recoveryAdvice: RuntimeRecoveryAdvice(
                    title: "Response stopped before completion",
                    detail: "Check endpoint compatibility before retrying.",
                    retryable: true)),
            CodeItem(
                id: "runtime-timeout",
                kind: .error,
                title: "main",
                body: timeout),
            CodeItem(
                id: "tool-failure",
                kind: .toolResult,
                title: "read_pdf",
                body: "Tool error: document could not be decoded.",
                isFailure: true,
                recoveryAdvice: RuntimeRecoveryAdvice(
                    title: "Inspect tool inputs and retry",
                    detail: "Check the selected file before retrying.",
                    retryable: true)),
            CodeItem(
                id: "normal-agent",
                kind: .agent,
                title: "main",
                body: "Normal answer."),
        ]

        let errors = IntatisThreadErrorPresentation.errors(
            items: items,
            errorTexts: [
                "Voice input failed.",
                "Projection unavailable.",
                "Projection unavailable.",
            ])

        XCTAssertEqual(errors.count, 5)
        let timeoutError = try XCTUnwrap(errors.first(where: {
            $0.details.contains(timeout)
        }))
        XCTAssertEqual(timeoutError.title, "main")
        XCTAssertEqual(timeoutError.retrySubmissionID, submissionID)
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Check endpoint compatibility before retrying.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Tool error: document could not be decoded.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Voice input failed.")
        }))
        XCTAssertTrue(errors.contains(where: {
            $0.details.contains("Projection unavailable.")
        }))

        let transcript = IntatisThreadErrorPresentation.transcriptItems(items)
        XCTAssertEqual(transcript.map(\.id), [
            "user-timeout",
            "partial-agent",
            "normal-agent",
        ])
        let user = try XCTUnwrap(transcript.first)
        XCTAssertNil(user.submissionStatus)
        XCTAssertNil(user.submissionFailure)
        XCTAssertNil(user.recoveryAdvice)
        XCTAssertFalse(user.isFailure)
        let partialAgent = try XCTUnwrap(transcript.dropFirst().first)
        XCTAssertEqual(partialAgent.body, "Partial answer remains visible.")
        XCTAssertNil(partialAgent.recoveryAdvice)
        XCTAssertFalse(partialAgent.isFailure)
    }

    func testThreadErrorCardIsAbsentWhenEveryErrorSourceIsEmpty() {
        let items = [
            CodeItem(
                id: "user",
                kind: .user,
                title: "",
                body: "Hello"),
            CodeItem(
                id: "agent",
                kind: .agent,
                title: "main",
                body: "Hello back"),
        ]

        XCTAssertTrue(IntatisThreadErrorPresentation.errors(
            items: items,
            errorTexts: ["  ", "\n"]).isEmpty)
        XCTAssertEqual(
            IntatisThreadErrorPresentation.transcriptItems(items),
            items)

        let cancelledSubmission = CodeItem(
            id: "cancelled-user",
            kind: .user,
            title: "",
            body: "Stop this request",
            isFailure: true,
            submissionID: SubmissionID(rawValue: "cancelled-submission"),
            submissionStatus: .cancelled)
        XCTAssertTrue(IntatisThreadErrorPresentation.errors(
            items: [cancelledSubmission],
            errorTexts: []).isEmpty)
        XCTAssertEqual(
            IntatisThreadErrorPresentation
                .transcriptItems([cancelledSubmission])
                .first?
                .submissionStatus,
            .cancelled)
    }

    func testWorkspaceShellsUseOneConditionalRightRailErrorList() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let codeSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CodeViews.swift"),
            encoding: .utf8)
        let coworkSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)

        XCTAssertTrue(codeSource.contains("if !errors.isEmpty"))
        XCTAssertTrue(codeSource.contains("IntatisThreadErrorList("))
        XCTAssertFalse(codeSource.contains("Recent Failures"))
        XCTAssertFalse(codeSource.contains(
            "case .error:\n            card("))
        XCTAssertTrue(coworkSource.contains("if !threadErrors.isEmpty"))
        XCTAssertTrue(coworkSource.contains("IntatisThreadErrorList("))
        XCTAssertFalse(coworkSource.contains("if let composerError"))
    }

    func testPermissionDetailsUseStructuredScopeWithoutRawArguments() {
        let request = PermissionRequestPayload(
            requestId: RequestID(rawValue: "permission-ui-test"),
            tool: "apply_patch",
            args: #"{"apiKey":"must-not-render","path":"Sources/App.swift"}"#,
            risk: .medium,
            reason: "Update the app",
            context: PermissionRequestContext(
                touchedPaths: ["Sources/App.swift"],
                sideEffect: .write,
                intent: PermissionIntent(
                    action: "filesystem.patch",
                    resources: [PermissionResource(
                        kind: .workspacePath,
                        value: "Sources/App.swift",
                        access: .readWrite)],
                    dataEffects: [.mutate],
                    risks: [.workspaceMutation],
                    replayPolicy: .doNotReplay)))

        let renderedDetails = PermissionReviewPresentation.details(for: request)
            .map(\.text)
            .joined(separator: " ")

        XCTAssertTrue(renderedDetails.contains("filesystem.patch"))
        XCTAssertTrue(renderedDetails.contains("Sources/App.swift"))
        XCTAssertFalse(renderedDetails.contains("must-not-render"))
        XCTAssertFalse(renderedDetails.contains("apiKey"))
    }

    func testPermissionDiffRemainsAvailableOnlyInsideDetails() {
        let args = #"{"diff":"*** Begin Patch\n*** End Patch"}"#
        XCTAssertEqual(
            PermissionCard.diff(from: args),
            "*** Begin Patch\n*** End Patch")
    }

    func testCompactPermissionSummaryDoesNotRenderRawArguments() {
        let request = PermissionRequestPayload(
            requestId: RequestID(rawValue: "compact-permission-ui-test"),
            tool: "write_file",
            args: #"{"apiKey":"must-not-render","path":"Sources/App.swift"}"#,
            risk: .medium,
            reason: "Update the selected workspace file")

        let summary = PermissionReviewPresentation.compactSummary(for: request)

        XCTAssertEqual(summary, "Update the selected workspace file")
        XCTAssertFalse(summary.contains("must-not-render"))
        XCTAssertFalse(summary.contains("apiKey"))
    }

    func testWorkspaceInspectorUsesOnlyTheStableOuterWidth() {
        let hidden = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 979,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390)
        XCTAssertEqual(
            hidden,
            IntatisWorkspaceInspectorLayout(
                isVisible: false,
                threadWidth: 979,
                inspectorWidth: 0))

        let visible = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 980,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390)
        XCTAssertTrue(visible.isVisible)
        XCTAssertEqual(visible.inspectorWidth, 318)
        XCTAssertEqual(
            visible.threadWidth + visible.inspectorWidth + 1,
            980)
        XCTAssertLessThan(visible.threadWidth, 980)

        let integratedCowork = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: 980,
            isRequested: true,
            activationWidth: 980,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 286,
            idealInspectorWidth: 318,
            maximumInspectorWidth: 390,
            dividerWidth: 0)
        XCTAssertTrue(integratedCowork.isVisible)
        XCTAssertEqual(
            integratedCowork.threadWidth + integratedCowork.inspectorWidth,
            980)

        for _ in 0..<10_000 {
            XCTAssertEqual(
                IntatisWorkspaceInspectorLayoutPolicy.resolve(
                    availableWidth: 980,
                    isRequested: true,
                    activationWidth: 980,
                    minimumThreadWidth: 620,
                    minimumInspectorWidth: 286,
                    idealInspectorWidth: 318,
                    maximumInspectorWidth: 390),
                visible)
        }
    }

    func testMacThreadsUseOneContinuousTimelineWithoutManualPaging() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sources = [
            try String(
                contentsOf: repositoryRoot.appendingPathComponent(
                    "Apps/TranslatisMac/Sources/TranslatisChatScreen.swift"),
                encoding: .utf8),
            try String(
                contentsOf: packageRoot.appendingPathComponent(
                    "Sources/CodeViews.swift"),
                encoding: .utf8),
            try String(
                contentsOf: packageRoot.appendingPathComponent(
                    "Sources/CoworkViews.swift"),
                encoding: .utf8),
        ]
        for source in sources {
            XCTAssertTrue(source.contains("IntatisContinuousThreadStack("))
            XCTAssertFalse(source.contains("IntatisThreadHistoryPager("))
            XCTAssertFalse(source.contains("onShowEarlier"))
            XCTAssertFalse(source.contains("onShowNewer"))
            XCTAssertFalse(source.contains("Messages %lld–%lld of %lld"))
        }

        let surfaceSource = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertTrue(surfaceSource.contains(
            "public static let maximumActiveRichRows = 16"))
        XCTAssertTrue(surfaceSource.contains("LazyVStack("))
        XCTAssertTrue(surfaceSource.contains("case evicted(generation:"))
        XCTAssertFalse(surfaceSource.contains(
            "public struct IntatisThreadHistoryPager"))
    }

    func testCoworkStatusRailAndConversationWidthStayFixedAcrossContentStates() {
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.railWidth, 348)
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.cardWidth, 318)
        XCTAssertEqual(IntatisCoworkStatusRailLayoutPolicy.cardSpacing, 18)

        for availableWidth in [CGFloat(980), 1_100, 1_372, 1_800] {
            let emptyConversation =
                IntatisCoworkStatusRailLayoutPolicy.resolve(
                    availableWidth: availableWidth,
                    isRequested: true)
            let longConversation =
                IntatisCoworkStatusRailLayoutPolicy.resolve(
                    availableWidth: availableWidth,
                    isRequested: true)

            XCTAssertEqual(emptyConversation, longConversation)
            XCTAssertTrue(emptyConversation.isVisible)
            XCTAssertEqual(emptyConversation.inspectorWidth, 348)
            XCTAssertEqual(
                emptyConversation.threadWidth
                    + emptyConversation.inspectorWidth,
                availableWidth)
        }
    }

    func testCoworkStatusRailRenderSnapshotExcludesConversationSelection() {
        let beforeSelection = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            errors: [],
            colorScheme: .light)
        let afterSelection = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            errors: [],
            colorScheme: .light)
        let changedRailState = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(tasks: [
                CoworkWorkTaskLine(
                    id: "finished",
                    title: "Finished",
                    status: "completed"),
            ]),
            errors: [],
            colorScheme: .light)
        let changedErrorState = CoworkStatusRailRenderSnapshot(
            agents: [],
            pending: nil,
            permissionNotice: nil,
            goal: nil,
            workTasks: CoworkWorkTaskSummary(),
            errors: IntatisThreadErrorPresentation.errors(
                items: [],
                errorTexts: ["Provider unavailable"]),
            colorScheme: .light)

        XCTAssertEqual(beforeSelection, afterSelection)
        XCTAssertNotEqual(beforeSelection, changedRailState)
        XCTAssertNotEqual(beforeSelection, changedErrorState)
    }

    func testWorkspaceInspectorNeverProducesInvalidGeometry() {
        for width in stride(from: CGFloat(-100), through: 2_000, by: 0.5) {
            let layout = IntatisWorkspaceInspectorLayoutPolicy.resolve(
                availableWidth: width,
                isRequested: true,
                activationWidth: 940,
                minimumThreadWidth: 620,
                minimumInspectorWidth: 260,
                idealInspectorWidth: 292,
                maximumInspectorWidth: 360)
            XCTAssertTrue(layout.threadWidth.isFinite)
            XCTAssertTrue(layout.inspectorWidth.isFinite)
            XCTAssertGreaterThan(layout.threadWidth, 0)
            XCTAssertGreaterThanOrEqual(layout.inspectorWidth, 0)
        }

        for invalidWidth in [
            CGFloat.infinity,
            -CGFloat.infinity,
            CGFloat.nan,
        ] {
            XCTAssertEqual(
                IntatisWorkspaceInspectorLayoutPolicy.resolve(
                    availableWidth: invalidWidth,
                    isRequested: true,
                    activationWidth: 940,
                    minimumThreadWidth: 620,
                    minimumInspectorWidth: 260,
                    idealInspectorWidth: 292,
                    maximumInspectorWidth: 360),
                IntatisWorkspaceInspectorLayout(
                    isVisible: false,
                    threadWidth: 1,
                    inspectorWidth: 0))
        }
    }

    func testWorkspaceThreadsDoNotVendWindowToolbarOrNestedInspectorPreferences() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for filename in ["CodeViews.swift", "CoworkViews.swift"] {
            let source = try String(
                contentsOf: packageRoot
                    .appendingPathComponent("Sources")
                    .appendingPathComponent(filename),
                encoding: .utf8)
            XCTAssertFalse(source.contains(".toolbar {"), filename)
            XCTAssertFalse(source.contains(".inspector("), filename)
            if filename == "CoworkViews.swift" {
                XCTAssertTrue(
                    source.contains(
                        "IntatisCoworkStatusRailLayoutPolicy.resolve("),
                    filename)
            } else {
                XCTAssertTrue(
                    source.contains(
                        "IntatisWorkspaceInspectorLayoutPolicy.resolve("),
                    filename)
            }
        }

        let coworkSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/CoworkViews.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            coworkSource.contains(".overlay(alignment: .trailing)"))
        XCTAssertFalse(
            coworkSource.contains("ZStack(alignment: .trailing)"))
        XCTAssertTrue(
            coworkSource.contains(
                "IntatisCoworkStatusRailLayoutPolicy.resolve("))
        XCTAssertTrue(coworkSource.contains("for: .scrollContent"))
        XCTAssertTrue(coworkSource.contains("primaryScrollerClearance"))
        XCTAssertTrue(coworkSource.contains(".allowsHitTesting(false)"))
        XCTAssertTrue(
            coworkSource.contains("CoworkStatusRailRenderBoundary("))
        XCTAssertTrue(coworkSource.contains(".equatable()"))
        XCTAssertTrue(coworkSource.contains(
            ".frame(width: rawWidth, height: rawHeight)"))
        XCTAssertTrue(coworkSource.contains(
            ".overlay(alignment: .leading)"))
        XCTAssertTrue(coworkSource.contains(
            "not the transcript's intrinsic size"))
        XCTAssertFalse(coworkSource.contains(".visualEffect { content, proxy in"))
        XCTAssertFalse(coworkSource.contains(".pixelAlignmentOffset("))
        XCTAssertTrue(coworkSource.contains(
            "selection.selectedAgentID == agentID ? 1 : 0"))
        XCTAssertTrue(coworkSource.contains("transaction.animation = nil"))
        XCTAssertTrue(coworkSource.contains(
            "transaction.disablesAnimations = true"))
        XCTAssertFalse(
            coworkSource.contains(
                "IntatisGlassEffectGroup(\n                spacing: IntatisCoworkStatusRailLayoutPolicy"))

        let surfaceSource = try String(
            contentsOf: packageRoot
                .appendingPathComponent("Sources/ThreadSurfaces.swift"),
            encoding: .utf8)
        XCTAssertTrue(surfaceSource.contains(
            "private struct IntatisClearLiquidGlassBackdrop"))
        XCTAssertTrue(surfaceSource.contains(
            "content.background {\n                IntatisClearLiquidGlassBackdrop("))
        XCTAssertTrue(surfaceSource.contains(
            "colorScheme: colorScheme)\n                    .equatable()"))

        let railSnapshotStart = try XCTUnwrap(
            coworkSource.range(
                of: "struct CoworkStatusRailRenderSnapshot: Equatable"))
        let railSnapshotEnd = try XCTUnwrap(
            coworkSource.range(
                of: "private final class CoworkStatusRailSelectionState",
                range: railSnapshotStart.upperBound..<coworkSource.endIndex))
        let railSnapshotSource = coworkSource[
            railSnapshotStart.lowerBound..<railSnapshotEnd.lowerBound]
        XCTAssertFalse(railSnapshotSource.contains("threadPage"))
        XCTAssertFalse(railSnapshotSource.contains("isThreadPageLoading"))
        XCTAssertFalse(railSnapshotSource.contains("threadSnapshot"))
        XCTAssertFalse(railSnapshotSource.contains("isThreadSnapshotLoading"))
        XCTAssertFalse(railSnapshotSource.contains("isRichRenderingEligible"))
        XCTAssertFalse(railSnapshotSource.contains("selectedAgentID"))

        let repositoryRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("Apps/TranslatisMac/Sources/TranslatisMacApp.swift"),
            encoding: .utf8)
        let codeStart = try XCTUnwrap(
            appSource.range(of: "struct CodeSessionView: View"))
        let codeEnd = try XCTUnwrap(
            appSource.range(
                of: "struct CoworkSessionView: View",
                range: codeStart.upperBound..<appSource.endIndex))
        let coworkEnd = try XCTUnwrap(
            appSource.range(
                of: "#if canImport(AppKit)",
                range: codeEnd.upperBound..<appSource.endIndex))
        let uiSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent(
                "Packages/IntatisCoworkUI/Sources/IntatisCoworkContentView.swift"),
            encoding: .utf8)
        let workspaceSessionViews = String(appSource[
            codeStart.lowerBound..<coworkEnd.lowerBound])
            + uiSource
        XCTAssertFalse(workspaceSessionViews.contains(".toolbar {"))
        XCTAssertTrue(workspaceSessionViews.contains("headerActions:"))
    }

    @MainActor
    func testProductionShapedWorkspaceChromeSurvivesRepeatedModeResizeAndInspectorChanges() {
        let model = WorkspaceChromeStressModel()
        let host = NSHostingView(
            rootView: AnyView(WorkspaceChromeStressHarness(model: model)))
        let initialFrame = NSRect(x: 0, y: 0, width: 1_180, height: 760)
        host.frame = initialFrame
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        settle(host: host, window: window, cycles: 6)

        let widths: [CGFloat] = [860, 1_119, 1_120, 1_159, 1_160, 1_420]
        for cycle in 0..<360 {
            model.mode = cycle % 3
            model.codeInspector = cycle % 4 != 0
            model.coworkInspector = cycle % 5 != 0
            model.coworkSelectedAgentID = cycle.isMultiple(of: 2)
                ? "main"
                : "worker"
            window.setContentSize(NSSize(
                width: widths[cycle % widths.count],
                height: cycle.isMultiple(of: 2) ? 720 : 800))
            settle(host: host, window: window, cycles: 1)

            XCTAssertTrue(host.frame.width.isFinite)
            XCTAssertTrue(host.frame.height.isFinite)
            XCTAssertGreaterThan(host.frame.width, 0)
            XCTAssertGreaterThan(host.frame.height, 0)
        }

        window.orderOut(nil)
        host.rootView = AnyView(EmptyView())
        settle(host: host, window: window, cycles: 4)
        window.contentView = nil
    }

    @MainActor
    private func settle(
        host: NSHostingView<AnyView>,
        window: NSWindow,
        cycles: Int
    ) {
        for _ in 0..<cycles {
            window.displayIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            _ = RunLoop.main.run(
                mode: .default,
                before: Date(timeIntervalSinceNow: 0.002))
        }
    }
}
#endif
