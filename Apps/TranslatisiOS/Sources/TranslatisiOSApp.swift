#if canImport(SwiftUI)
import SwiftUI
import Combine
import Foundation
import UniformTypeIdentifiers
import IntatisCore
import IntatisProviders
import IntatisConversation
import IntatisArtifacts
import IntatisMultimodal
import IntatisSharedUI

struct IOSConfigurationImportSummary: Equatable, Sendable {
    var providerCount: Int
    var modelCount: Int
    var warnings: [ImportedChatConfiguration.Warning]
}

/// Stable, process-level metadata channel. It is deliberately separate from
/// the replaceable ChatViewModel so a title generated for session A can still
/// update A's row after the user has switched to session B.
@MainActor
private final class IOSChatSessionMetadataRelay {
    let changes = PassthroughSubject<ChatSessionAutoTitleCommit, Never>()
    private var watermarks = SessionDisplayNameWatermarks()

    func accept(_ commit: ChatSessionAutoTitleCommit) {
        guard commit.kind == .chat else { return }
        guard watermarks.accept(
            sessionID: commit.sessionID,
            kind: commit.kind,
            settingsRevision: commit.settingsRevision,
            projectedThroughSeq: commit.projectedThroughSeq
        ) else { return }
        changes.send(commit)
    }
}

/// iOS app environment — the chat-only subset. It links Core / Providers /
/// Conversation / Artifacts / Multimodal / SharedUI and *cannot* reach Tools,
/// Permission, AgentKernel, or Cowork: those packages are simply not linked, so
/// there is no code path to a local workspace (ARCHITECTURE.md §4.1).
@MainActor
final class IOSAppEnvironment: ObservableObject {
    @Published private(set) var registry: ProviderRegistry
    @Published private(set) var providerCatalog: IOSProviderCatalog
    @Published private(set) var chatSessionID: SessionID
    @Published private(set) var viewModel: ChatViewModel
    @Published private(set) var chatSessionError: String?
    private(set) var log: EventLog
    private(set) var multimodal: MultimodalService
    @Published var needsAPIKey: Bool

    private let secrets: ConfigSecretResolver
    private let chatAutoTitleCoordinator: ChatSessionAutoTitleCoordinator
    private let chatSessionMetadataRelay: IOSChatSessionMetadataRelay
    private var chatAutoTitleSessions: [SessionID: ChatSessionAutoTitleSession]

    var chatSessionMetadataChanged:
        PassthroughSubject<ChatSessionAutoTitleCommit, Never> {
        chatSessionMetadataRelay.changes
    }

    init() {
        PlatformProfile.current = .iOS   // chat-only, no workspace, no shell

        let autoTitleCoordinator = ChatSessionAutoTitleCoordinator()
        let metadataRelay = IOSChatSessionMetadataRelay()
        self.chatAutoTitleCoordinator = autoTitleCoordinator
        self.chatSessionMetadataRelay = metadataRelay
        self.secrets = ConfigSecretResolver()
        self.providerCatalog = IOSConfig.providerCatalog
        let initialRegistry = Self.makeProviderRegistry(resolver: secrets)
        self.registry = initialRegistry
        let initialSession = IOSConfig.recentSessions().first?.id ?? IOSConfig.defaultSession
        self.chatSessionID = initialSession
        do {
            self.log = try EventLog(session: initialSession, fileURL: IOSConfig.sessionFile(initialSession))
        } catch {
            fatalError("Failed to open event log: \(error)")
        }
        let store: ArtifactStore
        do {
            store = try ArtifactStore(root: IOSConfig.artifactsDir(initialSession))
        } catch {
            fatalError("Failed to open artifact store: \(error)")
        }
        self.multimodal = MultimodalService(log: log, store: store)
        let autoTitleSession = autoTitleCoordinator.bind(
            sessionID: initialSession,
            log: log,
            onCommit: { commit in
                await metadataRelay.accept(commit)
            })
        self.chatAutoTitleSessions = [initialSession: autoTitleSession]
        self.viewModel = ChatViewModel(
            log: log,
            registry: initialRegistry,
            artifactStore: store,
            autoTitleSession: autoTitleSession)
        self.needsAPIKey = !Self.hasAPIKey(ref: IOSConfig.selectedAPIKeyRef)

        wireImageGeneration()
    }

