#if canImport(SwiftUI)
import Foundation
import IntatisCore
import IntatisMCP
import IntatisProtocol
import IntatisSharedUI
import SwiftUI

// MARK: - Host boundary

/// A reader-facing, already-authorized view of one resource. The host builds
/// these values from the exact frozen Agent resource catalog view; the UI
/// never receives or retains an `MCPPreparedConnectionRoute`.
struct MCPConversationResourceItem:
    Identifiable, Equatable, Sendable
{
    let id: String
    let serverAlias: String
    let server: MCPServerReference
    let name: String
    let title: String?
    let summary: String?
    let uri: String
    let mimeType: String?
    let size: Int?
    let identityFingerprint: String
    let connectionGeneration: MCPConnectionGeneration
    let rawCatalogRevision: MCPRawCatalogRevision
}

struct MCPConversationResourceTemplateItem:
    Identifiable, Equatable, Sendable
{
    let id: String
    let serverAlias: String
    let server: MCPServerReference
    let name: String
    let title: String?
    let summary: String?
    let uriTemplate: String
    let mimeType: String?
    let identityFingerprint: String
    let connectionGeneration: MCPConnectionGeneration
    let rawCatalogRevision: MCPRawCatalogRevision
}

struct MCPConversationPromptItem:
    Identifiable, Equatable, Sendable
{
    let id: String
    let serverAlias: String
    let server: MCPServerReference
    let name: String
    let title: String?
    let summary: String?
    let arguments: [MCPRawPromptArgument]
    let identityFingerprint: String
    let connectionGeneration: MCPConnectionGeneration
    let rawCatalogRevision: MCPRawCatalogRevision
}

/// Display-only by default. The server text remains untrusted and can enter a
/// model request only through the explicit one-shot action in the Details UI.
struct MCPConversationServerInstructionsItem:
    Identifiable, Equatable, Sendable
{
    let id: String
    let serverAlias: String
    let server: MCPServerReference
    let text: String
    let provenance: MCPContentProvenance
    let authorityFingerprint: String
    let connectionGeneration:
        MCPConnectionGeneration
    let policyRevision: MCPPolicyRevision
}

struct MCPConversationCatalogPresentation:
    Equatable, Sendable
{
    let snapshotID: MCPConnectionSetSnapshotID
    let bindingID: MCPBindingID
    let agentID: AgentID
    let resources: [MCPConversationResourceItem]
    let resourceTemplates:
        [MCPConversationResourceTemplateItem]
    let prompts: [MCPConversationPromptItem]
    let serverInstructions:
        [MCPConversationServerInstructionsItem]
    let subscribedResourceIDs: Set<String>
}

enum MCPConversationResourceBlockKind:
    String, Equatable, Sendable
{
    case inlineText = "inline_text"
    case artifact
    case redacted
}

/// Resource content reaches the UI only after the host has run the MCP result
/// sanitizer and ArtifactStore spill rules. `text` must be nil for artifact
/// and redacted blocks.
struct MCPConversationResourceBlock:
    Identifiable, Equatable, Sendable
{
    let id: String
    let kind: MCPConversationResourceBlockKind
    let uri: String
    let mimeType: String?
    let byteCount: Int
    let sha256: String
    let text: String?
    let artifactID: ArtifactID?
    let reason: String?
}

struct MCPConversationResourceReadPresentation:
    Equatable, Sendable
{
    let serverAlias: String
    let server: MCPServerReference
    let requestedURI: String
    let blocks: [MCPConversationResourceBlock]
    let provenance: MCPContentProvenance
}

struct MCPConversationCompletionRequest:
    Equatable, Sendable
{
    let fieldID: String
    let server: MCPServerReference
    let reference: MCPCompletionReference
    let argumentName: String
    let argumentValue: String
    let context: [String: String]
}

struct MCPConversationRemoteTaskResultPresentation:
    Equatable, Sendable
{
    let taskID: MCPRemoteServerTaskID
    let summary: String
    let artifactIDs: [ArtifactID]
    let resultReference: MCPResultReference?
}

enum MCPConversationCallState:
    String, Equatable, Sendable
{
    case waitingForApproval = "waiting_for_approval"
    case running
    case succeeded
    case failed
    case denied
    case cancelled
    case timedOut = "timed_out"
    case disconnected
    case uncertain
}

/// Secret-safe projection of an actual durable tool lifecycle. The data plane
/// supplies it from EventLog plus live progress; the view never fabricates
/// progress or infers a terminal state.
struct MCPConversationCallPresentation:
    Identifiable, Equatable, Sendable
{
    let id: String
    let serverAlias: String
    let server: MCPServerReference
    let toolName: String
    let argumentSummary: String
    let approvalMode: MCPApprovalMode
    let state: MCPConversationCallState
    let progressFraction: Double?
    let progressSummary: String?
    let durationMilliseconds: Int?
    let resultSummary: String?
    let artifactIDs: [ArtifactID]
    let sourceURIs: [String]
    let startedAt: Date
}

