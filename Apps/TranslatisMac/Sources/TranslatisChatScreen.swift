//
//  TranslatisChatScreen.swift
//  TranslatisMac
//
//  The macOS Chat surface follows the native window material. Content uses
//  semantic system Material, while the custom composer and controls adopt
//  Liquid Glass on current systems.
//

#if canImport(SwiftUI)
import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif
import IntatisCore
import IntatisProtocol
import IntatisProviders
import IntatisConversation
import IntatisSharedUI

struct TranslatisMacScreenLayout {
    let rawWidth: CGFloat

    private var width: CGFloat { max(rawWidth, 1) }
    private var threadLayout: IntatisThreadContentLayout {
        IntatisThreadContentLayout(rawWidth: rawWidth, contentMaxWidth: 900, messageMaxWidth: 560)
    }

    var isCompact: Bool { width < 700 }

    var horizontalPadding: CGFloat {
        if width < 380 { return 10 }
        if width < 500 { return 14 }
        if width < 760 { return 20 }
        return 30
    }

    var contentMaxWidth: CGFloat { 900 }
    var contentWidth: CGFloat { threadLayout.contentWidth }
    var settingsMaxWidth: CGFloat { 960 }
    var settingsCardMaxWidth: CGFloat { 820 }
    var settingsUsesColumns: Bool { width >= 760 }

    var providerListWidth: CGFloat {
        min(220, max(176, width * 0.30))
    }

    var messageMaxWidth: CGFloat {
        threadLayout.messageMaxWidth
    }

    var messageGutter: CGFloat {
        threadLayout.messageGutter
    }
}

struct TranslatisChatScreen: View {
    @ObservedObject var env: AppEnvironment
    let sessionTitle: String

    var body: some View {
        IntatisChatSessionScreen(
            env: env,
            model: env.viewModel,
            sessionTitle: sessionTitle)
            .id(env.chatSessionID.rawValue)
    }
}

private struct IntatisChatSessionScreen: View {
    @ObservedObject var env: AppEnvironment
    @ObservedObject var model: ChatViewModel
    let sessionTitle: String
    @Environment(\.colorScheme) private var scheme
    @State private var showAttachmentImporter = false
    @StateObject private var scrollCoordinator =
        IntatisThreadScrollCoordinator()
    @Environment(\.intatisWindowContentWidth) private var windowContentWidth

    var body: some View {
        GeometryReader { proxy in
            content(layout: TranslatisMacScreenLayout(rawWidth: proxy.size.width))
        }
        .intatisComposerAttachmentImport(
            isPresented: $showAttachmentImporter,
            onImport: { model.importDraftAttachments($0) },
            onFailure: { model.reportAttachmentImportFailure($0) })
    }

    private func content(layout: TranslatisMacScreenLayout) -> some View {
        VStack(spacing: 0) {
            header(layout: layout)

            messages(layout: layout)

            errorText(layout: layout)

            if !model.artifactProgress.isEmpty {
                IntatisArtifactProgressStrip(progress: model.artifactProgress)
                    .frame(maxWidth: layout.contentMaxWidth)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 8)
            }

            IntatisComposer(model: model,
                            catalog: env.providerCatalog,
                            onSelectModel: env.selectProviderModel(providerID:modelID:variantID:),
                            onAttach: {
                                showAttachmentImporter = true
                            },
                            onSend: {
                                scrollCoordinator.resumeFollowingBottom(
                                    scope: threadPresentationScope)
                                model.send()
                            })
                .frame(maxWidth: layout.contentMaxWidth)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, 10)
                .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(layout: TranslatisMacScreenLayout) -> some View {
        TranslatisPageHeader(title: sessionTitle, subtitle: nil)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 24)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func errorText(layout: TranslatisMacScreenLayout) -> some View {
        if let err = env.chatSessionError
            ?? model.voiceInput.errorText
            ?? model.errorText {
            Text(err)
                .font(TranslatisType.caption(12))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, layout.horizontalPadding)
        }
    }

    @ViewBuilder private func messages(layout: TranslatisMacScreenLayout) -> some View {
        if model.messages.isEmpty {
            emptyState
        } else {
            let threadScope = threadPresentationScope
            let baseAdmission = scrollCoordinator
                .effectiveViewportAdmission(
                    for: threadScope,
                    defersUntilInitialRestore:
                        defersRichUntilInitialRestore)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 14) {
                        IntatisContinuousThreadStack(
                            items: model.messages,
                            scope: threadScope,
                            baseAdmission: baseAdmission,
                            spacing: 14,
                            rowID: { $0.id.rawValue }
                        ) { msg in
                            IntatisMessageBubble(message: msg,
                                                 rowWidth: layout.contentWidth,
                                                 maxWidth: layout.messageMaxWidth,
                                                 gutter: layout.messageGutter)
                                .id(msg.id)
                        }
                        if showsVisibleThinkingIndicator {
                            thinkingRow(layout: layout)
                                .id(IntatisHostApplication.identity
                                    .namespacedIdentifier(
                                        "chat-thinking-\(chatThinkingPhaseID)"))
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
                    .frame(width: layout.contentWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, layout.horizontalPadding)
                    .padding(.top, 16)
                }
                .scrollContentBackground(.hidden)
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
                .onChange(of: layout.contentWidth) { _, width in
                    scrollCoordinator.contentWidthDidChange(
                        scope: threadScope,
                        width: width,
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
                .overlay(alignment: .bottom) {
                    if !scrollCoordinator.isFollowingBottom {
                        IntatisJumpToLatestButton(
                            accessibilityIdentifier: "chat.jump-to-latest"
                        ) {
                            scrollCoordinator.jumpToLatest(
                                scope: threadScope,
                                perform: scrollPerformer(
                                    proxy,
                                    scope: threadScope))
                        }
                        .offset(x: IntatisWindowCenteredOverlayLayoutPolicy
                            .horizontalOffset(
                                windowWidth: windowContentWidth,
                                detailWidth: layout.rawWidth,
                                overlaySurfaceWidth: layout.rawWidth))
                    }
                }
                .onDisappear {
                    scrollCoordinator.deactivate(scope: threadScope)
                }
            }
        }
    }

    private var threadPresentationScope: IntatisThreadPresentationScope {
        IntatisThreadPresentationScope(
            kind: .chat,
            sessionID: env.chatSessionID)
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
            last.turnStats?.id ?? "no-stats",
            "\(model.isStreaming)"
        ].joined(separator: ":")
    }

    private var isCompletedChatTurn: Bool {
        model.messages.last?.isComplete == true
            && !model.isStreaming
    }

    private var showsVisibleThinkingIndicator: Bool {
        model.isStreaming
            && model.messages.last?.role == .user
    }

    private var chatThinkingPhaseID: String {
        [
            env.chatSessionID.rawValue,
            model.messages.last?.id.rawValue ?? "initial"
        ].joined(separator: ":")
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sparkle")
                .font(IntatisTypography.system(size: 30, weight: .semibold))
                .foregroundStyle(TranslatisTheme.accent(scheme))
            .frame(width: 76, height: 76)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func thinkingRow(layout: TranslatisMacScreenLayout) -> some View {
        IntatisThreadBubbleRow(isTrailing: false,
                               fillsAvailableWidth: true,
                               rowWidth: layout.contentWidth,
                               maxWidth: layout.messageMaxWidth,
                               gutter: layout.messageGutter) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                IntatisThinkingElapsedLabel(phaseID: chatThinkingPhaseID)
                    .font(TranslatisType.caption(12))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
        }
    }
}

