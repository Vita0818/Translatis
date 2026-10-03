#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

private func intatisLocalizedAgentState(_ state: String) -> String {
    switch state {
    case AgentState.idle.rawValue:
        return IntatisLocalization.string("Idle")
    case AgentState.thinking.rawValue:
        return IntatisLocalization.string("Thinking")
    case AgentState.tool.rawValue:
        return IntatisLocalization.string("Tool")
    case AgentState.blocked.rawValue:
        return IntatisLocalization.string("Blocked")
    case "active":
        return IntatisLocalization.string("Active")
    case "retrying":
        return IntatisLocalization.string("Reconnecting")
    default:
        return state
    }
}

/// Presentational Code thread (v0.2). All data + callbacks are injected, so the
/// kernel-driving view model lives in the app, not here (keeps SharedUI free of
/// Tools/Permission/AgentKernel dependencies).
public struct CodeShell: View {
    private let displayedItems: [CodeItem]
    private let threadErrors: [IntatisThreadErrorEntry]
    private let presentationScope: IntatisThreadPresentationScope
    private let sessionTitle: String
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let isWorking: Bool
    private let workspaceName: String
    private let agentState: String
    private let threadStyle: IntatisThreadStyle
    private let onShowSessions: (() -> Void)?
    private let onNewSession: (() -> Void)?
    private let composerAccessory: AnyView?
    private let composerTrailingAction:
        IntatisThreadComposerSecondaryAction?
    private let headerActions: [IntatisThreadHeaderAction]
    @Binding private var input: String
    private let onSend: () -> Void
    private let onCancelCurrent: (() -> Void)?
    private let onResolve: (PermissionResponseAction) -> Void
    private let onRetrySubmission: ((SubmissionID) -> Void)?
    private let pendingUserInput: IntatisUserInputPresentation?
    private let onSubmitUserInput:
        ((IntatisUserInputSubmission) -> Void)?
    @Binding private var showsInspector: Bool
    @StateObject private var scrollCoordinator = IntatisThreadScrollCoordinator()
    @Environment(\.intatisWindowContentWidth) private var windowContentWidth

    public init(items: [CodeItem],
                presentationScope: IntatisThreadPresentationScope,
                sessionTitle: String = IntatisLocalization.string("Code"),
                thinkingScopeID: String = "code",
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                isWorking: Bool,
                workspaceName: String,
                agentState: String,
                errorTexts: [String] = [],
                threadStyle: IntatisThreadStyle = .standard(.light),
                splitLayout: IntatisSplitColumnLayout = .workspace,
                onShowSessions: (() -> Void)? = nil,
                onNewSession: (() -> Void)? = nil,
                composerAccessory: AnyView? = nil,
                composerTrailingAction:
                    IntatisThreadComposerSecondaryAction? = nil,
                headerActions: [IntatisThreadHeaderAction] = [],
                showsInspector: Binding<Bool>,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onCancelCurrent: (() -> Void)? = nil,
                onRetrySubmission: ((SubmissionID) -> Void)? = nil,
                onResolve: @escaping (PermissionResponseAction) -> Void,
                pendingUserInput: IntatisUserInputPresentation? = nil,
                onSubmitUserInput:
                    ((IntatisUserInputSubmission) -> Void)? = nil) {
        self.displayedItems = IntatisThreadErrorPresentation.transcriptItems(
            IntatisExecutionTracePresentation.displayedItems(items))
        self.threadErrors = IntatisThreadErrorPresentation.errors(
            items: items,
            errorTexts: errorTexts)
        self.presentationScope = presentationScope
        self.sessionTitle = sessionTitle
        _ = thinkingScopeID
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.isWorking = isWorking
        self.workspaceName = workspaceName
        self.agentState = agentState
        self.threadStyle = threadStyle
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.composerAccessory = composerAccessory
        self.composerTrailingAction = composerTrailingAction
        self.headerActions = headerActions
        self._showsInspector = showsInspector
        self._input = input
        self.onSend = onSend
        self.onCancelCurrent = onCancelCurrent
        self.onRetrySubmission = onRetrySubmission
        self.onResolve = onResolve
        self.pendingUserInput = pendingUserInput
        self.onSubmitUserInput = onSubmitUserInput
        _ = splitLayout
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
    }

    public var body: some View {
        GeometryReader { proxy in
            content(rawWidth: proxy.size.width)
        }
    }

    private func content(rawWidth: CGFloat) -> some View {
        let inspectorLayout = IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: rawWidth,
            isRequested: showsInspector,
            activationWidth: 940,
            minimumThreadWidth: 620,
            minimumInspectorWidth: 260,
            idealInspectorWidth: 292,
            maximumInspectorWidth: 360)

