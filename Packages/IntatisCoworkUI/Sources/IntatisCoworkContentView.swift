#if canImport(SwiftUI)
import IntatisCore
import IntatisProtocol
import IntatisSharedUI
import SwiftUI

/// Complete Cowork right-hand presentation with no runtime or session
/// ownership. The embedding host supplies current state and exact actions.
public struct IntatisCoworkContentView: View {
    public var state: IntatisCoworkContentState
    public var actions: IntatisCoworkContentActions
    public var projectSettingsContent: AnyView?
    @Binding private var input: String
    @Binding private var showsInspector: Bool

    @StateObject private var agentThreadPresentation:
        CoworkAgentThreadPresentationModel
    @State private var showProjectSettings = false
    @State private var showGoalEditor = false
    @State private var showGoalClearConfirmation = false
    @State private var goalObjectiveDraft = ""
    @State private var goalSuccessCriteriaDraft = ""
    @State private var goalConstraintsDraft = ""
    @State private var goalTokenBudgetDraft = ""
    @State private var goalEditorSubmissionError: String?
    @State private var showAttachmentImporter = false
    @Environment(\.colorScheme) private var scheme

    public init(
        state: IntatisCoworkContentState,
        threadSource: IntatisCoworkThreadSource,
        actions: IntatisCoworkContentActions,
        projectSettingsContent: AnyView? = nil,
        input: Binding<String>,
        showsInspector: Binding<Bool>
    ) {
        self.state = state
        self.actions = actions
        self.projectSettingsContent = projectSettingsContent
        self._input = input
        self._showsInspector = showsInspector
        self._agentThreadPresentation = StateObject(
            wrappedValue: CoworkAgentThreadPresentationModel(
                mainAgentID: state.project.mainAgentName,
                loadSnapshot: threadSource.loadSnapshot,
                updates: threadSource.updates))
    }

    private var hasMainAgent: Bool {
        state.agents.contains {
            $0.name == state.project.mainAgentName
        }
    }

