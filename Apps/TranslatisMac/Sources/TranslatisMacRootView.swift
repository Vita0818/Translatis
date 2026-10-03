//
//  TranslatisMacRootView.swift
//  TranslatisMac
//
//  macOS workbench shell: mode + session history live in the sidebar, the center
//  stays focused on the thread, and Code/Cowork reserve the right side for status.
//

#if canImport(SwiftUI)
import SwiftUI
import IntatisCore
import IntatisConversation
import IntatisSharedUI

enum IntatisNavItem: String, CaseIterable, Identifiable, Hashable {
    case chat, code, cowork

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return IntatisLocalization.string("Chat")
        case .code: return IntatisLocalization.string("Code")
        case .cowork: return IntatisLocalization.string("Cowork")
        }
    }

    var icon: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .cowork: return "person.2"
        }
    }

    var sessionKind: SessionKind {
        switch self {
        case .chat: return .chat
        case .code: return .code
        case .cowork: return .cowork
        }
    }

    var newSessionTitle: String {
        switch self {
        case .chat: return IntatisLocalization.string("New chat")
        case .code: return IntatisLocalization.string("New code session")
        case .cowork: return IntatisLocalization.string("New cowork session")
        }
    }

    init(sessionKind: SessionKind) {
        switch sessionKind {
        case .chat: self = .chat
        case .code: self = .code
        case .cowork: self = .cowork
        }
    }
}

private struct SessionActionTarget: Identifiable {
    let sessionID: SessionID
    let kind: SessionKind
    let title: String

    var id: String { "\(kind.rawValue):\(sessionID.rawValue)" }
}

private struct ProjectRemovalTarget: Identifiable {
    let id: ProjectID
    let title: String
}

private struct ProjectConversationSidebarItem: Identifiable {
    let reference: ProjectConversationReference
    let title: String
    let systemImage: String
    let updatedAt: Date
    let isSelected: Bool
    let isDeleteDisabled: Bool

    var id: String { reference.id }
}

private struct ProjectSidebarItem: Identifiable {
    let project: ProjectFolderRecord
    let conversations: [ProjectConversationSidebarItem]

    var id: ProjectID { project.id }
}

struct TranslatisMacRootView: View {
    @EnvironmentObject var env: AppEnvironment
    @ObservedObject private var runtimeManager: AppSessionRuntimeManager
    @Environment(\.colorScheme) private var scheme
    @State private var selection: IntatisNavItem = .chat
    @State private var isSettings = false
    @State private var didInit = false
    @State private var recentChatSessions: [AppSessionSummary] = []
    @State private var recentCodeSessions: [AppSessionSummary] = []
    @State private var recentCoworkSessions: [AppSessionSummary] = []
    @State private var codeVM: CodeViewModel?
    @State private var coworkVM: CoworkViewModel?
    @State private var showsCodeInspector = true
    @State private var showsCoworkInspector = true
    @State private var coworkTransitionID: UUID?
    @State private var codeSessionError: String?
    @State private var coworkSessionError: String?
    @State private var renameTarget: SessionActionTarget?
    @State private var deleteTarget: SessionActionTarget?
    @State private var projectRemovalTarget: ProjectRemovalTarget?
    @State private var sessionActionError: String?
    @State private var runtimeStatuses: [
        AppSessionRuntimeKey: AppSessionRuntimePresentationStatus
    ]

    init(runtimeManager: AppSessionRuntimeManager) {
        _runtimeManager = ObservedObject(wrappedValue: runtimeManager)
        _runtimeStatuses = State(initialValue: runtimeManager.runtimeStatusSnapshot())
    }

    private var items: [IntatisNavItem] {
        IntatisNavItem.allCases.filter { item in
            switch item {
            case .chat: return true
            case .code: return PlatformProfile.current.supports(.code)
            case .cowork: return PlatformProfile.current.supports(.cowork)
            }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            root
                .environment(
                    \.intatisWindowContentWidth,
                    proxy.size.width)
        }
    }