    func startNewChatSession() {
        do {
            try switchChatSession(to: SessionID.new())
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not start chat session: %@",
                error.localizedDescription)
        }
    }

    func resumeChatSession(_ session: IOSSessionSummary) {
        do {
            try switchChatSession(to: session.id)
        } catch {
            chatSessionError = IntatisLocalization.format(
                "Could not resume chat session: %@",
                error.localizedDescription)
        }
    }

    func recentChatSessions() -> [IOSSessionSummary] {
        IOSConfig.recentSessions()
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let providerID = providerCatalog.selectedProvider?.id ?? "default"
        try? ConfigSecretResolver.writeSecrets([providerID: trimmed])
        secrets.cache(trimmed, for: .authFile(providerID: providerID))
        needsAPIKey = false
    }

    func hasAPIKey(account: String) -> Bool {
        Self.hasAPIKey(ref: .authFile(providerID: account))
    }

    func hasAPIKey(for provider: IOSProviderSettings) -> Bool {
        Self.hasAPIKey(ref: IOSConfig.apiKeyRef(for: provider))
    }

    func saveSettings(catalog rawCatalog: IOSProviderCatalog,
                      apiKeysByProviderID: [String: String]) throws {
        var catalog = IOSConfig.normalizedCatalog(rawCatalog)
        for index in catalog.providers.indices {
            let provider = catalog.providers[index]
            let key = apiKeysByProviderID[provider.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty else { continue }
            try ConfigSecretResolver.writeSecrets([provider.id: key])
            catalog.providers[index].apiKeySource = IOSProviderAPIKeySource(type: "authFile", value: "")
            secrets.cache(key, for: IOSConfig.apiKeyRef(for: catalog.providers[index]))
        }
        try IOSConfig.saveProviderCatalog(catalog)
        providerCatalog = IOSConfig.providerCatalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))

        refreshProviderRegistry()
    }

    func importProviderConfiguration(
        data: Data,
        sourceURL: URL
    ) throws -> IOSConfigurationImportSummary {
        let imported = try ChatConfigurationImporter.parse(
            data: data,
            sourceURL: sourceURL)
        var literalSecrets: [String: String] = [:]
        imported.forEachLiteralSecret { providerID, secret in
            literalSecrets[providerID] = secret
        }
        try ConfigSecretResolver.writeSecrets(literalSecrets)
        for (providerID, secret) in literalSecrets {
            secrets.cache(secret, for: .authFile(providerID: providerID))
        }

        let catalog = try IOSConfig.installImportedConfiguration(
            imported,
            sourceFilename: sourceURL.lastPathComponent)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(
            ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
        return IOSConfigurationImportSummary(
            providerCount: imported.providerCount,
            modelCount: imported.modelCount,
            warnings: imported.warnings)
    }

    func selectProviderModel(providerID: String, modelID: String) {
        let catalog = IOSConfig.selectProviderModel(providerID: providerID, modelID: modelID)
        providerCatalog = catalog
        needsAPIKey = !Self.hasAPIKey(ref: catalog.selectedProvider.map(IOSConfig.apiKeyRef(for:))
                                      ?? .authFile(providerID: "default"))
        refreshProviderRegistry()
    }

    func healthCheckSelectedProvider() async -> ProviderHealthReport {
        await registry.healthCheck(role: .chat, options: ProviderHealthCheckOptions(timeoutSeconds: 15))
    }

    private static func makeProviderRegistry(resolver: ConfigSecretResolver) -> ProviderRegistry {
        ProviderRegistry(config: IOSConfig.providerConfig(), resolver: resolver)
    }

    private func refreshProviderRegistry() {
        secrets.clearCache()
        let updated = Self.makeProviderRegistry(resolver: secrets)
        registry = updated
        viewModel.updateProviderRegistry(updated)
        wireImageGeneration()
    }

    private func switchChatSession(to session: SessionID) throws {
        viewModel.stop()
        let log = try EventLog(session: session, fileURL: IOSConfig.sessionFile(session))
        let store = try ArtifactStore(root: IOSConfig.artifactsDir(session))
        let autoTitleSession: ChatSessionAutoTitleSession
        if let existing = chatAutoTitleSessions[session] {
            autoTitleSession = existing
        } else {
            autoTitleSession = chatAutoTitleCoordinator.bind(
                sessionID: session,
                log: log,
                onCommit: { [metadataRelay = chatSessionMetadataRelay] commit in
                    await metadataRelay.accept(commit)
                })
            chatAutoTitleSessions[session] = autoTitleSession
        }
        let model = ChatViewModel(
            log: log,
            registry: registry,
            artifactStore: store,
            autoTitleSession: autoTitleSession)
        self.log = log
        self.multimodal = MultimodalService(log: log, store: store)
        self.viewModel = model
        self.chatSessionID = session
        self.chatSessionError = nil
        wireImageGeneration()
        model.start()
    }

    private static func hasAPIKey(ref: KeychainRef) -> Bool {
        ConfigSecretResolver.exists(ref)
    }

    private func wireImageGeneration() {
        viewModel.onGenerateImage = { [weak self] prompt in
            guard let self else { throw IntatisError.cancelled }
            guard let provider = try await self.registry.defaultImageProvider(),
                  let model = await self.registry.imageModel() else {
                throw IntatisError.config("image generation is not configured")
            }
            _ = try await self.multimodal.generateImage(using: provider, model: model, prompt: prompt)
        }
    }
}