        return HStack(spacing: 0) {
            threadColumn(
                layout: IntatisThreadContentLayout(
                    rawWidth: inspectorLayout.threadWidth),
                inspectorIsAvailable: rawWidth >= 940,
                jumpHorizontalOffset:
                    IntatisWindowCenteredOverlayLayoutPolicy.horizontalOffset(
                        windowWidth: windowContentWidth,
                        detailWidth: rawWidth,
                        overlaySurfaceWidth: inspectorLayout.threadWidth))
                .frame(width: inspectorLayout.threadWidth)
                .frame(maxHeight: .infinity)
            if inspectorLayout.isVisible {
                Divider()
                CodeInspectorView(
                    workspaceName: workspaceName,
                    agentState: agentState,
                    itemCount: displayedItems.count,
                    pending: pending,
                    errors: threadErrors,
                    onRetrySubmission: onRetrySubmission,
                    style: threadStyle)
                    .frame(width: inspectorLayout.inspectorWidth)
                    .frame(maxHeight: .infinity)
                    .background(.bar)
                    .accessibilityIdentifier("code.inspector")
            }
        }
    }

    private func threadColumn(
        layout: IntatisThreadContentLayout,
        inspectorIsAvailable: Bool,
        jumpHorizontalOffset: CGFloat
    ) -> some View {
        VStack(spacing: 0) {
            header(
                layout: layout,
                inspectorIsAvailable: inspectorIsAvailable)
            thread(
                layout: layout,
                jumpHorizontalOffset: jumpHorizontalOffset)
            permissionArea(layout: layout)
            userInputArea(layout: layout)
            composerArea(layout: layout)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(
        layout: IntatisThreadContentLayout,
        inspectorIsAvailable: Bool
    ) -> some View {
        IntatisWorkspaceThreadHeader(
            title: sessionTitle,
            subtitle: nil,
            style: threadStyle,
            actions: headerActions + [inspectorAction(
                isAvailable: inspectorIsAvailable)])
        .frame(maxWidth: layout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func inspectorAction(
        isAvailable: Bool
    ) -> IntatisThreadHeaderAction {
        let title = showsInspector && isAvailable
            ? IntatisLocalization.string("Hide Inspector")
            : IntatisLocalization.string("Show Inspector")
        return IntatisThreadHeaderAction(
            title: title,
            systemImage: "sidebar.right",
            isDisabled: !isAvailable,
            isIconOnly: true,
            help: title,
            accessibilityIdentifier: "code.inspector.toggle") {
                guard isAvailable else { return }
                showsInspector.toggle()
            }
    }

    @ViewBuilder private func thread(
        layout: IntatisThreadContentLayout,
        jumpHorizontalOffset: CGFloat
    ) -> some View {
        if displayedItems.isEmpty {
            CodeEmptyThreadView(style: threadStyle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, layout.horizontalPadding)
        } else {
            let threadScope = presentationScope
            let baseAdmission = scrollCoordinator.effectiveViewportAdmission(
                for: threadScope,
                defersUntilInitialRestore: defersRichUntilInitialRestore)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        IntatisContinuousThreadStack(
                            items: displayedItems,
                            scope: threadScope,
                            baseAdmission: baseAdmission,
                            alignment: .leading,
                            spacing: 12,
                            rowID: { $0.id }
                        ) { item in
                            CodeItemRow(item: item, style: threadStyle, layout: layout)
                                .id(item.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 16)
                            .id(IntatisThreadBottomAnchorID(scope: threadScope))
                            .onScrollVisibilityChange(threshold: 0.99) {
                                isVisible in
                                scrollCoordinator
                                    .enqueueBottomAnchorVisibility(
                                        isVisible,
                                        scope: threadScope)
                            }
                    }
                    .environment(
                        \.intatisThreadScrollCoordinator,
                        scrollCoordinator)
                    .environment(
                        \.intatisThreadRichSettleSource,
                        scrollCoordinator.effectiveRichSettleSource(
                            for: threadScope))
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 16)
                }
                .scrollContentBackground(.hidden)
                .overlay(alignment: .bottom) {
                    if scrollCoordinator.followState == .detachedByUser {
                        IntatisJumpToLatestButton(
                            accessibilityIdentifier: "code.jump-to-latest"
                        ) {
                            scrollCoordinator.jumpToLatest(
                                scope: threadScope,
                                perform: scrollPerformer(proxy))
                        }
                        .offset(x: jumpHorizontalOffset)
                    }
                }
                .onAppear {
                    scrollCoordinator.activate(
                        scope: threadScope,
                        defersRichUntilInitialRestore:
                            defersRichUntilInitialRestore)
                    requestScroll(
                        proxy,
                        reason: .initialRestore,
                        scope: threadScope)
                }
                .onChange(of: itemScrollSignature) { _, _ in
                    requestScroll(
                        proxy,
                        reason: scrollReason,
                        scope: threadScope)
                }
                .onChange(of: layout.contentWidth) { _, _ in
                    scrollCoordinator.openWidthSettleEpoch(
                        scope: threadScope,
                        width: layout.contentWidth,
                        perform: scrollPerformer(proxy))
                }
                .onScrollGeometryChange(
                    for: IntatisThreadScrollGeometry.self
                ) { geometry in
                    IntatisThreadScrollGeometry.measure(
                        contentOffsetY: geometry.contentOffset.y,
                        containerHeight: geometry.containerSize.height,
                        bottomInset: geometry.contentInsets.bottom,
                        contentHeight: geometry.contentSize.height)
                } action: { _, current in
                    scrollCoordinator.enqueueGeometryObservation(
                        current.isAtBottom,
                        contentHeight: current.contentHeight,
                        scope: threadScope)
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting, .decelerating:
                        scrollCoordinator.userInteractionDidBegin(
                            scope: threadScope)
                    case .idle:
                        scrollCoordinator.userInteractionDidEnd(
                            scope: threadScope)
                    case .animating:
                        break
                    }
                }
                .onDisappear {
                    scrollCoordinator.deactivate(scope: threadScope)
                }
            }
        }
    }

    private var defersRichUntilInitialRestore: Bool {
        IntatisThreadRichEntryPolicy.defersUntilInitialRestore(
            richRowCount: displayedItems.count)
    }

    private var itemScrollSignature: IntatisThreadScrollSignature {
        let last = displayedItems.last
        return IntatisThreadScrollSignature(
            visibleItemCount: displayedItems.count,
            lastItemID: last?.id,
            lastBodyUTF8Count: last?.body.utf8.count ?? 0,
            lastItemComplete: last?.complete ?? false,
            lastTurnStatsID: last?.responsesUsage?.id
                ?? last?.turnStats?.id,
            isWorking: isWorking,
            showsThinkingIndicator: false)
    }

    private var scrollReason: IntatisThreadScrollReason {
        guard let last = displayedItems.last else {
            return .liveUpdate
        }
        return last.complete && !isWorking
            ? .completion
            : .liveUpdate
    }

    private func requestScroll(
        _ proxy: ScrollViewProxy,
        reason: IntatisThreadScrollReason,
        scope: IntatisThreadPresentationScope
    ) {
        scrollCoordinator.request(
            scope: scope,
            reason: reason,
            perform: scrollPerformer(proxy))
    }

    private func scrollPerformer(
        _ proxy: ScrollViewProxy
    ) -> @MainActor (IntatisThreadScrollRequest) -> Void {
        { request in
            let anchorID = IntatisThreadBottomAnchorID(scope: request.scope)
            proxy.scrollTo(anchorID, anchor: .bottom)
        }
    }

    @ViewBuilder private func permissionArea(layout: IntatisThreadContentLayout) -> some View {
        if let pending {
            PermissionCard(permission: pending, onResolve: onResolve)
                .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
        } else if let permissionNotice {
            PermissionResolutionNoticeView(notice: permissionNotice)
                .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
        }
    }

    @ViewBuilder private func userInputArea(
        layout: IntatisThreadContentLayout
    ) -> some View {
        if let pendingUserInput {
            IntatisUserInputView(
                presentation: pendingUserInput,
                onSubmit: onSubmitUserInput)
                .id(pendingUserInput.id)
                .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 8)
        }
    }

    private func composerArea(layout: IntatisThreadContentLayout) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IntatisThreadComposer(
                placeholder: IntatisLocalization.string("Message Coder..."),
                input: $input,
                canSend: !isWorking
                    && !permissionBlocksComposer
                    && composerTrailingAction?.blocksSubmission != true
                    && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                isInputDisabled: isWorking || permissionBlocksComposer,
                style: threadStyle,
                leadingAccessory: composerAccessory,
                trailingAction: composerTrailingAction,
                stopAction: isWorking
                    ? onCancelCurrent.map { onCancelCurrent in
                        IntatisThreadComposerSecondaryAction(
                            systemImage: "stop.fill",
                            help: IntatisLocalization.string("Stop"),
                            action: onCancelCurrent)
                    }
                    : nil,
                accessory: { EmptyView() },
                onSend: onSend)
        }
        .frame(maxWidth: layout.contentMaxWidth)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }
}

