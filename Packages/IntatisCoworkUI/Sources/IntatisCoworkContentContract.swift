#if canImport(SwiftUI)
import Foundation
import IntatisConversation
import IntatisCore
import IntatisProtocol
import IntatisSharedUI

/// Source-level compatibility marker for the reusable, presentation-only
/// Cowork content pane.
///
/// This module deliberately owns no session, runtime, provider, workspace,
/// MCP, permission engine, or dynamic-tool registration. Those remain with
/// the embedding host.
public enum IntatisCoworkUIContract {
    public static let publicAPIMajorVersion = 1
}

/// Secret-free presentation identity for one selectable inference profile.
public struct IntatisCoworkInferenceOption:
    Identifiable, Equatable, Sendable
{
    public let binding: AgentInferenceBinding
    public let providerID: String
    public let providerTitle: String
    public let modelID: String
    public let modelTitle: String
    public let variantID: String?
    public let variantTitle: String?

    public var id: String {
        let ref = binding.inferenceProfileRef
        return "\(ref.inferenceProfileID.rawValue)\u{001F}\(ref.inferenceProfileRevision.rawValue)"
    }

    public init(
        binding: AgentInferenceBinding,
        providerID: String,
        providerTitle: String,
        modelID: String,
        modelTitle: String,
        variantID: String? = nil,
        variantTitle: String? = nil
    ) {
        self.binding = binding
        self.providerID = providerID
        self.providerTitle = providerTitle
        self.modelID = modelID
        self.modelTitle = modelTitle
        self.variantID = variantID
        self.variantTitle = variantTitle
    }
}

/// Pure presentation state for the complete Cowork right-hand content pane.
/// Every value is supplied by the host that already owns the active session.
public struct IntatisCoworkContentState {
    public var sessionID: SessionID
    public var sessionTitle: String
    public var agents: [CoworkAgentInfo]
    public var pendingPermission: PendingPermission?
    public var permissionNotice: PermissionResolutionNotice?
    public var summary: CoworkStatusSummary
    public var project: CoworkProjectInfo
    public var goal: CoworkGoalCardInfo?
    public var workTasks: CoworkWorkTaskSummary
    public var errorTexts: [String]
    public var isWorking: Bool
    public var isAcceptingSubmission: Bool
    public var draftAttachments: [IntatisComposerDraftAttachment]
    public var inferenceOptions: [IntatisCoworkInferenceOption]
    public var selectedInferenceBinding: AgentInferenceBinding?
    public var pendingMCPExternalContextCount: Int
    public var voice: IntatisCoworkVoicePresentation
    public var pendingUserInput: IntatisUserInputPresentation?

    public init(
        sessionID: SessionID,
        sessionTitle: String,
        agents: [CoworkAgentInfo],
        pendingPermission: PendingPermission?,
        permissionNotice: PermissionResolutionNotice? = nil,
        summary: CoworkStatusSummary,
        project: CoworkProjectInfo,
        goal: CoworkGoalCardInfo? = nil,
        workTasks: CoworkWorkTaskSummary = CoworkWorkTaskSummary(),
        errorTexts: [String] = [],
        isWorking: Bool,
        isAcceptingSubmission: Bool,
        draftAttachments: [IntatisComposerDraftAttachment] = [],
        inferenceOptions: [IntatisCoworkInferenceOption] = [],
        selectedInferenceBinding: AgentInferenceBinding? = nil,
        pendingMCPExternalContextCount: Int = 0,
        voice: IntatisCoworkVoicePresentation = .unavailable,
        pendingUserInput: IntatisUserInputPresentation? = nil
    ) {
        self.sessionID = sessionID
        self.sessionTitle = sessionTitle
        self.agents = agents
        self.pendingPermission = pendingPermission
        self.permissionNotice = permissionNotice
        self.summary = summary
        self.project = project
        self.goal = goal
        self.workTasks = workTasks
        self.errorTexts = errorTexts
        self.isWorking = isWorking
        self.isAcceptingSubmission = isAcceptingSubmission
        self.draftAttachments = draftAttachments
        self.inferenceOptions = inferenceOptions
        self.selectedInferenceBinding = selectedInferenceBinding
        self.pendingMCPExternalContextCount =
            max(0, pendingMCPExternalContextCount)
        self.voice = voice
        self.pendingUserInput = pendingUserInput
    }
}

public struct IntatisCoworkVoicePresentation: Equatable, Sendable {
    public var systemImage: String
    public var help: String
    public var showsProgress: Bool
    public var isToggleDisabled: Bool
    public var isRecording: Bool
    public var isEngaged: Bool

    public static let unavailable = IntatisCoworkVoicePresentation(
        systemImage: "mic",
        help: IntatisLocalization.string("Voice input is unavailable"),
        showsProgress: false,
        isToggleDisabled: true,
        isRecording: false,
        isEngaged: false)

    public init(
        systemImage: String,
        help: String,
        showsProgress: Bool,
        isToggleDisabled: Bool,
        isRecording: Bool,
        isEngaged: Bool
    ) {
        self.systemImage = systemImage
        self.help = help
        self.showsProgress = showsProgress
        self.isToggleDisabled = isToggleDisabled
        self.isRecording = isRecording
        self.isEngaged = isEngaged
    }
}