struct IntatisChatModelMenu: View {
    let catalog: AppProviderCatalog
    let isBusy: Bool
    let isCompact: Bool
    var usesGlassButton: Bool = true
    var help: String = IntatisLocalization.string("Switch model")
    let onSelect: (String, String, String?) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedModel: AppProviderModel? { catalog.selectedModel }
    private var menuProviders: [ProviderModelMenuProvider] {
        catalog.providers.compactMap { provider in
            let models = catalog.inferenceModels(for: provider)
            guard !models.isEmpty else { return nil }
            return ProviderModelMenuProvider(
                id: provider.id,
                title: provider.title,
                models: models.flatMap { model in
                    let base = ProviderModelMenuModel(
                        id: model.id,
                        modelID: model.id,
                        variantID: nil,
                        title: model.title,
                        detail: model.reasoningLabel)
                    let variants = model.variants.map { variant in
                        ProviderModelMenuModel(
                            id: variantMenuID(modelID: model.id, variantID: variant.id),
                            modelID: model.id,
                            variantID: variant.id,
                            title: model.title,
                            detail: variantMenuDetail(variant))
                    }
                    return [base] + variants
                })
        }
    }

    @ViewBuilder var body: some View {
        if usesGlassButton {
            selectionMenu
                .intatisComposerSelectionMenu()
        } else {
            selectionMenu
                .buttonStyle(.borderless)
        }
    }

    private var selectionMenu: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: catalog.selectedProviderID,
            selectedModelID: catalog.selectedModelID,
            selectedVariantID: catalog.selectedVariantID,
            isBusy: isBusy,
            onSelect: onSelect) {
                label
        }
        .help(isBusy
            ? IntatisLocalization.string("Model changes apply after the current response finishes")
            : help)
    }

    @ViewBuilder private var label: some View {
        if usesGlassButton && isCompact {
            labelContent
                .intatisComposerSelectionLabel()
        } else if usesGlassButton {
            labelContent
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .intatisLiquidGlass(cornerRadius: 16, interactive: true)
        } else {
            labelContent
                .padding(.horizontal, 2)
                .padding(.vertical, 1)
                .frame(
                    maxWidth: IntatisComposerControlMetrics.selectionMaxWidth,
                    alignment: .leading)
        }
    }

    private var labelContent: some View {
        HStack(spacing: 8) {
            Text(selectedModel?.title ?? AppConfig.defaultDisplayName(for: AppConfig.defaultModel))
                .font(TranslatisType.body(13, .semibold))
                .foregroundStyle(TranslatisTheme.deepText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.down")
                .font(IntatisTypography.system(size: 10, weight: .semibold))
                .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
        }
        .frame(
            minWidth: isCompact || !usesGlassButton ? 0 : 190,
            maxWidth: usesGlassButton
                ? (isCompact ? nil : 260)
                : IntatisComposerControlMetrics.selectionMaxWidth,
            alignment: .leading)
    }

    private func variantMenuID(modelID: String, variantID: String) -> String {
        "\(modelID.utf8.count):\(modelID)\(variantID)"
    }

    private func variantMenuDetail(_ variant: AppProviderModelVariant) -> String {
        guard let reasoning = variant.reasoningLabel,
              reasoning.caseInsensitiveCompare(variant.id) != .orderedSame else {
            return variant.reasoningLabel ?? variant.id
        }
        return "\(variant.id) · \(reasoning)"
    }
}