struct CodeItemRow: View {
    let item: CodeItem
    let style: IntatisThreadStyle
    let layout: IntatisThreadContentLayout

    init(item: CodeItem,
         style: IntatisThreadStyle = .standard(.light),
         layout: IntatisThreadContentLayout = IntatisThreadContentLayout(rawWidth: 900)) {
        self.item = item
        self.style = style
        self.layout = layout
    }

    var body: some View {
        switch item.kind {
        case .user:
            bubble(
                title: nil,
                body: item.body,
                isUser: true,
                tags: item.tags)
        case .agent:
            if item.messagePhase == .commentary {
                intermediateText(item.body)
            } else {
                bubble(
                    title: item.title,
                    body: item.body.isEmpty && !item.complete ? "…" : item.body,
                    isUser: false)
            }
        case .runtimeEvent:
            runtimeEvent()
        case .toolCall:
            if item.isFailure || item.recoveryAdvice != nil {
                EmptyView()
            } else {
                card(
                    icon: "wrench.and.screwdriver",
                    title: IntatisLocalization.format("tool · %@", item.title),
                    body: item.body,
                    tint: .blue)
            }
        case .toolResult:
            if item.isFailure || item.recoveryAdvice != nil {
                EmptyView()
            } else {
                card(
                    icon: "arrow.turn.down.right",
                    title: item.title,
                    body: item.body,
                    tint: .gray)
            }
        case .patch:
            if item.isFailure || item.recoveryAdvice != nil {
                EmptyView()
            } else {
                card(
                    icon: "doc.badge.gearshape",
                    title: IntatisLocalization.format(
                        "patch · %@",
                        item.files.joined(separator: ", ")),
                    body: item.body,
                    tint: .purple)
            }
        case .note:
            if item.isFailure || item.recoveryAdvice != nil {
                EmptyView()
            } else {
                Text(item.body).font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
            }
        case .error:
            EmptyView()
        case .agentToAgent:
            bubble(
                title: item.title,
                body: item.body.isEmpty && !item.complete ? "…" : item.body,
                isUser: false)
        }
    }