public struct IntatisCoworkGoalEditDraft: Equatable, Sendable {
    public var objective: String
    public var successCriteria: String
    public var constraints: String
    public var tokenBudget: String

    public init(
        objective: String,
        successCriteria: String,
        constraints: String,
        tokenBudget: String
    ) {
        self.objective = objective
        self.successCriteria = successCriteria
        self.constraints = constraints
        self.tokenBudget = tokenBudget
    }
}

/// Existing host-owned thread source. The UI observes it but never creates or
/// replaces the underlying session.
public struct IntatisCoworkThreadSource {
    public let loadSnapshot:
        CoworkAgentThreadPresentationModel.SnapshotLoader
    public let updates:
        CoworkAgentThreadPresentationModel.UpdateStream

    public init(
        loadSnapshot: @escaping
            CoworkAgentThreadPresentationModel.SnapshotLoader,
        updates: @escaping
            CoworkAgentThreadPresentationModel.UpdateStream
    ) {
        self.loadSnapshot = loadSnapshot
        self.updates = updates
    }
}

/// Host actions invoked by the presentation-only Cowork content view.
public struct IntatisCoworkContentActions {
    public var onShowSessions: (() -> Void)?
    public var onNewSession: (() -> Void)?
    public var onSessionDidBecomeReady: (() -> Void)?
    public var onSelectInference: ((AgentInferenceBinding) -> Void)?
    public var onCancelPendingMCPContext: (() -> Void)?
    public var onImportAttachments: (([URL]) -> Void)?
    public var onAttachmentImportFailure: ((Error) -> Void)?
    public var onRemoveAttachment:
        ((IntatisComposerDraftAttachment.ID) -> Void)?
    public var onToggleVoice: (() -> Void)?
    public var onSend: () -> Void
    public var onCancelCurrent: (() -> Void)?
    public var onResolvePermission: (PermissionResponseAction) -> Void
    public var onRemoveAgent: ((String) -> Void)?
    public var onRetryTask: ((String) -> Void)?
    public var onRetrySubmission: ((SubmissionID) -> Void)?
    public var onPauseGoal: (() -> Void)?
    public var onResumeGoal: (() -> Void)?
    public var goalEditDraft:
        (() -> IntatisCoworkGoalEditDraft?)?
    public var onSaveGoal:
        ((_ objective: String,
          _ successCriteria: String,
          _ constraints: String,
          _ tokenBudget: String) -> String?)?
    public var onClearGoal: (() -> Void)?
    public var onSubmitUserInput:
        ((IntatisUserInputSubmission) -> Void)?

    public init(
        onShowSessions: (() -> Void)? = nil,
        onNewSession: (() -> Void)? = nil,
        onSessionDidBecomeReady: (() -> Void)? = nil,
        onSelectInference:
            ((AgentInferenceBinding) -> Void)? = nil,
        onCancelPendingMCPContext: (() -> Void)? = nil,
        onImportAttachments: (([URL]) -> Void)? = nil,
        onAttachmentImportFailure: ((Error) -> Void)? = nil,
        onRemoveAttachment:
            ((IntatisComposerDraftAttachment.ID) -> Void)? = nil,
        onToggleVoice: (() -> Void)? = nil,
        onSend: @escaping () -> Void,
        onCancelCurrent: (() -> Void)? = nil,
        onResolvePermission:
            @escaping (PermissionResponseAction) -> Void,
        onRemoveAgent: ((String) -> Void)? = nil,
        onRetryTask: ((String) -> Void)? = nil,
        onRetrySubmission: ((SubmissionID) -> Void)? = nil,
        onPauseGoal: (() -> Void)? = nil,
        onResumeGoal: (() -> Void)? = nil,
        goalEditDraft:
            (() -> IntatisCoworkGoalEditDraft?)? = nil,
        onSaveGoal:
            ((
                String,
                String,
                String,
                String
            ) -> String?)? = nil,
        onClearGoal: (() -> Void)? = nil,
        onSubmitUserInput:
            ((IntatisUserInputSubmission) -> Void)? = nil
    ) {
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.onSessionDidBecomeReady = onSessionDidBecomeReady
        self.onSelectInference = onSelectInference
        self.onCancelPendingMCPContext =
            onCancelPendingMCPContext
        self.onImportAttachments = onImportAttachments
        self.onAttachmentImportFailure =
            onAttachmentImportFailure
        self.onRemoveAttachment = onRemoveAttachment
        self.onToggleVoice = onToggleVoice
        self.onSend = onSend
        self.onCancelCurrent = onCancelCurrent
        self.onResolvePermission = onResolvePermission
        self.onRemoveAgent = onRemoveAgent
        self.onRetryTask = onRetryTask
        self.onRetrySubmission = onRetrySubmission
        self.onPauseGoal = onPauseGoal
        self.onResumeGoal = onResumeGoal
        self.goalEditDraft = goalEditDraft
        self.onSaveGoal = onSaveGoal
        self.onClearGoal = onClearGoal
        self.onSubmitUserInput = onSubmitUserInput
    }
}
#endif
