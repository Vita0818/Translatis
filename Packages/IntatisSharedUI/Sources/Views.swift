#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

/// Shared chat shell. The caller chooses split or single-thread presentation via
/// `ThreeColumnShellLayout`, so macOS/iPad-style panes and compact iOS chat use
/// the same thread/composer implementation with different parameters. A
/// thread-only caller owns the surrounding navigation container so its native
/// toolbar and sheets participate in the same navigation stack.
public struct ThreeColumnShell: View {
    @ObservedObject private var model: ChatViewModel
    private let layout: ThreeColumnShellLayout
    private let composerLeadingAccessory: AnyView?
    private let placesTurnStatsInComposer: Bool
    private let presentationScope: IntatisThreadPresentationScope?

    public init(model: ChatViewModel,
                layout: ThreeColumnShellLayout = .split,
                composerLeadingAccessory: AnyView? = nil,
                placesTurnStatsInComposer: Bool = false,
                presentationScope: IntatisThreadPresentationScope? = nil) {
        self.model = model
        self.layout = layout
        self.composerLeadingAccessory = composerLeadingAccessory
        self.placesTurnStatsInComposer = placesTurnStatsInComposer
        self.presentationScope = presentationScope
    }

    public var body: some View {
        Group {
            switch layout.presentation {
            case .split:
                NavigationSplitView {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: layout.columns.sidebarMin,
                                                        ideal: layout.columns.sidebarIdeal)
                } content: {
                    ThreadView(
                        model: model,
                        composerLeadingAccessory: composerLeadingAccessory,
                        placesTurnStatsInComposer: placesTurnStatsInComposer,
                        presentationScope: presentationScope)
                        .navigationSplitViewColumnWidth(min: layout.columns.contentMin,
                                                        ideal: layout.columns.contentIdeal)
                } detail: {
                    InspectorView(messages: model.messages,
                                  isStreaming: model.isStreaming,
                                  isGeneratingArtifact: model.isGeneratingArtifact,
                                  artifacts: model.artifacts,
                                  artifactProgress: model.artifactProgress)
                        .navigationSplitViewColumnWidth(min: layout.columns.detailMin,
                                                        ideal: layout.columns.detailIdeal)
                }
            case .threadOnly:
                ThreadView(
                    model: model,
                    composerLeadingAccessory: composerLeadingAccessory,
                    placesTurnStatsInComposer: placesTurnStatsInComposer,
                    presentationScope: presentationScope)
            }
        }
        .task { model.start() }
    }
}

// MARK: - Left: Sidebar

struct SidebarView: View {
    private var surfaces: [SessionKind] {
        SessionKind.allCases.filter { PlatformProfile.current.supports($0) }
    }