    private func intermediateText(_ text: String) -> some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            fillsAvailableWidth: true,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            Text(text)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 3)
        }
    }

    @ViewBuilder private func runtimeEvent() -> some View {
        if let activity = item.codexActivity {
            semanticActivity(activity)
        } else {
            rawRuntimeEvent()
        }
    }

    private func semanticActivity(
        _ activity: CodexActivityPresentation
    ) -> some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            fillsAvailableWidth: true,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: activitySystemImage(activity))
                        .font(IntatisTypography.system(
                            .caption,
                            weight: .medium))
                        .foregroundStyle(activityIconColor(activity))
                        .accessibilityHidden(true)
                    Text(activityTitle(activity.category))
                        .font(IntatisTypography.system(
                            .caption,
                            weight: .medium))
                        .foregroundStyle(style.secondaryText)
                    if activity.category != .turn,
                       activity.category != .retry,
                       let state = activity.state {
                        Text("·")
                            .foregroundStyle(style.tertiaryText)
                        Text(activityStateTitle(state))
                            .font(IntatisTypography.system(.caption2))
                            .foregroundStyle(
                                state == .failed
                                    ? Color.red
                                    : style.tertiaryText)
                    }
                }
                if activity.category == .retry,
                   let attempt = activity.retryAttempt,
                   let limit = activity.retryLimit {
                    Text(IntatisLocalization.format(
                        "Retrying request %lld of %lld",
                        Int64(attempt),
                        Int64(limit)))
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(style.secondaryText)
                }
                if !activity.text.isEmpty {
                    Text(activity.text)
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(style.secondaryText)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
            .help(activityTechnicalSummary(activity))
            .accessibilityElement(children: .combine)
        }
    }

    private func rawRuntimeEvent() -> some View {
        IntatisThreadBubbleRow(
            isTrailing: false,
            fillsAvailableWidth: true,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(IntatisTypography.system(.caption2))
                    .foregroundStyle(style.tertiaryText)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(style.secondaryText)
                }
            }
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 3)
        }
    }

    private func activityTitle(
        _ category: CodexActivityPresentation.Category
    ) -> String {
        switch category {
        case .turn:
            return IntatisLocalization.string("Working")
        case .command:
            return IntatisLocalization.string("Command")
        case .fileChanges:
            return IntatisLocalization.string("File changes")
        case .tool:
            return IntatisLocalization.string("Tool")
        case .mcpTool:
            return IntatisLocalization.string("MCP tool")
        case .webSearch:
            return IntatisLocalization.string("Web search")
        case .image:
            return IntatisLocalization.string("Image")
        case .collaboration:
            return IntatisLocalization.string("Collaboration")
        case .subagent:
            return IntatisLocalization.string("Subagent")
        case .plan:
            return IntatisLocalization.string("Plan")
        case .reasoning:
            return IntatisLocalization.string("Reasoning")
        case .retry:
            return IntatisLocalization.string("Reconnecting")
        case .approvalReview:
            return IntatisLocalization.string("Approval review")
        case .compaction:
            return IntatisLocalization.string("Context compaction")
        case .review:
            return IntatisLocalization.string("Review")
        case .waiting:
            return IntatisLocalization.string("Waiting")
        case .runtime:
            return IntatisLocalization.string("Runtime activity")
        }
    }

    private func activityStateTitle(
        _ state: CodexActivityPresentation.State
    ) -> String {
        switch state {
        case .running:
            return IntatisLocalization.string("Running")
        case .completed:
            return IntatisLocalization.string("Completed")
        case .failed:
            return IntatisLocalization.string("Failed")
        case .cancelled:
            return IntatisLocalization.string("Cancelled")
        }
    }

    private func activitySystemImage(
        _ activity: CodexActivityPresentation
    ) -> String {
        if let state = activity.state {
            switch state {
            case .failed:
                return "xmark.circle"
            case .cancelled:
                return "stop.circle"
            case .completed:
                return "checkmark.circle"
            case .running:
                break
            }
        }
        switch activity.category {
        case .turn:
            return "ellipsis.circle"
        case .command:
            return "terminal"
        case .fileChanges:
            return "doc.badge.gearshape"
        case .tool:
            return "wrench.and.screwdriver"
        case .mcpTool:
            return "network"
        case .webSearch:
            return "globe"
        case .image:
            return "photo"
        case .collaboration:
            return "person.2"
        case .subagent:
            return "person.crop.circle.badge.plus"
        case .plan:
            return "list.bullet"
        case .reasoning:
            return "brain"
        case .retry:
            return "arrow.triangle.2.circlepath"
        case .approvalReview:
            return "checkmark.shield"
        case .compaction:
            return "arrow.triangle.2.circlepath"
        case .review:
            return "checklist"
        case .waiting:
            return "clock"
        case .runtime:
            return "gearshape.2"
        }
    }

    private func activityIconColor(
        _ activity: CodexActivityPresentation
    ) -> Color {
        switch activity.state {
        case .some(.failed):
            return .red
        case .some(.cancelled):
            return .orange
        case .some(.completed), .some(.running), .none:
            return style.tertiaryText
        }
    }

    private func activityTechnicalSummary(
        _ activity: CodexActivityPresentation
    ) -> String {
        var details = activity.rawMethods
        if let itemType = activity.itemType {
            details.append("type: \(itemType)")
        }
        if let status = activity.rawStatus {
            details.append("status: \(status)")
        }
        return details.joined(separator: "\n")
    }

    private func bubble(title: String?, body: String, isUser: Bool, tags: [String] = []) -> some View {
        IntatisThreadBubbleRow(
            isTrailing: isUser,
            fillsAvailableWidth: !isUser,
            rowWidth: layout.contentWidth,
            maxWidth: layout.messageMaxWidth,
            gutter: layout.messageGutter) {
                bubbleContent(title: title, body: body, isUser: isUser, tags: tags)
            }
    }

    @ViewBuilder private func bubbleContent(title: String?,
                                            body: String,
                                            isUser: Bool,
                                            tags: [String]) -> some View {
        if isUser {
            bubbleBody(title: title, body: body, isUser: isUser, tags: tags)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .intatisLiquidGlass(cornerRadius: 20)
        } else {
            bubbleBody(title: title, body: body, isUser: false, tags: tags)
                .padding(.vertical, 8)
        }
    }

    private func bubbleBody(title: String?,
                            body: String,
                            isUser: Bool,
                            tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if title != nil || !tags.isEmpty {
                HStack(spacing: 6) {
                    if let title {
                        Text(displayTitle(title))
                            .font(IntatisTypography.system(.caption2, bold: true))
                            .foregroundStyle(
                                isUser ? style.accent : style.tertiaryText)
                    }
                    if !isUser, let timestamp = item.timestamp {
                        Text(IntatisMessageTimestampPresentation.string(for: timestamp))
                            .font(IntatisTypography.system(.caption2))
                            .monospacedDigit()
                            .foregroundStyle(style.tertiaryText)
                    }
                    ForEach(tags, id: \.self) { tag in
                        tagBadge(tag)
                    }
                }
            }
            if isUser {
                if !body.isEmpty {
                    Text(body)
                        .font(IntatisTypography.system(size: 15))
                        .foregroundStyle(style.primaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !item.attachments.isEmpty {
                    Label(
                        item.attachments.count == 1
                            ? IntatisLocalization.format(
                                "%lld attachment",
                                Int64(item.attachments.count))
                            : IntatisLocalization.format(
                                "%lld attachments",
                                Int64(item.attachments.count)),
                        systemImage: "paperclip")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(style.secondaryText)
                }
            } else {
                IntatisMessageContentView(
                    messageID: item.id,
                    rawText: item.body,
                    isComplete: item.complete,
                    policy: .richText,
                    style: style)
                #if os(macOS)
                if item.complete {
                    IntatisMessageFooter(
                        messageID: item.id,
                        rawText: item.body,
                        stats: item.turnStats,
                        responsesUsage: item.responsesUsage,
                        style: style)
                }
                #endif
            }
        }
    }

    private func displayTitle(_ title: String) -> String {
        title == "Agent" ? IntatisHostApplication.identity.name : title
    }

    private func card(icon: String, title: String, body: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(IntatisTypography.system(.caption, bold: true)).foregroundStyle(tint)
            Text(body).font(IntatisTypography.system(.caption, design: .monospaced))
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(11)
        .intatisContentSurface(cornerRadius: 8)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tint.opacity(0.25)))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .frame(maxWidth: min(layout.contentMaxWidth, 740), alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tagBadge(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(IntatisTypography.system(.caption2, bold: true))
            .foregroundStyle(style.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().stroke(style.stroke, lineWidth: 1) }
    }
}

