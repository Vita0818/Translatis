#if canImport(SwiftUI)
import Foundation
import SwiftUI
import IntatisCore
import IntatisProtocol
import IntatisConversation

private func intatisNormalizedStatus(_ status: String) -> String {
    status
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
        .lowercased()
}

private func intatisLocalizedRawStatus(_ status: String) -> String {
    switch intatisNormalizedStatus(status) {
    case "idle": return IntatisLocalization.string("idle")
    case "active": return IntatisLocalization.string("active")
    case "running": return IntatisLocalization.string("running")
    case "thinking": return IntatisLocalization.string("thinking")
    case "tool": return IntatisLocalization.string("tool")
    case "assigned": return IntatisLocalization.string("assigned")
    case "paused": return IntatisLocalization.string("paused")
    case "pending": return IntatisLocalization.string("pending")
    case "queued": return IntatisLocalization.string("queued")
    case "ready": return IntatisLocalization.string("ready")
    case "mailbox": return IntatisLocalization.string("mailbox")
    case "completed", "complete", "done":
        return IntatisLocalization.string("completed")
    case "failed": return IntatisLocalization.string("failed")
    case "error": return IntatisLocalization.string("error")
    case "rejected": return IntatisLocalization.string("rejected")
    case "blocked": return IntatisLocalization.string("blocked")
    case "budget_limited": return IntatisLocalization.string("budget limited")
    case "usage_limited": return IntatisLocalization.string("usage limited")
    case "in_progress", "inprogress":
        return IntatisLocalization.string("in progress")
    case "cancelled", "canceled":
        return IntatisLocalization.string("cancelled")
    case "detached", "removed", "cleaned":
        return IntatisLocalization.string("detached")
    default: return status
    }
}

private func intatisLocalizedDisplayStatus(_ status: String) -> String {
    switch intatisNormalizedStatus(status) {
    case "idle": return IntatisLocalization.string("Idle")
    case "active": return IntatisLocalization.string("Active")
    case "running": return IntatisLocalization.string("Running")
    case "thinking": return IntatisLocalization.string("Thinking")
    case "tool": return IntatisLocalization.string("Tool")
    case "assigned": return IntatisLocalization.string("Assigned")
    case "paused": return IntatisLocalization.string("Paused")
    case "pending": return IntatisLocalization.string("Pending")
    case "queued": return IntatisLocalization.string("Queued")
    case "ready": return IntatisLocalization.string("Ready")
    case "mailbox": return IntatisLocalization.string("Mailbox")
    case "completed", "complete", "done":
        return IntatisLocalization.string("Completed")
    case "failed": return IntatisLocalization.string("Failed")
    case "error": return IntatisLocalization.string("Error")
    case "rejected": return IntatisLocalization.string("Rejected")
    case "blocked": return IntatisLocalization.string("Blocked")
    case "budget_limited": return IntatisLocalization.string("Budget Limited")
    case "usage_limited": return IntatisLocalization.string("Usage Limited")
    case "in_progress", "inprogress":
        return IntatisLocalization.string("In Progress")
    case "cancelled", "canceled":
        return IntatisLocalization.string("Cancelled")
    case "detached", "removed", "cleaned":
        return IntatisLocalization.string("Detached")
    default:
        let display = status
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
        return IntatisLocalization.string(display)
    }
}

private func intatisLocalizedAgentRole(_ role: String) -> String {
    switch role.lowercased() {
    case "main": return IntatisLocalization.string("main")
    case "coordinator": return IntatisLocalization.string("coordinator")
    case "worker": return IntatisLocalization.string("worker")
    case "reviewer": return IntatisLocalization.string("reviewer")
    default: return role
    }
}

public enum CoworkInferenceResolution: String, Codable, Equatable, Sendable {
    /// A legacy projection has no durable inference binding to resolve yet.
    case legacy
    case resolved
    case unresolved
    case incompatible

    public var requiresAttention: Bool {
        self != .resolved
    }
}

public struct CoworkAgentInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let workspace: String
    public let model: String
    public let permissionProfile: String
    public let inferenceProfileLabel: String?
    public let inferenceProfileRef: InferenceProfileRef?
    public let inferenceConnectionLabel: String?
    public let inferenceVariant: String?
    public let inferenceResolution: CoworkInferenceResolution
    public let status: String
    public let role: String
    public let pendingTasks: Int
    public let pendingMessages: Int
    public let completedTasks: Int
    public let workspaceLease: String?
    public let capabilityLease: String?
    /// Whether this historical identity is still present in the runtime's live
    /// roster. Detached agents remain conversation-selectable but expose no
    /// runtime mutation actions.
    public let isAttached: Bool
    public let canRemove: Bool
    public let isConversationSelectable: Bool

    /// Compatibility alias for callers compiled before inference profiles made
    /// the permission/inference distinction explicit.
    public var profile: String { permissionProfile }

    public init(id: String,
                name: String,
                workspace: String,
                model: String,
                permissionProfile: String,
                inferenceProfileLabel: String? = nil,
                inferenceProfileRef: InferenceProfileRef? = nil,
                inferenceConnectionLabel: String? = nil,
                inferenceVariant: String? = nil,
                inferenceResolution: CoworkInferenceResolution = .legacy,
                status: String = "idle",
                role: String = "worker",
                pendingTasks: Int = 0,
                pendingMessages: Int = 0,
                completedTasks: Int = 0,
                workspaceLease: String? = nil,
                capabilityLease: String? = nil,
                isAttached: Bool = true,
                canRemove: Bool = true,
                isConversationSelectable: Bool = true) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.model = model
        self.permissionProfile = permissionProfile
        self.inferenceProfileLabel = inferenceProfileLabel
        self.inferenceProfileRef = inferenceProfileRef
        self.inferenceConnectionLabel = inferenceConnectionLabel
        self.inferenceVariant = inferenceVariant
        self.inferenceResolution = inferenceResolution
        self.status = status
        self.role = role
        self.pendingTasks = pendingTasks
        self.pendingMessages = pendingMessages
        self.completedTasks = completedTasks
        self.workspaceLease = workspaceLease
        self.capabilityLease = capabilityLease
        self.isAttached = isAttached
        self.canRemove = canRemove
        self.isConversationSelectable = isConversationSelectable
    }

    /// Source-compatible initializer for the existing CoworkViewModel. New
    /// call sites should use `permissionProfile:` and the inference fields.
    public init(id: String,
                name: String,
                workspace: String,
                model: String,
                profile: String,
                status: String = "idle",
                role: String = "worker",
                pendingTasks: Int = 0,
                pendingMessages: Int = 0,
                completedTasks: Int = 0,
                workspaceLease: String? = nil,
                capabilityLease: String? = nil,
                isAttached: Bool = true,
                canRemove: Bool = true,
                isConversationSelectable: Bool = true) {
        self.init(
            id: id,
            name: name,
            workspace: workspace,
            model: model,
            permissionProfile: profile,
            status: status,
            role: role,
            pendingTasks: pendingTasks,
            pendingMessages: pendingMessages,
            completedTasks: completedTasks,
            workspaceLease: workspaceLease,
            capabilityLease: capabilityLease,
            isAttached: isAttached,
            canRemove: canRemove,
            isConversationSelectable: isConversationSelectable)
    }

    public var statusLine: String {
        let queued = pendingTasks + pendingMessages
        if queued > 0 {
            return IntatisLocalization.format(
                "%@ · %lld queued",
                intatisLocalizedRawStatus(status),
                Int64(queued))
        }
        if completedTasks > 0 {
            return IntatisLocalization.format(
                "%@ · %lld completed",
                intatisLocalizedRawStatus(status),
                Int64(completedTasks))
        }
        return intatisLocalizedRawStatus(status)
    }

    /// Safe secondary roster text. Raw endpoints, raw request options, profile
    /// identifiers, and credential references are never inputs to this string.
    public var inferenceDisplayLabel: String? {
        switch inferenceResolution {
        case .unresolved:
            return IntatisLocalization.string("Inference unavailable")
        case .incompatible:
            return IntatisLocalization.string("Inference incompatible")
        case .legacy, .resolved:
            break
        }

        if let explicit = Self.safeInferenceComponent(inferenceProfileLabel) {
            return explicit
        }
        let components = [
            Self.safeInferenceComponent(inferenceConnectionLabel),
            Self.safeInferenceComponent(model),
            Self.safeInferenceComponent(inferenceVariant),
        ].compactMap { $0 }
        if !components.isEmpty {
            let label = components.joined(separator: " · ")
            return inferenceResolution == .legacy
                ? IntatisLocalization.format("Legacy · %@", label)
                : label
        }
        return inferenceResolution == .resolved
            ? IntatisLocalization.string("Inference resolved")
            : IntatisLocalization.string("Legacy inference")
    }

    private static func safeInferenceComponent(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !lower.contains("://"),
              !lower.hasPrefix("www."),
              !lower.hasPrefix("file:"),
              !lower.hasPrefix("data:"),
              !lower.hasPrefix("bearer "),
              !lower.hasPrefix("basic "),
              !lower.hasPrefix("sk-"),
              !lower.hasPrefix("ghp_"),
              !lower.hasPrefix("github_pat_"),
              !lower.hasPrefix("glpat-"),
              !lower.hasPrefix("xox"),
              !lower.contains("api_key="),
              !lower.contains("apikey="),
              !lower.contains("access_token="),
              !lower.contains("-----begin ") else {
            return nil
        }
        return String(trimmed.prefix(96))
    }
}