/// Stable App-host seam for all conversation-facing MCP content. Every
/// operation must revalidate the exact snapshot/generation/grant in its host
/// closure before touching the network or EventLog.
struct MCPConversationContentHost: Sendable {
    let loadCatalog:
        @Sendable () async throws
            -> MCPConversationCatalogPresentation
    let readResource:
        @Sendable (
            MCPConversationResourceItem,
            String
        ) async throws
            -> MCPConversationResourceReadPresentation
    let setResourceSubscription:
        @Sendable (
            MCPConversationResourceItem,
            Bool
        ) async throws -> Void
    let resourceUpdates:
        @Sendable () async
            -> AsyncStream<MCPSubscribedResourceUpdate>
    let previewPrompt:
        @Sendable (
            MCPConversationPromptItem,
            [String: String]
        ) async throws -> MCPPromptPreview
    /// Performs exact preview/digest confirmation, appends the durable
    /// `mcp_prompt_inserted` event, and inserts only untrusted external
    /// context into the current composer.
    let insertPrompt:
        @Sendable (MCPPromptPreview) async throws -> Void
    let stageServerInstructions:
        @Sendable (
            MCPConversationServerInstructionsItem
        ) async throws -> Void
    let complete:
        @Sendable (
            MCPConversationCompletionRequest
        ) async throws -> MCPCompletionSuggestions
    let loadRemoteTasks:
        @Sendable () async throws
            -> [MCPRemoteTaskSnapshot]
    let refreshRemoteTask:
        @Sendable (
            MCPRemoteTaskSnapshot
        ) async throws -> MCPRemoteTaskSnapshot
    let cancelRemoteTask:
        @Sendable (
            MCPRemoteTaskSnapshot
        ) async throws -> MCPRemoteTaskSnapshot
    let loadRemoteTaskResult:
        @Sendable (
            MCPRemoteTaskSnapshot
        ) async throws
            -> MCPConversationRemoteTaskResultPresentation
    let loadCallActivity:
        @Sendable () async throws
            -> [MCPConversationCallPresentation]
    let openArtifact:
        @Sendable (ArtifactID) async throws -> Void
    /// Ends every subscription and completion task owned by this content
    /// center. The session runtime remains alive; reopening creates a fresh
    /// reader boundary.
    let shutdown:
        @Sendable () async -> Void

    init(
        loadCatalog:
            @escaping @Sendable () async throws
                -> MCPConversationCatalogPresentation,
        readResource:
            @escaping @Sendable (
                MCPConversationResourceItem,
                String
            ) async throws
                -> MCPConversationResourceReadPresentation,
        setResourceSubscription:
            @escaping @Sendable (
                MCPConversationResourceItem,
                Bool
            ) async throws -> Void,
        resourceUpdates:
            @escaping @Sendable () async
                -> AsyncStream<MCPSubscribedResourceUpdate>,
        previewPrompt:
            @escaping @Sendable (
                MCPConversationPromptItem,
                [String: String]
            ) async throws -> MCPPromptPreview,
        insertPrompt:
            @escaping @Sendable (
                MCPPromptPreview
            ) async throws -> Void,
        stageServerInstructions:
            @escaping @Sendable (
                MCPConversationServerInstructionsItem
            ) async throws -> Void,
        complete:
            @escaping @Sendable (
                MCPConversationCompletionRequest
            ) async throws -> MCPCompletionSuggestions,
        loadRemoteTasks:
            @escaping @Sendable () async throws
                -> [MCPRemoteTaskSnapshot],
        refreshRemoteTask:
            @escaping @Sendable (
                MCPRemoteTaskSnapshot
            ) async throws -> MCPRemoteTaskSnapshot,
        cancelRemoteTask:
            @escaping @Sendable (
                MCPRemoteTaskSnapshot
            ) async throws -> MCPRemoteTaskSnapshot,
        loadRemoteTaskResult:
            @escaping @Sendable (
                MCPRemoteTaskSnapshot
            ) async throws
                -> MCPConversationRemoteTaskResultPresentation,
        loadCallActivity:
            @escaping @Sendable () async throws
                -> [MCPConversationCallPresentation],
        openArtifact:
            @escaping @Sendable (
                ArtifactID
            ) async throws -> Void,
        shutdown:
            @escaping @Sendable () async -> Void
    ) {
        self.loadCatalog = loadCatalog
        self.readResource = readResource
        self.setResourceSubscription =
            setResourceSubscription
        self.resourceUpdates = resourceUpdates
        self.previewPrompt = previewPrompt
        self.insertPrompt = insertPrompt
        self.stageServerInstructions =
            stageServerInstructions
        self.complete = complete
        self.loadRemoteTasks = loadRemoteTasks
        self.refreshRemoteTask = refreshRemoteTask
        self.cancelRemoteTask = cancelRemoteTask
        self.loadRemoteTaskResult =
            loadRemoteTaskResult
        self.loadCallActivity = loadCallActivity
        self.openArtifact = openArtifact
        self.shutdown = shutdown
    }
}

// MARK: - Entry point

struct MCPConversationCenterButton: View {
    let host: MCPConversationContentHost
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Label(
                "MCP Content",
                systemImage: "shippingbox.and.arrow.backward")
        }
        .help("Browse granted MCP resources, prompts, tasks, and calls")
        .sheet(isPresented: $isPresented) {
            MCPConversationCenterSheet(host: host)
        }
    }
}

struct MCPPendingExternalContextControl: View {
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

struct MCPConversationCenterSheet: View {
    let host: MCPConversationContentHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView {
                MCPResourceBrowserView(host: host)
                    .tabItem {
                        Label(
                            "Resources",
                            systemImage: "doc.text.magnifyingglass")
                    }
                MCPPromptPickerView(host: host)
                    .tabItem {
                        Label(
                            "Prompts",
                            systemImage: "text.bubble")
                    }
                MCPServerInstructionsView(
                    host: host)
                    .tabItem {
                        Label(
                            "Instructions",
                            systemImage:
                                "text.book.closed")
                    }
                MCPRemoteTasksView(host: host)
                    .tabItem {
                        Label(
                            "Remote Tasks",
                            systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    }
                MCPCallActivityView(host: host)
                    .tabItem {
                        Label(
                            "Calls",
                            systemImage: "waveform.path.ecg")
                    }
            }
            .navigationTitle("MCP Content")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .onDisappear {
            Task {
                await host.shutdown()
            }
        }
    }
}

// MARK: - Resources

@MainActor
private final class MCPResourceBrowserModel:
    ObservableObject
{
    @Published var catalog:
        MCPConversationCatalogPresentation?
    @Published var selectedID: String?
    @Published var search = ""
    @Published var readURI = ""
    @Published var templateArguments:
        [String: String] = [:]
    @Published var completionSuggestions:
        [String: [String]] = [:]
    @Published var readResult:
        MCPConversationResourceReadPresentation?
    @Published var isWorking = false
    @Published var errorMessage: String?

    let host: MCPConversationContentHost

    init(host: MCPConversationContentHost) {
        self.host = host
    }

    var resources: [MCPConversationResourceItem] {
        let values = catalog?.resources ?? []
        guard !search.isEmpty else { return values }
        return values.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.uri.localizedCaseInsensitiveContains(search)
                || $0.serverAlias
                    .localizedCaseInsensitiveContains(search)
        }
    }