private struct CodeEmptyThreadView: View {
    let style: IntatisThreadStyle

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(IntatisTypography.system(size: 30, weight: .semibold))
                .foregroundStyle(style.accent)
                .frame(width: 76, height: 76)
            Spacer()
        }
        .multilineTextAlignment(.center)
    }
}

private struct PermissionReviewSurfaceModifier: ViewModifier {
    let isEnabled: Bool
    let cornerRadius: CGFloat

    @ViewBuilder func body(content: Content) -> some View {
        if isEnabled {
            content.intatisSubtleContentSurface(cornerRadius: cornerRadius)
        } else {
            content
        }
    }
}

public enum PermissionReviewCardStyle: Equatable, Sendable {
    case standard
    case compactRail
}

public struct PermissionResolutionNoticeView: View {
    let notice: PermissionResolutionNotice
    private let embedsSurface: Bool
    private let presentationStyle: PermissionReviewCardStyle

    public init(notice: PermissionResolutionNotice,
                embedsSurface: Bool = true,
                presentationStyle: PermissionReviewCardStyle = .standard) {
        self.notice = notice
        self.embedsSurface = embedsSurface
        self.presentationStyle = presentationStyle
    }

    @ViewBuilder public var body: some View {
        Group {
            switch presentationStyle {
            case .standard:
                standardContent
            case .compactRail:
                compactRailContent
            }
        }
        .modifier(PermissionReviewSurfaceModifier(
            isEnabled: embedsSurface,
            cornerRadius: presentationStyle == .compactRail ? 14 : 10))
        .accessibilityIdentifier("permission.resolution")
    }