public struct CoworkTaskLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let status: String

    public init(id: String, title: String, detail: String, status: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
    }
}

/// Product-level Goal presentation for Cowork. This is deliberately separate
/// from `CoworkTaskLine`, which still describes execution-layer task activity.
/// A caller may therefore migrate the durable Goal projection independently
/// without making an AgentInvocation look like a user-owned Goal.
public struct CoworkGoalCardInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let objective: String
    public let status: String
    public let activeElapsedSeconds: Double
    public let activeSince: Date?
    public let tokensUsed: Int
    public let tokenBudget: Int?
    public let auditProvenCount: Int?
    public let auditRequirementCount: Int?
    public let latestAuditSummary: String?
    public let currentRunOrdinal: Int?
    public let revision: Int
    public let canPause: Bool
    public let canResume: Bool
    public let canEdit: Bool
    public let canClear: Bool

    public init(id: String,
                objective: String,
                status: String,
                activeElapsedSeconds: Double = 0,
                activeSince: Date? = nil,
                tokensUsed: Int = 0,
                tokenBudget: Int? = nil,
                auditProvenCount: Int? = nil,
                auditRequirementCount: Int? = nil,
                latestAuditSummary: String? = nil,
                currentRunOrdinal: Int? = nil,
                revision: Int = 0,
                canPause: Bool = false,
                canResume: Bool = false,
                canEdit: Bool = true,
                canClear: Bool = true) {
        self.id = id
        self.objective = objective
        self.status = status
        self.activeElapsedSeconds = max(activeElapsedSeconds, 0)
        self.activeSince = activeSince
        self.tokensUsed = max(tokensUsed, 0)
        self.tokenBudget = tokenBudget
        self.auditProvenCount = auditProvenCount
        self.auditRequirementCount = auditRequirementCount
        self.latestAuditSummary = latestAuditSummary
        self.currentRunOrdinal = currentRunOrdinal
        self.revision = revision
        self.canPause = canPause
        self.canResume = canResume
        self.canEdit = canEdit
        self.canClear = canClear
    }

    public func elapsedSeconds(at date: Date) -> Double {
        guard normalizedStatus == "active", let activeSince else {
            return activeElapsedSeconds
        }
        return activeElapsedSeconds + max(date.timeIntervalSince(activeSince), 0)
    }

    public var normalizedStatus: String {
        status
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }
}

/// Product-level WorkTask presentation. It intentionally contains no
/// execution status aliases: linked AgentInvocation IDs live in the detail
/// disclosure while the row itself represents the durable work item.
public struct CoworkWorkTaskLine: Identifiable, Equatable, Sendable {
    public let id: String
    public let ordinal: Int?
    public let title: String
    public let detail: String
    public let status: String
    public let dependencySummary: String?
    public let statusReason: String?
    public let acceptanceCriteria: [String]
    public let result: String?
    public let evidence: [String]
    public let linkedInvocationIDs: [String]

    public init(id: String,
                ordinal: Int? = nil,
                title: String,
                detail: String = "",
                status: String,
                dependencySummary: String? = nil,
                statusReason: String? = nil,
                acceptanceCriteria: [String] = [],
                result: String? = nil,
                evidence: [String] = [],
                linkedInvocationIDs: [String] = []) {
        self.id = id
        self.ordinal = ordinal
        self.title = title
        self.detail = detail
        self.status = status
        self.dependencySummary = dependencySummary
        self.statusReason = statusReason
        self.acceptanceCriteria = acceptanceCriteria
        self.result = result
        self.evidence = evidence
        self.linkedInvocationIDs = linkedInvocationIDs
    }

    public var normalizedStatus: String {
        status
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    public var isCompleted: Bool {
        ["completed", "complete", "done"].contains(normalizedStatus)
    }

    public var hasExpandedDetails: Bool {
        !detail.isEmpty
            || dependencySummary != nil
            || statusReason != nil
            || !acceptanceCriteria.isEmpty
            || result != nil
            || !evidence.isEmpty
            || !linkedInvocationIDs.isEmpty
    }
}

public struct CoworkWorkTaskSummary: Equatable, Sendable {
    public let tasks: [CoworkWorkTaskLine]

    public init(tasks: [CoworkWorkTaskLine] = []) {
        self.tasks = tasks
    }

    public var totalCount: Int { tasks.count }
    public var completedCount: Int { tasks.filter(\.isCompleted).count }
    public var runningCount: Int {
        tasks.filter { ["in_progress", "inprogress", "running"].contains($0.normalizedStatus) }.count
    }
}

public struct CoworkWorkspaceInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let path: String
    public let displayName: String
    public let agentName: String?
    public let isPrimary: Bool
    public let access: String
    public let canRemove: Bool

    public init(path: String,
                displayName: String,
                agentName: String? = nil,
                isPrimary: Bool = false,
                access: String = "read_write",
                canRemove: Bool = true) {
        self.id = path
        self.path = path
        self.displayName = displayName
        self.agentName = agentName
        self.isPrimary = isPrimary
        self.access = access
        self.canRemove = canRemove
    }
}

private enum CoworkInspectorTab: String, CaseIterable, Identifiable {
    case agents
    case tasks
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: return IntatisLocalization.string("Agents")
        case .tasks: return IntatisLocalization.string("Tasks")
        case .context: return IntatisLocalization.string("Context")
        }
    }
}

public struct CoworkProjectInfo: Equatable, Sendable {
    public let sessionID: String
    public let mainAgentName: String
    public let defaultModel: String
    public let defaultPermission: String
    public let tokenBudget: String?
    public let workspaces: [CoworkWorkspaceInfo]

    public init(sessionID: String = "",
                mainAgentName: String = "main",
                defaultModel: String = IntatisLocalization.string("current model"),
                defaultPermission: String = IntatisLocalization.string("reviewed"),
                tokenBudget: String? = nil,
                workspaces: [CoworkWorkspaceInfo] = []) {
        self.sessionID = sessionID
        self.mainAgentName = mainAgentName
        self.defaultModel = defaultModel
        self.defaultPermission = defaultPermission
        self.tokenBudget = tokenBudget
        self.workspaces = workspaces
    }
}

public struct CoworkStatusSummary: Equatable, Sendable {
    public let activeCount: Int
    public let runningCount: Int
    public let completedCount: Int
    public let failedCount: Int
    public let pendingMailboxCount: Int
    public let completedMailboxCount: Int
    public let workspaceLeaseCount: Int
    public let capabilityLeaseCount: Int
    public let runningTasks: [CoworkTaskLine]
    public let failedTasks: [CoworkTaskLine]
    public let recentCompletedTasks: [CoworkTaskLine]

    public init(activeCount: Int = 0,
                runningCount: Int = 0,
                completedCount: Int = 0,
                failedCount: Int = 0,
                pendingMailboxCount: Int = 0,
                completedMailboxCount: Int = 0,
                workspaceLeaseCount: Int = 0,
                capabilityLeaseCount: Int = 0,
                runningTasks: [CoworkTaskLine] = [],
                failedTasks: [CoworkTaskLine] = [],
                recentCompletedTasks: [CoworkTaskLine] = []) {
        self.activeCount = activeCount
        self.runningCount = runningCount
        self.completedCount = completedCount
        self.failedCount = failedCount
        self.pendingMailboxCount = pendingMailboxCount
        self.completedMailboxCount = completedMailboxCount
        self.workspaceLeaseCount = workspaceLeaseCount
        self.capabilityLeaseCount = capabilityLeaseCount
        self.runningTasks = runningTasks
        self.failedTasks = failedTasks
        self.recentCompletedTasks = recentCompletedTasks
    }
}

/// Only state rendered by the trailing status rail belongs in this snapshot.
/// Transcript paging, loading and rich-rendering admission intentionally stay
/// out so those high-frequency updates cannot rematerialize Liquid Glass.
struct CoworkStatusRailRenderSnapshot: Equatable {
    let agents: [CoworkAgentInfo]
    let pending: PendingPermission?
    let permissionNotice: PermissionResolutionNotice?
    let goal: CoworkGoalCardInfo?
    let workTasks: CoworkWorkTaskSummary
    let errors: [IntatisThreadErrorEntry]
    let colorScheme: ColorScheme
}