    var body: some View {
        List {
            Section(IntatisHostApplication.identity.name) {
                ForEach(surfaces, id: \.self) { kind in
                    Label(title(kind), systemImage: icon(kind))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func title(_ kind: SessionKind) -> String {
        switch kind {
        case .chat:   return IntatisLocalization.string("Chat")
        case .code:   return IntatisLocalization.string("Code")
        case .cowork: return IntatisLocalization.string("Cowork")
        }
    }

    private func icon(_ kind: SessionKind) -> String {
        switch kind {
        case .chat:   return "bubble.left"
        case .code:   return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.2"
        }
    }
}

// MARK: - Center: Thread

struct ThreadView: View {
    @ObservedObject var model: ChatViewModel
    let composerLeadingAccessory: AnyView?
    let placesTurnStatsInComposer: Bool
    let presentationScope: IntatisThreadPresentationScope?
    @Environment(\.colorScheme) private var scheme
    @StateObject private var scrollCoordinator =
        IntatisThreadScrollCoordinator()

    var body: some View {
        let threadScope = resolvedPresentationScope
        let baseAdmission = scrollCoordinator
            .effectiveViewportAdmission(
                for: threadScope,
                defersUntilInitialRestore:
                    defersRichUntilInitialRestore)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        IntatisContinuousThreadStack(
                            items: model.messages,
                            scope: threadScope,
                            baseAdmission: baseAdmission,
                            alignment: .leading,
                            spacing: 12,
                            rowID: { $0.id.rawValue }
                        ) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .padding(.bottom, 16)
                            .id(IntatisThreadBottomAnchorID(
                                scope: threadScope))
                            .onScrollVisibilityChange(threshold: 0.99) {
                                isVisible in
                                scrollCoordinator
                                    .enqueueBottomAnchorVisibility(
                                        isVisible,
                                        scope: threadScope)
                            }
                    }
                    .intatisThreadScrollLifecycle(
                        coordinator: scrollCoordinator,
                        scope: threadScope)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onAppear {
                    scrollCoordinator.activate(
                        scope: threadScope,
                        defersRichUntilInitialRestore:
                            defersRichUntilInitialRestore)
                    scrollCoordinator.requestInitialRestore(
                        scope: threadScope,
                        perform: scrollPerformer(
                            proxy,
                            scope: threadScope))
                }
                .onChange(of: chatScrollSignature) { _, _ in
                    scrollCoordinator.requestContentFollow(
                        scope: threadScope,
                        isCompletion: isCompletedChatTurn,
                        perform: scrollPerformer(
                            proxy,
                            scope: threadScope))
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
                .onDisappear {
                    scrollCoordinator.deactivate(scope: threadScope)
                }
            }
            if let errorText = presentedErrorText {
                Text(errorText)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            if !placesTurnStatsInComposer,
               let latestTurnStats = model.latestTurnStats {
                IntatisTurnStatsSummaryView(stats: latestTurnStats, style: .standard(scheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 4)
            }
            #if !os(iOS)
            Divider()
            #endif
            ComposerView(
                model: model,
                leadingAccessory: composerLeadingAccessory,
                placesTurnStatsInComposer: placesTurnStatsInComposer,
                onSend: {
                    scrollCoordinator.resumeFollowingBottom(
                        scope: threadScope)
                    model.send()
                })
        }
    }

    private var resolvedPresentationScope: IntatisThreadPresentationScope {
        if let presentationScope {
            return presentationScope
        }
        return IntatisThreadPresentationScope(
            kind: .chat,
            sessionID: SessionID(
                rawValue:
                    "shared-\(ObjectIdentifier(model).hashValue)"))
    }

    private var defersRichUntilInitialRestore: Bool {
        IntatisThreadRichEntryPolicy.defersUntilInitialRestore(
            richRowCount: model.messages.count)
    }

    private var chatScrollSignature: String {
        guard let last = model.messages.last else { return "0" }
        return [
            "\(model.messages.count)",
            last.id.rawValue,
            "\(last.text.count)",
            "\(last.isComplete)",
            "\(model.isStreaming)"
        ].joined(separator: ":")
    }

    private var isCompletedChatTurn: Bool {
        model.messages.last?.isComplete == true
            && !model.isStreaming
    }

    private var presentedErrorText: String? {
        #if canImport(AVFoundation)
        return model.voiceInput.errorText ?? model.errorText
        #else
        return model.errorText
        #endif
    }

    private func scrollPerformer(
        _ proxy: ScrollViewProxy,
        scope: IntatisThreadPresentationScope
    ) -> @MainActor () -> Void {
        {
            proxy.scrollTo(
                IntatisThreadBottomAnchorID(scope: scope),
                anchor: .bottom)
        }
    }
}

struct MessageRow: View {
    let message: ChatMessageView
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .body)
    private var chatTextSize: CGFloat = IntatisTypography.spec(for: .chat).nominalPointSize
    @ScaledMetric(relativeTo: .caption)
    private var captionSize: CGFloat = IntatisTypography.spec(for: .caption).nominalPointSize
    @ScaledMetric(relativeTo: .caption2)
    private var metadataSize: CGFloat = IntatisTypography.spec(for: .metadata).nominalPointSize

    private var style: IntatisThreadStyle {
        .standard(scheme)
    }

    @ViewBuilder var body: some View {
        if message.role == .user {
            messageBody
                .padding(10)
                .intatisLiquidGlass(cornerRadius: 10)
        } else {
            messageBody
                .padding(.vertical, 8)
        }
    }

    private var messageBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if IntatisMessageHeaderPolicy.showsIdentity(for: message.role)
                || !message.tags.isEmpty {
                HStack(spacing: 6) {
                    if let roleLabel {
                        Text(roleLabel)
                            .font(IntatisTypography.metadata(metadataSize, .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                    }
                    if (message.role == .assistant || message.role == .agent),
                       let timestamp = message.timestamp {
                        Text(IntatisMessageTimestampPresentation.string(for: timestamp))
                            .font(IntatisTypography.metadata(metadataSize))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(message.tags, id: \.self) { tag in
                        tagBadge(tag)
                    }
                }
            }
            if message.role == .assistant || message.role == .agent {
                IntatisMessageContentView(
                    messageID: message.id.rawValue,
                    rawText: message.text,
                    isComplete: message.isComplete,
                    policy: .richText,
                    style: style)
                if !message.citations.isEmpty {
                    IntatisMessageCitationsView(citations: message.citations)
                }
            } else {
                if !displayText.isEmpty {
                    Text(displayText)
                        .font(IntatisTypography.chat(chatTextSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if message.role == .user, !message.attachments.isEmpty {
                    Label(
                        message.attachments.count == 1
                            ? IntatisLocalization.format(
                                "%lld attachment",
                                Int64(message.attachments.count))
                            : IntatisLocalization.format(
                                "%lld attachments",
                                Int64(message.attachments.count)),
                        systemImage: "paperclip")
                        .font(IntatisTypography.caption(captionSize))
                        .foregroundStyle(.secondary)
                }
            }
            if let advice = message.recoveryAdvice {
                IntatisRecoveryAdviceView(advice: advice, tint: .red, style: style)
            }
        }
    }

    private var displayText: String {
        (message.text.isEmpty && !message.isComplete) ? "…" : message.text
    }

    private var roleLabel: String? {
        switch message.role {
        case .user:      return nil
        case .assistant: return IntatisLocalization.string("Assistant")
        case .agent:
            return message.agent?.rawValue ?? IntatisLocalization.string("Agent")
        case .system:    return IntatisLocalization.string("System")
        }
    }

    private func tagBadge(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(IntatisTypography.metadata(metadataSize, .semibold))
            .foregroundStyle(Color.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                Capsule().stroke(style.stroke, lineWidth: 1)
            }
    }
}

public struct IntatisMessageCitationsView: View {
    private struct LinkValue: Identifiable {
        let id: String
        let title: String
        let url: URL

        init?(_ citation: MessageCitation) {
            guard citation.url.count <= 4_096,
                  let url = URL(string: citation.url),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host,
                  !host.isEmpty,
                  url.user == nil,
                  url.password == nil else {
                return nil
            }
            self.id = url.absoluteString
            self.title = citation.title.isEmpty ? host : citation.title
            self.url = url
        }
    }

    private let citations: [MessageCitation]

    public init(citations: [MessageCitation]) {
        self.citations = citations
    }

    private var links: [LinkValue] {
        citations.compactMap(LinkValue.init)
    }

    @ViewBuilder public var body: some View {
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(IntatisLocalization.string("Sources"))
                    .font(IntatisTypography.system(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(links) { link in
                            Link(destination: link.url) {
                                Label(link.title, systemImage: "link")
                                    .font(IntatisTypography.system(.caption))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint(link.url.host ?? link.id)
                        }
                    }
                }
            }
            .padding(.top, 6)
        }
    }
}

struct ComposerView: View {
    @ObservedObject var model: ChatViewModel
    let leadingAccessory: AnyView?
    let placesTurnStatsInComposer: Bool
    let onSend: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !model.isBusy
            && voiceAllowsSubmission
            && !model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        IntatisThreadComposer(
            placeholder: IntatisLocalization.string(
                "Message \(IntatisHostApplication.identity.name)…"),
            input: $model.input,
            canSend: canSend,
            isInputDisabled: model.isBusy,
            style: .standard(scheme),
            leadingAccessory: leadingAccessory,
            inputLeadingAccessory: inputLeadingAccessory,
            trailingAction: voiceAction,
            stopAction: model.isBusy
                ? IntatisThreadComposerSecondaryAction(
                    systemImage: "stop.fill",
                    help: IntatisLocalization.string("Stop"),
                    action: { model.cancelCurrentOperation() })
                : nil,
            accessory: placesTurnStatsInComposer
                ? AnyView(IntatisComposerUsageStrip(
                    stats: model.latestTurnStats,
                    style: .standard(scheme)))
                : nil,
            onSend: onSend)
        .padding(10)
    }

    private var voiceAllowsSubmission: Bool {
        #if canImport(AVFoundation)
        return !model.voiceInput.isEngaged
        #else
        return true
        #endif
    }

    private var voiceAction: IntatisThreadComposerSecondaryAction? {
        #if canImport(AVFoundation)
        let voice = model.voiceInput
        return IntatisThreadComposerSecondaryAction(
            systemImage: voice.buttonSystemImage,
            help: voice.buttonHelp,
            isBusy: voice.showsProgress,
            isDisabled: voice.isToggleDisabled
                || (model.isBusy && !voice.isRecording),
            blocksSubmission: voice.isEngaged,
            action: { model.toggleVoiceInput() })
        #else
        return nil
        #endif
    }

    private var inputLeadingAccessory: AnyView? {
        #if os(iOS)
        let label = IntatisLocalization.string("Attachments and chat tools")
        return AnyView(
            Menu {
                Button {
                    model.generateImage()
                } label: {
                    Label(
                        IntatisLocalization.string("Generate image from prompt"),
                        systemImage: "photo.badge.plus")
                }
                .disabled(!canSend)
            } label: {
                Label(label, systemImage: "paperclip")
                    .intatisComposerIconLabel()
            }
            .intatisComposerIconButton()
            .help(label)
            .accessibilityLabel(label)
            .accessibilityIdentifier("thread.composer.actions")
            .disabled(model.isBusy))
        #else
        return nil
        #endif
    }
}

// MARK: - Right: Inspector

struct InspectorView: View {
    let messages: [ChatMessageView]
    let isStreaming: Bool
    let isGeneratingArtifact: Bool
    let artifacts: [ArtifactCardInfo]
    let artifactProgress: [ArtifactProgressSnapshot]

    var body: some View {
        List {
            Section("Status") {
                LabeledContent("Messages", value: "\(messages.count)")
                LabeledContent(
                    "Streaming",
                    value: isStreaming
                        ? IntatisLocalization.string("Yes")
                        : IntatisLocalization.string("No"))
                LabeledContent(
                    "Image job",
                    value: isGeneratingArtifact
                        ? IntatisLocalization.string("Running")
                        : IntatisLocalization.string("Idle"))
                LabeledContent(
                    "Artifact progress",
                    value: artifactProgress.isEmpty
                        ? IntatisLocalization.string("None")
                        : IntatisLocalization.format("%lld active", Int64(artifactProgress.count)))
                LabeledContent("Artifacts", value: "\(artifacts.count)")
            }
            Section("Artifacts") {
                ArtifactInspector(artifacts: artifacts, progress: artifactProgress)
            }
        }
    }
}
#endif