struct IntatisArtifactProgressStrip: View {
    let progress: [ArtifactProgressSnapshot]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(progress) { item in
                HStack(spacing: 10) {
                    ProgressView(value: min(max(item.progress, 0), 1))
                        .frame(width: 120)
                    Text(localizedState(item.state))
                        .font(TranslatisType.caption(12, .semibold))
                        .foregroundStyle(TranslatisTheme.deepText(scheme))
                    Spacer(minLength: 8)
                    Text("\(Int(min(max(item.progress, 0), 1) * 100))%")
                        .font(TranslatisType.caption(12))
                        .foregroundStyle(TranslatisTheme.softText(scheme))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .translatisCard(cornerRadius: 14)
    }

    private func localizedState(_ state: String) -> String {
        switch state.lowercased() {
        case "queued": return IntatisLocalization.string("queued")
        case "running": return IntatisLocalization.string("running")
        case "completed": return IntatisLocalization.string("completed")
        case "failed": return IntatisLocalization.string("failed")
        case "cancelled": return IntatisLocalization.string("cancelled")
        default: return state
        }
    }
}

// MARK: - Message bubble

struct IntatisMessageBubble: View {
    let message: ChatMessageView
    let rowWidth: CGFloat
    let maxWidth: CGFloat
    let gutter: CGFloat
    @Environment(\.colorScheme) private var scheme

    private var isUser: Bool { message.role == .user }

    private var roleLabel: String? {
        switch message.role {
        case .user:      return nil
        case .assistant: return IntatisHostApplication.identity.name
        case .agent:
            return message.agent?.rawValue
                ?? IntatisHostApplication.identity.name
        case .system:    return IntatisLocalization.string("System")
        }
    }

    private var displayText: String {
        (message.text.isEmpty && !message.isComplete) ? "…" : message.text
    }

    var body: some View {
        IntatisThreadBubbleRow(
            isTrailing: isUser,
            fillsAvailableWidth: message.role == .assistant || message.role == .agent,
            rowWidth: rowWidth,
            maxWidth: maxWidth,
            gutter: gutter) {
            bubble
        }
    }

    @ViewBuilder private var bubble: some View {
        if isUser {
            bubbleBody
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .intatisLiquidGlass(cornerRadius: 20)
        } else {
            bubbleBody
                .padding(.vertical, 8)
        }
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 5) {
            if IntatisMessageHeaderPolicy.showsIdentity(for: message.role)
                || !message.tags.isEmpty {
                HStack(spacing: 6) {
                    if let roleLabel {
                        Text(roleLabel)
                            .font(TranslatisType.caption(10, .semibold))
                            .tracking(0.6)
                            .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                    }
                    if (message.role == .assistant || message.role == .agent),
                       let timestamp = message.timestamp {
                        Text(IntatisMessageTimestampPresentation.string(for: timestamp))
                            .font(TranslatisType.caption(10))
                            .monospacedDigit()
                            .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                    }
                    ForEach(message.tags, id: \.self) { tag in
                        goalTag(tag)
                    }
                }
            }
            if message.role == .assistant || message.role == .agent {
                IntatisMessageContentView(
                    messageID: message.id.rawValue,
                    rawText: message.text,
                    isComplete: message.isComplete,
                    policy: .richText,
                    style: .translatisMac(scheme))
                if !message.citations.isEmpty {
                    IntatisMessageCitationsView(
                        citations: message.citations)
                }
                if message.isComplete {
                    IntatisMessageFooter(
                        messageID: message.id.rawValue,
                        rawText: message.text,
                        stats: message.turnStats,
                        style: .translatisMac(scheme))
                }
            } else {
                if !displayText.isEmpty {
                    Text(displayText)
                        .font(TranslatisType.chat(15))
                        .foregroundStyle(TranslatisTheme.deepText(scheme))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isUser, !message.attachments.isEmpty {
                    Label(
                        message.attachments.count == 1
                            ? IntatisLocalization.format(
                                "%lld attachment",
                                Int64(message.attachments.count))
                            : IntatisLocalization.format(
                                "%lld attachments",
                                Int64(message.attachments.count)),
                        systemImage: "paperclip")
                        .font(TranslatisType.caption(12))
                        .foregroundStyle(TranslatisTheme.softText(scheme))
                }
            }
        }
    }

    private func goalTag(_ tag: String) -> some View {
        Text(tag.uppercased())
            .font(TranslatisType.caption(10, .semibold))
            .foregroundStyle(TranslatisTheme.accent(scheme))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay {
                Capsule().stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
            }
    }
}

// MARK: - Composer

struct IntatisComposer: View {
    @ObservedObject var model: ChatViewModel
    let catalog: AppProviderCatalog
    let onSelectModel: (String, String, String?) -> Void
    let onAttach: () -> Void
    let onSend: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var canSend: Bool {
        !model.isBusy
            && !model.voiceInput.isEngaged
            && (!model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !model.draftAttachments.isEmpty)
    }