struct IOSRootView: View {
    @EnvironmentObject var env: IOSAppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .title)
    private var brandTitleSize: CGFloat = IntatisTypography.spec(for: .brand).nominalPointSize
    @ScaledMetric(relativeTo: .largeTitle)
    private var sessionTitleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .largeTitle)
    private var settingsTitleSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body)
    private var settingsRowSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption)
    private var captionSize: CGFloat = IntatisTypography.spec(for: .caption).nominalPointSize
    @State private var showSettings = false
    @State private var showSidebar = false
    @State private var showConfigImporter = false
    @State private var catalog = IOSConfig.providerCatalog
    @State private var apiKeysByProviderID: [String: String] = [:]
    @State private var settingsError: String?
    @State private var configImportMessage: String?
    @State private var configImportWarnings: [String] = []
    @State private var isTestingProvider = false
    @State private var providerHealthReport: ProviderHealthReport?
    @State private var recentSessions: [IOSSessionSummary] = []
    @AppStorage(IntatisMessageRendererMode.defaultsKey)
    private var rendererModeRawValue = IntatisMessageRendererMode.microsoft.rawValue

    var body: some View {
        // iOS uses the shared chat thread in single-column mode; Code/Cowork are
        // not linked, so no local workspace execution is reachable.
        NavigationStack {
            GeometryReader { proxy in
                let sidebarWidth = min(max(proxy.size.width * 0.82, 280), 420)

                ZStack(alignment: .leading) {
                    sidebar(width: sidebarWidth)

                    chatSurface
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .simultaneousGesture(openSidebarEdgeGesture)
                        .clipShape(RoundedRectangle(
                            cornerRadius: showSidebar ? 30 : 0,
                            style: .continuous))
                        .overlay {
                            if showSidebar {
                                RoundedRectangle(cornerRadius: 30, style: .continuous)
                                    .stroke(.secondary.opacity(0.18), lineWidth: 1)
                            }
                        }
                        .overlay {
                            if showSidebar {
                                Rectangle()
                                    .fill(.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { setSidebarVisible(false) }
                                    .accessibilityLabel(
                                        IntatisLocalization.string("Close sidebar"))
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityIdentifier("ios.sidebar.close")
                            }
                        }
                        .offset(x: showSidebar ? sidebarWidth : 0)
                }
                .background(.background)
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.34, extraBounce: 0),
                    value: showSidebar)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .task(id: env.chatSessionID.rawValue) {
            refreshSessions()
        }
        .onReceive(
            Publishers.CombineLatest(
                env.viewModel.$isStreaming,
                env.viewModel.$imageGenerationState)
                .map { isStreaming, generationState in
                    isStreaming || generationState.isRunning
                }
                .removeDuplicates()
        ) { isBusy in
            if !isBusy {
                refreshSessions()
            }
        }
        .onReceive(env.chatSessionMetadataChanged) { commit in
            applyAutoTitleCommit(commit)
        }
    }

    private var chatSurface: some View {
        VStack(spacing: 0) {
            chatHeader
            sessionErrorBanner
            ThreeColumnShell(
                model: env.viewModel,
                layout: .iOSChat,
                composerLeadingAccessory: AnyView(
                    IOSChatModelMenu(
                        catalog: env.providerCatalog,
                        isBusy: env.viewModel.isBusy,
                        onSelect: env.selectProviderModel(providerID:modelID:))),
                placesTurnStatsInComposer: true,
                presentationScope: IntatisThreadPresentationScope(
                    kind: .chat,
                    sessionID: env.chatSessionID))
                .id(env.chatSessionID.rawValue)
        }
        .background(.background)
    }

    private var chatHeader: some View {
        HStack(spacing: 12) {
            Button {
                openSidebar()
            } label: {
                Label(
                    IntatisLocalization.string("Open sidebar"),
                    systemImage: "line.3.horizontal")
                    .intatisComposerIconLabel()
            }
            .intatisCompactIconButton()
            .accessibilityIdentifier("ios.sidebar.open")
            .frame(width: 48)

            Text(activeSessionTitle)
                .font(IntatisTypography.largeTitle(sessionTitleSize))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("ios.chat.session-title")

            Button {
                startNewChat()
            } label: {
                Label(
                    IntatisLocalization.string("New chat"),
                    systemImage: "square.and.pencil")
                    .intatisComposerIconLabel()
            }
            .intatisCompactIconButton()
            .disabled(env.viewModel.isBusy)
            .accessibilityIdentifier("ios.chat.new")
            .frame(width: 48)
        }
        .padding(.horizontal, 12)
        .frame(height: 64)
        .accessibilityElement(children: .contain)
    }

    private func sidebar(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(IntatisHostApplication.identity.name)
                .font(IntatisTypography.brand(brandTitleSize))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.top, 10)
                .padding(.bottom, 12)

            IOSSidebarModeRow()
                .padding(.bottom, 14)
                .accessibilityIdentifier("ios.sidebar.mode.chat")

            Divider()
                .opacity(0.45)
                .padding(.bottom, 12)

            IntatisSessionHistoryList(
                title: IntatisLocalization.string("Recent"),
                newTitle: IntatisLocalization.string("New chat"),
                emptyTitle: IntatisLocalization.string("No chat sessions yet."),
                items: sidebarHistoryItems,
                style: .standard(colorScheme),
                isNewDisabled: env.viewModel.isBusy,
                onNew: { startNewChat(closingSidebar: true) },
                onSelect: selectSession(id:))
                .frame(maxHeight: .infinity, alignment: .top)

            Button {
                presentSettings()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "gearshape")
                        .font(IntatisTypography.body(settingsRowSize, .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    Text(IntatisLocalization.string("Settings"))
                        .font(IntatisTypography.body(settingsRowSize, .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(RoundedRectangle(
                    cornerRadius: 8,
                    style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityIdentifier("chat.settings")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .leading)
        .background(.background)
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(
                minimumDistance: IntatisSidebarGesturePolicy.minimumDistance)
                .onEnded { value in
                    if IntatisSidebarGesturePolicy.shouldClose(
                        translation: value.translation) {
                        setSidebarVisible(false)
                    }
                })
        .allowsHitTesting(showSidebar)
        .accessibilityHidden(!showSidebar)
    }

    @ViewBuilder private var sessionErrorBanner: some View {
        if let error = env.chatSessionError {
            Text(error)
                .font(captionFont)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay {
                    Capsule().stroke(Color.red.opacity(0.45), lineWidth: 1)
                }
                .padding(.top, 8)
        }
    }

    private func refreshSessions() {
        recentSessions = env.recentChatSessions()
    }

    private func applyAutoTitleCommit(_ commit: ChatSessionAutoTitleCommit) {
        guard commit.kind == .chat else { return }
        // Reload the canonical list for any activity that landed alongside the
        // rename, then exact-patch the verified commit. The patch also avoids a
        // filesystem metadata-cache edge where an equal-length title could be
        // temporarily returned from an older projection entry.
        refreshSessions()
        guard let index = recentSessions.firstIndex(where: {
            $0.id == commit.sessionID && $0.kind == .chat
        }) else { return }
        let current = recentSessions[index]
        recentSessions[index] = SessionSummary(
            id: current.id,
            kind: current.kind,
            updatedAt: current.updatedAt,
            eventCount: current.eventCount,
            displayName: commit.displayName)
    }

    private var openSidebarEdgeGesture: some Gesture {
        DragGesture(
            minimumDistance: IntatisSidebarGesturePolicy.minimumDistance,
            coordinateSpace: .local)
            .onEnded { value in
                guard !showSidebar,
                      IntatisSidebarGesturePolicy.shouldOpen(
                        startX: value.startLocation.x,
                        translation: value.translation) else { return }
                openSidebar()
            }
    }

    private func openSidebar() {
        refreshSessions()
        setSidebarVisible(true)
    }

    private func sessionMenuTitle(_ session: IOSSessionSummary) -> String {
        if let displayName = session.displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        if session.eventCount == 0 || session.updatedAt == .distantPast {
            return IntatisLocalization.string("New chat")
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: session.updatedAt)
    }

    private func selectSession(_ session: IOSSessionSummary) {
        if session.id != env.chatSessionID {
            env.resumeChatSession(session)
            refreshSessions()
        }
        setSidebarVisible(false)
    }

    private func selectSession(id: SessionID) {
        guard let session = recentSessions.first(where: { $0.id == id }) else {
            return
        }
        selectSession(session)
    }

    private var activeSessionTitle: String {
        guard let session = recentSessions.first(where: {
            $0.id == env.chatSessionID
        }) else {
            return IntatisLocalization.string("New chat")
        }
        return sessionMenuTitle(session)
    }

    private var sidebarHistoryItems: [IntatisSessionHistoryItem] {
        recentSessions.prefix(24).map { session in
            IntatisSessionHistoryItem(
                id: session.id,
                title: sessionMenuTitle(session),
                detail: "",
                systemImage: "bubble.left.and.bubble.right",
                isSelected: session.id == env.chatSessionID)
        }
    }

    private func startNewChat(closingSidebar: Bool = false) {
        env.startNewChatSession()
        refreshSessions()
        if closingSidebar {
            setSidebarVisible(false)
        }
    }

    private func presentSettings() {
        catalog = IOSConfig.providerCatalog
        setSidebarVisible(false)
        showSettings = true
    }

    private func setSidebarVisible(_ isVisible: Bool) {
        showSidebar = isVisible
    }

    private var settingsSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                Text(IntatisLocalization.string("Settings"))
                    .font(IntatisTypography.largeTitle(settingsTitleSize))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Form {
                Section("Configuration") {
                    Button {
                        showConfigImporter = true
                    } label: {
                        Label(
                            "Import \(IntatisHostApplication.identity.name) Config",
                            systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("settings.import-config")

                    if let filename = IOSConfig.importedConfigDescription {
                        LabeledContent("Imported file", value: filename)
                    }

                    Text("Import a \(IntatisHostApplication.identity.name) JSON or JSONC file from Files. Provider and model settings are stored in this app; literal credentials are migrated to the protected auth file.")
                        .font(captionFont)
                        .foregroundStyle(.secondary)

                    if let configImportMessage {
                        Label(
                            configImportMessage,
                            systemImage: configImportWarnings.isEmpty
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill")
                            .font(captionFont)
                            .foregroundStyle(configImportWarnings.isEmpty ? .green : .orange)
                    }

                    ForEach(Array(configImportWarnings.enumerated()), id: \.offset) { _, warning in
                        Text(warning)
                            .font(captionFont)
                            .foregroundStyle(.orange)
                    }
                }

                if let providerIndex = selectedProviderIndex {
                    Section("Provider") {
                        Picker("Active provider", selection: $catalog.selectedProviderID) {
                            ForEach(catalog.providers) { provider in
                                Text(provider.title).tag(provider.id)
                            }
                        }
                        .onChange(of: catalog.selectedProviderID) { _, _ in
                            ensureSelectedModel()
                        }

                        TextField("Provider name", text: providerFieldBinding(providerIndex, \.displayName))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Base URL", text: baseURLBinding(providerIndex))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Chat endpoint", text: chatEndpointBinding(providerIndex))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField(apiKeyPlaceholder(for: catalog.providers[providerIndex]),
                                    text: apiKeyBinding(for: catalog.providers[providerIndex].id))

                        Button("Add Provider") { addProvider() }
                        Button("Delete Provider", role: .destructive) { removeProvider(providerIndex) }
                            .disabled(catalog.providers.count == 1)
                    }

                    Section("Models") {
                        Picker("Active model", selection: $catalog.selectedModelID) {
                            ForEach(catalog.providers[providerIndex].models) { model in
                                Text(model.title).tag(model.id)
                            }
                        }

                        ForEach(Array(catalog.providers[providerIndex].models.indices), id: \.self) { modelIndex in
                            TextField("Model ID",
                                      text: modelFieldBinding(providerIndex: providerIndex,
                                                              modelIndex: modelIndex,
                                                              keyPath: \.id))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("Display name",
                                      text: modelFieldBinding(providerIndex: providerIndex,
                                                              modelIndex: modelIndex,
                                                              keyPath: \.displayName))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button("Delete Model", role: .destructive) {
                                removeModel(providerIndex: providerIndex, modelIndex: modelIndex)
                            }
                            .disabled(catalog.providers[providerIndex].models.count == 1)
                        }

                        Button("Add Model") { addModel(providerIndex: providerIndex) }
                    }

                    Section("Health Check") {
                        Button {
                            testProvider()
                        } label: {
                            Label(isTestingProvider
                                    ? IntatisLocalization.string("Testing Provider")
                                    : IntatisLocalization.string("Test Provider"),
                                  systemImage: isTestingProvider ? "hourglass" : "checkmark.seal")
                        }
                        .disabled(isTestingProvider)

                        if isTestingProvider {
                            ProgressView("Testing provider...")
                        } else if let report = providerHealthReport {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(IntatisLocalization.string(report.displayTitle),
                                      systemImage: report.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(report.isOK ? .green : .red)
                                Text(IntatisLocalization.providerHealthSummary(report))
                                    .font(captionFont)
                                    .foregroundStyle(.secondary)
                                Text(IntatisLocalization.providerHealthDetail(report))
                                    .font(captionFont)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Message Rendering") {
                    Picker("Message rendering", selection: rendererModeSelection) {
                        Text("Rich Markdown").tag(IntatisMessageRendererMode.microsoft.rawValue)
                        Text("Plain text safe mode").tag(IntatisMessageRendererMode.plainSafe.rawValue)
                    }
                    Text(messageRendererHelpText)
                        .font(captionFont)
                        .foregroundStyle(.secondary)
                }

                Section("Open Source") {
                    NavigationLink("Third-party notices") {
                        IntatisThirdPartyNoticesView()
                            .navigationTitle("Open-source notices")
                            .navigationBarTitleDisplayMode(.inline)
                    }
                }

                if let settingsError {
                    Section {
                        Text(settingsError).font(captionFont).foregroundStyle(.red)
                    }
                }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showSettings = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                            catalog = IOSConfig.providerCatalog
                            apiKeysByProviderID = [:]
                            settingsError = nil
                            providerHealthReport = nil
                            showSettings = false
                        } catch {
                            settingsError = IntatisLocalization.format(
                                "Could not save settings: %@",
                                error.localizedDescription)
                        }
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showConfigImporter,
            allowedContentTypes: [.json, Self.jsoncType],
            allowsMultipleSelection: false,
            onCompletion: importConfiguration)
    }

    private static var jsoncType: UTType {
        UTType(filenameExtension: "jsonc") ?? .plainText
    }

    private var captionFont: Font {
        IntatisTypography.caption(captionSize, .regular)
    }

    private func importConfiguration(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else {
                throw IntatisError.config("no configuration file was selected")
            }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess { url.stopAccessingSecurityScopedResource() }
            }
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            if let fileSize = resourceValues.fileSize,
               fileSize > ChatConfigurationImporter.maximumByteCount {
                throw ChatConfigurationImportError.fileTooLarge
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let summary = try env.importProviderConfiguration(
                data: data,
                sourceURL: url)
            catalog = IOSConfig.providerCatalog
            apiKeysByProviderID = [:]
            providerHealthReport = nil
            settingsError = nil

            let imported = IntatisLocalization.format(
                "Imported providers: %lld · models: %lld.",
                Int64(summary.providerCount),
                Int64(summary.modelCount))
            configImportWarnings = summary.warnings.map(importWarningText)
            if !summary.warnings.isEmpty {
                configImportMessage = imported + " " + IntatisLocalization.format(
                    "%lld compatibility warnings require review.",
                    Int64(summary.warnings.count))
            } else {
                configImportMessage = imported
            }
        } catch {
            configImportMessage = nil
            configImportWarnings = []
            settingsError = IntatisLocalization.format(
                "Could not import configuration: %@",
                error.localizedDescription)
        }
    }

    private func importWarningText(
        _ warning: ImportedChatConfiguration.Warning
    ) -> String {
        switch warning {
        case .ignoredModelVariants(let providerID, let modelID):
            return IntatisLocalization.format(
                "Variants for %@/%@ are not imported on iOS.",
                boundedImportLabel(providerID),
                boundedImportLabel(modelID))
        case .externalCredentialReference(let providerID, let kind):
            return IntatisLocalization.format(
                "%@ uses an external %@ credential reference; verify or enter the credential on iOS.",
                boundedImportLabel(providerID),
                boundedImportLabel(kind))
        case .unsupportedRequestAdapter(let providerID, let package):
            return IntatisLocalization.format(
                "%@ uses unsupported provider adapter %@; requests remain blocked until a supported OpenAI-compatible adapter is selected.",
                boundedImportLabel(providerID),
                boundedImportLabel(package))
        case .skippedProviderWithoutBaseURL(let providerID):
            return IntatisLocalization.format(
                "%@ was skipped because it has no OpenAI-compatible Base URL for iOS Chat.",
                boundedImportLabel(providerID))
        }
    }

    private func boundedImportLabel(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(120))
    }

    private var messageRendererHelpText: String {
        if let launchOverride = IntatisMessageRendererMode.launchOverride() {
            let label = launchOverride == .plainSafe
                ? IntatisLocalization.string("Plain text safe mode")
                : IntatisLocalization.string("Rich Markdown")
            return IntatisLocalization.format(
                "Current launch is forced to %@. This picker is saved immediately for the next launch without an override; Cancel only discards provider edits.",
                label)
        }
        return IntatisLocalization.string(
            "This choice is saved and applied immediately; Cancel only discards provider edits. Rich Markdown uses the audited upstream renderer with images, math typesetting, and syntax highlighting disabled for the first release. Plain text safe mode bypasses Markdown entirely without changing session data.")
    }

    private var rendererModeSelection: Binding<String> {
        Binding(
            get: {
                IntatisMessageRendererMode.resolve(
                    persistedRawValue: rendererModeRawValue,
                    arguments: []).rawValue
            },
            set: { rendererModeRawValue = $0 })
    }

    private var selectedProviderIndex: Int? {
        catalog.providers.firstIndex { $0.id == catalog.selectedProviderID } ?? catalog.providers.indices.first
    }

    private func ensureSelectedModel() {
        guard let providerIndex = selectedProviderIndex else { return }
        let provider = catalog.providers[providerIndex]
        if !provider.models.contains(where: { $0.id == catalog.selectedModelID }) {
            catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
        }
    }

    private func addProvider() {
        let provider = IOSConfig.newProvider()
        catalog.providers.append(provider)
        catalog.selectedProviderID = provider.id
        catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
    }

    private func removeProvider(_ index: Int) {
        guard catalog.providers.count > 1, catalog.providers.indices.contains(index) else { return }
        let removedID = catalog.providers[index].id
        catalog.providers.remove(at: index)
        apiKeysByProviderID[removedID] = nil
        if catalog.selectedProviderID == removedID {
            let provider = catalog.providers[min(index, catalog.providers.count - 1)]
            catalog.selectedProviderID = provider.id
            catalog.selectedModelID = provider.models.first?.id ?? IOSConfig.defaultModel
        }
    }

    private func addModel(providerIndex: Int) {
        guard catalog.providers.indices.contains(providerIndex) else { return }
        let existing = Set(catalog.providers[providerIndex].models.map(\.id))
        let modelID = existing.contains(IOSConfig.defaultModel) ? "model-id" : IOSConfig.defaultModel
        catalog.providers[providerIndex].models.append(IOSProviderModel(id: modelID, displayName: modelID))
        catalog.selectedModelID = modelID
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
    }

    private func providerFieldBinding(_ providerIndex: Int,
                                      _ keyPath: WritableKeyPath<IOSProviderSettings, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex][keyPath: keyPath] },
            set: { catalog.providers[providerIndex][keyPath: keyPath] = $0 })
    }

    private func baseURLBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].baseURL },
            set: {
                let baseURL = IOSConfig.baseURL(fromChatEndpoint: $0)
                catalog.providers[providerIndex].baseURL = baseURL
                catalog.providers[providerIndex].chatEndpoint = IOSConfig.chatEndpoint(forBaseURL: baseURL)
            })
    }

    private func chatEndpointBinding(_ providerIndex: Int) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].chatEndpoint },
            set: {
                let endpoint = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                catalog.providers[providerIndex].chatEndpoint = endpoint
                catalog.providers[providerIndex].baseURL = IOSConfig.baseURL(fromChatEndpoint: endpoint)
            })
    }

    private func modelFieldBinding(providerIndex: Int,
                                   modelIndex: Int,
                                   keyPath: WritableKeyPath<IOSProviderModel, String>) -> Binding<String> {
        Binding(
            get: { catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] },
            set: {
                let oldID = catalog.providers[providerIndex].models[modelIndex].id
                catalog.providers[providerIndex].models[modelIndex][keyPath: keyPath] = $0
                if keyPath == \IOSProviderModel.id, catalog.selectedModelID == oldID {
                    catalog.selectedModelID = $0
                }
            })
    }

    private func apiKeyBinding(for providerID: String) -> Binding<String> {
        Binding(
            get: { apiKeysByProviderID[providerID] ?? "" },
            set: { apiKeysByProviderID[providerID] = $0 })
    }

    private func apiKeyPlaceholder(for provider: IOSProviderSettings) -> String {
        env.hasAPIKey(for: provider)
            ? "••••••••••••••••"
            : IntatisLocalization.string("Enter API key")
    }

    private func testProvider() {
        guard !isTestingProvider else { return }
        isTestingProvider = true
        settingsError = nil
        providerHealthReport = nil
        Task { @MainActor in
            defer { isTestingProvider = false }
            do {
                try env.saveSettings(catalog: catalog, apiKeysByProviderID: apiKeysByProviderID)
                catalog = IOSConfig.providerCatalog
                apiKeysByProviderID = [:]
                providerHealthReport = await env.healthCheckSelectedProvider()
            } catch {
                settingsError = IntatisLocalization.format(
                    "Could not test provider: %@",
                    error.localizedDescription)
            }
        }
    }
}