    private var standardContent: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusIcon)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(statusColor)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(IntatisTypography.system(.caption, weight: .medium))
                Text(notice.reason)
                    .font(IntatisTypography.system(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: 620, alignment: .leading)
    }

    private var compactRailContent: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusIcon)
                .font(IntatisTypography.system(.body, weight: .semibold))
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(title)
                .font(IntatisTypography.system(.body, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(notice.reason)
        .accessibilityHint(notice.reason)
    }

    private var statusIcon: String {
        notice.decision == .allow
            ? "checkmark.circle.fill"
            : "xmark.circle.fill"
    }

    private var statusColor: Color {
        notice.decision == .allow ? .green : .orange
    }

    private var title: String {
        if notice.decision == .allow {
            return IntatisLocalization.format("%@ approved", notice.tool)
        }
        if notice.action == .cancelTurn {
            return IntatisLocalization.string("Turn cancelled")
        }
        switch notice.failureSource {
        case .userDenied:
            return IntatisLocalization.format("%@ call declined", notice.tool)
        case .userCancelled, .turnCancelled:
            return IntatisLocalization.string("Turn cancelled")
        case .policyDenied:
            return IntatisLocalization.format("%@ call denied by policy", notice.tool)
        case .reviewerTimedOut:
            return IntatisLocalization.string("Automatic review timed out")
        case .reviewerFailed:
            return IntatisLocalization.string("Automatic review failed")
        case .sandboxDenied:
            return IntatisLocalization.format("Sandbox denied %@", notice.tool)
        case .runtimeFailed:
            return IntatisLocalization.format("%@ runtime failed", notice.tool)
        case nil:
            return IntatisLocalization.format("%@ denied", notice.tool)
        }
    }
}

struct PermissionReviewDetail: Equatable, Identifiable {
    let id: String
    let systemImage: String
    let text: String
}

enum PermissionReviewPresentation {
    /// Builds a small, secret-safe review summary from the structured
    /// authorization snapshot. Raw JSON arguments are deliberately excluded.
    static func details(
        for request: PermissionRequestPayload
    ) -> [PermissionReviewDetail] {
        if let preview = request.context?.authorization?.actionPreview {
            let previewDetails: [PermissionReviewDetail] = preview.fields.keys
                .sorted()
                .compactMap { key -> PermissionReviewDetail? in
                guard let value = preview.fields[key], !value.isEmpty else {
                    return nil
                }
                return PermissionReviewDetail(
                    id: "preview.\(key)",
                    systemImage: "info.circle",
                    text: "\(humanized(key)): \(value)")
            }
            if !previewDetails.isEmpty {
                return previewDetails
            }
        }

        let intent = request.context?.intent
            ?? request.context?.authorization?.intent
        var details: [PermissionReviewDetail] = []
        if let action = intent?.action, !action.isEmpty {
            details.append(PermissionReviewDetail(
                id: "action",
                systemImage: "bolt",
                text: action))
        }

        let resources = intent?.resources.map(\.value).filter { !$0.isEmpty }
            ?? []
        if !resources.isEmpty {
            details.append(PermissionReviewDetail(
                id: "resources",
                systemImage: "scope",
                text: resources.joined(separator: ", ")))
        } else if let paths = request.context?.touchedPaths,
                  !paths.isEmpty {
            details.append(PermissionReviewDetail(
                id: "paths",
                systemImage: "folder",
                text: paths.joined(separator: ", ")))
        }
        return details
    }