    public var body: some View {
        CoworkShell(
            threadSnapshot: agentThreadPresentation.snapshot,
            presentationScope: IntatisThreadPresentationScope(
                kind: .cowork,
                sessionID: state.sessionID),
            sessionTitle: state.sessionTitle,
            thinkingScopeID: state.sessionID.rawValue,
            agents: state.agents,
            pending: state.pendingPermission,
            permissionNotice: state.permissionNotice,
            summary: state.summary,
            project: state.project,
            goal: state.goal,
            workTasks: state.workTasks,
            errorTexts: state.errorTexts,
            isWorking: state.isWorking,
            isAcceptingSubmission:
                state.isAcceptingSubmission,
            hasDraftAttachments:
                !state.draftAttachments.isEmpty,
            threadStyle: .standard(scheme),
            onShowSessions: actions.onShowSessions,
            onNewSession: actions.onNewSession,
            onShowProjectSettings:
                projectSettingsContent == nil
                    ? nil
                    : { showProjectSettings = true },
            composerAccessory: composerAccessory,
            composerInputAccessory:
                composerInputAccessory,
            composerTrailingAction: voiceAction,
            showsInspector: $showsInspector,
            input: $input,
            onSend: actions.onSend,
            onCancelCurrent: state.isWorking
                ? actions.onCancelCurrent
                : nil,
            onResolve: actions.onResolvePermission,
            onRemoveAgent: actions.onRemoveAgent,
            onRetryTask: actions.onRetryTask,
            onRetrySubmission: actions.onRetrySubmission,
            onPauseGoal: actions.onPauseGoal,
            onResumeGoal: actions.onResumeGoal,
            onEditGoal: canEditGoal
                ? presentGoalEditor
                : nil,
            onClearGoal: actions.onClearGoal == nil
                ? nil
                : {
                    showGoalClearConfirmation = true
                },
            selectedAgentID:
                agentThreadPresentation.selectedAgentID,
            isThreadSnapshotLoading:
                agentThreadPresentation.isLoading,
            isRichRenderingEligible:
                agentThreadPresentation.isRichRenderingEligible,
            onSelectAgent: {
                agentThreadPresentation.select($0)
            },
            pendingUserInput: state.pendingUserInput,
            onSubmitUserInput: actions.onSubmitUserInput)
        .onChange(of: hasMainAgent) { _, isReady in
            guard isReady else { return }
            actions.onSessionDidBecomeReady?()
        }
        .onAppear {
            activateAgentThreadPresentation()
        }
        .onDisappear {
            agentThreadPresentation.deactivate()
        }
        .onChange(of: state.agents) { _, _ in
            reconcileAgentThreadPresentation()
        }
        .onChange(of: state.project.mainAgentName) { _, _ in
            reconcileAgentThreadPresentation()
        }
        .sheet(isPresented: $showProjectSettings) {
            projectSettingsSheet
        }
        .sheet(isPresented: $showGoalEditor) {
            goalEditorSheet
        }
        .intatisComposerAttachmentImport(
            isPresented: $showAttachmentImporter,
            onImport: {
                actions.onImportAttachments?($0)
            },
            onFailure: {
                actions.onAttachmentImportFailure?($0)
            })
        .alert(
            "Clear this Goal?",
            isPresented: $showGoalClearConfirmation
        ) {
            Button("Clear", role: .destructive) {
                actions.onClearGoal?()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The Goal card will be cleared without marking the Goal completed. Its durable history remains in the session log.")
        }
    }

    private var composerAccessory: AnyView? {
        guard actions.onSelectInference != nil
                || (state.pendingMCPExternalContextCount > 0
                    && actions.onCancelPendingMCPContext != nil)
        else { return nil }
        return AnyView(HStack(
            alignment: .center,
            spacing: IntatisComposerControlMetrics.rowSpacing
        ) {
            if let onSelect = actions.onSelectInference {
                IntatisCoworkInferenceAccessory(
                    options: state.inferenceOptions,
                    selectedBinding:
                        state.selectedInferenceBinding,
                    isDisabled: !hasMainAgent,
                    onSelect: onSelect)
            }
            if let onCancel =
                actions.onCancelPendingMCPContext
            {
                IntatisCoworkPendingContextControl(
                    count:
                        state.pendingMCPExternalContextCount,
                    onCancel: onCancel)
            }
        })
    }

    private var composerInputAccessory: AnyView? {
        guard actions.onImportAttachments != nil,
              let onRemove = actions.onRemoveAttachment
        else { return nil }
        return AnyView(IntatisMacComposerAttachmentAccessory(
            attachments: state.draftAttachments,
            accessibilityPrefix: "cowork",
            onAttach: {
                showAttachmentImporter = true
            },
            onRemove: onRemove))
    }

    private var voiceAction:
        IntatisThreadComposerSecondaryAction?
    {
        guard let onToggleVoice = actions.onToggleVoice else {
            return nil
        }
        return IntatisThreadComposerSecondaryAction(
            systemImage: state.voice.systemImage,
            help: state.voice.help,
            isBusy: state.voice.showsProgress,
            isDisabled:
                state.voice.isToggleDisabled
                || (state.isAcceptingSubmission
                    && !state.voice.isRecording),
            blocksSubmission: state.voice.isEngaged,
            action: onToggleVoice)
    }

    private var canEditGoal: Bool {
        actions.goalEditDraft != nil
            && actions.onSaveGoal != nil
    }

    private func activateAgentThreadPresentation() {
        agentThreadPresentation.activate(
            mainAgentID: state.project.mainAgentName,
            selectableAgentIDs: state.agents
                .filter(\.isConversationSelectable)
                .map(\.id))
    }

    private func reconcileAgentThreadPresentation() {
        agentThreadPresentation.reconcile(
            mainAgentID: state.project.mainAgentName,
            selectableAgentIDs: state.agents
                .filter(\.isConversationSelectable)
                .map(\.id))
    }

    @ViewBuilder
    private var projectSettingsSheet: some View {
        if let projectSettingsContent {
            projectSettingsContent
        } else {
            EmptyView()
        }
    }

    private var goalEditorValidationMessage: String? {
        if let goalEditorSubmissionError {
            return goalEditorSubmissionError
        }
        if goalObjectiveDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        {
            return IntatisLocalization.string(
                "A Goal objective is required.")
        }
        let budget = goalTokenBudgetDraft
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !budget.isEmpty,
           Int(budget).map({ $0 > 0 }) != true
        {
            return IntatisLocalization.string(
                "Token budget must be a positive whole number, or left empty for no budget.")
        }
        return nil
    }

    private func presentGoalEditor() {
        guard let draft = actions.goalEditDraft?() else { return }
        goalObjectiveDraft = draft.objective
        goalSuccessCriteriaDraft = draft.successCriteria
        goalConstraintsDraft = draft.constraints
        goalTokenBudgetDraft = draft.tokenBudget
        goalEditorSubmissionError = nil
        showGoalEditor = true
    }

    private var goalEditorSheet: some View {
        let style = IntatisThreadStyle.standard(scheme)
        return VStack(alignment: .leading, spacing: 16) {
            Text("Edit Goal")
                .font(IntatisTypography.system(.title2, bold: true))
            Text("Edit the durable objective and its requirements. Enter one success criterion or constraint per line. Leaving token budget empty means no Goal budget. A paused Goal remains paused.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)

            goalTextEditor(
                title: "Objective",
                accessibilityLabel: "Goal objective",
                accessibilityIdentifier:
                    "cowork.goal.editor.objective",
                text: $goalObjectiveDraft,
                minHeight: 90,
                style: style)

            goalTextEditor(
                title: "Success criteria",
                hint: "One per line",
                accessibilityLabel:
                    "Goal success criteria, one per line",
                accessibilityIdentifier:
                    "cowork.goal.editor.success_criteria",
                text: $goalSuccessCriteriaDraft,
                minHeight: 82,
                style: style)

            goalTextEditor(
                title: "Constraints",
                hint: "One per line",
                accessibilityLabel:
                    "Goal constraints, one per line",
                accessibilityIdentifier:
                    "cowork.goal.editor.constraints",
                text: $goalConstraintsDraft,
                minHeight: 82,
                style: style)

            VStack(alignment: .leading, spacing: 6) {
                Text("Token budget (optional)")
                    .font(IntatisTypography.system(
                        .caption,
                        bold: true))
                TextField(
                    "No budget",
                    text: $goalTokenBudgetDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityLabel(
                        "Optional positive Goal token budget")
                    .accessibilityIdentifier(
                        "cowork.goal.editor.token_budget")
            }

            if let validationMessage =
                goalEditorValidationMessage
            {
                Label(
                    validationMessage,
                    systemImage:
                        "exclamationmark.triangle.fill")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(
                        horizontal: false,
                        vertical: true)
                    .accessibilityIdentifier(
                        "cowork.goal.editor.validation")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    showGoalEditor = false
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(
                    "cowork.goal.editor.cancel")
                Button("Save") {
                    guard let onSaveGoal = actions.onSaveGoal else {
                        return
                    }
                    if let error = onSaveGoal(
                        goalObjectiveDraft,
                        goalSuccessCriteriaDraft,
                        goalConstraintsDraft,
                        goalTokenBudgetDraft)
                    {
                        goalEditorSubmissionError = error
                        return
                    }
                    showGoalEditor = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    goalEditorValidationMessage != nil)
                .accessibilityIdentifier(
                    "cowork.goal.editor.save")
            }
        }
        .padding(22)
        .frame(width: 580)
        .accessibilityIdentifier("cowork.goal.editor")
        .onChange(of: goalObjectiveDraft) { _, _ in
            goalEditorSubmissionError = nil
        }
        .onChange(of: goalSuccessCriteriaDraft) { _, _ in
            goalEditorSubmissionError = nil
        }
        .onChange(of: goalConstraintsDraft) { _, _ in
            goalEditorSubmissionError = nil
        }
        .onChange(of: goalTokenBudgetDraft) { _, _ in
            goalEditorSubmissionError = nil
        }
    }

    private func goalTextEditor(
        title: String,
        hint: String? = nil,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        text: Binding<String>,
        minHeight: CGFloat,
        style: IntatisThreadStyle
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(IntatisTypography.system(
                        .caption,
                        bold: true))
                if let hint {
                    Spacer()
                    Text(hint)
                        .font(IntatisTypography.system(
                            .caption2))
                        .foregroundStyle(.tertiary)
                }
            }
            TextEditor(text: text)
                .font(IntatisTypography.system(.body))
                .frame(minWidth: 500, minHeight: minHeight)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(style.stroke, lineWidth: 1)
                }
                .accessibilityLabel(accessibilityLabel)
                .accessibilityIdentifier(
                    accessibilityIdentifier)
        }
    }
}