    var body: some View {
        IntatisThreadComposer(
            placeholder: IntatisLocalization.string(
                "Message \(IntatisHostApplication.identity.name)..."),
            input: $model.input,
            canSend: canSend,
            isInputDisabled: model.isBusy,
            style: .translatisMac(scheme),
            leadingAccessory: AnyView(IntatisComposerModelControl(
                catalog: catalog,
                isBusy: model.isBusy,
                onSelectModel: onSelectModel)),
            inputLeadingAccessory: AnyView(
                IntatisMacComposerAttachmentAccessory(
                    attachments: model.draftAttachments,
                    accessibilityPrefix: "chat",
                    isBusy: model.isImportingAttachments,
                    isDisabled: model.isBusy,
                    onAttach: onAttach,
                    onRemove: {
                        model.removeDraftAttachment($0)
                    })),
            trailingAction: IntatisThreadComposerSecondaryAction(
                systemImage: model.voiceInput.buttonSystemImage,
                help: model.voiceInput.buttonHelp,
                isBusy: model.voiceInput.showsProgress,
                isDisabled: model.voiceInput.isToggleDisabled
                    || (model.isBusy && !model.voiceInput.isRecording),
                blocksSubmission: model.voiceInput.isEngaged,
                action: { model.toggleVoiceInput() }),
            stopAction: model.isBusy
                ? IntatisThreadComposerSecondaryAction(
                    systemImage: "stop.fill",
                    help: IntatisLocalization.string("Stop"),
                    action: { model.cancelCurrentOperation() })
                : nil,
            accessory: {
                IntatisComposerContextStrip(
                    stats: model.latestTurnStats,
                    style: .translatisMac(scheme))
            },
            onSend: onSend)
    }
}

struct IntatisComposerModelControl: View {
    let catalog: AppProviderCatalog
    let isBusy: Bool
    let onSelectModel: (String, String, String?) -> Void

    var body: some View {
        IntatisChatModelMenu(
            catalog: catalog,
            isBusy: isBusy,
            isCompact: true,
            usesGlassButton: true,
            help: IntatisLocalization.string("Switch model"),
            onSelect: onSelectModel)
    }
}

// MARK: - Settings panel

struct IntatisSettingsPanel: View {
    @EnvironmentObject var env: AppEnvironment
    @Environment(\.colorScheme) private var scheme
    @State private var catalog = AppConfig.providerCatalog
    @State private var apiKeysByProviderID: [String: String] = [:]
    @State private var saved = false
    @State private var settingsError: String?
    @State private var isTestingProvider = false
    @State private var providerHealthReports: [ProviderHealthReport] = []
    @State private var showThirdPartyNotices = false
    @State private var isAdvancedSettingsExpanded = false
    @State private var isProviderConnectionExpanded = false
    @State private var isModelManagementExpanded = false
    @State private var isExportingDiagnostics = false
    @State private var diagnosticExportMessage: String?
    @State private var diagnosticExportSucceeded = false
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var rendererModeRawValue = IntatisMessageRendererMode.microsoft.rawValue