    static func compactSummary(
        for request: PermissionRequestPayload
    ) -> String {
        let reason = request.reason.trimmingCharacters(
            in: .whitespacesAndNewlines)
        if !reason.isEmpty {
            return reason
        }
        return details(for: request).first?.text ?? request.tool
    }

    private static func humanized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }
}

public struct PermissionCard: View {
    let permission: PendingPermission
    let onResolve: (PermissionResponseAction) -> Void
    private let embedsSurface: Bool
    private let presentationStyle: PermissionReviewCardStyle
    @State private var showsDetails = false

    public init(permission: PendingPermission,
                embedsSurface: Bool = true,
                presentationStyle: PermissionReviewCardStyle = .standard,
                onResolve: @escaping (PermissionResponseAction) -> Void) {
        self.permission = permission
        self.embedsSurface = embedsSurface
        self.presentationStyle = presentationStyle
        self.onResolve = onResolve
    }

    private var request: PermissionRequestPayload { permission.request }
    private var reviewDetails: [PermissionReviewDetail] {
        PermissionReviewPresentation.details(for: request)
    }
    private var proposedDiff: String? { Self.diff(from: request.args) }
    private var hasDetails: Bool {
        !reviewDetails.isEmpty || proposedDiff != nil
    }

    @ViewBuilder public var body: some View {
        Group {
            switch presentationStyle {
            case .standard:
                standardContent
            case .compactRail:
                compactRailContent
            }
        }
        .modifier(PermissionReviewSurfaceModifier(
            isEnabled: embedsSurface,
            cornerRadius: presentationStyle == .compactRail ? 18 : 14))
        .onChange(of: request.requestId) { _, _ in
            showsDetails = false
        }
    }