    private var root: some View {
        NavigationSplitView {
            IntatisSidebar(
                items: items,
                selection: selection,
                isSettings: $isSettings,
                projects: projectSidebarItems,
                projectStoreError: env.projectStoreError,
                historyItems: historyItems,
                historyTitle: IntatisLocalization.string("Unfiled"),
                emptyHistoryTitle: IntatisLocalization.string(
                    "No unfiled sessions."),
                newSessionTitle: selection.newSessionTitle,
                isNewDisabled: newSessionDisabled,
                onSelectMode: selectMode,
                onAddProject: addProject,
                onRemoveProject: beginRemoveProject,
                onNewProjectConversation: startNewProjectConversation,
                onSelectProjectConversation: selectProjectConversation,
                isProjectConversationCreationDisabled: newSessionDisabled,
                onNewSession: startNewSelectedSession,
                onSelectSession: resumeSelectedSession,
                onRenameSession: beginRenameSession,
                onDeleteSession: beginDeleteSession)
                .navigationSplitViewColumnWidth(
                    min: IntatisSplitColumnLayout.chatInspector.sidebarMin,
                    ideal: 236)
        } detail: {
            ZStack {
                TranslatisSystemCanvas().ignoresSafeArea()
                detail
            }
        }
        .navigationTitle("")
        .mcpInteractionHost(env.mcp.interactionCenter)
        .task {
            guard !didInit else { return }
            didInit = true
            refreshAllSessions()
            if env.needsAPIKey { isSettings = true }
        }
        .onChange(of: selection) { _ in refreshAllSessions() }
        .onChange(of: env.chatSessionID.rawValue) { _ in refreshChatSessions() }
        .onChange(of: env.projects) { _, _ in refreshAllSessions() }
        .onReceive(runtimeManager.runtimeRemoved) { key in
            handleRemovedRuntime(key)
        }
        .onReceive(runtimeManager.sessionDisplayNameChanged) { change in
            handleSessionDisplayNameChange(change)
        }
        .onReceive(runtimeManager.sessionActivitySettled) { settlement in
            refreshSessions(kind: settlement.key.kind)
        }
        .onReceive(runtimeManager.sessionRuntimeStatusChanged) { change in
            if let status = change.status {
                runtimeStatuses[change.key] = status
            } else {
                runtimeStatuses.removeValue(forKey: change.key)
            }
        }
        .sheet(item: $renameTarget) { target in
            SessionRenameSheet(initialName: target.title) { newName in
                try await renameSession(target, to: newName)
            }
        }
        .alert("Delete Session?", isPresented: deleteAlertPresented, presenting: deleteTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteSession(target)
            }
        } message: { target in
            let identity = IntatisHostApplication.identity
            Text(IntatisLocalization.format(
                "\"%@\" and its %@ event history and artifacts will be permanently deleted. Files in the linked workspace will not be changed.",
                target.title,
                identity.name))
        }
        .alert("Remove Project?", isPresented: projectRemovalAlertPresented, presenting: projectRemovalTarget) { target in
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                removeProject(target)
            }
        } message: { target in
            let identity = IntatisHostApplication.identity
            Text(IntatisLocalization.format(
                "Remove \"%@\" from %@? The folder and all conversations will remain on disk.",
                target.title,
                identity.name))
        }
        .alert("Action Failed", isPresented: sessionErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionActionError ?? IntatisLocalization.string("The action failed."))
        }
    }

    @ViewBuilder private var detail: some View {
        if isSettings {
            IntatisSettingsPanel()
        } else {
            switch selection {
            case .chat:
                TranslatisChatScreen(
                    env: env,
                    sessionTitle: sessionTitle(
                        kind: .chat,
                        sessionID: env.chatSessionID))
            case .code:
                codeDetail
            case .cowork:
                coworkDetail
            }
        }
    }

    @ViewBuilder private var codeDetail: some View {
        if let vm = codeVM {
            let presentationScope = IntatisThreadPresentationScope(
                kind: .code,
                sessionID: vm.sessionID)
            CodeSessionView(
                vm: vm,
                sessionTitle: sessionTitle(kind: .code, sessionID: vm.sessionID),
                catalog: env.providerCatalog,
                mcpProjectSettingsHost:
                    env.mcpProjectSettingsHost(for: vm),
                mcpContentHost:
                    env.mcpConversationContentHost(
                        for: vm),
                onSelectModel: env.selectProviderModel(providerID:modelID:variantID:),
                onShowSessions: showCodeSessions,
                onNewSession: startNewCodeSession,
                showsInspector: $showsCodeInspector)
                .id(presentationScope)
        } else {
            WorkspaceSessionHome(
                title: IntatisLocalization.string("Code"),
                subtitle: IntatisLocalization.string("Local workspace agent session"),
                icon: "folder.badge.plus",
                primaryTitle: IntatisLocalization.string("Choose Workspace"),
                primarySystemImage: "folder",
                primaryShortcut: "o",
                error: codeSessionError,
                sessionsTitle: IntatisLocalization.string("Recent Code Sessions"),
                sessions: [],
                workspacePath: { WorkspaceAccess.workspacePath(for: $0) },
                onPrimary: startNewCodeSession,
                onResume: { resumeCodeSession($0.id) })
        }
    }

    @ViewBuilder private var coworkDetail: some View {
        if let vm = coworkVM {
            let presentationScope = IntatisThreadPresentationScope(
                kind: .cowork,
                sessionID: vm.sessionID)
            CoworkSessionView(
                vm: vm,
                sessionTitle: sessionTitle(kind: .cowork, sessionID: vm.sessionID),
                catalog: env.providerCatalog,
                mcpProjectSettingsHost:
                    env.mcpProjectSettingsHost(for: vm),
                mcpContentHost:
                    env.mcpConversationContentHost(
                        for: vm),
                onShowSessions: showCoworkSessions,
                onNewSession: startNewCoworkSession,
                onSessionDidBecomeReady: refreshCoworkSessions,
                showsInspector: $showsCoworkInspector)
                .id(presentationScope)
        } else {
            WorkspaceSessionHome(
                title: IntatisLocalization.string("Cowork"),
                subtitle: IntatisLocalization.string("Multi-agent workspace session"),
                icon: "person.2",
                primaryTitle: IntatisLocalization.string("New Cowork Session"),
                primarySystemImage: "plus",
                primaryShortcut: "n",
                error: coworkSessionError,
                sessionsTitle: IntatisLocalization.string("Recent Cowork Sessions"),
                sessions: [],
                workspacePath: { _ in String?.none },
                onPrimary: startNewCoworkSession,
                onResume: { resumeCoworkSession($0.id) })
        }
    }

    private var historyItems: [IntatisSessionHistoryItem] {
        let filed = Set(projectSidebarItems.flatMap {
            $0.conversations.map(\.reference)
        })
        return sessions(for: selection.sessionKind)
            .filter { session in
                !filed.contains(ProjectConversationReference(
                    sessionID: session.id,
                    kind: session.kind))
            }
            .map {
                historyItem(
                    $0,
                    icon: selection.icon,
                    selected: $0.id == selectedSessionID)
            }
    }

    private var projectSidebarItems: [ProjectSidebarItem] {
        env.projects.filter {
            $0.kind == selection.sessionKind
        }.map { project in
            let conversations = project.conversations.compactMap {
                reference -> ProjectConversationSidebarItem? in
                guard let session = sessionSummary(for: reference) else {
                    return nil
                }
                return ProjectConversationSidebarItem(
                    reference: reference,
                    title: session.displayName ?? session.id.rawValue,
                    systemImage: selection.icon,
                    updatedAt: session.updatedAt,
                    isSelected: session.id == selectedSessionID,
                    isDeleteDisabled: isDeleteDisabled(session))
            }
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
            return ProjectSidebarItem(
                project: project,
                conversations: conversations)
        }
        .sorted { lhs, rhs in
            let order = lhs.project.displayName.localizedCaseInsensitiveCompare(
                rhs.project.displayName)
            if order != .orderedSame { return order == .orderedAscending }
            if lhs.project.createdAt != rhs.project.createdAt {
                return lhs.project.createdAt < rhs.project.createdAt
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
    }

    private var selectedSessionID: SessionID? {
        switch selection {
        case .chat:
            return env.chatSessionID
        case .code:
            return codeVM?.sessionID
        case .cowork:
            return coworkVM?.sessionID
        }
    }

    private func sessionSummary(
        for reference: ProjectConversationReference
    ) -> AppSessionSummary? {
        sessions(for: reference.kind).first(where: {
            $0.id == reference.sessionID
        })
    }

    private var newSessionDisabled: Bool {
        guard env.runtimeManager.acceptsNewRuntimes else { return true }
        switch selection {
        case .chat, .code:
            return false
        case .cowork:
            return coworkTransitionID != nil
        }
    }

    private func historyItem(_ session: AppSessionSummary,
                             icon: String,
                             selected: Bool) -> IntatisSessionHistoryItem {
        IntatisSessionHistoryItem(
            id: session.id,
            title: session.displayName ?? session.id.rawValue,
            detail: "",
            systemImage: icon,
            isSelected: selected,
            isDeleteDisabled: isDeleteDisabled(session))
    }

    private func isDeleteDisabled(_ session: AppSessionSummary) -> Bool {
        guard runtimeManager.state == .running else { return true }
        let key = AppSessionRuntimeKey(kind: session.kind, sessionID: session.id)
        return runtimeStatuses[key]?.blocksDeletion == true
            || runtimeManager.isBusy(kind: session.kind, sessionID: session.id)
    }

    private func refreshAllSessions() {
        refreshChatSessions()
        refreshCodeSessions()
        refreshCoworkSessions()
        env.refreshProjects()
    }

    private func refreshChatSessions() {
        recentChatSessions = env.recentChatSessions()
    }

    private func refreshCodeSessions() {
        recentCodeSessions = env.recentCodeSessions()
    }

    private func refreshCoworkSessions() {
        recentCoworkSessions = env.recentCoworkSessions()
    }

    private func refreshSessions(kind: SessionKind) {
        switch kind {
        case .chat:
            refreshChatSessions()
        case .code:
            refreshCodeSessions()
        case .cowork:
            refreshCoworkSessions()
        }
    }

    private func handleRemovedRuntime(_ key: AppSessionRuntimeKey) {
        switch key.kind {
        case .chat:
            env.handleRemovedChatRuntime(sessionID: key.sessionID)
        case .code:
            if codeVM?.sessionID == key.sessionID {
                codeVM = nil
            }
        case .cowork:
            if coworkVM?.sessionID == key.sessionID {
                coworkVM = nil
            }
        }
        refreshAllSessions()
    }

    private func handleSessionDisplayNameChange(_ change: AppSessionDisplayNameChange) {
        switch change.key.kind {
        case .chat:
            guard let updated = replacingDisplayName(
                in: recentChatSessions,
                with: change) else {
                refreshChatSessions()
                return
            }
            recentChatSessions = updated
        case .code:
            guard let updated = replacingDisplayName(
                in: recentCodeSessions,
                with: change) else {
                refreshCodeSessions()
                return
            }
            recentCodeSessions = updated
        case .cowork:
            guard let updated = replacingDisplayName(
                in: recentCoworkSessions,
                with: change) else {
                refreshCoworkSessions()
                return
            }
            recentCoworkSessions = updated
        }
    }

    private func replacingDisplayName(
        in sessions: [AppSessionSummary],
        with change: AppSessionDisplayNameChange
    ) -> [AppSessionSummary]? {
        guard let index = sessions.firstIndex(where: {
            $0.id == change.key.sessionID &&
                $0.kind.rawValue == change.key.kind.rawValue
        }) else {
            return nil
        }
        var updated = sessions
        let current = updated[index]
        updated[index] = AppSessionSummary(
            id: current.id,
            kind: current.kind,
            updatedAt: current.updatedAt,
            eventCount: current.eventCount,
            displayName: change.displayName)
        return updated
    }

    private func selectMode(_ item: IntatisNavItem) {
        selection = item
        isSettings = false
        refreshAllSessions()
    }

    private func addProject() {
        guard let workspace = WorkspaceAccess.choose(
            prompt: IntatisLocalization.string("Choose Project Folder")) else {
            return
        }
        defer { workspace.release() }
        do {
            _ = try env.addProject(
                workspace: workspace,
                kind: selection.sessionKind)
            isSettings = false
            refreshAllSessions()
        } catch {
            sessionActionError = IntatisLocalization.format(
                "Could not add project: %@",
                error.localizedDescription)
        }
    }

    private func beginRemoveProject(_ projectID: ProjectID) {
        guard let project = env.projects.first(where: {
            $0.id == projectID
        }) else { return }
        projectRemovalTarget = ProjectRemovalTarget(
            id: project.id,
            title: project.displayName)
    }

    private func removeProject(_ target: ProjectRemovalTarget) {
        do {
            try env.removeProject(target.id)
            refreshAllSessions()
        } catch {
            sessionActionError = IntatisLocalization.format(
                "Could not remove project: %@",
                error.localizedDescription)
        }
    }

    private func selectProjectConversation(
        _ projectID: ProjectID,
        _ reference: ProjectConversationReference
    ) {
        guard env.projects.contains(where: {
            $0.id == projectID
                && $0.kind == selection.sessionKind
                && $0.conversations.contains(reference)
        }), sessionSummary(for: reference) != nil else {
            return
        }
        isSettings = false
        switch reference.kind {
        case .chat:
            guard let session = recentChatSessions.first(where: {
                $0.id == reference.sessionID
            }) else { return }
            env.resumeChatSession(session)
            refreshChatSessions()
        case .code:
            resumeCodeSession(reference.sessionID)
        case .cowork:
            resumeCoworkSession(reference.sessionID)
        }
    }

    private func startNewProjectConversation(
        _ projectID: ProjectID
    ) {
        guard !newSessionDisabled,
              let project = env.projects.first(where: {
                  $0.id == projectID && $0.kind == selection.sessionKind
              }) else { return }
        isSettings = false

        switch project.kind {
        case .chat:
            do {
                _ = try env.startNewProjectChatSession(projectID: projectID)
                refreshAllSessions()
            } catch {
                guard !(error is CancellationError) else { return }
                sessionActionError = IntatisLocalization.format(
                    "Could not start project conversation: %@",
                    error.localizedDescription)
            }
        case .code:
            do {
                let runtime = try env.makeProjectCodeViewModel(
                    projectID: projectID)
                selection = .code
                codeVM = runtime
                codeSessionError = nil
                refreshAllSessions()
            } catch {
                guard !(error is CancellationError) else { return }
                sessionActionError = IntatisLocalization.format(
                    "Could not start project conversation: %@",
                    error.localizedDescription)
            }
        case .cowork:
            selection = .cowork
            let transitionID = UUID()
            coworkTransitionID = transitionID
            Task { @MainActor in
                defer {
                    if coworkTransitionID == transitionID {
                        coworkTransitionID = nil
                    }
                }
                do {
                    let runtime = try await env.makeProjectCoworkViewModel(
                        projectID: projectID)
                    guard coworkTransitionID == transitionID else { return }
                    coworkVM = runtime
                    coworkSessionError = nil
                    refreshAllSessions()
                } catch {
                    if !(error is CancellationError) {
                        sessionActionError = IntatisLocalization.format(
                            "Could not start project conversation: %@",
                            error.localizedDescription)
                    }
                }
            }
        }
    }

    private func startNewSelectedSession() {
        isSettings = false
        switch selection {
        case .chat:
            env.startNewChatSession()
            refreshChatSessions()
        case .code:
            startNewCodeSession()
        case .cowork:
            startNewCoworkSession()
        }
    }

    private func resumeSelectedSession(_ sessionID: SessionID) {
        isSettings = false
        switch selection {
        case .chat:
            guard let session = recentChatSessions.first(where: { $0.id == sessionID }) else { return }
            env.resumeChatSession(session)
            refreshChatSessions()
        case .code:
            resumeCodeSession(sessionID)
        case .cowork:
            resumeCoworkSession(sessionID)
        }
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } })
    }

    private var projectRemovalAlertPresented: Binding<Bool> {
        Binding(
            get: { projectRemovalTarget != nil },
            set: { if !$0 { projectRemovalTarget = nil } })
    }

    private var sessionErrorPresented: Binding<Bool> {
        Binding(
            get: { sessionActionError != nil },
            set: { if !$0 { sessionActionError = nil } })
    }

    private func beginRenameSession(_ sessionID: SessionID) {
        guard let session = sessions(for: selection.sessionKind)
            .first(where: { $0.id == sessionID }) else { return }
        renameTarget = SessionActionTarget(
            sessionID: session.id,
            kind: session.kind,
            title: session.displayName ?? session.id.rawValue)
    }

    private func beginDeleteSession(_ sessionID: SessionID) {
        guard let session = sessions(for: selection.sessionKind)
            .first(where: { $0.id == sessionID }) else { return }
        deleteTarget = SessionActionTarget(
            sessionID: session.id,
            kind: session.kind,
            title: session.displayName ?? session.id.rawValue)
    }

    private func sessions(for kind: SessionKind) -> [AppSessionSummary] {
        switch kind {
        case .chat: return recentChatSessions
        case .code: return recentCodeSessions
        case .cowork: return recentCoworkSessions
        }
    }

    private func sessionTitle(kind: SessionKind, sessionID: SessionID) -> String {
        sessions(for: kind)
            .first(where: { $0.id == sessionID })
            .flatMap(\.displayName)
            ?? sessionID.rawValue
    }

    private func renameSession(_ target: SessionActionTarget, to newName: String) async throws {
        let log = try EventLog(
            session: target.sessionID,
            fileURL: AppConfig.sessionFile(target.sessionID))
        let update = try await SessionProjectionStore.renameDisplayName(
            in: log,
            kind: target.kind,
            displayName: newName,
            source: .userInterface)
        let projection = update.projection
        guard projection.sessionID == target.sessionID,
              projection.kind.rawValue == target.kind.rawValue,
              let displayName = projection.displayName,
              let settingsRevision = projection.settingsRevision else {
            throw SessionProjectionStoreError.verificationFailed
        }
        runtimeManager.publishSessionDisplayNameChange(AppSessionDisplayNameChange(
            key: AppSessionRuntimeKey(
                kind: projection.kind,
                sessionID: projection.sessionID),
            displayName: displayName,
            settingsRevision: settingsRevision,
            projectedThroughSeq: projection.projectedThroughSeq))
    }

    private func deleteSession(_ target: SessionActionTarget) {
        Task { @MainActor in
            do {
                switch target.kind {
                case .chat:
                    try await env.deleteChatSession(target.sessionID)
                case .code:
                    try await env.runtimeManager.removeSession(
                        kind: .code,
                        sessionID: target.sessionID,
                        reason: "Code session deleted by user"
                    ) {
                        try SessionHistoryStore.deleteSession(
                            root: AppConfig.appSupportDir(),
                            session: target.sessionID)
                        WorkspaceAccess.forget(session: target.sessionID)
                    }
                case .cowork:
                    try await env.runtimeManager.removeSession(
                        kind: .cowork,
                        sessionID: target.sessionID,
                        reason: "Cowork session deleted by user"
                    ) {
                        try SessionHistoryStore.deleteSession(
                            root: AppConfig.appSupportDir(),
                            session: target.sessionID)
                        CoworkProjectSettingsStore.remove(sessionID: target.sessionID)
                        WorkspaceAccess.forget(session: target.sessionID)
                    }
                }
                do {
                    try env.removeProjectConversation(
                        ProjectConversationReference(
                            sessionID: target.sessionID,
                            kind: target.kind))
                } catch {
                    sessionActionError = IntatisLocalization.format(
                        "The session was deleted, but its project reference could not be removed: %@",
                        error.localizedDescription)
                }
                refreshAllSessions()
            } catch {
                sessionActionError = error.localizedDescription
            }
        }
    }

    private func startNewCodeSession() {
        guard let authorization = WorkspaceAccess.choose() else { return }
        selection = .code
        isSettings = false
        do {
            codeVM = try env.makeCodeViewModel(workspace: authorization)
            codeSessionError = nil
            refreshCodeSessions()
        } catch {
            codeSessionError = IntatisLocalization.format(
                "Could not start Code session: %@",
                error.localizedDescription)
        }
    }

    private func showCodeSessions() {
        codeVM = nil
        refreshCodeSessions()
    }

    private func resumeCodeSession(_ sessionID: SessionID) {
        let workspace: WorkspaceAccessLease
        do {
            if let restored = try WorkspaceAccess.restoredWorkspace(for: sessionID) {
                workspace = restored
            } else {
                guard let expectedPath = try WorkspaceAccess.workspacePathChecked(for: sessionID),
                      let selected = WorkspaceAccess.choose(
                        prompt: IntatisLocalization.string("Reauthorize Code Workspace")) else {
                    codeSessionError = IntatisLocalization.string(
                        "The original Code workspace identity is unavailable; this session was not rebound.")
                    return
                }
                let expected = URL(fileURLWithPath: expectedPath)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard selected.canonicalURL == expected else {
                    selected.release()
                    codeSessionError = IntatisLocalization.format(
                        "Choose the original Code workspace at %@.",
                        expectedPath)
                    return
                }
                workspace = selected
            }
        } catch {
            codeSessionError = IntatisLocalization.format(
                "Code workspace access could not be read safely: %@",
                error.localizedDescription)
            return
        }
        selection = .code
        isSettings = false
        do {
            let runtime =
                try env.makeCodeViewModel(
                    session: sessionID,
                    workspace: workspace)
            codeVM = runtime
            Task { @MainActor [weak runtime] in
                await runtime?
                    .flushProjectionForPresentation()
            }
            codeSessionError = nil
            refreshCodeSessions()
        } catch {
            codeSessionError = IntatisLocalization.format(
                "Could not resume Code session: %@",
                error.localizedDescription)
        }
    }

    private func startNewCoworkSession() {
        guard let workspace = WorkspaceAccess.choose(
            prompt: IntatisLocalization.string("Choose Cowork Workspace")) else { return }
        selection = .cowork
        isSettings = false
        let transitionID = UUID()
        coworkTransitionID = transitionID
        Task { @MainActor in
            guard coworkTransitionID == transitionID else {
                workspace.release()
                return
            }
            do {
                let runtime = try await env.makeCoworkViewModel(primaryWorkspace: workspace)
                guard coworkTransitionID == transitionID else { return }
                coworkVM = runtime
                coworkSessionError = nil
                refreshCoworkSessions()
            } catch {
                coworkSessionError = IntatisLocalization.format(
                    "Could not start Cowork session: %@",
                    error.localizedDescription)
            }
            if coworkTransitionID == transitionID {
                coworkTransitionID = nil
            }
        }
    }

    private func showCoworkSessions() {
        coworkTransitionID = nil
        coworkVM = nil
        refreshCoworkSessions()
    }

    private func resumeCoworkSession(_ sessionID: SessionID) {
        selection = .cowork
        isSettings = false
        let transitionID = UUID()
        coworkTransitionID = transitionID
        Task { @MainActor in
            guard coworkTransitionID == transitionID else { return }
            do {
                let runtime = try await env.makeCoworkViewModel(session: sessionID)
                guard coworkTransitionID == transitionID else { return }
                await runtime.flushProjectionForPresentation()
                guard coworkTransitionID == transitionID else { return }
                coworkVM = runtime
                coworkSessionError = nil
                refreshCoworkSessions()
            } catch {
                coworkSessionError = IntatisLocalization.format(
                    "Could not resume Cowork session: %@",
                    error.localizedDescription)
            }
            if coworkTransitionID == transitionID {
                coworkTransitionID = nil
            }
        }
    }
}