/// Selection is intentionally not part of the rail render snapshot. Updating
/// it must repaint only the selected-row affordance; rebuilding the rail would
/// make every native Glass backdrop reacquire its optical phase on each click.
private final class CoworkStatusRailSelectionState: ObservableObject {
    @Published private(set) var selectedAgentID: String

    init(selectedAgentID: String) {
        self.selectedAgentID = selectedAgentID
    }

    func update(_ selectedAgentID: String) {
        guard self.selectedAgentID != selectedAgentID else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            self.selectedAgentID = selectedAgentID
        }
    }
}

private struct CoworkAgentSelectionBackground: View {
    @ObservedObject var selection: CoworkStatusRailSelectionState
    let agentID: String
    let accent: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(accent.opacity(0.16))
            .opacity(selection.selectedAgentID == agentID ? 1 : 0)
    }
}

private struct CoworkAgentSelectionAccessibilityModifier: ViewModifier {
    @ObservedObject var selection: CoworkStatusRailSelectionState
    let agentID: String

    func body(content: Content) -> some View {
        content.accessibilityValue(
            selection.selectedAgentID == agentID
                ? IntatisLocalization.string("Selected")
                : IntatisLocalization.string("Not selected"))
    }
}

/// SwiftUI otherwise walks the rail again whenever its transcript sibling
/// publishes an empty/loading/loaded/rich state. This boundary keeps the
/// existing rail subtree mounted until an actual rail input changes.
private struct CoworkStatusRailRenderBoundary<Content: View>: View, Equatable {
    let snapshot: CoworkStatusRailRenderSnapshot
    let content: () -> Content

    init(
        snapshot: CoworkStatusRailRenderSnapshot,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.snapshot = snapshot
        self.content = content
    }

    static func == (
        lhs: CoworkStatusRailRenderBoundary<Content>,
        rhs: CoworkStatusRailRenderBoundary<Content>
    ) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    var body: some View {
        content()
    }
}