    var body: some View {
        GeometryReader { proxy in
            settingsContent(layout: TranslatisMacScreenLayout(rawWidth: proxy.size.width))
        }
        .sheet(isPresented: $showThirdPartyNotices) {
            NavigationStack {
                IntatisThirdPartyNoticesView()
                    .navigationTitle("Open-source notices")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showThirdPartyNotices = false }
                        }
                    }
            }
            .frame(minWidth: 680, minHeight: 560)
        }
    }

    private func settingsContent(layout: TranslatisMacScreenLayout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TranslatisPageHeader(
                    title: IntatisLocalization.string("Settings"),
                    subtitle: nil)

                settingsCard(layout: layout)

                if let settingsError {
                    Text(settingsError)
                        .font(TranslatisType.caption(12, .regular))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
                }

                providerHealthSummary
                    .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)

                settingsActions(layout: layout)

                advancedSettingsCard(layout: layout)

                diagnosticExportRow(layout: layout)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.top, 26)
            .padding(.bottom, 30)
            .frame(maxWidth: layout.settingsMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollContentBackground(.hidden)
    }

    private var messageRenderingSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Text("Message rendering")
                    .font(TranslatisType.body(14, .semibold))
                Spacer(minLength: 12)
                Picker("Message rendering", selection: rendererModeSelection) {
                    Text("Rich Markdown").tag(IntatisMessageRendererMode.microsoft.rawValue)
                    Text("Plain text safe mode").tag(IntatisMessageRendererMode.plainSafe.rawValue)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 300)
                .help(rendererModeHelpText)
                .accessibilityIdentifier("settings.message-renderer-mode")
            }

            if rendererLaunchOverride != nil {
                Text(rendererModeHelpText)
                    .font(TranslatisType.caption(12, .regular))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                showThirdPartyNotices = true
            } label: {
                Label("Open-source notices", systemImage: "doc.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(TranslatisTheme.accent(scheme))
            .accessibilityIdentifier("settings.open-source-notices")
        }
    }

    private func advancedSettingsCard(layout: TranslatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.45)

            DisclosureGroup(isExpanded: $isAdvancedSettingsExpanded) {
                VStack(alignment: .leading, spacing: 18) {
                    IntatisMCPSettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().opacity(0.45)

                    messageRenderingSettings

                    Divider().opacity(0.45)

                    HStack(spacing: 16) {
                        Text("Configuration")
                            .font(TranslatisType.body(14, .semibold))
                        Spacer(minLength: 12)
                        openJSONButton
                    }
                }
                .padding(.top, 16)
            } label: {
                Label("Advanced settings", systemImage: "slider.horizontal.3")
                    .font(TranslatisType.body(14, .semibold))
                    .foregroundStyle(TranslatisTheme.deepText(scheme))
            }
            .accessibilityIdentifier("settings.advanced")
        }
        .padding(.top, 2)
        .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
    }

    private func diagnosticExportRow(layout: TranslatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.45)

            Group {
                if layout.isCompact {
                    VStack(alignment: .leading, spacing: 12) {
                        diagnosticExportTitle
                        diagnosticExportButton
                    }
                } else {
                    HStack(spacing: 18) {
                        diagnosticExportTitle
                        Spacer(minLength: 12)
                        diagnosticExportButton
                    }
                }
            }

            if let diagnosticExportMessage {
                Label(
                    diagnosticExportMessage,
                    systemImage: diagnosticExportSucceeded
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                    .font(TranslatisType.caption(12, .semibold))
                    .foregroundStyle(diagnosticExportSucceeded ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
        .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
    }

    private var diagnosticExportTitle: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
                .font(TranslatisType.body(14, .semibold))
            Text("Local ZIP. Nothing is uploaded.")
                .font(TranslatisType.caption(12, .regular))
                .foregroundStyle(TranslatisTheme.softText(scheme))
        }
    }

    private var diagnosticExportButton: some View {
        Button(action: exportDiagnostics) {
            Label(
                isExportingDiagnostics
                    ? IntatisLocalization.string("Generating Diagnostic Logs…")
                    : IntatisLocalization.string("Export Diagnostic Logs…"),
                systemImage: isExportingDiagnostics
                    ? "hourglass"
                    : "square.and.arrow.down")
                .font(TranslatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .intatisGlassButton()
        .disabled(isExportingDiagnostics)
        .help("Choose where to save a local diagnostic ZIP")
        .accessibilityIdentifier("settings.export-diagnostic-logs")
    }

    private var rendererLaunchOverride: IntatisMessageRendererMode? {
        IntatisMessageRendererMode.launchOverride()
    }

    /// The Phase 0 renderer stored `rich`. Render routing already migrates that
    /// value to Microsoft; normalize the Picker view as well so an upgraded
    /// user never sees an empty segmented selection.
    private var rendererModeSelection: Binding<String> {
        Binding(
            get: {
                IntatisMessageRendererMode.resolve(
                    persistedRawValue: rendererModeRawValue,
                    arguments: []).rawValue
            },
            set: { rendererModeRawValue = $0 })
    }

    private var rendererModeHelpText: String {
        if let rendererLaunchOverride {
            let label = rendererLaunchOverride == .plainSafe
                ? IntatisLocalization.string("Plain text safe mode")
                : IntatisLocalization.string("Rich Markdown")
            return IntatisLocalization.format(
                "Current launch is forced to %@. This picker is saved immediately for the next launch without an override, so a rescued session can remain in safe mode.",
                label)
        }
        return IntatisLocalization.string(
            "This choice is saved and applied immediately; it is independent of provider Save. Rich Markdown uses the audited upstream renderer with LaTeX math typesetting enabled; remote images and syntax highlighting remain disabled for the first release. Plain text safe mode bypasses Markdown entirely. Raw session data is unchanged.")
    }

    @ViewBuilder private func settingsCard(layout: TranslatisMacScreenLayout) -> some View {
        if layout.settingsUsesColumns {
            HStack(alignment: .top, spacing: 18) {
                providerList
                    .frame(width: layout.providerListWidth, alignment: .topLeading)
                Divider().opacity(0.45)
                providerDetail(layout: layout)
            }
            .padding(22)
            .translatisCard(cornerRadius: 24)
            .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 18) {
                providerList
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                Divider().opacity(0.45)
                providerDetail(layout: layout)
            }
            .padding(18)
            .translatisCard(cornerRadius: 20)
            .frame(maxWidth: layout.settingsCardMaxWidth, alignment: .leading)
        }
    }

    @ViewBuilder private func settingsActions(layout: TranslatisMacScreenLayout) -> some View {
        if layout.isCompact {
            VStack(alignment: .trailing, spacing: 10) {
                savedLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Spacer(minLength: 0)
                    testProviderButton(layout: layout)
                    saveButton
                }
            }
            .frame(maxWidth: layout.settingsCardMaxWidth)
        } else {
            HStack {
                savedLabel
                Spacer()
                testProviderButton(layout: layout)
                saveButton
            }
            .frame(maxWidth: layout.settingsCardMaxWidth)
        }
    }

    @ViewBuilder private var savedLabel: some View {
        if saved {
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(.green)
        }
    }

    private var openJSONButton: some View {
        Button(action: openJSONConfig) {
            Label(
                "Open \(IntatisHostApplication.identity.name) Config",
                systemImage: "curlybraces")
                .font(TranslatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .intatisGlassButton()
        .help(settingsStorageNote)
    }

    private func testProviderButton(layout: TranslatisMacScreenLayout) -> some View {
        Button(action: testProvider) {
            Label(isTestingProvider
                    ? IntatisLocalization.string("Testing")
                    : IntatisLocalization.string(layout.isCompact ? "Test" : "Test Provider"),
                  systemImage: isTestingProvider ? "hourglass" : "checkmark.seal")
                .font(TranslatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .intatisGlassButton()
        .disabled(isTestingProvider)
        .help("Save current settings and run a small model health check")
    }

    private var saveButton: some View {
        Button(action: save) {
            Text("Save")
                .font(TranslatisType.body(14, .semibold))
                .foregroundStyle(.primary)
        }
        .intatisGlassButton(prominent: true)
    }

    @ViewBuilder private var providerHealthSummary: some View {
        if isTestingProvider {
            Label("Testing provider…", systemImage: "hourglass")
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(TranslatisTheme.softText(scheme))
        } else if !providerHealthReports.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(providerHealthReports.enumerated()), id: \.offset) { _, report in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(IntatisLocalization.string(report.displayTitle),
                              systemImage: report.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(TranslatisType.caption(12, .semibold))
                            .foregroundStyle(report.isOK ? .green : .red)
                        Text(IntatisLocalization.providerHealthSummary(report))
                            .font(TranslatisType.caption(11, .medium))
                            .foregroundStyle(TranslatisTheme.softText(scheme))
                            .lineLimit(2)
                        Text(IntatisLocalization.providerHealthDetail(report))
                            .font(TranslatisType.caption(11, .regular))
                            .foregroundStyle(TranslatisTheme.softText(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var providerList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Providers")
                    .font(TranslatisType.caption(12, .semibold))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
                Spacer()
                Button(action: addProvider) {
                    Image(systemName: "plus")
                        .font(IntatisTypography.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Add provider")
            }

            VStack(spacing: 8) {
                ForEach(catalog.providers) { provider in
                    providerRow(provider)
                }
            }
        }
    }

    private func providerDetail(layout: TranslatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let providerIndex = selectedProviderIndex {
                field("Provider name",
                      text: providerFieldBinding(providerIndex, \.displayName),
                      placeholder: "OpenAI")
                secureField("API key",
                            text: apiKeyBinding(for: catalog.providers[providerIndex].id),
                            placeholder: apiKeyPlaceholder(for: catalog.providers[providerIndex]))
                activeModelPicker(providerIndex: providerIndex, layout: layout)
                providerConnectionSettings(providerIndex: providerIndex)
                modelList(providerIndex: providerIndex, layout: layout)
            } else {
                Text("Add a provider to configure models.")
                    .font(TranslatisType.body(14))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func providerConnectionSettings(providerIndex: Int) -> some View {
        DisclosureGroup(isExpanded: $isProviderConnectionExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                field("Base URL",
                      text: baseURLBinding(providerIndex),
                      placeholder: AppConfig.defaultBaseURL)
                field("Chat endpoint",
                      text: chatEndpointBinding(providerIndex),
                      placeholder: AppConfig.defaultChatEndpoint)
                Text(IntatisLocalization.format(
                    "Key source: %@",
                    apiKeySourceLabel(for: catalog.providers[providerIndex])))
                    .font(TranslatisType.caption(11, .medium))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
            }
            .padding(.top, 10)
        } label: {
            Text("Connection")
                .font(TranslatisType.body(13, .semibold))
                .foregroundStyle(TranslatisTheme.deepText(scheme))
        }
        .accessibilityIdentifier("settings.provider.connection")
    }

    private func providerRow(_ provider: AppProviderSettings) -> some View {
        let selected = provider.id == catalog.selectedProviderID
        return Button {
            selectProvider(provider)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(IntatisTypography.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? TranslatisTheme.accent(scheme) : TranslatisTheme.tertiaryText(scheme))
                    Text(provider.title)
                        .font(TranslatisType.body(13, .semibold))
                        .foregroundStyle(TranslatisTheme.deepText(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                Text(providerSubtitle(provider))
                    .font(TranslatisType.caption(11))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(selected ? TranslatisTheme.selectedStroke(scheme) : TranslatisTheme.separator(scheme),
                            lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func activeModelPicker(providerIndex: Int, layout: TranslatisMacScreenLayout) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Active model")
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(TranslatisTheme.softText(scheme))
            Picker("", selection: $catalog.selectedModelID) {
                ForEach(catalog.providers[providerIndex].models) { model in
                    IntatisModelTitleLabel(model: model).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: layout.settingsUsesColumns ? 280 : .infinity, alignment: .leading)
        }
    }

    private func modelList(providerIndex: Int, layout: TranslatisMacScreenLayout) -> some View {
        DisclosureGroup(isExpanded: $isModelManagementExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Spacer()
                    Button(action: { addModel(providerIndex: providerIndex) }) {
                        Label("Add model", systemImage: "plus")
                            .font(TranslatisType.caption(12, .semibold))
                    }
                    .buttonStyle(.plain)
                }

                ForEach(Array(catalog.providers[providerIndex].models.indices), id: \.self) { modelIndex in
                    modelEditorRow(providerIndex: providerIndex,
                                   modelIndex: modelIndex,
                                   layout: layout)
                }

                HStack {
                    Spacer()
                    Button(action: { removeProvider(providerIndex) }) {
                        Label("Delete provider", systemImage: "trash")
                            .font(TranslatisType.caption(12, .semibold))
                    }
                    .buttonStyle(.borderless)
                    .disabled(catalog.providers.count == 1)
                }
            }
            .padding(.top, 10)
        } label: {
            HStack {
                Text("Models")
                    .font(TranslatisType.body(13, .semibold))
                    .foregroundStyle(TranslatisTheme.deepText(scheme))
                Spacer()
                Text("\(catalog.providers[providerIndex].models.count)")
                    .font(TranslatisType.caption(12, .medium))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
            }
        }
        .accessibilityIdentifier("settings.provider.models")
    }

    @ViewBuilder private func modelEditorRow(providerIndex: Int,
                                             modelIndex: Int,
                                             layout: TranslatisMacScreenLayout) -> some View {
        if layout.settingsUsesColumns {
            HStack(spacing: 8) {
                modelIDField(providerIndex: providerIndex, modelIndex: modelIndex)
                modelDisplayNameField(providerIndex: providerIndex, modelIndex: modelIndex)
                removeModelButton(providerIndex: providerIndex, modelIndex: modelIndex)
                    .padding(.top, 20)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                modelIDField(providerIndex: providerIndex, modelIndex: modelIndex)
                modelDisplayNameField(providerIndex: providerIndex, modelIndex: modelIndex)
                HStack {
                    Spacer()
                    removeModelButton(providerIndex: providerIndex, modelIndex: modelIndex)
                }
            }
        }
    }

    private func modelIDField(providerIndex: Int, modelIndex: Int) -> some View {
        field("Model ID",
              text: modelFieldBinding(providerIndex: providerIndex,
                                      modelIndex: modelIndex,
                                      keyPath: \.id),
              placeholder: AppConfig.defaultModel)
    }

    private func modelDisplayNameField(providerIndex: Int, modelIndex: Int) -> some View {
        field("Display name",
              text: modelFieldBinding(providerIndex: providerIndex,
                                      modelIndex: modelIndex,
                                      keyPath: \.displayName),
              placeholder: "GPT-4o mini")
    }

    private func removeModelButton(providerIndex: Int, modelIndex: Int) -> some View {
        Button(action: { removeModel(providerIndex: providerIndex, modelIndex: modelIndex) }) {
            Image(systemName: "trash")
                .font(IntatisTypography.system(size: 13, weight: .medium))
                .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
        }
        .buttonStyle(.plain)
        .disabled(catalog.providers[providerIndex].models.count == 1)
        .help("Remove model")
    }

    private func save() {
        do {
            try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
            catalog = AppConfig.providerCatalog
            apiKeysByProviderID = [:]
            settingsError = nil
            providerHealthReports = []
            withAnimation { saved = true }
        } catch {
            saved = false
            settingsError = IntatisLocalization.format(
                "Could not save settings: %@",
                error.localizedDescription)
        }
    }

    private func openJSONConfig() {
        do {
            let url = try AppConfig.prepareEditableConfigFile()
            catalog = AppConfig.providerCatalog
            settingsError = nil
            providerHealthReports = []
            saved = false
            #if canImport(AppKit)
            if !NSWorkspace.shared.open(url) {
                settingsError = IntatisLocalization.format(
                    "Could not open JSON config at %@",
                    url.path)
            }
            #else
            settingsError = IntatisLocalization.string(
                "Opening JSON config is not available on this platform.")
            #endif
        } catch {
            saved = false
            settingsError = IntatisLocalization.format(
                "Could not open JSON config: %@",
                error.localizedDescription)
        }
    }

    private func testProvider() {
        guard !isTestingProvider else { return }
        isTestingProvider = true
        settingsError = nil
        providerHealthReports = []
        Task { @MainActor in
            defer { isTestingProvider = false }
            do {
                try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                catalog = AppConfig.providerCatalog
                apiKeysByProviderID = [:]
                withAnimation { saved = true }
                providerHealthReports = await env.healthCheckSelectedProvider()
            } catch {
                saved = false
                settingsError = IntatisLocalization.format(
                    "Could not test provider: %@",
                    error.localizedDescription)
            }
        }
    }

    private func exportDiagnostics() {
        guard !isExportingDiagnostics else { return }
        #if canImport(AppKit)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue =
            IntatisDiagnosticExportService.suggestedArchiveName()
        panel.canCreateDirectories = true
        panel.title = IntatisLocalization.string("Export Diagnostic Logs")
        panel.message = IntatisLocalization.string(
            "Choose where to save a local diagnostic ZIP")
        TranslatisMacProcessDiagnostics.shared.setKnownModalPresented(true)
        defer {
            TranslatisMacProcessDiagnostics.shared.setKnownModalPresented(false)
        }
        guard panel.runModal() == .OK,
              let destinationURL = panel.url else { return }

        isExportingDiagnostics = true
        diagnosticExportMessage = nil
        diagnosticExportSucceeded = false
        Task { @MainActor in
            defer { isExportingDiagnostics = false }
            do {
                let result = try await IntatisDiagnosticExportService.export(
                    to: destinationURL)
                diagnosticExportSucceeded = true
                if result.collectionErrorCount == 0 {
                    diagnosticExportMessage = IntatisLocalization.format(
                        "Diagnostic logs were exported as %@.",
                        result.archiveFileName)
                } else {
                    diagnosticExportMessage = IntatisLocalization.format(
                        "Diagnostic logs were exported as %@ with %lld collection warnings recorded in manifest.json.",
                        result.archiveFileName,
                        Int64(result.collectionErrorCount))
                }
            } catch {
                diagnosticExportSucceeded = false
                diagnosticExportMessage = IntatisLocalization.format(
                    "Could not export diagnostic logs: %@",
                    error.localizedDescription)
            }
        }
        #endif
    }

    private var selectedProviderIndex: Int? {
        catalog.providers.firstIndex { $0.id == catalog.selectedProviderID } ?? catalog.providers.indices.first
    }

    private func selectProvider(_ provider: AppProviderSettings) {
        catalog.selectedProviderID = provider.id
        isProviderConnectionExpanded = false
        isModelManagementExpanded = false
        let models = catalog.inferenceModels(for: provider)
        if !models.contains(where: { $0.id == catalog.selectedModelID }) {
            catalog.selectedModelID = models.first?.id ?? AppConfig.defaultModel
        }
        saved = false
    }

    private func addProvider() {
        let provider = AppConfig.newProvider()
        catalog.providers.append(provider)
        selectProvider(provider)
        saved = false
    }

    private func removeProvider(_ index: Int) {
        guard catalog.providers.count > 1, catalog.providers.indices.contains(index) else { return }
        let removedID = catalog.providers[index].id
        catalog.providers.remove(at: index)
        apiKeysByProviderID[removedID] = nil
        if catalog.selectedProviderID == removedID {
            let provider = catalog.providers[min(index, catalog.providers.count - 1)]
            selectProvider(provider)
        }
        saved = false
    }

    private func addModel(providerIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex) else { return }
        let existing = Set(catalog.providers[providerIndex].models.map(\.id))
        let modelID = existing.contains(AppConfig.defaultModel) ? "model-id" : AppConfig.defaultModel
        catalog.providers[providerIndex].models.append(AppProviderModel(id: modelID, displayName: modelID))
        catalog.selectedModelID = modelID
        saved = false
    }

    private func removeModel(providerIndex: Int, modelIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex),
              catalog.providers[providerIndex].models.count > 1,
              catalog.providers[providerIndex].models.indices.contains(modelIndex) else { return }
        let removedID = catalog.providers[providerIndex].models[modelIndex].id
        catalog.providers[providerIndex].models.remove(at: modelIndex)
        if catalog.selectedModelID == removedID {
            catalog.selectedModelID = catalog.providers[providerIndex].models[0].id
        }
        saved = false
    }

    private func providerSubtitle(_ provider: AppProviderSettings) -> String {
        if provider.models.count == 1 {
            return IntatisLocalization.string("1 model")
        }
        return IntatisLocalization.format(
            "%lld models",
            Int64(provider.models.count))
    }

    private func providerFieldBinding(_ providerIndex: Int,
                                      _ keyPath: WritableKeyPath<AppProviderSettings, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex][keyPath: keyPath] },
            set: {
                catalog.providers[providerIndex][keyPath: keyPath] = $0
                saved = false
            })
    }

    private func baseURLBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].baseURL },
            set: {
                let baseURL = AppConfig.baseURL(fromChatEndpoint: $0)
                catalog.providers[providerIndex].baseURL = baseURL
                catalog.providers[providerIndex].chatEndpoint = AppConfig.chatEndpoint(forBaseURL: baseURL)
                saved = false
            })
    }

    private func chatEndpointBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].chatEndpoint },
            set: {
                let endpoint = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                catalog.providers[providerIndex].chatEndpoint = endpoint
                catalog.providers[providerIndex].baseURL = AppConfig.baseURL(fromChatEndpoint: endpoint)
                saved = false
            })
    }

    private func modelFieldBinding(providerIndex: Int,
                                   modelIndex: Int,
                                   keyPath: WritableKeyPath<AppProviderModel, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] },
            set: {
                let oldID = catalog.providers[providerIndex].models[modelIndex].id
                catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] = $0
                if keyPath == \AppProviderModel.id, catalog.selectedModelID == oldID {
                    catalog.selectedModelID = $0
                }
                saved = false
            })
    }

    private func apiKeyBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: { apiKeysByProviderID[providerID] ?? "" },
            set: {
                apiKeysByProviderID[providerID] = $0
                saved = false
            })
    }

    private func apiKeyPlaceholder(for provider: AppProviderSettings) -> String {
        let ref = AppConfig.apiKeyRef(for: provider)
        if ref.source != .authFile {
            return IntatisLocalization.format(
                "Using %@; enter key to replace",
                apiKeySourceLabel(for: provider))
        }
        return env.hasAPIKey(for: provider)
            ? "••••••••••••••••"
            : IntatisLocalization.string("Enter API key")
    }

    private func apiKeySourceLabel(for provider: AppProviderSettings) -> String {
        let ref = AppConfig.apiKeyRef(for: provider)
        switch ref.source {
        case .authFile:
            return IntatisLocalization.string("auth file")
        case .environment:
            return ref.account.isEmpty
                ? IntatisLocalization.string("environment")
                : IntatisLocalization.format("env %@", ref.account)
        case .file:
            return IntatisLocalization.string("secret file")
        case .providerConfig:
            return IntatisLocalization.string("provider config")
        case .keychain:
            return IntatisLocalization.string("legacy keychain")
        }
    }

    private var settingsStorageNote: String {
        if let path = AppConfig.externalConfigDescription {
            return IntatisLocalization.format("Config: %@", path)
        }
        return IntatisLocalization.format(
            "Config: %@",
            AppConfig.editableConfigDescription)
    }

    @ViewBuilder private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(IntatisLocalization.string(label))
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(TranslatisTheme.softText(scheme))
            TextField(IntatisLocalization.string(placeholder), text: text)
                .textFieldStyle(.plain)
                .font(TranslatisType.mono(13))
                .foregroundStyle(TranslatisTheme.deepText(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(inputBackground)
        }
    }

    @ViewBuilder private func secureField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(IntatisLocalization.string(label))
                .font(TranslatisType.caption(12, .semibold))
                .foregroundStyle(TranslatisTheme.softText(scheme))
            SecureField(IntatisLocalization.string(placeholder), text: text)
                .textFieldStyle(.plain)
                .font(TranslatisType.mono(13))
                .foregroundStyle(TranslatisTheme.deepText(scheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .overlay(inputBackground)
        }
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
    }
}

struct IntatisModelTitleLabel: View {
    let model: AppProviderModel

    var body: some View {
        HStack(spacing: 5) {
            Text(model.title)
                .foregroundStyle(.primary)
            if let reasoningLabel = model.reasoningLabel {
                Text(reasoningLabel)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
#endif