private struct IntatisCoworkInferenceAccessory: View {
    let options: [IntatisCoworkInferenceOption]
    let selectedBinding: AgentInferenceBinding?
    let isDisabled: Bool
    let onSelect: (AgentInferenceBinding) -> Void
    @Environment(\.colorScheme) private var scheme

    private var selectedOption:
        IntatisCoworkInferenceOption?
    {
        guard let selectedBinding else { return nil }
        return options.first {
            $0.binding == selectedBinding
        }
    }

    private var modelLabel: String {
        selectedOption?.modelTitle
            ?? IntatisLocalization.string(
                "Inference unavailable")
    }

    private var menuProviders: [ProviderModelMenuProvider] {
        Dictionary(grouping: options, by: \.providerID)
            .compactMap { providerID, providerOptions in
                guard let first = providerOptions.first else {
                    return nil
                }
                return ProviderModelMenuProvider(
                    id: providerID,
                    title: first.providerTitle,
                    models: providerOptions.map { option in
                        ProviderModelMenuModel(
                            id: option.id,
                            modelID: option.modelID,
                            variantID: option.variantID,
                            title: option.modelTitle,
                            detail: option.variantTitle)
                    })
            }
            .sorted { lhs, rhs in
                [lhs.title, lhs.id]
                    .lexicographicallyPrecedes(
                        [rhs.title, rhs.id])
            }
    }