/// Presentational Cowork project thread: the user gives work to Main, while
/// the roster/inspector exposes the sub-agent activity Main schedules.
public struct CoworkShell: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.intatisWindowContentWidth) private var windowContentWidth

    private let threadSnapshot: CoworkAgentThreadSnapshot
    private let displayedThreadItems: [CodeItem]
    private let presentationScope: IntatisThreadPresentationScope
    private let sessionTitle: String
    private let agents: [CoworkAgentInfo]
    private let pending: PendingPermission?
    private let permissionNotice: PermissionResolutionNotice?
    private let summary: CoworkStatusSummary
    private let project: CoworkProjectInfo
    private let goal: CoworkGoalCardInfo?
    private let workTasks: CoworkWorkTaskSummary
    private let errorTexts: [String]
    private let isWorking: Bool
    private let isAcceptingSubmission: Bool
    private let hasDraftAttachments: Bool
    private let threadStyle: IntatisThreadStyle
    private let onShowSessions: (() -> Void)?
    private let onNewSession: (() -> Void)?
    private let onShowProjectSettings: (() -> Void)?
    private let composerAccessory: AnyView?
    private let composerInputAccessory: AnyView?
    private let composerTrailingAction:
        IntatisThreadComposerSecondaryAction?
    private let headerActions: [IntatisThreadHeaderAction]
    @Binding private var input: String
    private let onSend: () -> Void
    private let onCancelCurrent: (() -> Void)?
    private let onResolve: (PermissionResponseAction) -> Void
    private let onAddAgent: (() -> Void)?
    private let onRemoveAgent: ((String) -> Void)?
    private let onRetryTask: ((String) -> Void)?
    private let onRetrySubmission: ((SubmissionID) -> Void)?
    private let onPauseGoal: (() -> Void)?
    private let onResumeGoal: (() -> Void)?
    private let onEditGoal: (() -> Void)?
    private let onClearGoal: (() -> Void)?
    private let selectedAgentID: String
    private let isThreadSnapshotLoading: Bool
    private let isRichRenderingEligible: Bool
    private let onSelectAgent: (String) -> Void
    private let pendingUserInput: IntatisUserInputPresentation?
    private let onSubmitUserInput:
        ((IntatisUserInputSubmission) -> Void)?
    @State private var inspectorTab: CoworkInspectorTab = .agents
    @Binding private var showsInspector: Bool
    @StateObject private var scrollCoordinator = IntatisThreadScrollCoordinator()
    @StateObject private var statusRailSelection:
        CoworkStatusRailSelectionState

    public init(threadSnapshot: CoworkAgentThreadSnapshot,
                presentationScope: IntatisThreadPresentationScope,
                sessionTitle: String = IntatisLocalization.string("Cowork"),
                thinkingScopeID: String = "cowork",
                agents: [CoworkAgentInfo],
                pending: PendingPermission?,
                permissionNotice: PermissionResolutionNotice? = nil,
                summary: CoworkStatusSummary,
                project: CoworkProjectInfo = CoworkProjectInfo(),
                goal: CoworkGoalCardInfo? = nil,
                workTasks: CoworkWorkTaskSummary = CoworkWorkTaskSummary(),
                errorTexts: [String] = [],
                isWorking: Bool,
                isAcceptingSubmission: Bool = false,
                hasDraftAttachments: Bool = false,
                threadStyle: IntatisThreadStyle = .standard(.light),
                splitLayout: IntatisSplitColumnLayout = .workspace,
                onShowSessions: (() -> Void)? = nil,
                onNewSession: (() -> Void)? = nil,
                onShowProjectSettings: (() -> Void)? = nil,
                composerAccessory: AnyView? = nil,
                composerInputAccessory: AnyView? = nil,
                composerTrailingAction:
                    IntatisThreadComposerSecondaryAction? = nil,
                headerActions: [IntatisThreadHeaderAction] = [],
                showsInspector: Binding<Bool>,
                input: Binding<String>,
                onSend: @escaping () -> Void,
                onCancelCurrent: (() -> Void)? = nil,
                onResolve: @escaping (PermissionResponseAction) -> Void,
                onAddAgent: (() -> Void)? = nil,
                onRemoveAgent: ((String) -> Void)? = nil,
                onRetryTask: ((String) -> Void)? = nil,
                onRetrySubmission: ((SubmissionID) -> Void)? = nil,
                onPauseGoal: (() -> Void)? = nil,
                onResumeGoal: (() -> Void)? = nil,
                onEditGoal: (() -> Void)? = nil,
                onClearGoal: (() -> Void)? = nil,
                selectedAgentID: String,
                isThreadSnapshotLoading: Bool = false,
                isRichRenderingEligible: Bool = true,
                onSelectAgent: @escaping (String) -> Void,
                pendingUserInput: IntatisUserInputPresentation? = nil,
                onSubmitUserInput:
                    ((IntatisUserInputSubmission) -> Void)? = nil) {
        self.threadSnapshot = threadSnapshot
        self.displayedThreadItems =
            IntatisThreadErrorPresentation.transcriptItems(
                IntatisExecutionTracePresentation.displayedItems(
                    threadSnapshot.items))
        self.presentationScope = presentationScope
        self.sessionTitle = sessionTitle
        _ = thinkingScopeID
        self.agents = agents
        self.pending = pending
        self.permissionNotice = permissionNotice
        self.summary = summary
        self.project = project
        self.goal = goal
        self.workTasks = workTasks
        self.errorTexts = errorTexts
        self.isWorking = isWorking
        self.isAcceptingSubmission = isAcceptingSubmission
        self.hasDraftAttachments = hasDraftAttachments
        self.threadStyle = threadStyle
        self.onShowSessions = onShowSessions
        self.onNewSession = onNewSession
        self.onShowProjectSettings = onShowProjectSettings
        self.composerAccessory = composerAccessory
        self.composerInputAccessory = composerInputAccessory
        self.composerTrailingAction = composerTrailingAction
        self.headerActions = headerActions
        self._showsInspector = showsInspector
        self._input = input
        self.onSend = onSend
        self.onCancelCurrent = onCancelCurrent
        self.onResolve = onResolve
        self.onAddAgent = onAddAgent
        self.onRemoveAgent = onRemoveAgent
        self.onRetryTask = onRetryTask
        self.onRetrySubmission = onRetrySubmission
        self.onPauseGoal = onPauseGoal
        self.onResumeGoal = onResumeGoal
        self.onEditGoal = onEditGoal
        self.onClearGoal = onClearGoal
        self.selectedAgentID = selectedAgentID
        self.isThreadSnapshotLoading = isThreadSnapshotLoading
        self.isRichRenderingEligible = isRichRenderingEligible
        self.onSelectAgent = onSelectAgent
        self.pendingUserInput = pendingUserInput
        self.onSubmitUserInput = onSubmitUserInput
        self._statusRailSelection = StateObject(
            wrappedValue: CoworkStatusRailSelectionState(
                selectedAgentID: selectedAgentID))
        _ = splitLayout
    }

    private var permissionBlocksComposer: Bool {
        guard let pending else { return false }
        return pending.state == .livePending || pending.state == .resolving
    }

    private var hasMainAgent: Bool {
        agents.contains { $0.name == project.mainAgentName }
    }

    private var selectedAgent: CoworkAgentInfo? {
        agents.first { $0.id == selectedAgentID }
    }

    private var threadErrors: [IntatisThreadErrorEntry] {
        IntatisThreadErrorPresentation.errors(
            items: threadSnapshot.items,
            errorTexts: errorTexts)
    }

    private var inspectorRenderSnapshot: CoworkStatusRailRenderSnapshot {
        CoworkStatusRailRenderSnapshot(
            agents: agents,
            pending: pending,
            permissionNotice: permissionNotice,
            goal: goal,
            workTasks: workTasks,
            errors: threadErrors,
            colorScheme: colorScheme)
    }

    public var body: some View {
        GeometryReader { proxy in
            content(outerSize: proxy.size)
        }
        .onChange(of: selectedAgentID, initial: true) { _, nextSelection in
            statusRailSelection.update(nextSelection)
        }
    }

    private func content(outerSize: CGSize) -> some View {
        let rawWidth = outerSize.width.isFinite
            ? max(outerSize.width, 1)
            : 1
        let rawHeight = outerSize.height.isFinite
            ? max(outerSize.height, 1)
            : 1
        let inspectorIsPinnedForPermission = pending != nil
        let inspectorLayout = IntatisCoworkStatusRailLayoutPolicy.resolve(
            availableWidth: rawWidth,
            isRequested: showsInspector || inspectorIsPinnedForPermission)
        let trailingStatusRailWidth = inspectorLayout.isVisible
            ? inspectorLayout.inspectorWidth
            : 0
        let primaryScrollerClearance: CGFloat = inspectorLayout.isVisible
            ? IntatisCoworkStatusRailLayoutPolicy.scrollerClearance
            : 0

        // This exact outer canvas, not the transcript's intrinsic size, owns
        // both placements. The thread can change content, scroller state and
        // rendering mode without ever becoming the rail's alignment guide.
        return Color.clear
            .frame(width: rawWidth, height: rawHeight)
            .overlay(alignment: .leading) {
                threadColumn(
                    layout: IntatisThreadContentLayout(
                        rawWidth: inspectorLayout.threadWidth),
                    showsCompactActions: !inspectorLayout.isVisible,
                    inspectorIsAvailable: rawWidth
                        >= IntatisCoworkStatusRailLayoutPolicy.activationWidth,
                    inspectorIsVisible: inspectorLayout.isVisible,
                    showsPermissionFallback: pending != nil
                        && !inspectorLayout.isVisible,
                    trailingStatusRailWidth: trailingStatusRailWidth,
                    jumpHorizontalOffset:
                        IntatisWindowCenteredOverlayLayoutPolicy
                            .horizontalOffset(
                                windowWidth: windowContentWidth,
                                detailWidth: rawWidth,
                                overlaySurfaceWidth: rawWidth))
                    .frame(
                        width: rawWidth,
                        height: rawHeight,
                        alignment: .topLeading)
            }
            .overlay(alignment: .trailing) {
                if inspectorLayout.isVisible {
                    HStack(spacing: 0) {
                        CoworkStatusRailRenderBoundary(
                            snapshot: inspectorRenderSnapshot
                        ) {
                            inspectorColumn
                        }
                        .equatable()
                            .frame(width: max(
                                inspectorLayout.inspectorWidth
                                    - primaryScrollerClearance,
                                1))
                            .frame(maxHeight: .infinity)
                        Color.clear
                            .frame(width: primaryScrollerClearance)
                            .allowsHitTesting(false)
                    }
                    .frame(
                        width: inspectorLayout.inspectorWidth,
                        height: rawHeight,
                        alignment: .top)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
                    .accessibilityIdentifier("cowork.inspector")
                }
            }
    }

    private func threadColumn(layout: IntatisThreadContentLayout,
                              showsCompactActions: Bool,
                              inspectorIsAvailable: Bool,
                              inspectorIsVisible: Bool,
                              showsPermissionFallback: Bool,
                              trailingStatusRailWidth: CGFloat,
                              jumpHorizontalOffset: CGFloat) -> some View {
        VStack(spacing: 0) {
            header(
                layout: layout,
                showsCompactActions: showsCompactActions,
                inspectorIsAvailable: inspectorIsAvailable,
                inspectorIsVisible: inspectorIsVisible)
                .frame(width: layout.rawWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            thread(
                layout: layout,
                trailingContentMargin: trailingStatusRailWidth,
                jumpHorizontalOffset: jumpHorizontalOffset)
            if showsPermissionFallback {
                permissionFallbackArea(layout: layout)
                    .frame(width: layout.rawWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            userInputArea(layout: layout)
                .frame(width: layout.rawWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
            composerArea(layout: layout)
                .frame(width: layout.rawWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(
        layout: IntatisThreadContentLayout,
        showsCompactActions: Bool,
        inspectorIsAvailable: Bool,
        inspectorIsVisible: Bool
    ) -> some View {
        IntatisWorkspaceThreadHeader(
            title: sessionTitle,
            subtitle: nil,
            style: threadStyle,
            actions: resolvedHeaderActions(
                showsCompactActions: showsCompactActions,
                inspectorIsAvailable: inspectorIsAvailable,
                inspectorIsVisible: inspectorIsVisible))
        .frame(maxWidth: layout.contentMaxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private func resolvedHeaderActions(
        showsCompactActions: Bool,
        inspectorIsAvailable: Bool,
        inspectorIsVisible: Bool
    ) -> [IntatisThreadHeaderAction] {
        var actions = headerActions
        if showsCompactActions {
            if let onShowProjectSettings {
                actions.append(IntatisThreadHeaderAction(
                    title: IntatisLocalization.string("Project"),
                    systemImage: "slider.horizontal.3",
                    isDisabled: isWorking,
                    isIconOnly: true,
                    action: onShowProjectSettings))
            }
            if let onAddAgent {
                actions.append(IntatisThreadHeaderAction(
                    title: IntatisLocalization.string("Attach"),
                    systemImage: "person.badge.plus",
                    isIconOnly: true,
                    action: onAddAgent))
            }
        }
        let permissionPinsInspector = pending != nil && inspectorIsVisible
        let inspectorTitle = permissionPinsInspector
            ? IntatisLocalization.string("Permission Review")
            : inspectorIsVisible
                ? IntatisLocalization.string("Hide Inspector")
                : IntatisLocalization.string("Show Inspector")
        actions.append(IntatisThreadHeaderAction(
            title: inspectorTitle,
            systemImage: permissionPinsInspector ? "lock.shield" : "sidebar.right",
            isDisabled: !inspectorIsAvailable || permissionPinsInspector,
            isIconOnly: true,
            presentation: .compactSystemIcon,
            help: inspectorTitle,
            accessibilityIdentifier: "cowork.inspector.toggle") {
                guard inspectorIsAvailable else { return }
                showsInspector.toggle()
            })
        return actions
    }

    private var inspectorColumn: some View {
        ScrollView {
            // These are independent status surfaces, not a morphing control
            // cluster. Keeping them outside GlassEffectContainer prevents
            // focus or selection updates from optically regrouping the cards.
            VStack(
                alignment: .leading,
                spacing: IntatisCoworkStatusRailLayoutPolicy.cardSpacing
            ) {
                if pending != nil || permissionNotice != nil {
                    permissionStatusSection
                }
                agentStatusSection
                if goal != nil {
                    goalCardSection
                }
                if !workTasks.tasks.isEmpty {
                    workTasksSection
                }
                if !threadErrors.isEmpty {
                    rightRailSection("Error Information", systemImage: "exclamationmark.triangle") {
                        IntatisThreadErrorList(
                            errors: threadErrors,
                            style: threadStyle,
                            onRetrySubmission: onRetrySubmission == nil
                                ? nil
                                : retrySubmission)
                    }
                    .accessibilityIdentifier("cowork.error.card")
                }
            }
            .frame(width: IntatisCoworkStatusRailLayoutPolicy.cardWidth)
            .padding(
                .leading,
                IntatisCoworkStatusRailLayoutPolicy.leadingInset)
            .padding(
                .trailing,
                IntatisCoworkStatusRailLayoutPolicy.trailingInset)
            .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder private var permissionStatusSection: some View {
        if let pending {
            PermissionCard(
                permission: pending,
                embedsSurface: false,
                presentationStyle: .compactRail,
                onResolve: onResolve)
                .frame(
                    width: IntatisCoworkStatusRailLayoutPolicy.cardWidth,
                    alignment: .leading)
                .intatisClearLiquidGlass(cornerRadius: 22)
                .accessibilityIdentifier("cowork.permission.review")
        } else if let permissionNotice {
            PermissionResolutionNoticeView(
                notice: permissionNotice,
                embedsSurface: false,
                presentationStyle: .compactRail)
                .frame(
                    width: IntatisCoworkStatusRailLayoutPolicy.cardWidth,
                    alignment: .leading)
                .intatisClearLiquidGlass(cornerRadius: 22)
                .accessibilityIdentifier("cowork.permission.review")
        }
    }

    private var agentStatusSection: some View {
        rightRailSection("Agents", systemImage: "person.2.fill") {
            agentStatusList
        }
    }

    @ViewBuilder private var agentStatusList: some View {
        if agents.isEmpty {
            Text("No agents in this session")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            LazyVStack(alignment: .leading, spacing: 5) {
                ForEach(agents) { agent in
                    agentStatusRow(agent)
                }
            }
        }
    }

    @ViewBuilder
    private func agentStatusRow(_ agent: CoworkAgentInfo) -> some View {
        if agent.isConversationSelectable {
            Button {
                onSelectAgent(agent.id)
            } label: {
                agentStatusRowContent(agent)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(
                "cowork.agent.\(agent.id).conversation")
            .accessibilityLabel(
                IntatisLocalization.format(
                    "View @%@ conversation",
                    agent.name))
            .modifier(CoworkAgentSelectionAccessibilityModifier(
                selection: statusRailSelection,
                agentID: agent.id))
        } else {
            agentStatusRowContent(agent)
                .accessibilityIdentifier(
                    "cowork.agent.\(agent.id).status-only")
        }
    }

    private func agentStatusRowContent(_ agent: CoworkAgentInfo) -> some View {
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: statusIconName(for: agent.status))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(statusColor(for: agent.status))
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text("@\(agent.name)")
                    .font(IntatisTypography.system(.body, weight: .semibold))
                    .foregroundStyle(threadStyle.primaryText)
                    .lineLimit(1)
                if let inferenceLabel = agent.inferenceDisplayLabel {
                    Text(inferenceLabel)
                        .font(IntatisTypography.system(.callout))
                        .foregroundStyle(agent.isAttached
                            && agent.inferenceResolution.requiresAttention
                            ? threadStyle.accent
                            : threadStyle.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier("cowork.agent.\(agent.id).inference")
                }
            }
            Spacer(minLength: 10)
            if agent.isAttached && agent.inferenceResolution.requiresAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(threadStyle.accent)
                    .accessibilityLabel(agent.inferenceDisplayLabel
                        ?? IntatisLocalization.string("Inference unavailable"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background {
            CoworkAgentSelectionBackground(
                selection: statusRailSelection,
                agentID: agent.id,
                accent: threadStyle.accent)
        }
        .contentShape(Rectangle())
        .help(["\(agent.name): \(intatisLocalizedRawStatus(agent.status))", agent.inferenceDisplayLabel]
            .compactMap { $0 }
            .joined(separator: " · "))
    }

    private var goalCardSection: some View {
        rightRailSection("Goal", systemImage: "scope") {
            goalCardContent
        }
        .accessibilityIdentifier("cowork.goal.card")
    }

    private var workTasksSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(
                    IntatisLocalization.string("Tasks"),
                    systemImage: "checklist")
                    .font(IntatisTypography.system(.title3, weight: .semibold))
                    .foregroundStyle(threadStyle.primaryText)
                Spacer(minLength: 8)
                Text("\(workTasks.completedCount)/\(workTasks.totalCount)")
                    .font(IntatisTypography.system(
                        .caption,
                        monospacedDigits: true))
                    .foregroundStyle(threadStyle.secondaryText)
                    .accessibilityLabel(IntatisLocalization.format(
                        "%lld / %lld complete",
                        Int64(workTasks.completedCount),
                        Int64(workTasks.totalCount)))
            }
            workTasksContent
        }
        .padding(18)
        .frame(
            width: IntatisCoworkStatusRailLayoutPolicy.cardWidth,
            alignment: .leading)
        .intatisClearLiquidGlass(cornerRadius: 22)
        .accessibilityIdentifier("cowork.tasks.card")
    }

    @ViewBuilder private var goalCardContent: some View {
        if let goal {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Label(displayStatus(goal.status), systemImage: statusIconName(for: goal.status))
                            .font(IntatisTypography.system(.caption, bold: true))
                            .foregroundStyle(statusColor(for: goal.status))
                            .lineLimit(1)
                            .accessibilityIdentifier("cowork.goal.status")
                        Spacer(minLength: 6)
                        Label(formatElapsed(goal.elapsedSeconds(at: timeline.date)), systemImage: "timer")
                            .font(IntatisTypography.system(.caption, monospacedDigits: true))
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                    }

                    Text(goal.objective)
                        .font(IntatisTypography.system(.callout, weight: .semibold))
                        .foregroundStyle(threadStyle.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("cowork.goal.objective")

                    HStack(alignment: .top, spacing: 12) {
                        goalMetric(
                            IntatisLocalization.string("Tokens"),
                            value: tokenSummary(for: goal))
                        goalMetric(
                            IntatisLocalization.string("Run"),
                            value: goal.currentRunOrdinal.map { "#\($0)" }
                                ?? IntatisLocalization.string("Not started"))
                    }

                    if let auditSummary = auditSummary(for: goal) {
                        Label(auditSummary, systemImage: "checkmark.shield")
                            .font(IntatisTypography.system(.caption))
                            .foregroundStyle(threadStyle.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if goal.revision > 0 {
                        Text(IntatisLocalization.format(
                            "Revision %lld",
                            Int64(goal.revision)))
                            .font(IntatisTypography.system(.caption))
                            .foregroundStyle(threadStyle.tertiaryText)
                    }

                    goalActions(goal)
                }
            }
        } else {
            Text("No active goal")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
        }
    }

    private func goalMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IntatisLocalization.string(title).uppercased())
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(threadStyle.tertiaryText)
            Text(value)
                .font(IntatisTypography.system(.caption, monospacedDigits: true))
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func goalActions(_ goal: CoworkGoalCardInfo) -> some View {
        if goal.canPause || goal.canResume || goal.canEdit || goal.canClear {
            Divider().opacity(0.35)
            IntatisGlassEffectGroup(spacing: 10) {
                HStack(spacing: 10) {
                    if goal.canPause {
                        Button("Pause") { onPauseGoal?() }
                            .intatisGlassButton()
                            .disabled(onPauseGoal == nil)
                            .accessibilityIdentifier("cowork.goal.pause")
                    }
                    if goal.canResume {
                        Button("Resume") { onResumeGoal?() }
                            .intatisGlassButton()
                            .disabled(onResumeGoal == nil)
                            .accessibilityIdentifier("cowork.goal.resume")
                    }
                    if goal.canEdit {
                        Button("Edit") { onEditGoal?() }
                            .intatisGlassButton()
                            .disabled(onEditGoal == nil)
                            .accessibilityIdentifier("cowork.goal.edit")
                    }
                    Spacer(minLength: 0)
                    if goal.canClear {
                        Button("Clear") { onClearGoal?() }
                            .intatisGlassButton()
                            .foregroundStyle(threadStyle.error)
                            .disabled(onClearGoal == nil)
                            .accessibilityIdentifier("cowork.goal.clear")
                    }
                }
            }
            .font(IntatisTypography.system(.caption, bold: true))
        }
    }

    @ViewBuilder private var workTasksContent: some View {
        if workTasks.tasks.isEmpty {
            Text("No work tasks yet")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(workTasks.tasks) { task in
                    CoworkWorkTaskRow(
                        task: task,
                        style: threadStyle)
                }
            }
        }
    }

    private func formatElapsed(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded(.down)), 0)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private func tokenSummary(for goal: CoworkGoalCardInfo) -> String {
        let used = NumberFormatter.localizedString(from: NSNumber(value: goal.tokensUsed), number: .decimal)
        guard let tokenBudget = goal.tokenBudget else {
            return IntatisLocalization.format("%@ · no budget", used)
        }
        let budget = NumberFormatter.localizedString(from: NSNumber(value: max(tokenBudget, 0)), number: .decimal)
        return "\(used) / \(budget)"
    }

    private func auditSummary(for goal: CoworkGoalCardInfo) -> String? {
        var parts: [String] = []
        if let proven = goal.auditProvenCount, let required = goal.auditRequirementCount {
            parts.append(IntatisLocalization.format(
                "%lld / %lld requirements proven",
                Int64(max(proven, 0)),
                Int64(max(required, 0))))
        }
        if let summary = goal.latestAuditSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            parts.append(summary)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func displayStatus(_ status: String) -> String {
        intatisLocalizedDisplayStatus(status)
    }

    private func rightRailSection<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(IntatisLocalization.string(title), systemImage: systemImage)
                .font(IntatisTypography.system(.title3, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
            content()
        }
        .padding(18)
        .frame(
            width: IntatisCoworkStatusRailLayoutPolicy.cardWidth,
            alignment: .leading)
        .intatisClearLiquidGlass(cornerRadius: 22)
    }

    private var inspectorOverview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("@\(project.mainAgentName)")
                        .font(IntatisTypography.system(.caption, bold: true))
                        .foregroundStyle(threadStyle.primaryText)
                        .lineLimit(1)
                    Text(project.defaultModel)
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(threadStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if let onShowProjectSettings {
                    Button(action: onShowProjectSettings) {
                        Label("Project Settings", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .intatisGlassButton()
                    .disabled(isWorking)
                    .help("Project Settings")
                }
            }

            Divider().opacity(0.35)

            HStack(alignment: .top, spacing: 12) {
                overviewMetric("Agents", "\(agents.count)")
                overviewMetric("Running", "\(summary.runningCount)")
                overviewMetric("Tasks", "\(summary.activeCount)")
                overviewMetric("Inbox", "\(summary.pendingMailboxCount)")
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .intatisContentSurface(cornerRadius: 8)
    }

    private func overviewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IntatisLocalization.string(title).uppercased())
                .font(IntatisTypography.system(.caption2, bold: true))
                .foregroundStyle(threadStyle.tertiaryText)
                .lineLimit(1)
            Text(value)
                .font(IntatisTypography.system(size: 15, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inspectorTabs: some View {
        Picker("Inspector view", selection: $inspectorTab) {
            ForEach(CoworkInspectorTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    @ViewBuilder private var inspectorTabContent: some View {
        switch inspectorTab {
        case .agents:
            agentsInspector
        case .tasks:
            tasksInspector
        case .context:
            contextInspector
        }
    }

    @ViewBuilder private var agentsInspector: some View {
        inspectorSection("Roster") {
            agentRosterList
        }
        if let agent = selectedAgent {
            inspectorSection("Selected Agent") {
                selectedAgentDetails(agent)
            }
        }
    }

    private var tasksInspector: some View {
        inspectorSection("Task Flow") {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .top, spacing: 12) {
                    overviewMetric("Active", "\(summary.activeCount)")
                    overviewMetric("Running", "\(summary.runningCount)")
                    overviewMetric("Failed", "\(summary.failedCount)")
                }
                Divider().opacity(0.35)
                taskList
            }
        }
    }

    @ViewBuilder private var contextInspector: some View {
        inspectorSection("Project") {
            projectSection
        }
        inspectorSection("Workspaces") {
            inspectorRow("Directories", value: "\(project.workspaces.count)")
            workspaceDirectoryList
        }
        inspectorSection("Access") {
            inspectorRow("Workspace leases", value: "\(summary.workspaceLeaseCount)")
            inspectorRow("Capability leases", value: "\(summary.capabilityLeaseCount)")
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            inspectorRow(
                "Session",
                value: project.sessionID.isEmpty
                    ? IntatisLocalization.string("current")
                    : project.sessionID)
            inspectorRow("Main", value: "@\(project.mainAgentName)")
            inspectorRow("Model", value: project.defaultModel)
            inspectorRow("Permission", value: project.defaultPermission)
            if let tokenBudget = project.tokenBudget {
                inspectorRow("Soft token budget", value: tokenBudget)
            }
            if let onShowProjectSettings {
                Button(action: onShowProjectSettings) {
                    Label("Project Settings", systemImage: "slider.horizontal.3")
                        .font(IntatisTypography.system(.caption, bold: true))
                }
                .intatisGlassButton()
                .disabled(isWorking)
            }
        }
    }

    @ViewBuilder private var workspaceDirectoryList: some View {
        if project.workspaces.isEmpty {
            Text("No workspace directories")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(project.workspaces.prefix(5)) { workspace in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: workspace.isPrimary ? "house" : "folder")
                                .font(IntatisTypography.system(.caption2))
                                .foregroundStyle(workspace.isPrimary ? threadStyle.accent : threadStyle.secondaryText)
                            Text(workspace.displayName)
                                .font(IntatisTypography.system(.caption, bold: true))
                                .foregroundStyle(threadStyle.primaryText)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let agentName = workspace.agentName {
                                Text("@\(agentName)")
                                    .font(IntatisTypography.system(.caption2, bold: true))
                                    .foregroundStyle(threadStyle.secondaryText)
                            }
                        }
                        Text(workspace.path)
                            .font(IntatisTypography.system(.caption2))
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Inspector")
                .font(IntatisTypography.system(size: 16, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
            Text("Agents, tasks, and workspace status")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.secondaryText)
        }
    }

    @ViewBuilder private var agentRosterList: some View {
        if agents.isEmpty {
            Text("No agents in this session")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
        } else {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(agents) { agent in
                    agentListRow(agent)
                }
            }
        }
    }

    @ViewBuilder private var taskList: some View {
        let allTasks = summary.runningTasks + summary.failedTasks + summary.recentCompletedTasks
        if allTasks.isEmpty {
            Text("No structured task events in the current projection.")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(summary.runningTasks) { task in
                taskCompactRow(task: task)
            }
            ForEach(summary.failedTasks) { task in
                taskCompactRow(
                    task: task,
                    actionTitle: onRetryTask == nil
                        ? nil
                        : IntatisLocalization.string("Retry"),
                    actionDisabled: isWorking,
                    action: onRetryTask.map { retry in { retry(task.id) } })
            }
            ForEach(summary.recentCompletedTasks) { task in
                taskCompactRow(task: task)
            }
        }
    }

    private func inspectorSection<Content: View>(_ title: String,
                                                 @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(IntatisLocalization.string(title).uppercased())
                .font(IntatisTypography.system(.caption2, bold: true))
                .foregroundStyle(threadStyle.tertiaryText)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .intatisContentSurface(cornerRadius: 8)
    }

    private func inspectorRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(IntatisLocalization.string(title))
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(threadStyle.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(threadStyle.primaryText)
        }
    }

    private func statusStrip(layout: IntatisThreadContentLayout) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                metric("Active", summary.activeCount)
                metric("Running", summary.runningCount)
                metric("Failed", summary.failedCount)
                metric("Mailbox", summary.pendingMailboxCount)
                metric("Leases", summary.workspaceLeaseCount + summary.capabilityLeaseCount)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], alignment: .leading, spacing: 8) {
                metric("Active", summary.activeCount)
                metric("Running", summary.runningCount)
                metric("Failed", summary.failedCount)
                metric("Mailbox", summary.pendingMailboxCount)
                metric("Leases", summary.workspaceLeaseCount + summary.capabilityLeaseCount)
            }
        }
        .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IntatisLocalization.string(title))
                .font(IntatisTypography.system(.caption2, bold: true))
                .foregroundStyle(threadStyle.tertiaryText)
            Text("\(value)")
                .font(IntatisTypography.system(size: 15, weight: .semibold))
                .foregroundStyle(threadStyle.primaryText)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(minWidth: 96, alignment: .leading)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(threadStyle.cardStroke, lineWidth: 1)
        }
    }

    private func agentListRow(_ agent: CoworkAgentInfo) -> some View {
        let selected = selectedAgentID == agent.id
        return Button {
            onSelectAgent(agent.id)
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(statusColor(for: agent.status))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("@\(agent.name)")
                            .font(IntatisTypography.system(.caption, bold: true))
                            .foregroundStyle(threadStyle.primaryText)
                            .lineLimit(1)
                        Text(intatisLocalizedAgentRole(agent.role))
                            .font(IntatisTypography.system(.caption2, bold: true))
                            .foregroundStyle(threadStyle.secondaryText)
                            .lineLimit(1)
                    }
                    Text(agent.statusLine)
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(threadStyle.secondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(threadStyle.accent)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? threadStyle.accent.opacity(0.48) : Color.clear,
                            lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(!agent.isConversationSelectable)
    }

    private func selectedAgentDetails(_ agent: CoworkAgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("@\(agent.name)")
                    .font(IntatisTypography.system(.caption, bold: true))
                    .foregroundStyle(threadStyle.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(intatisLocalizedRawStatus(agent.status))
                    .font(IntatisTypography.system(.caption2, bold: true))
                    .foregroundStyle(statusColor(for: agent.status))
                    .lineLimit(1)
                if agent.canRemove, let onRemoveAgent {
                    Button {
                        onRemoveAgent(agent.name)
                    } label: {
                        Label("Remove agent", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .intatisGlassButton()
                    .disabled(isWorking)
                    .help("Remove agent")
                }
            }
            Text(agent.workspace)
                .font(IntatisTypography.system(.caption2))
                .foregroundStyle(threadStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Divider().opacity(0.35)
            agentDetailRow("Role", value: intatisLocalizedAgentRole(agent.role))
            agentDetailRow("Model", value: agent.model)
            if let inferenceLabel = agent.inferenceDisplayLabel {
                agentDetailRow("Inference", value: inferenceLabel)
            }
            agentDetailRow("Permission", value: agent.permissionProfile)
            agentDetailRow(
                "Queued",
                value: IntatisLocalization.format(
                    "%lld tasks / %lld messages",
                    Int64(agent.pendingTasks),
                    Int64(agent.pendingMessages)))
            agentDetailRow(
                "Completed",
                value: IntatisLocalization.format(
                    "%lld tasks",
                    Int64(agent.completedTasks)))
            if let workspaceLease = agent.workspaceLease {
                agentDetailRow("Workspace lease", value: workspaceLease)
            }
            if let capabilityLease = agent.capabilityLease {
                agentDetailRow("Capability lease", value: capabilityLease)
            }
        }
    }

    private func taskCompactRow(task: CoworkTaskLine,
                                actionTitle: String? = nil,
                                actionDisabled: Bool = false,
                                action: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(task.title)
                    .font(IntatisTypography.system(.callout, weight: .semibold))
                    .foregroundStyle(threadStyle.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .intatisGlassButton()
                        .disabled(actionDisabled)
                }
                Text(intatisLocalizedDisplayStatus(task.status))
                    .font(IntatisTypography.system(.caption2, bold: true))
                    .foregroundStyle(statusColor(for: task.status))
                    .lineLimit(1)
            }
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(IntatisTypography.system(.caption2))
                    .foregroundStyle(threadStyle.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(for status: String) -> Color {
        switch normalizedStatus(status) {
        case "failed", "error", "rejected":
            return threadStyle.error
        case "active", "in_progress", "inprogress", "running", "thinking", "tool":
            return threadStyle.accent
        case "blocked", "budget_limited", "usage_limited":
            return .orange
        case "assigned", "paused", "pending", "queued", "ready", "mailbox":
            return .orange
        case "completed", "complete", "done":
            return .green
        default:
            return threadStyle.tertiaryText
        }
    }

    private func statusIconName(for status: String) -> String {
        switch normalizedStatus(status) {
        case "failed", "error", "rejected":
            return "exclamationmark.circle.fill"
        case "active", "in_progress", "inprogress", "running", "thinking", "tool":
            return "ellipsis.circle.fill"
        case "blocked":
            return "pause.circle.fill"
        case "budget_limited", "usage_limited":
            return "hourglass.circle.fill"
        case "paused":
            return "pause.circle.fill"
        case "assigned", "pending", "queued", "ready", "mailbox":
            return "clock.fill"
        case "completed", "complete", "done":
            return "checkmark.circle.fill"
        case "cancelled", "canceled":
            return "xmark.circle.fill"
        case "detached", "removed", "cleaned":
            return "minus.circle.fill"
        default:
            return "circle"
        }
    }

    private func normalizedStatus(_ status: String) -> String {
        status
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private func agentRoster(layout: IntatisThreadContentLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal) {
                IntatisGlassEffectGroup(spacing: 8) {
                    LazyHStack(spacing: 8) {
                        if agents.isEmpty {
                            Text("No agents in this session")
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(threadStyle.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .intatisContentSurface(cornerRadius: 18)
                        }
                        ForEach(agents) { agent in
                            agentPill(agent)
                        }
                        if let onAddAgent {
                            Button(action: onAddAgent) {
                                Label("Attach", systemImage: "plus")
                                    .font(IntatisTypography.system(.caption, bold: true))
                            }
                            .intatisGlassButton()
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)

            if let agent = selectedAgent {
                selectedAgentCard(agent)
            }
        }
        .frame(maxWidth: layout.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.bottom, 10)
    }

    private func agentPill(_ agent: CoworkAgentInfo) -> some View {
        let selected = selectedAgentID == agent.id
        return Button {
            onSelectAgent(agent.id)
        } label: {
            HStack(spacing: 7) {
                Text("@\(agent.name)")
                    .font(IntatisTypography.system(.caption, bold: true))
                    .foregroundStyle(selected ? threadStyle.accent : threadStyle.primaryText)
                Text(intatisLocalizedRawStatus(agent.status))
                    .font(IntatisTypography.system(.caption2))
                    .foregroundStyle(threadStyle.secondaryText)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(threadStyle.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .intatisLiquidGlass(cornerRadius: 18, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(!agent.isConversationSelectable)
    }

    private func selectedAgentCard(_ agent: CoworkAgentInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("@\(agent.name)")
                    .font(IntatisTypography.system(.caption, bold: true))
                    .foregroundStyle(threadStyle.primaryText)
                Spacer(minLength: 8)
                Text(intatisLocalizedRawStatus(agent.status))
                    .font(IntatisTypography.system(.caption2, bold: true))
                    .foregroundStyle(threadStyle.accent)
            }
            Text(agent.workspace)
                .font(IntatisTypography.system(.caption2))
                .foregroundStyle(threadStyle.secondaryText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            agentDetailRow("Role", value: intatisLocalizedAgentRole(agent.role))
            agentDetailRow("Model", value: agent.model)
            if let inferenceLabel = agent.inferenceDisplayLabel {
                agentDetailRow("Inference", value: inferenceLabel)
            }
            agentDetailRow("Permission", value: agent.permissionProfile)
            agentDetailRow(
                "Queued",
                value: IntatisLocalization.format(
                    "%lld tasks / %lld messages",
                    Int64(agent.pendingTasks),
                    Int64(agent.pendingMessages)))
            agentDetailRow(
                "Completed",
                value: IntatisLocalization.format(
                    "%lld tasks",
                    Int64(agent.completedTasks)))
            if let workspaceLease = agent.workspaceLease {
                agentDetailRow("Workspace lease", value: workspaceLease)
            }
            if let capabilityLease = agent.capabilityLease {
                agentDetailRow("Capability lease", value: capabilityLease)
            }
            if agent.canRemove, let onRemoveAgent {
                HStack {
                    Spacer(minLength: 0)
                    Button {
                        onRemoveAgent(agent.name)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .intatisGlassButton()
                    .disabled(isWorking)
                    .help("Remove agent")
                }
            }
        }
        .padding(11)
        .intatisContentSurface(cornerRadius: 8)
    }

    private func agentDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(IntatisLocalization.string(title))
                .font(IntatisTypography.system(.caption2))
                .foregroundStyle(threadStyle.secondaryText)
            Spacer(minLength: 8)
            Text(value)
                .font(IntatisTypography.system(.caption2, bold: true))
                .foregroundStyle(threadStyle.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private func taskHighlights(layout: IntatisThreadContentLayout) -> some View {
        if !summary.runningTasks.isEmpty || !summary.failedTasks.isEmpty || !summary.recentCompletedTasks.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.runningTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
                ForEach(summary.failedTasks) { task in
                    CoworkTaskLineRow(
                        task: task,
                        style: threadStyle,
                        actionTitle: onRetryTask == nil
                            ? nil
                            : IntatisLocalization.string("Retry"),
                        actionDisabled: isWorking,
                        action: onRetryTask.map { retry in { retry(task.id) } })
                }
                ForEach(summary.recentCompletedTasks) { task in CoworkTaskLineRow(task: task, style: threadStyle) }
            }
            .frame(maxWidth: layout.contentMaxWidth)
            .padding(.horizontal, layout.horizontalPadding)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder private func thread(
        layout: IntatisThreadContentLayout,
        trailingContentMargin: CGFloat,
        jumpHorizontalOffset: CGFloat
    ) -> some View {
        let items = threadItems
        let threadScope = threadPresentationScope
        ScrollViewReader { proxy in
            ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if isThreadSnapshotLoading && items.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 20)
                                .accessibilityIdentifier(
                                    "cowork.agent-thread.loading")
                        }
                        IntatisContinuousThreadStack(
                            items: items,
                            scope: threadScope,
                            baseAdmission: resolvedViewportAdmission(
                                for: threadScope),
                            alignment: .leading,
                            spacing: 10,
                            rowID: { $0.id }
                        ) { item in
                            CodeItemRow(
                                item: item,
                                style: threadStyle,
                                layout: layout)
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
                    // The transcript is centered inside one exact conversation
                    // column before the ScrollView expands under the trailing
                    // rail. A selected agent's content or scroller visibility
                    // therefore cannot move either horizontal edge.
                    .frame(width: layout.rawWidth)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                }
                .contentMargins(
                    .trailing,
                    trailingContentMargin,
                    for: .scrollContent)
                .scrollContentBackground(.hidden)
                .overlay {
                    if threadSnapshot.items.isEmpty
                        && !isThreadSnapshotLoading {
                        CoworkEmptyThreadView(style: threadStyle)
                            .frame(width: layout.contentWidth)
                            .frame(width: layout.rawWidth)
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: .leading)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier(
                                "cowork.agent-thread.empty")
                    }
                }
                // The ScrollView spans the entire Cowork detail canvas,
                // including the area beneath the trailing rail. Center the
                // floating action on that canvas, not on the transcript or
                // the rail-adjusted content margin.
                .overlay(alignment: .bottom) {
                    if scrollCoordinator.followState == .detachedByUser {
                        IntatisJumpToLatestButton(
                            accessibilityIdentifier: "cowork.jump-to-latest"
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
                .onChange(of: threadScope) { previous, current in
                    scrollCoordinator.deactivate(scope: previous)
                    scrollCoordinator.activate(
                        scope: current,
                        defersRichUntilInitialRestore:
                            defersRichUntilInitialRestore)
                    requestScroll(
                        proxy,
                        reason: .initialRestore,
                        scope: current)
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

    private func resolvedViewportAdmission(
        for threadScope: IntatisThreadPresentationScope
    ) -> IntatisMessageViewportAdmission {
        guard isRichRenderingEligible else {
            return .suspended(generation: UInt64.max)
        }
        return scrollCoordinator.effectiveViewportAdmission(
            for: threadScope,
            defersUntilInitialRestore: defersRichUntilInitialRestore)
    }

    private var selectedAgentIsWorking: Bool {
        if selectedAgentID == project.mainAgentName, isWorking {
            return true
        }
        if threadSnapshot.isAgentWorking { return true }
        guard let selectedAgent else { return false }
        switch normalizedStatus(selectedAgent.status) {
        case "active", "running", "thinking", "tool":
            return true
        default:
            return false
        }
    }

    private var defersRichUntilInitialRestore: Bool {
        IntatisThreadRichEntryPolicy.defersUntilInitialRestore(
            richRowCount: threadItems.count)
    }

    private var threadItems: [CodeItem] {
        displayedThreadItems
    }

    private var threadPresentationScope: IntatisThreadPresentationScope {
        IntatisThreadPresentationScope(
            kind: presentationScope.kind,
            sessionID: presentationScope.sessionID,
            presentationID:
                "\(presentationScope.presentationID):agent:\(selectedAgentID)")
    }

    private func retrySubmission(_ submissionID: SubmissionID) {
        onRetrySubmission?(submissionID)
    }

    private var itemScrollSignature: IntatisThreadScrollSignature {
        let last = threadItems.last
        return IntatisThreadScrollSignature(
            visibleItemCount: threadItems.count,
            lastItemID: last?.id,
            lastBodyUTF8Count: last?.body.utf8.count ?? 0,
            lastItemComplete: last?.complete ?? false,
            lastTurnStatsID: last?.responsesUsage?.id
                ?? last?.turnStats?.id,
            isWorking: selectedAgentIsWorking,
            showsThinkingIndicator: false)
    }

    private var scrollReason: IntatisThreadScrollReason {
        guard let last = threadItems.last else {
            return .liveUpdate
        }
        return last.complete && !selectedAgentIsWorking
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

    @ViewBuilder private func permissionFallbackArea(
        layout: IntatisThreadContentLayout
    ) -> some View {
        if let pending {
            PermissionCard(permission: pending, onResolve: onResolve)
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
                placeholder: IntatisLocalization.string("Give Main a project task..."),
                input: $input,
                canSend: !isAcceptingSubmission
                    && composerTrailingAction?.blocksSubmission != true
                    && (!input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || hasDraftAttachments),
                isInputDisabled: false,
                style: threadStyle,
                leadingAccessory: composerAccessory,
                inputLeadingAccessory: composerInputAccessory,
                trailingAction: composerTrailingAction,
                stopAction: onCancelCurrent.map { onCancelCurrent in
                    IntatisThreadComposerSecondaryAction(
                        systemImage: "stop.fill",
                        help: IntatisLocalization.string("Stop"),
                        action: onCancelCurrent)
                },
                accessory: { EmptyView() },
                onSend: onSend)
        }
        .frame(maxWidth: layout.contentMaxWidth)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 22)
    }
}

private struct CoworkWorkTaskRow: View {
    let task: CoworkWorkTaskLine
    let style: IntatisThreadStyle
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if task.hasExpandedDetails {
                Button {
                    isExpanded.toggle()
                } label: {
                    taskLabel(showsDisclosure: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.title)
                .accessibilityValue(displayStatus)
                .accessibilityHint(IntatisLocalization.string(
                    isExpanded ? "Hide task details" : "Show task details"))

                if isExpanded {
                    taskDetails
                        .padding(.top, 8)
                        .padding(.leading, 32)
                }
            } else {
                taskLabel(showsDisclosure: false)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(task.title)
                    .accessibilityValue(displayStatus)
            }
        }
        .padding(.vertical, 3)
        .accessibilityIdentifier("cowork.task.\(task.id)")
        .help(displayStatus)
    }

    private func taskLabel(showsDisclosure: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            taskMarker
            Text(task.title)
                .font(IntatisTypography.system(.callout, weight: .semibold))
                .foregroundStyle(
                    task.isCompleted ? style.secondaryText : style.primaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(IntatisTypography.system(size: 10, weight: .semibold))
                    .foregroundStyle(style.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var taskMarker: some View {
        switch task.normalizedStatus {
        case "completed", "complete", "done":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case "in_progress", "inprogress", "running":
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case "blocked":
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.orange)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case "failed", "error":
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(style.error)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        case "cancelled", "canceled":
            Image(systemName: "slash.circle")
                .foregroundStyle(style.tertiaryText)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
        default:
            neutralMarker
        }
    }

    private var neutralMarker: some View {
        Circle()
            .stroke(statusColor, lineWidth: 1.2)
            .frame(width: 18, height: 18)
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)
    }

    private var taskDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !task.detail.isEmpty {
                detailBlock("Details", value: task.detail)
            }
            if let dependencies = task.dependencySummary, !dependencies.isEmpty {
                detailBlock("Dependencies", value: dependencies)
            }
            if let reason = task.statusReason, !reason.isEmpty {
                detailBlock("Status reason", value: reason)
            }
            if !task.acceptanceCriteria.isEmpty {
                detailList("Acceptance", values: task.acceptanceCriteria)
            }
            if let result = task.result, !result.isEmpty {
                detailBlock("Result", value: result)
            }
            if !task.evidence.isEmpty {
                detailList("Evidence", values: task.evidence)
            }
            if !task.linkedInvocationIDs.isEmpty {
                detailList("Invocations", values: task.linkedInvocationIDs, monospaced: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailBlock(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(IntatisLocalization.string(title).uppercased())
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(style.tertiaryText)
            Text(value)
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func detailList(_ title: String,
                            values: [String],
                            monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(IntatisLocalization.string(title).uppercased())
                .font(IntatisTypography.system(.caption, bold: true))
                .foregroundStyle(style.tertiaryText)
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                HStack(alignment: .top, spacing: 5) {
                    Text("•")
                    Text(value)
                        .font(IntatisTypography.system(
                            .caption,
                            design: monospaced ? .monospaced : .default))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(style.secondaryText)
            }
        }
    }

    private var displayStatus: String {
        intatisLocalizedDisplayStatus(task.status)
    }

    private var statusColor: Color {
        switch task.normalizedStatus {
        case "completed", "complete", "done":
            return .green
        case "active", "in_progress", "inprogress", "running":
            return style.accent
        case "blocked", "budget_limited", "usage_limited":
            return .orange
        case "failed", "error", "rejected":
            return style.error
        default:
            return style.tertiaryText
        }
    }
}

private struct CoworkTaskLineRow: View {
    let task: CoworkTaskLine
    let style: IntatisThreadStyle
    let actionTitle: String?
    let actionDisabled: Bool
    let action: (() -> Void)?

    init(task: CoworkTaskLine,
         style: IntatisThreadStyle = .standard(.light),
         actionTitle: String? = nil,
         actionDisabled: Bool = false,
         action: (() -> Void)? = nil) {
        self.task = task
        self.style = style
        self.actionTitle = actionTitle
        self.actionDisabled = actionDisabled
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(IntatisTypography.system(.caption, bold: true))
                    .foregroundStyle(style.primaryText)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .intatisGlassButton()
                        .disabled(actionDisabled)
                }
                Text(intatisLocalizedDisplayStatus(task.status))
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(style.secondaryText)
            }
            if !task.detail.isEmpty {
                Text(task.detail)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(style.secondaryText)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .intatisContentSurface(cornerRadius: 8)
    }
}

private struct CoworkEmptyThreadView: View {
    let style: IntatisThreadStyle

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "person.2")
                .font(IntatisTypography.system(size: 30, weight: .semibold))
                .foregroundStyle(style.accent)
                .frame(width: 76, height: 76)
            Spacer()
        }
        .multilineTextAlignment(.center)
    }
}
#endif