private struct IOSSidebarModeRow: View {
    @ScaledMetric(relativeTo: .body)
    private var bodySize: CGFloat = IntatisTypography.spec(for: .body).nominalPointSize

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(IntatisTypography.body(bodySize, .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            Text(IntatisLocalization.string("Chat"))
                .font(IntatisTypography.body(bodySize, .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .intatisLiquidGlass(cornerRadius: 10, interactive: true)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isSelected)
    }
}

private struct IOSChatModelMenu: View {
    let catalog: IOSProviderCatalog
    let isBusy: Bool
    let onSelect: (String, String) -> Void
    @ScaledMetric(relativeTo: .body) private var modelLabelSize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption)
    private var metadataSize: CGFloat = IntatisTypography.spec(for: .metadata).nominalPointSize

    private var selectedProvider: IOSProviderSettings? { catalog.selectedProvider }
    private var selectedModel: IOSProviderModel? { catalog.selectedModel }
    private var menuProviders: [ProviderModelMenuProvider] {
        catalog.providers.map { provider in
            ProviderModelMenuProvider(
                id: provider.id,
                title: provider.title,
                models: provider.models.map { ProviderModelMenuModel(id: $0.id, title: $0.title) })
        }
    }

    var body: some View {
        ProviderModelSelectionMenu(
            providers: menuProviders,
            selectedProviderID: catalog.selectedProviderID,
            selectedModelID: catalog.selectedModelID,
            isBusy: isBusy,
            onSelect: onSelect) {
                HStack(spacing: 8) {
                    Text(selectedModel?.title ?? IOSConfig.defaultModel)
                        .font(IntatisTypography.body(modelLabelSize, .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(IntatisTypography.metadata(metadataSize, .semibold))
                        .foregroundStyle(.secondary)
                }
                .intatisComposerSelectionLabel()
        }
        .intatisComposerSelectionMenu()
        .tint(.primary)
        .accessibilityLabel(
            "\(selectedModel?.title ?? IOSConfig.defaultModel), \(selectedProvider?.title ?? "OpenAI")")
        .accessibilityIdentifier("ios.model.menu")
    }
}

@main
struct TranslatisiOSApp: App {
    @StateObject private var env: IOSAppEnvironment

    init() {
        try! IntatisHostApplication.configure(name: "Translatis")
        _env = StateObject(wrappedValue: IOSAppEnvironment())
        IntatisTypography.prepareJetBrainsMonoTypography()
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environmentObject(env)
                .font(IntatisTypography.globalFont)
        }
    }
}
#else
// Non-Apple platforms: trivial entry point so the executable target still links.
@main
struct TranslatisiOSApp {
    static func main() {
        print("\(IntatisHostApplication.identity.storageName)iOS is an iOS SwiftUI app and only runs on iOS.")
    }
}
#endif