private struct SessionRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var errorText: String?
    @State private var isRenaming = false
    private let onRename: (String) async throws -> Void

    init(initialName: String,
         onRename: @escaping (String) async throws -> Void) {
        _name = State(initialValue: initialName)
        self.onRename = onRename
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canRename: Bool {
        !trimmedName.isEmpty && trimmedName.count <= 120
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Session")
                .font(IntatisTypography.system(.headline))
            TextField("Session name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)

            if let errorText {
                Text(errorText)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: dismiss.callAsFunction)
                Button("Rename", action: rename)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename || isRenaming)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func rename() {
        guard canRename else { return }
        isRenaming = true
        Task { @MainActor in
            do {
                try await onRename(trimmedName)
                dismiss()
            } catch {
                errorText = error.localizedDescription
                isRenaming = false
            }
        }
    }
}

// MARK: - Sidebar

private struct IntatisSidebar: View {
    let items: [IntatisNavItem]
    let selection: IntatisNavItem
    @Binding var isSettings: Bool
    let projects: [ProjectSidebarItem]
    let projectStoreError: String?
    let historyItems: [IntatisSessionHistoryItem]
    let historyTitle: String
    let emptyHistoryTitle: String
    let newSessionTitle: String
    let isNewDisabled: Bool
    let onSelectMode: (IntatisNavItem) -> Void
    let onAddProject: () -> Void
    let onRemoveProject: (ProjectID) -> Void
    let onNewProjectConversation: (ProjectID) -> Void
    let onSelectProjectConversation:
        (ProjectID, ProjectConversationReference) -> Void
    let isProjectConversationCreationDisabled: Bool
    let onNewSession: () -> Void
    let onSelectSession: (SessionID) -> Void
    let onRenameSession: (SessionID) -> Void
    let onDeleteSession: (SessionID) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBlock
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 12)

            modeNavigation
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .accessibilityIdentifier("sidebar.mode.selector")

            Divider().opacity(0.45)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ProjectSidebarSection(
                        projects: projects,
                        newConversationTitle: newSessionTitle,
                        storeError: projectStoreError,
                        onAddProject: onAddProject,
                        onRemoveProject: onRemoveProject,
                        onNewConversation: onNewProjectConversation,
                        onSelectConversation:
                            onSelectProjectConversation,
                        onRenameConversation: onRenameSession,
                        onDeleteConversation: onDeleteSession,
                        isCreationDisabled:
                            isProjectConversationCreationDisabled)

                    Divider().opacity(0.45)

                    IntatisSessionHistoryList(
                        title: historyTitle,
                        newTitle: newSessionTitle,
                        emptyTitle: emptyHistoryTitle,
                        items: historyItems,
                        style: .translatisMac(scheme),
                        isNewDisabled: isNewDisabled,
                        usesOwnScrollView: false,
                        onNew: onNewSession,
                        onSelect: onSelectSession,
                        onRename: onRenameSession,
                        onDelete: onDeleteSession)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity, alignment: .top)

            Button { isSettings = true } label: {
                IntatisSidebarSettingsRow(selected: isSettings)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .accessibilityIdentifier("sidebar.settings")
        }
    }

    private var titleBlock: some View {
        Text(IntatisHostApplication.identity.name)
            .font(TranslatisType.brand(28))
            .foregroundStyle(TranslatisTheme.deepText(scheme))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modeNavigation: some View {
        VStack(spacing: 4) {
            ForEach(items) { item in
                let isSelected = selection == item
                    && !isSettings
                Button {
                    onSelectMode(item)
                } label: {
                    IntatisSidebarModeRow(
                        title: item.title,
                        systemImage: item.icon,
                        selected: isSelected)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("sidebar.mode.\(item.rawValue)")
            }
        }
    }
}

private struct ProjectSidebarSection: View {
    let projects: [ProjectSidebarItem]
    let newConversationTitle: String
    let storeError: String?
    let onAddProject: () -> Void
    let onRemoveProject: (ProjectID) -> Void
    let onNewConversation: (ProjectID) -> Void
    let onSelectConversation:
        (ProjectID, ProjectConversationReference) -> Void
    let onRenameConversation: (SessionID) -> Void
    let onDeleteConversation: (SessionID) -> Void
    let isCreationDisabled: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var expandedProjectIDs: Set<ProjectID> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(IntatisLocalization.string("Projects"))
                    .font(IntatisTypography.system(size: 12, weight: .semibold))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onAddProject) {
                    Label("Add Project", systemImage: "folder.badge.plus")
                        .labelStyle(.iconOnly)
                        .font(IntatisTypography.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                .controlSize(.small)
                .buttonBorderShape(.circle)
                .intatisGlassButton()
                .help(IntatisLocalization.string("Add Project"))
                .accessibilityLabel(IntatisLocalization.string("Add Project"))
                .accessibilityIdentifier("sidebar.project.add")
            }

            if let storeError {
                Text(storeError)
                    .font(IntatisTypography.system(size: 11, weight: .regular))
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if projects.isEmpty {
                Text(IntatisLocalization.string("No projects yet."))
                    .font(IntatisTypography.system(size: 12, weight: .medium))
                    .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                    .padding(.vertical, 4)
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(projects) { item in
                        project(item)
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func project(_ item: ProjectSidebarItem) -> some View {
        let isExpanded = expandedProjectIDs.contains(item.id)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Button {
                    if isExpanded {
                        expandedProjectIDs.remove(item.id)
                    } else {
                        expandedProjectIDs.insert(item.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(IntatisTypography.system(
                                size: 9,
                                weight: .semibold))
                            .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: isExpanded ? "folder.fill" : "folder")
                            .font(IntatisTypography.system(
                                size: 12,
                                weight: .medium))
                            .foregroundStyle(isExpanded
                                ? TranslatisTheme.accent(scheme)
                                : TranslatisTheme.tertiaryText(scheme))
                            .frame(width: 16)
                        Text(item.project.displayName)
                            .font(IntatisTypography.system(
                                size: 12,
                                weight: isExpanded ? .semibold : .medium))
                            .foregroundStyle(TranslatisTheme.softText(scheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text("\(item.conversations.count)")
                            .font(IntatisTypography.system(size: 10, weight: .medium))
                            .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .contentShape(RoundedRectangle(
                        cornerRadius: 8,
                        style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.project.displayName)
                .accessibilityValue(Text(IntatisLocalization.string(
                    isExpanded ? "Expanded" : "Collapsed")))
                .accessibilityIdentifier(
                    "sidebar.project.\(item.id.rawValue)")
                .contextMenu {
                    Button(role: .destructive) {
                        onRemoveProject(item.id)
                    } label: {
                        Label("Remove Project…", systemImage: "folder.badge.minus")
                    }
                }

                Button {
                    onNewConversation(item.id)
                } label: {
                    Image(systemName: "plus")
                        .font(IntatisTypography.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .disabled(isCreationDisabled)
                .help(newConversationTitle)
                .accessibilityLabel(newConversationTitle)
                .accessibilityIdentifier(
                    "sidebar.project.\(item.id.rawValue).new")
            }

            if isExpanded {
                if item.conversations.isEmpty {
                    Text(IntatisLocalization.string("No conversations yet."))
                        .font(IntatisTypography.system(
                            size: 10,
                            weight: .regular))
                        .foregroundStyle(TranslatisTheme.tertiaryText(scheme))
                        .padding(.leading, 35)
                        .padding(.vertical, 3)
                } else {
                    ForEach(item.conversations) { conversation in
                        Button {
                            onSelectConversation(
                                item.id,
                                conversation.reference)
                        } label: {
                            ProjectConversationRow(item: conversation)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 25)
                        .accessibilityIdentifier(
                            "sidebar.project.conversation.\(conversation.id)")
                        .contextMenu {
                            Button {
                                onRenameConversation(
                                    conversation.reference.sessionID)
                            } label: {
                                Label("Rename…", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                onDeleteConversation(
                                    conversation.reference.sessionID)
                            } label: {
                                Label("Delete…", systemImage: "trash")
                            }
                            .disabled(conversation.isDeleteDisabled)
                        }
                    }
                }
            }
        }
    }
}

private struct ProjectConversationRow: View {
    let item: ProjectConversationSidebarItem
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: item.systemImage)
                .font(IntatisTypography.system(size: 11, weight: .medium))
                .foregroundStyle(item.isSelected
                    ? TranslatisTheme.accent(scheme)
                    : TranslatisTheme.tertiaryText(scheme))
                .frame(width: 14)
            Text(item.title)
                .font(IntatisTypography.system(
                    size: 11,
                    weight: item.isSelected ? .semibold : .medium))
                .foregroundStyle(item.isSelected
                    ? TranslatisTheme.deepText(scheme)
                    : TranslatisTheme.softText(scheme))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    item.isSelected
                        ? TranslatisTheme.accent(scheme).opacity(0.36)
                        : Color.clear,
                    lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

private struct IntatisSidebarModeRow: View {
    let title: String
    let systemImage: String
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if selected {
                content
                    .intatisLiquidGlass(cornerRadius: 10, interactive: true)
            } else {
                content
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var content: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(IntatisTypography.system(size: 14, weight: .semibold))
                .foregroundStyle(selected
                    ? TranslatisTheme.accent(scheme)
                    : TranslatisTheme.softText(scheme))
                .frame(width: 22)
            Text(title)
                .font(TranslatisType.body(14, selected ? .semibold : .medium))
                .foregroundStyle(selected
                    ? TranslatisTheme.deepText(scheme)
                    : TranslatisTheme.softText(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

private struct IntatisSidebarSettingsRow: View {
    let selected: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "gearshape")
                .font(IntatisTypography.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? TranslatisTheme.accent(scheme) : TranslatisTheme.softText(scheme))
                .frame(width: 20)
            Text(IntatisLocalization.string("Settings"))
                .font(TranslatisType.body(13, selected ? .semibold : .medium))
                .foregroundStyle(selected ? TranslatisTheme.deepText(scheme) : TranslatisTheme.softText(scheme))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(selected ? TranslatisTheme.selectedStroke(scheme) : TranslatisTheme.separator(scheme),
                        lineWidth: 1)
                .opacity(selected ? 1 : (hover ? 0.4 : 0))
        }
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { hover = $0 }
    }
}
#endif