    private var standardContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(IntatisTypography.system(.callout, weight: .medium))
                    .foregroundStyle(riskColor)
                    .frame(width: 18)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(IntatisLocalization.string("Permission needed"))
                            .font(IntatisTypography.system(.callout, weight: .semibold))
                        Text(riskLabel)
                            .font(IntatisTypography.system(.caption2, weight: .semibold))
                            .foregroundStyle(riskColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(riskColor.opacity(0.10), in: Capsule())
                    }
                    Text(request.tool)
                        .font(IntatisTypography.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(request.reason)
                        .font(IntatisTypography.system(.callout))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if hasDetails {
                DisclosureGroup(
                    isExpanded: $showsDetails,
                    content: {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(reviewDetails) { detail in
                                Label {
                                    Text(detail.text)
                                        .font(IntatisTypography.system(.caption))
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                } icon: {
                                    Image(systemName: detail.systemImage)
                                        .font(IntatisTypography.system(.caption2))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            if let proposedDiff {
                                ScrollView {
                                    Text(proposedDiff)
                                        .font(IntatisTypography.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(
                                            maxWidth: .infinity,
                                            alignment: .leading)
                                }
                                .frame(maxHeight: 150)
                                .padding(8)
                                .intatisSubtleContentSurface(cornerRadius: 7)
                            }
                        }
                        .padding(.top, 6)
                        .padding(.leading, 4)
                    },
                    label: {
                        Text(IntatisLocalization.string("Details"))
                            .font(IntatisTypography.system(.caption, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                )
                .tint(.secondary)
                .accessibilityIdentifier("permission.details")
            }

            permissionFooter
        }
        .padding(13)
        .frame(maxWidth: 720, alignment: .leading)
    }

    private var compactRailContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(IntatisTypography.system(.body, weight: .semibold))
                    .foregroundStyle(riskColor)
                    .frame(width: 20)
                    .padding(.top, 1)
                    .accessibilityLabel(
                        IntatisLocalization.format("%@ risk", riskLabel))
                VStack(alignment: .leading, spacing: 3) {
                    Text(IntatisLocalization.string("Permission Review"))
                        .font(IntatisTypography.system(.body, weight: .semibold))
                    Text(request.tool)
                        .font(IntatisTypography.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(PermissionReviewPresentation.compactSummary(
                        for: request))
                        .font(IntatisTypography.system(.callout))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            compactRailFooter
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var compactRailFooter: some View {
        if permission.state.isActionable {
            ViewThatFits(in: .horizontal) {
                horizontalPermissionActions
                compactPermissionActions
            }
            .controlSize(.small)
        } else {
            permissionStatus
        }
    }

    private var permissionFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                permissionStatus
                Spacer(minLength: 8)
                if permission.state.isActionable {
                    horizontalPermissionActions
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                permissionStatus
                if permission.state.isActionable {
                    compactPermissionActions
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder private var permissionStatus: some View {
        if permission.state == .resolving {
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text(request.effectiveApprovalMode == .automaticReviewer
                     ? IntatisLocalization.string("Automatic review in progress…")
                     : IntatisLocalization.string("Resolving…"))
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(statusText)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        }
    }

    private var horizontalPermissionActions: some View {
        HStack(spacing: 8) {
            cancelTurnButton
            declineCallButton
            approveCallButton
            if permitsRememberedApproval {
                rememberApprovalButton
            }
        }
    }

    private var compactPermissionActions: some View {
        VStack(alignment: .trailing, spacing: 7) {
            approveCallButton
                .frame(maxWidth: .infinity, alignment: .trailing)
            if permitsRememberedApproval {
                rememberApprovalButton
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            HStack(spacing: 8) {
                cancelTurnButton
                Spacer(minLength: 8)
                declineCallButton
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var cancelTurnButton: some View {
        Button("Cancel Turn") { onResolve(.cancelTurn) }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("permission.cancel-turn")
    }

    private var declineCallButton: some View {
        Button("Decline Call") { onResolve(.decline) }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("permission.decline-call")
    }

    private var approveCallButton: some View {
        Button(
            request.context?.authorization?.mcp == nil
                ? "Approve Call"
                : "Allow Call Once"
        ) {
            onResolve(.approve)
        }
        .intatisGlassButton(prominent: true)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("permission.approve-call")
    }

    private var rememberApprovalButton: some View {
        Button("Remember Exact Tool Approval") {
            onResolve(.approveAndRemember)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("permission.approve-and-remember")
    }

    private var permitsRememberedApproval: Bool {
        request.context?.authorization?.permitsMCPRememberedApproval == true
    }

    private var riskColor: Color {
        switch request.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private var riskLabel: String {
        switch request.risk {
        case .low: return IntatisLocalization.string("LOW")
        case .medium: return IntatisLocalization.string("MEDIUM")
        case .high: return IntatisLocalization.string("HIGH")
        }
    }

    private var statusText: String {
        switch permission.state {
        case .livePending:
            return IntatisLocalization.string("Waiting for your decision.")
        case .resolving:
            return request.effectiveApprovalMode == .automaticReviewer
                ? IntatisLocalization.string(
                    "The reserved permission reviewer is evaluating this call.")
                : IntatisLocalization.string("Applying your decision.")
        case .approved:
            return IntatisLocalization.string("Approved.")
        case .rejected:
            return IntatisLocalization.string("Rejected.")
        case .expired:
            return IntatisLocalization.string(
                "This approval channel expired. Rerun the task to continue.")
        case .needsRerun:
            return IntatisLocalization.string(
                "This request was restored from history. Rerun the task to continue.")
        }
    }

    public static func diff(from args: String) -> String? {
        struct A: Decodable { let diff: String? }
        return (try? JSONDecoder().decode(A.self, from: Data(args.utf8)))?.diff
    }
}

private struct CodeInspectorView: View {
    let workspaceName: String
    let agentState: String
    let itemCount: Int
    let pending: PendingPermission?
    let errors: [IntatisThreadErrorEntry]
    let onRetrySubmission: ((SubmissionID) -> Void)?
    let style: IntatisThreadStyle

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                inspectorHeader
                inspectorSection(IntatisLocalization.string("Plan")) {
                    inspectorRow(
                        IntatisLocalization.string("Activity"),
                        value: intatisLocalizedAgentState(agentState))
                    inspectorRow(IntatisLocalization.string("Thread events"), value: "\(itemCount)")
                    if let pending {
                        inspectorRow(
                            IntatisLocalization.string("Permission"),
                            value: pending.request.tool)
                    } else {
                        inspectorRow(
                            IntatisLocalization.string("Permission"),
                            value: IntatisLocalization.string("none pending"))
                    }
                }
                inspectorSection(IntatisLocalization.string("Workspace")) {
                    inspectorRow(IntatisLocalization.string("Root"), value: workspaceName)
                    inspectorRow(
                        IntatisLocalization.string("Git"),
                        value: IntatisLocalization.string("status only"))
                    Text("Commit, branch, PR, CI, and review workflows are deferred.")
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(style.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !errors.isEmpty {
                    inspectorSection(IntatisLocalization.string("Error Information")) {
                        IntatisThreadErrorList(
                            errors: errors,
                            style: style,
                            onRetrySubmission: onRetrySubmission)
                    }
                    .accessibilityIdentifier("code.error.card")
                }
            }
            .padding(16)
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inspector")
                .font(IntatisTypography.system(size: 16, weight: .semibold))
                .foregroundStyle(style.primaryText)
            Text("Task and workspace status")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
        }
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(IntatisTypography.system(.caption2, bold: true))
                .foregroundStyle(style.tertiaryText)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .intatisContentSurface(cornerRadius: 8)
    }

    private func inspectorRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(style.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}
#endif