    var body: some View {
        let style = IntatisThreadStyle.standard(scheme)
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID:
                selectedOption?.providerID ?? "",
            selectedModelID:
                selectedOption?.modelID ?? "",
            selectedVariantID:
                selectedOption?.variantID,
            isBusy: isDisabled || options.isEmpty,
            onSelect: {
                providerID,
                modelID,
                variantID in
                guard let option = options.first(where: {
                    $0.providerID == providerID
                        && $0.modelID == modelID
                        && $0.variantID == variantID
                }) else { return }
                onSelect(option.binding)
            }
        ) {
            HStack(spacing: 8) {
                Text(modelLabel)
                    .font(IntatisTypography.body(
                        13,
                        .semibold))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(IntatisTypography.system(
                        size: 10,
                        weight: .semibold))
                    .foregroundStyle(style.tertiaryText)
                    .accessibilityHidden(true)
            }
            .intatisComposerSelectionLabel()
        }
        .intatisComposerSelectionMenu()
        .help(helpText)
        .accessibilityLabel(Text(IntatisLocalization.format(
            "Next @main model: %@",
            modelLabel)))
        .accessibilityIdentifier(
            "cowork.main.inference-profile")
    }

    private var helpText: String {
        if options.isEmpty {
            return IntatisLocalization.string(
                "No configured inference profiles are available")
        }
        if isDisabled {
            return IntatisLocalization.string(
                "@main must be attached before selecting its next model")
        }
        return IntatisLocalization.string(
            "Model for the next @main message. Current work and other agents keep their existing models.")
    }
}

private struct IntatisCoworkPendingContextControl: View {
    let count: Int
    let onCancel: () -> Void

    var body: some View {
        if count > 0 {
            Menu {
                Text(
                    count == 1
                        ? IntatisLocalization.string(
                            "1 untrusted MCP context item will be attached to the next message only.")
                        : IntatisLocalization.format(
                            "%lld untrusted MCP context items will be attached to the next message only.",
                            Int64(count)))
                Button(
                    "Remove Pending MCP Context",
                    role: .destructive,
                    action: onCancel)
            } label: {
                Label(
                    IntatisLocalization.format(
                        "%lld MCP",
                        Int64(count)),
                    systemImage: "text.badge.checkmark")
            }
            .help(
                "Review or remove untrusted MCP context staged for the next message")
            .accessibilityIdentifier(
                "mcp.pending-external-context")
        }
    }
}
#endif