    var templates:
        [MCPConversationResourceTemplateItem]
    {
        let values = catalog?.resourceTemplates ?? []
        guard !search.isEmpty else { return values }
        return values.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.uriTemplate
                    .localizedCaseInsensitiveContains(search)
                || $0.serverAlias
                    .localizedCaseInsensitiveContains(search)
        }
    }

    var selectedResource:
        MCPConversationResourceItem?
    {
        catalog?.resources.first { $0.id == selectedID }
    }

    var selectedTemplate:
        MCPConversationResourceTemplateItem?
    {
        catalog?.resourceTemplates.first {
            $0.id == selectedID
        }
    }

    func load() async {
        await perform {
            let catalog = try await self.host.loadCatalog()
            self.catalog = catalog
            if self.selectedID == nil {
                self.selectedID =
                    catalog.resources.first?.id
                        ?? catalog.resourceTemplates.first?.id
            }
            self.resetSelection()
        }
    }

    func resetSelection() {
        readResult = nil
        completionSuggestions = [:]
        if let resource = selectedResource {
            readURI = resource.uri
            templateArguments = [:]
        } else if let template = selectedTemplate {
            let names = Self.templateFieldNames(
                template.uriTemplate)
            templateArguments = Dictionary(
                uniqueKeysWithValues:
                    names.map { ($0, "") })
            readURI = render(template: template)
        } else {
            readURI = ""
            templateArguments = [:]
        }
    }

    func updateRenderedURI() {
        guard let template = selectedTemplate else {
            return
        }
        readURI = render(template: template)
    }

    func read() async {
        let source: MCPConversationResourceItem
        if let resource = selectedResource {
            source = resource
        } else if let template = selectedTemplate {
            source = MCPConversationResourceItem(
                id: template.id,
                serverAlias: template.serverAlias,
                server: template.server,
                name: template.name,
                title: template.title,
                summary: template.summary,
                uri: readURI,
                mimeType: template.mimeType,
                size: nil,
                identityFingerprint:
                    template.identityFingerprint,
                connectionGeneration:
                    template.connectionGeneration,
                rawCatalogRevision:
                    template.rawCatalogRevision)
        } else {
            return
        }
        let uri = readURI
        await perform {
            self.readResult =
                try await self.host.readResource(source, uri)
        }
    }

    func setSubscribed(_ subscribed: Bool) async {
        guard let resource = selectedResource else {
            return
        }
        await perform {
            try await self.host.setResourceSubscription(
                resource,
                subscribed)
            self.catalog = try await self.host.loadCatalog()
        }
    }

    func observeSubscribedUpdates() async {
        let stream = await host.resourceUpdates()
        for await update in stream {
            guard !Task.isCancelled else { return }
            guard let resource = selectedResource,
                  resource.server == update.server,
                  resource.connectionGeneration
                    == update.generation,
                  resource.uri == update.uri else {
                continue
            }
            await read()
        }
    }

    func requestCompletion(
        field: String
    ) async {
        guard let template = selectedTemplate else {
            return
        }
        let value = templateArguments[field] ?? ""
        do {
            let suggestions = try await host.complete(
                MCPConversationCompletionRequest(
                    fieldID:
                        "\(template.id):\(field)",
                    server: template.server,
                    reference: .resource(
                        uriTemplate:
                            template.uriTemplate),
                    argumentName: field,
                    argumentValue: value,
                    context: templateArguments))
            completionSuggestions[field] =
                suggestions.values
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func openArtifact(_ artifactID: ArtifactID) async {
        await perform {
            try await self.host.openArtifact(artifactID)
        }
    }

    private func perform(
        _ operation:
            @escaping @MainActor () async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func render(
        template: MCPConversationResourceTemplateItem
    ) -> String {
        var value = template.uriTemplate
        for (name, argument) in templateArguments {
            value = value.replacingOccurrences(
                of: "{\(name)}",
                with: argument
                    .addingPercentEncoding(
                        withAllowedCharacters:
                            .urlPathAllowed)
                    ?? argument)
        }
        return value
    }

    static func templateFieldNames(
        _ template: String
    ) -> [String] {
        let pattern = #"\{([A-Za-z0-9_.-]+)\}"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern) else {
            return []
        }
        let range = NSRange(
            template.startIndex..<template.endIndex,
            in: template)
        var names: [String] = []
        for match in regex.matches(
            in: template,
            range: range)
        where match.numberOfRanges == 2 {
            guard let swiftRange = Range(
                match.range(at: 1),
                in: template) else {
                continue
            }
            let value = String(template[swiftRange])
            if !names.contains(value) {
                names.append(value)
            }
        }
        return names
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}

private struct MCPResourceBrowserView: View {
    @StateObject private var model:
        MCPResourceBrowserModel

    init(host: MCPConversationContentHost) {
        _model = StateObject(
            wrappedValue:
                MCPResourceBrowserModel(host: host))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(
                    "Search granted resources",
                    text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(selection: $model.selectedID) {
                    Section("Resources") {
                        ForEach(model.resources) { resource in
                            MCPResourceCatalogRow(
                                title:
                                    resource.title
                                        ?? resource.name,
                                subtitle:
                                    resource.serverAlias,
                                detail: resource.uri,
                                systemImage: "doc")
                                .tag(
                                    Optional(resource.id))
                        }
                    }
                    Section("Templates") {
                        ForEach(model.templates) { template in
                            MCPResourceCatalogRow(
                                title:
                                    template.title
                                        ?? template.name,
                                subtitle:
                                    template.serverAlias,
                                detail:
                                    template.uriTemplate,
                                systemImage:
                                    "doc.badge.gearshape")
                                .tag(
                                    Optional(template.id))
                        }
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 330)

            Group {
                if model.selectedResource != nil
                    || model.selectedTemplate != nil {
                    MCPResourceBrowserDetail(model: model)
                } else {
                    ContentUnavailableView(
                        "No Granted Resources",
                        systemImage:
                            "doc.text.magnifyingglass",
                        description: Text(
                            "Attach a server and grant this Agent resource access."))
                }
            }
            .frame(minWidth: 480)
        }
        .overlay {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task { await model.load() }
        .task { await model.observeSubscribedUpdates() }
        .onChange(of: model.selectedID) {
            model.resetSelection()
        }
        .alert(
            "MCP Resource Operation Failed",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MCPResourceCatalogRow: View {
    let title: String
    let subtitle: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
                Text(detail)
                    .font(IntatisTypography.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct MCPResourceBrowserDetail: View {
    @ObservedObject var model: MCPResourceBrowserModel

    private var isSubscribed: Bool {
        guard let resource = model.selectedResource else {
            return false
        }
        return model.catalog?.subscribedResourceIDs
            .contains(resource.id) ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let resource = model.selectedResource {
                    resourceHeader(
                        title: resource.title ?? resource.name,
                        server: resource.serverAlias,
                        summary: resource.summary,
                        mimeType: resource.mimeType,
                        revision:
                            resource.rawCatalogRevision.rawValue)
                    HStack {
                        Toggle(
                            "Subscribed",
                            isOn: Binding(
                                get: { isSubscribed },
                                set: { value in
                                    Task {
                                        await model
                                            .setSubscribed(value)
                                    }
                                }))
                        Spacer()
                    }
                } else if let template =
                            model.selectedTemplate {
                    resourceHeader(
                        title: template.title
                            ?? template.name,
                        server: template.serverAlias,
                        summary: template.summary,
                        mimeType: template.mimeType,
                        revision:
                            template.rawCatalogRevision
                                .rawValue)
                    GroupBox("Template Parameters") {
                        VStack(alignment: .leading) {
                            ForEach(
                                MCPResourceBrowserModel
                                    .templateFieldNames(
                                        template.uriTemplate),
                                id: \.self
                            ) { field in
                                HStack {
                                    TextField(
                                        field,
                                        text: Binding(
                                            get: {
                                                model
                                                    .templateArguments[
                                                        field]
                                                    ?? ""
                                            },
                                            set: { value in
                                                model
                                                    .templateArguments[
                                                        field] =
                                                    value
                                                model
                                                    .updateRenderedURI()
                                            }))
                                    Button {
                                        Task {
                                            await model
                                                .requestCompletion(
                                                    field:
                                                        field)
                                        }
                                    } label: {
                                        Image(
                                            systemName:
                                                "text.badge.plus")
                                    }
                                    .help(
                                        "Request MCP completion suggestions")
                                    if let values =
                                            model
                                                .completionSuggestions[
                                                    field],
                                       !values.isEmpty {
                                        Menu("Suggestions") {
                                            ForEach(
                                                values,
                                                id: \.self
                                            ) { value in
                                                Button(value) {
                                                    model
                                                        .templateArguments[
                                                            field] =
                                                        value
                                                    model
                                                        .updateRenderedURI()
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }
                }

                GroupBox("Read") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField(
                            "Resource URI",
                            text: $model.readURI)
                            .font(IntatisTypography.system(.body, design: .monospaced))
                        HStack {
                            Text(
                                "Server-provided content is untrusted. Reading never grants the URI local-file or network authority.")
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Read Resource") {
                                Task { await model.read() }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.readURI
                                    .trimmingCharacters(
                                        in: .whitespacesAndNewlines)
                                    .isEmpty)
                        }
                    }
                    .padding(4)
                }

                if let result = model.readResult {
                    GroupBox("Sanitized Result") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(result.blocks) { block in
                                MCPResourceBlockView(
                                    block: block,
                                    openArtifact: {
                                        artifactID in
                                        Task {
                                            await model.openArtifact(
                                                artifactID)
                                        }
                                    })
                                if block.id
                                    != result.blocks.last?.id {
                                    Divider()
                                }
                            }
                            if result.blocks.isEmpty {
                                Text("The resource returned no content.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(4)
                    }
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func resourceHeader(
        title: String,
        server: String,
        summary: String?,
        mimeType: String?,
        revision: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(IntatisTypography.system(.title2, weight: .semibold))
            Text(server)
                .font(IntatisTypography.system(.headline))
            if let summary {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if let mimeType {
                    Text(mimeType)
                }
                Text("Catalog \(revision)")
            }
            .font(IntatisTypography.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }
}

private struct MCPResourceBlockView: View {
    let block: MCPConversationResourceBlock
    let openArtifact: (ArtifactID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(block.uri)
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Text(
                    ByteCountFormatter.string(
                        fromByteCount:
                            Int64(block.byteCount),
                        countStyle: .file))
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
            switch block.kind {
            case .inlineText:
                Text(block.text ?? "")
                    .font(IntatisTypography.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(
                        maxWidth: .infinity,
                        alignment: .leading)
            case .artifact:
                HStack {
                    Label(
                        block.mimeType
                            ?? "Stored artifact",
                        systemImage: "archivebox")
                    Spacer()
                    if let artifactID = block.artifactID {
                        Button("Open Artifact") {
                            openArtifact(artifactID)
                        }
                    }
                }
            case .redacted:
                Label(
                    block.reason
                        ?? "Sensitive content was redacted.",
                    systemImage: "eye.slash")
                    .foregroundStyle(.orange)
            }
            Text("SHA-256 \(block.sha256)")
                .font(IntatisTypography.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Prompts

@MainActor
private final class MCPPromptPickerModel:
    ObservableObject
{
    @Published var catalog:
        MCPConversationCatalogPresentation?
    @Published var selectedID: String?
    @Published var search = ""
    @Published var arguments: [String: String] = [:]
    @Published var suggestions:
        [String: [String]] = [:]
    @Published var preview: MCPPromptPreview?
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var didInsert = false

    let host: MCPConversationContentHost

    init(host: MCPConversationContentHost) {
        self.host = host
    }

    var prompts: [MCPConversationPromptItem] {
        let values = catalog?.prompts ?? []
        guard !search.isEmpty else { return values }
        return values.filter {
            $0.name.localizedCaseInsensitiveContains(search)
                || $0.serverAlias
                    .localizedCaseInsensitiveContains(search)
                || ($0.summary?
                    .localizedCaseInsensitiveContains(search)
                    ?? false)
        }
    }

    var selected: MCPConversationPromptItem? {
        catalog?.prompts.first { $0.id == selectedID }
    }

    func load() async {
        await perform {
            let catalog = try await self.host.loadCatalog()
            self.catalog = catalog
            self.selectedID =
                self.selectedID
                    ?? catalog.prompts.first?.id
            self.resetSelection()
        }
    }

    func resetSelection() {
        arguments = Dictionary(
            uniqueKeysWithValues:
                (selected?.arguments ?? [])
                    .map { ($0.name, "") })
        suggestions = [:]
        preview = nil
        didInsert = false
    }

    func requestCompletion(field: String) async {
        guard let selected else { return }
        do {
            let result = try await host.complete(
                MCPConversationCompletionRequest(
                    fieldID:
                        "\(selected.id):\(field)",
                    server: selected.server,
                    reference: .prompt(
                        name: selected.name),
                    argumentName: field,
                    argumentValue:
                        arguments[field] ?? "",
                    context: arguments))
            suggestions[field] = result.values
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func buildPreview() async {
        guard let selected else { return }
        await perform {
            self.preview = try await self.host
                .previewPrompt(selected, self.arguments)
        }
    }

    func insert() async {
        guard let preview else { return }
        await perform {
            try await self.host.insertPrompt(preview)
            self.didInsert = true
        }
    }

    private func perform(
        _ operation:
            @escaping @MainActor () async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
    }
}

private struct MCPPromptPickerView: View {
    @StateObject private var model:
        MCPPromptPickerModel

    init(host: MCPConversationContentHost) {
        _model = StateObject(
            wrappedValue:
                MCPPromptPickerModel(host: host))
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                TextField(
                    "Search granted prompts",
                    text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .padding(10)
                List(selection: $model.selectedID) {
                    ForEach(model.prompts) { prompt in
                        Label {
                            VStack(
                                alignment: .leading,
                                spacing: 2)
                            {
                                Text(
                                    prompt.title
                                        ?? prompt.name)
                                Text(
                                    "\(prompt.serverAlias) · \(prompt.name)")
                                    .font(IntatisTypography.system(.caption))
                                    .foregroundStyle(
                                        .secondary)
                            }
                        } icon: {
                            Image(
                                systemName:
                                    "text.bubble")
                        }
                        .tag(Optional(prompt.id))
                    }
                }
            }
            .frame(minWidth: 280, idealWidth: 330)

            if let prompt = model.selected {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 16)
                    {
                        Text(prompt.title ?? prompt.name)
                            .font(
                                IntatisTypography.system(
                                    .title2,
                                    weight: .semibold))
                        Text(
                            "\(prompt.serverAlias) · \(prompt.name)")
                            .font(IntatisTypography.system(.headline))
                        if let summary = prompt.summary {
                            Text(summary)
                                .foregroundStyle(.secondary)
                        }
                        Text(
                            "Catalog \(prompt.rawCatalogRevision.rawValue)")
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)

                        GroupBox("Arguments") {
                            VStack(alignment: .leading) {
                                ForEach(
                                    prompt.arguments,
                                    id: \.name
                                ) { argument in
                                    VStack(
                                        alignment: .leading,
                                        spacing: 4)
                                    {
                                        HStack {
                                            Text(
                                                argument.title
                                                    ?? argument.name)
                                            if argument.required {
                                                Text(
                                                    "Required")
                                                    .font(
                                                        IntatisTypography.system(
                                                            .caption))
                                                    .foregroundStyle(
                                                        .orange)
                                            }
                                        }
                                        HStack {
                                            TextField(
                                                argument.summary
                                                    ?? argument.name,
                                                text: Binding(
                                                    get: {
                                                        model
                                                            .arguments[
                                                                argument
                                                                    .name]
                                                            ?? ""
                                                    },
                                                    set: {
                                                        model
                                                            .arguments[
                                                                argument
                                                                    .name] =
                                                            $0
                                                        model.preview =
                                                            nil
                                                    }))
                                            Button {
                                                Task {
                                                    await model
                                                        .requestCompletion(
                                                            field:
                                                                argument
                                                                    .name)
                                                }
                                            } label: {
                                                Image(
                                                    systemName:
                                                        "text.badge.plus")
                                            }
                                            .help(
                                                "Request MCP completion suggestions")
                                            if let values =
                                                    model
                                                        .suggestions[
                                                            argument
                                                                .name],
                                               !values.isEmpty {
                                                Menu(
                                                    "Suggestions")
                                                {
                                                    ForEach(
                                                        values,
                                                        id: \.self
                                                    ) { value in
                                                        Button(
                                                            value)
                                                        {
                                                            model
                                                                .arguments[
                                                                    argument
                                                                        .name] =
                                                                value
                                                            model
                                                                .preview =
                                                                nil
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                if prompt.arguments.isEmpty {
                                    Text(
                                        "This prompt has no arguments.")
                                        .foregroundStyle(
                                            .secondary)
                                }
                            }
                            .padding(4)
                        }

                        HStack {
                            Text(
                                "Server prompt content remains untrusted and can only be inserted after this preview.")
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Preview Prompt") {
                                Task {
                                    await model.buildPreview()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        if let preview = model.preview {
                            MCPPromptPreviewView(
                                preview: preview,
                                didInsert:
                                    model.didInsert,
                                insert: {
                                    Task {
                                        await model.insert()
                                    }
                                })
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "No Granted Prompts",
                    systemImage: "text.bubble",
                    description: Text(
                        "Attach a standard-extended server and grant this Agent prompt access."))
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task { await model.load() }
        .onChange(of: model.selectedID) {
            model.resetSelection()
        }
        .alert(
            "MCP Prompt Operation Failed",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MCPPromptPreviewView: View {
    let preview: MCPPromptPreview
    let didInsert: Bool
    let insert: () -> Void

    var body: some View {
        GroupBox("Untrusted Prompt Preview") {
            VStack(alignment: .leading, spacing: 10) {
                if let description = preview.description {
                    Text(description)
                }
                ForEach(
                    Array(preview.messages.enumerated()),
                    id: \.offset
                ) { _, message in
                    Text(MCPConversationJSON.text(message))
                        .font(IntatisTypography.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading)
                        .padding(8)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(
                                cornerRadius: 7))
                }
                HStack {
                    Text(
                        "Source: \(preview.serverAlias) / \(preview.promptName)")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if didInsert {
                        Label(
                            "Inserted",
                            systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button(
                            "Insert as Untrusted Context",
                            action: insert)
                            .buttonStyle(
                                .borderedProminent)
                    }
                }
            }
            .padding(4)
        }
    }
}

// MARK: - Server instructions

@MainActor
private final class MCPServerInstructionsModel:
    ObservableObject
{
    @Published var items:
        [MCPConversationServerInstructionsItem] = []
    @Published var selectedID: String?
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var stagedID: String?

    let host: MCPConversationContentHost

    init(host: MCPConversationContentHost) {
        self.host = host
    }

    var selected:
        MCPConversationServerInstructionsItem?
    {
        items.first { $0.id == selectedID }
    }

    func load() async {
        await perform {
            let catalog =
                try await self.host.loadCatalog()
            self.items =
                catalog.serverInstructions
            if !self.items.contains(
                where: {
                    $0.id == self.selectedID
                })
            {
                self.selectedID =
                    self.items.first?.id
            }
        }
    }

    func stageSelected() async {
        guard let selected else { return }
        await perform {
            try await self.host
                .stageServerInstructions(
                    selected)
            self.stagedID = selected.id
        }
    }

    private func perform(
        _ operation:
            @escaping @MainActor () async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?
                    .errorDescription
                    ?? String(describing: error)
        }
    }
}

private struct MCPServerInstructionsView: View {
    @StateObject private var model:
        MCPServerInstructionsModel
    @State private var showConfirmation = false

    init(host: MCPConversationContentHost) {
        _model = StateObject(
            wrappedValue:
                MCPServerInstructionsModel(
                    host: host))
    }

    var body: some View {
        HSplitView {
            List(
                model.items,
                selection: $model.selectedID
            ) { item in
                Label {
                    VStack(
                        alignment: .leading,
                        spacing: 2)
                    {
                        Text(item.serverAlias)
                        Text(
                            item.server.serverRevision
                                .rawValue)
                            .font(
                                IntatisTypography.system(
                                    .caption,
                                    design: .monospaced))
                            .foregroundStyle(
                                .secondary)
                            .lineLimit(1)
                    }
                } icon: {
                    Image(
                        systemName:
                            "text.book.closed")
                }
                .tag(Optional(item.id))
            }
            .frame(minWidth: 280, idealWidth: 330)

            if let item = model.selected {
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: 16)
                    {
                        Text(item.serverAlias)
                            .font(
                                IntatisTypography.system(
                                    .title2,
                                    weight: .semibold))
                        Text(
                            "Server instructions are display-only and untrusted by default.")
                            .foregroundStyle(
                                .secondary)
                        GroupBox("Details") {
                            VStack(
                                alignment: .leading,
                                spacing: 8)
                            {
                                Text(item.text)
                                    .font(
                                        IntatisTypography.system(
                                            .body,
                                            design: .monospaced))
                                    .textSelection(
                                        .enabled)
                                    .frame(
                                        maxWidth:
                                            .infinity,
                                        alignment:
                                            .leading)
                                Divider()
                                Text(
                                    "Server \(item.server.serverID.rawValue) · Revision \(item.server.serverRevision.rawValue)")
                                Text(
                                    "Generation \(item.connectionGeneration.rawValue)")
                                Text(
                                    "Catalog \(item.provenance.rawCatalogRevision.rawValue) · Binding \(item.provenance.bindingID.rawValue)")
                                Text(
                                    "Policy \(item.policyRevision.rawValue)")
                            }
                            .font(
                                IntatisTypography.system(
                                    .caption,
                                    design: .monospaced))
                            .padding(4)
                        }
                        HStack {
                            Text(
                                "Using these instructions creates provenance-tagged untrusted context for exactly the next message; it never becomes a system or developer instruction.")
                                .font(IntatisTypography.system(.caption))
                                .foregroundStyle(
                                    .secondary)
                            Spacer()
                            if model.stagedID
                                    == item.id {
                                Label(
                                    "Staged for Next Message",
                                    systemImage:
                                        "checkmark.circle.fill")
                                    .foregroundStyle(
                                        .green)
                            } else {
                                Button(
                                    "Use Once in Next Message")
                                {
                                    showConfirmation =
                                        true
                                }
                                .buttonStyle(
                                    .borderedProminent)
                            }
                        }
                    }
                    .padding(20)
                }
            } else {
                ContentUnavailableView(
                    "No Server Instructions",
                    systemImage:
                        "text.book.closed",
                    description: Text(
                        "Connected servers have not published initialize instructions for this Agent."))
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
                    .controlSize(.large)
            }
        }
        .task { await model.load() }
        .confirmationDialog(
            "Use Untrusted Server Instructions?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "Use Once in Next Message")
            {
                Task {
                    await model.stageSelected()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "The exact server text shown in Details will be attached as provenance-tagged, untrusted user context to the next message only.")
        }
        .alert(
            "MCP Instructions Operation Failed",
            isPresented: Binding(
                get: {
                    model.errorMessage != nil
                },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Remote tasks

@MainActor
private final class MCPRemoteTasksModel:
    ObservableObject
{
    @Published var tasks: [MCPRemoteTaskSnapshot] = []
    @Published var result:
        MCPConversationRemoteTaskResultPresentation?
    @Published var isWorking = false
    @Published var errorMessage: String?

    let host: MCPConversationContentHost

    init(host: MCPConversationContentHost) {
        self.host = host
    }

    func load() async {
        await perform {
            self.tasks = try await self.host
                .loadRemoteTasks()
                .sorted {
                    $0.lastUpdatedAt
                        > $1.lastUpdatedAt
                }
        }
    }

    func refresh(_ task: MCPRemoteTaskSnapshot) async {
        await perform {
            let replacement =
                try await self.host.refreshRemoteTask(task)
            self.replace(replacement)
        }
    }

    func cancel(_ task: MCPRemoteTaskSnapshot) async {
        await perform {
            let replacement =
                try await self.host.cancelRemoteTask(task)
            self.replace(replacement)
        }
    }

    func loadResult(
        _ task: MCPRemoteTaskSnapshot
    ) async {
        await perform {
            self.result =
                try await self.host.loadRemoteTaskResult(task)
        }
    }

    func openArtifact(_ id: ArtifactID) async {
        await perform {
            try await self.host.openArtifact(id)
        }
    }

    private func replace(
        _ replacement: MCPRemoteTaskSnapshot
    ) {
        if let index = tasks.firstIndex(where: {
            $0.taskID == replacement.taskID
        }) {
            tasks[index] = replacement
        } else {
            tasks.append(replacement)
        }
        tasks.sort {
            $0.lastUpdatedAt > $1.lastUpdatedAt
        }
    }

    private func perform(
        _ operation:
            @escaping @MainActor () async throws -> Void
    ) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            try await operation()
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?
                    .errorDescription
                    ?? String(describing: error)
        }
    }
}

private struct MCPRemoteTasksView: View {
    @StateObject private var model:
        MCPRemoteTasksModel

    init(host: MCPConversationContentHost) {
        _model = StateObject(
            wrappedValue:
                MCPRemoteTasksModel(host: host))
    }

    var body: some View {
        Group {
            if model.tasks.isEmpty && !model.isWorking {
                ContentUnavailableView(
                    "No Remote MCP Tasks",
                    systemImage:
                        "clock.arrow.trianglehead.counterclockwise.rotate.90",
                    description: Text(
                        "Experimental server-owned tasks will appear here when the negotiated profile and grants permit them."))
            } else {
                List {
                    ForEach(
                        model.tasks,
                        id: \.taskID.rawValue
                    ) { task in
                        MCPRemoteTaskCard(
                            task: task,
                            refresh: {
                                Task {
                                    await model.refresh(task)
                                }
                            },
                            cancel: {
                                Task {
                                    await model.cancel(task)
                                }
                            },
                            loadResult: {
                                Task {
                                    await model
                                        .loadResult(task)
                                }
                            })
                    }
                }
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
            }
        }
        .toolbar {
            Button {
                Task { await model.load() }
            } label: {
                Label("Refresh Tasks", systemImage: "arrow.clockwise")
            }
        }
        .task { await model.load() }
        .sheet(
            isPresented: Binding(
                get: { model.result != nil },
                set: {
                    if !$0 { model.result = nil }
                })
        ) {
            if let result = model.result {
                NavigationStack {
                    VStack(
                        alignment: .leading,
                        spacing: 14)
                    {
                        Text(result.summary)
                            .textSelection(.enabled)
                        ForEach(
                            result.artifactIDs,
                            id: \.rawValue
                        ) { artifactID in
                            Button {
                                Task {
                                    await model.openArtifact(
                                        artifactID)
                                }
                            } label: {
                                Label(
                                    artifactID.rawValue,
                                    systemImage:
                                        "archivebox")
                            }
                        }
                        Spacer()
                    }
                    .padding(20)
                    .navigationTitle("Remote Task Result")
                }
                .frame(minWidth: 520, minHeight: 320)
            }
        }
        .alert(
            "Remote MCP Task Operation Failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct MCPRemoteTaskCard: View {
    let task: MCPRemoteTaskSnapshot
    let refresh: () -> Void
    let cancel: () -> Void
    let loadResult: () -> Void

    private var isTerminal: Bool {
        switch task.state {
        case .completed, .failed, .cancelled:
            return true
        case .requested, .working, .inputRequired:
            return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    task.operation.rawValue,
                    systemImage: stateIcon)
                    .font(IntatisTypography.system(.headline))
                Spacer()
                Text(task.state.rawValue)
                    .font(IntatisTypography.system(.caption, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        stateColor.opacity(0.15),
                        in: Capsule())
                    .foregroundStyle(stateColor)
            }
            Text(
                task.authority.server.serverID.rawValue)
                .font(IntatisTypography.system(.body, design: .monospaced))
            Text(task.taskID.rawValue)
                .font(IntatisTypography.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Text(
                    "Revision \(task.stateRevision) · Updated \(task.lastUpdatedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                if !isTerminal {
                    Button("Refresh", action: refresh)
                    Button(
                        "Cancel Task",
                        role: .destructive,
                        action: cancel)
                }
                if task.state == .completed {
                    Button(
                        "View Result",
                        action: loadResult)
                }
            }
        }
        .padding(.vertical, 7)
    }

    private var stateIcon: String {
        switch task.state {
        case .requested: return "clock"
        case .working: return "gearshape.2"
        case .inputRequired: return "questionmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        }
    }

    private var stateColor: Color {
        switch task.state {
        case .requested, .inputRequired: return .orange
        case .working: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}

// MARK: - Call cards

@MainActor
private final class MCPCallActivityModel:
    ObservableObject
{
    @Published var calls:
        [MCPConversationCallPresentation] = []
    @Published var isWorking = false
    @Published var errorMessage: String?
    let host: MCPConversationContentHost

    init(host: MCPConversationContentHost) {
        self.host = host
    }

    func load() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            calls = try await host
                .loadCallActivity()
                .sorted {
                    $0.startedAt > $1.startedAt
                }
        } catch is CancellationError {
            return
        } catch {
            errorMessage =
                (error as? LocalizedError)?
                    .errorDescription
                    ?? String(describing: error)
        }
    }

    func openArtifact(_ id: ArtifactID) async {
        do {
            try await host.openArtifact(id)
        } catch {
            errorMessage =
                (error as? LocalizedError)?
                    .errorDescription
                    ?? String(describing: error)
        }
    }
}

private struct MCPCallActivityView: View {
    @StateObject private var model:
        MCPCallActivityModel

    init(host: MCPConversationContentHost) {
        _model = StateObject(
            wrappedValue:
                MCPCallActivityModel(host: host))
    }

    var body: some View {
        Group {
            if model.calls.isEmpty && !model.isWorking {
                ContentUnavailableView(
                    "No MCP Calls",
                    systemImage: "waveform.path.ecg",
                    description: Text(
                        "Durable MCP tool calls for this session will appear here."))
            } else {
                List {
                    ForEach(model.calls) { call in
                        MCPCallCard(
                            call: call,
                            openArtifact: { artifactID in
                                Task {
                                    await model
                                        .openArtifact(
                                            artifactID)
                                }
                            })
                    }
                }
            }
        }
        .overlay {
            if model.isWorking {
                ProgressView()
            }
        }
        .toolbar {
            Button {
                Task { await model.load() }
            } label: {
                Label(
                    "Refresh Calls",
                    systemImage: "arrow.clockwise")
            }
        }
        .task { await model.load() }
        .alert(
            "MCP Call History Failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: {
                    if !$0 {
                        model.errorMessage = nil
                    }
                })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct MCPCallCard: View {
    let call: MCPConversationCallPresentation
    let openArtifact: (ArtifactID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.toolName)
                        .font(IntatisTypography.system(.headline))
                    Text(call.serverAlias)
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(
                    call.state.rawValue,
                    systemImage: stateIcon)
                    .font(IntatisTypography.system(.caption, weight: .semibold))
                    .foregroundStyle(stateColor)
            }
            Text(call.argumentSummary)
                .font(IntatisTypography.system(.body, design: .monospaced))
                .lineLimit(4)
                .textSelection(.enabled)
            HStack {
                Text(
                    "Approval: \(call.approvalMode.rawValue)")
                if let duration = call.durationMilliseconds {
                    Text("Duration: \(duration) ms")
                }
                Text(
                    call.startedAt.formatted(
                        date: .abbreviated,
                        time: .standard))
            }
            .font(IntatisTypography.system(.caption))
            .foregroundStyle(.secondary)

            if let fraction = call.progressFraction {
                ProgressView(
                    value: min(1, max(0, fraction)))
            } else if call.state == .running {
                ProgressView()
                    .controlSize(.small)
            }
            if let progress = call.progressSummary {
                Text(progress)
                    .font(IntatisTypography.system(.caption))
            }
            if let result = call.resultSummary {
                Text(result)
                    .textSelection(.enabled)
            }
            if !call.sourceURIs.isEmpty {
                DisclosureGroup("Sources") {
                    ForEach(
                        call.sourceURIs,
                        id: \.self
                    ) { source in
                        Text(source)
                            .font(IntatisTypography.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            if !call.artifactIDs.isEmpty {
                HStack {
                    ForEach(
                        call.artifactIDs,
                        id: \.rawValue
                    ) { artifactID in
                        Button {
                            openArtifact(artifactID)
                        } label: {
                            Label(
                                artifactID.rawValue,
                                systemImage: "archivebox")
                        }
                    }
                }
            }
        }
        .padding(.vertical, 7)
    }

    private var stateIcon: String {
        switch call.state {
        case .waitingForApproval:
            return "person.badge.clock"
        case .running:
            return "gearshape.2"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .denied:
            return "hand.raised.fill"
        case .cancelled:
            return "slash.circle"
        case .timedOut:
            return "clock.badge.exclamationmark"
        case .disconnected:
            return "network.slash"
        case .uncertain:
            return "questionmark.diamond"
        }
    }

    private var stateColor: Color {
        switch call.state {
        case .waitingForApproval, .uncertain:
            return .orange
        case .running:
            return .blue
        case .succeeded:
            return .green
        case .failed, .denied, .timedOut:
            return .red
        case .cancelled, .disconnected:
            return .secondary
        }
    }
}

private enum MCPConversationJSON {
    static func text(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        guard let data = try? encoder.encode(value),
              let text = String(
                data: data,
                encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
#endif
