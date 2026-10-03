#if DEBUG && canImport(SwiftUI)
import IntatisConversation
import IntatisCore
import IntatisSharedUI
import SwiftUI

/// Offline visual fixture for the production structured-input surface. It
/// renders the same CoworkShell used by the app and never opens a provider,
/// runtime, workspace, EventLog, credential, or network connection.
struct RequestUserInputFixtureView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var input = ""
    @State private var showsInspector = true
    @State private var pendingUserInput: IntatisUserInputPresentation? =
        Self.presentation

    var body: some View {
        GeometryReader { proxy in
            CoworkShell(
                threadSnapshot: Self.threadSnapshot,
                presentationScope: IntatisThreadPresentationScope(
                    kind: "cowork",
                    sessionID: "request-user-input-fixture"),
                sessionTitle: "Agent 工具接线",
                thinkingScopeID: "request-user-input-fixture",
                agents: Self.agents,
                pending: nil,
                summary: CoworkStatusSummary(
                    activeCount: 2,
                    runningCount: 1,
                    completedCount: 1),
                project: CoworkProjectInfo(
                    sessionID: "request-user-input-fixture",
                    mainAgentName: "Main",
                    defaultModel: "Codex",
                    defaultPermission: "reviewed"),
                goal: CoworkGoalCardInfo(
                    id: "goal-1",
                    objective: "接入结构化问答",
                    status: "active",
                    canEdit: false,
                    canClear: false),
                workTasks: CoworkWorkTaskSummary(tasks: [
                    CoworkWorkTaskLine(
                        id: "backend",
                        ordinal: 1,
                        title: "Backend",
                        status: "completed"),
                    CoworkWorkTaskLine(
                        id: "ui",
                        ordinal: 2,
                        title: "UI",
                        status: "in_progress"),
                ]),
                errorTexts: [],
                isWorking: true,
                isAcceptingSubmission: false,
                threadStyle: .translatisMac(colorScheme),
                showsInspector: $showsInspector,
                input: $input,
                onSend: {},
                onCancelCurrent: {},
                onResolve: { _ in },
                selectedAgentID: "research",
                onSelectAgent: { _ in },
                pendingUserInput: pendingUserInput,
                onSubmitUserInput: { _ in
                    pendingUserInput = nil
                })
                .environment(\.intatisWindowContentWidth, proxy.size.width)
        }
        .frame(minWidth: 1_100, minHeight: 760)
        .accessibilityIdentifier("request-user-input.fixture")
    }

    private static let presentation = IntatisUserInputPresentation(
        id: "fixture-request",
        requesterName: "Research",
        questions: [
            IntatisUserInputQuestionPresentation(
                id: "scope",
                question: "应该先实现哪种交互范围？",
                options: [
                    IntatisUserInputOptionPresentation(
                        label: "仅完成问题坞",
                        description: "只接入当前结构化问题。"),
                    IntatisUserInputOptionPresentation(
                        label: "同时加入跨 Agent 提醒",
                        description: "包含来自已验证子 Agent 的问题。"),
                ],
                allowsOther: true),
            IntatisUserInputQuestionPresentation(
                id: "details",
                question: "需要补充说明时怎么填写？",
                options: [
                    IntatisUserInputOptionPresentation(
                        label: "选择 Other 后填写",
                        description: "把自由文本作为这一题的替代答案。"),
                    IntatisUserInputOptionPresentation(
                        label: "不需要补充说明",
                        description: "直接使用当前选项作为完整答案。"),
                ],
                allowsOther: true),
        ])

    private static let agents = [
        CoworkAgentInfo(
            id: "main",
            name: "Main",
            workspace: "Translatis",
            model: "Codex",
            permissionProfile: "reviewed",
            inferenceResolution: .resolved,
            status: "active",
            role: "main",
            canRemove: false),
        CoworkAgentInfo(
            id: "research",
            name: "Research",
            workspace: "Translatis",
            model: "Codex",
            permissionProfile: "read-only",
            inferenceResolution: .resolved,
            status: "waiting",
            role: "research"),
    ]

    private static let threadSnapshot = CoworkAgentThreadSnapshot(
        agentID: AgentID(rawValue: "research"),
        items: [
            CodeItem(
                id: "research-message",
                kind: .agent,
                title: "Research",
                body: "后端协议已经接通，现在需要确定呈现方式。",
                timestamp: Date(timeIntervalSince1970: 1_788_394_680)),
        ],
        projectedThroughSeq: 1,
        projectionGeneration: UUID(uuidString:
            "7450E25A-7B7C-4C6B-9CC8-97B52B0DAAF1")!,
        isAgentWorking: true)
}
#endif
