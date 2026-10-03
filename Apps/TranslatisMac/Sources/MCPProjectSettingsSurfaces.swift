#if canImport(SwiftUI)
import CryptoKit
import Foundation
import IntatisAgentKernel
import IntatisConversation
import IntatisCore
import IntatisCodexRuntime
import IntatisMCP
import IntatisProtocol
import IntatisSharedUI
import SwiftUI

struct MCPProductAgentDescriptor:
    Identifiable, Equatable, Hashable, Sendable
{
    let agentID: AgentID
    let displayName: String
    let parentAgentID: AgentID?
    let isWorker: Bool
    let isPermissionReviewer: Bool
    /// Exact live lease/task authority that this settings row may grant.
    /// Code/main uses its stable session-root lease with a nil task; Cowork
    /// rows must be populated from the live roster and task lease.
    let capabilityLeaseID: CapabilityLeaseID
    let taskID: TaskID?
    /// Only the exact Code root or Cowork @main session-root lease is projected
    /// into the shipping Codex App Server. Other rows remain visible so old
    /// grants can be revoked, but cannot receive or execute native MCP access.
    let supportsNativeCodexMCP: Bool
    /// Exact upper bound already intersected with the live CapabilityLease
    /// and every ancestor/template ceiling by the data-plane host.
    let mcpCapabilityCeiling: Set<MCPGrantedCapability>

    var id: String {
        [
            agentID.rawValue,
            capabilityLeaseID.rawValue,
            taskID?.rawValue ?? "",
        ].joined(separator: "\u{1f}")
    }

    init(
        agentID: AgentID,
        displayName: String,
        parentAgentID: AgentID? = nil,
        isWorker: Bool,
        isPermissionReviewer: Bool = false,
        capabilityLeaseID: CapabilityLeaseID,
        taskID: TaskID? = nil,
        supportsNativeCodexMCP: Bool,
        mcpCapabilityCeiling:
            Set<MCPGrantedCapability>
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.parentAgentID = parentAgentID
        self.isWorker = isWorker
        self.isPermissionReviewer =
            isPermissionReviewer
        self.capabilityLeaseID =
            capabilityLeaseID
        self.taskID = taskID
        self.supportsNativeCodexMCP =
            !isPermissionReviewer
                && supportsNativeCodexMCP
        self.mcpCapabilityCeiling =
            isPermissionReviewer
                ? [] : mcpCapabilityCeiling
    }
}

struct MCPProductAgentAccessTemplate:
    Identifiable, Equatable, Hashable, Sendable
{
    let id: String
    let name: String
    let capabilityCeiling:
        Set<MCPGrantedCapability>
    let approvalModeCeiling: MCPApprovalMode
    let filter: MCPCatalogFilter

    init(
        id: String,
        name: String,
        capabilityCeiling:
            Set<MCPGrantedCapability>,
        approvalModeCeiling: MCPApprovalMode,
        filter: MCPCatalogFilter
    ) {
        self.id = id
        self.name = name
        self.capabilityCeiling = capabilityCeiling
        self.approvalModeCeiling =
            approvalModeCeiling
        self.filter = filter
    }
}

struct MCPProjectRuntimeInspection: Sendable {
    let snapshot: MCPConnectionSetSnapshot?
    let metrics: MCPMetricsSnapshot
    let diagnostics: [MCPDiagnosticSummary]

    init(
        snapshot: MCPConnectionSetSnapshot?,
        metrics: MCPMetricsSnapshot,
        diagnostics: [MCPDiagnosticSummary]
    ) {
        self.snapshot = snapshot
        self.metrics = metrics
        self.diagnostics = diagnostics
    }
}

struct MCPProjectGrantDraft: Sendable {
    let capabilities: Set<MCPGrantedCapability>
    let approvalModeCeiling: MCPApprovalMode
    let filter: MCPCatalogFilter
    let expiresAt: Date?
    let templateID: String?
}

/// Stable API used by shipping Code and Cowork native-Codex project settings.
///
/// EventLog authority mutations are provided by `eventLogBacked`. Runtime
/// actions remain injected because only the process runtime registry owns live
/// connections. No View owns or constructs an MCP connection. New grants are
/// restricted to the exact session-root Native Interactive surface; legacy
/// child grants remain visible only so the user can revoke them.
struct MCPProjectSettingsHost: Sendable {
    let sessionID: SessionID
    let state:
        @Sendable () async throws -> MCPDurableSessionState
    let inventory:
        @Sendable () async throws -> [MCPServerInventoryRecord]
    let agents:
        @Sendable () async throws -> [MCPProductAgentDescriptor]
    let templates:
        @Sendable () async throws
            -> [MCPProductAgentAccessTemplate]
    let attach:
        @Sendable (
            MCPServerInventoryRecord,
            MCPAttachmentPolicy,
            AgentID?
        ) async throws -> Void
    let detach:
        @Sendable (
            MCPServerAttachment,
            AgentID?
        ) async throws -> Void
    let updatePolicy:
        @Sendable (
            MCPServerAttachment,
            MCPAttachmentPolicy,
            AgentID?
        ) async throws -> Void
    let grant:
        @Sendable (
            MCPServerAttachment,
            MCPProductAgentDescriptor,
            MCPProjectGrantDraft
        ) async throws -> Void
    let revoke:
        @Sendable (MCPGrant) async throws -> Void
    let explicitConnect:
        @Sendable (
            MCPServerAttachment,
            MCPProductAgentDescriptor
        ) async throws -> MCPConnectionSetSnapshot
    let disconnect:
        @Sendable (MCPServerAttachment) async throws -> Void
    let refresh:
        @Sendable (
            MCPServerAttachment,
            MCPProductAgentDescriptor
        ) async throws -> MCPConnectionSetSnapshot
    /// Publishes the complete current set of exact workspace root authorities.
    /// The resulting durable event advances roots policy/revocation and the
    /// session observer notifies then retires every old generation.
    let publishRoots:
        @Sendable () async throws -> Void
    let inspect:
        @Sendable () async -> MCPProjectRuntimeInspection

    static func eventLogBacked(
        sessionID: SessionID,
        log: EventLog,
        management: MCPManagementService,
        agents:
            @escaping @Sendable () async throws
                -> [MCPProductAgentDescriptor],
        templates:
            @escaping @Sendable () async throws
                -> [MCPProductAgentAccessTemplate],
        resolveAuthorityFingerprint:
            @escaping @Sendable (
                MCPServerAttachment,
                MCPProductAgentDescriptor,
                MCPRevocationGeneration
            ) async throws -> String,
        explicitConnect:
            @escaping @Sendable (
                MCPServerAttachment,
                MCPProductAgentDescriptor
            ) async throws -> MCPConnectionSetSnapshot,
        disconnect:
            @escaping @Sendable (
                MCPServerAttachment
            ) async throws -> Void,
        refresh:
            @escaping @Sendable (
                MCPServerAttachment,
                MCPProductAgentDescriptor
            ) async throws -> MCPConnectionSetSnapshot,
        rootAuthorities:
            @escaping @Sendable () async throws
                -> [MCPRootAuthoritySummary],
        authorityChanged:
            @escaping @Sendable () async -> Void,
        inspect:
            @escaping @Sendable () async
                -> MCPProjectRuntimeInspection
    ) -> MCPProjectSettingsHost {
        MCPProjectSettingsHost(
            sessionID: sessionID,
            state: {
                try await MCPDurableSessionState.load(
                    from: log)
            },
            inventory: {
                try await management.inventory()
            },
            agents: agents,
            templates: templates,
            attach: { record, policy, actor in
                let definition =
                    try await management.definition(
                        serverOrAlias:
                            record.serverID.rawValue)
                let current =
                    try await MCPDurableSessionState
                        .load(from: log)
                guard !current.attachments.values
                    .contains(where: {
                        $0.server.serverID
                            == definition.reference.serverID
                    }) else {
                    throw MCPProjectSettingsError
                        .alreadyAttached
                }
                let attachment = MCPServerAttachment(
                    server: definition.reference,
                    policy: policy,
                    source: .user)
                _ = try await log.append(
                    .mcpServerAttached(.init(
                        attachment: attachment,
                        actorAgentID: actor)))
                await authorityChanged()
            },
            detach: { attachment, actor in
                let payload = MCPServerDetachedPayload(
                    attachmentID:
                        attachment.attachmentID,
                    server: attachment.server,
                    reason: .user,
                    revocationGeneration:
                        Self.newRevocation(),
                    actorAgentID: actor)
                _ = try await log.append(
                    .mcpServerDetached(payload))
                await authorityChanged()
                try await disconnect(attachment)
            },
            updatePolicy: {
                attachment, policy, actor in
                guard policy.revision
                        != attachment.policy.revision else {
                    throw MCPProjectSettingsError
                        .stalePolicy
                }
                _ = try await log.append(
                    .mcpAttachmentPolicyUpdated(.init(
                        attachmentID:
                            attachment.attachmentID,
                        server: attachment.server,
                        previousRevision:
                            attachment.policy.revision,
                        policy: policy,
                        revocationGeneration:
                            Self.newRevocation(),
                        actorAgentID: actor)))
                await authorityChanged()
            },
            grant: { attachment, agent, draft in
                guard !agent.isPermissionReviewer,
                      agent.agentID.rawValue
                        != "permission-reviewer" else {
                    throw MCPProjectSettingsError
                        .reviewerCannotReceiveAccess
                }
                guard agent.supportsNativeCodexMCP,
                      agent.taskID == nil else {
                    throw MCPProjectSettingsError
                        .nativeCodexRootRequired
                }
                let template = try await templates()
                    .first {
                        $0.id == draft.templateID
                    }
                let catalog =
                    try await management.catalog()
                guard let definition =
                        catalog.definition(
                            for: attachment.server) else {
                    throw MCPManagementError
                        .currentRevisionMissing(
                            attachment.server.serverID)
                }
                let templateCeiling =
                    template?.capabilityCeiling
                        ?? CodexRuntimeMCPProjector
                            .requiredNativeSurfaceCapabilities
                let effective = draft.capabilities
                    .intersection(templateCeiling)
                    .intersection(
                        agent.mcpCapabilityCeiling)
                try CodexRuntimeMCPProjector
                    .validateNativeSurfaceAuthority(
                        capabilities: effective,
                        expiresAt: draft.expiresAt)
                guard !effective.isEmpty else {
                    throw MCPProjectSettingsError
                        .emptyEffectiveGrant
                }
                guard Set(
                    definition.configuration
                        .requiredCapabilities)
                    .isSubset(of: effective) else {
                    throw MCPProjectSettingsError
                        .missingRequiredCapabilities
                }
                let approval =
                    Self.moreRestrictive(
                        Self.moreRestrictive(
                            draft.approvalModeCeiling,
                            template?.approvalModeCeiling
                                ?? draft
                                    .approvalModeCeiling),
                        Self.moreRestrictive(
                            attachment.policy.approvalMode,
                            definition.configuration
                                .approvalPolicy
                                .serverDefault))
                let filterRevision =
                    MCPPolicyRevision(
                        rawValue: IDGen.random(
                            prefix: "mcppolicy"))
                let serverFilter =
                    definition.configuration.filters
                let filter = MCPCatalogFilter(
                    revision: filterRevision,
                    tools: Self.intersection([
                        serverFilter.tools,
                        attachment.policy.filter.tools,
                        template?.filter.tools,
                        draft.filter.tools,
                    ].compactMap { $0 }),
                    resources: Self.intersection([
                        serverFilter.resources,
                        attachment.policy.filter.resources,
                        template?.filter.resources,
                        draft.filter.resources,
                    ].compactMap { $0 }),
                    prompts: Self.intersection([
                        serverFilter.prompts,
                        attachment.policy.filter.prompts,
                        template?.filter.prompts,
                        draft.filter.prompts,
                    ].compactMap { $0 }),
                    completions: Self.intersection([
                        serverFilter.completions,
                        attachment.policy.filter.completions,
                        template?.filter.completions,
                        draft.filter.completions,
                    ].compactMap { $0 }))
                let revocation = Self.newRevocation()
                let authority =
                    try await resolveAuthorityFingerprint(
                        attachment,
                        agent,
                        revocation)
                guard authority.count == 64,
                      authority.allSatisfy({
                          $0.isHexDigit
                      }) else {
                    throw MCPProjectSettingsError
                        .invalidAuthorityFingerprint
                }
                let capabilities = effective.sorted {
                    $0.rawValue < $1.rawValue
                }
                let fingerprint = Self.sha256([
                    attachment.attachmentID.rawValue,
                    attachment.server.serverRevision
                        .rawValue,
                    agent.agentID.rawValue,
                    capabilities.map(\.rawValue)
                        .joined(separator: ","),
                    authority,
                    revocation.rawValue,
                    draft.templateID ?? "",
                ])
                let grant = MCPGrant(
                    attachmentID:
                        attachment.attachmentID,
                    server: attachment.server,
                    agentID: agent.agentID,
                    capabilityLeaseID:
                        agent.capabilityLeaseID,
                    taskID: agent.taskID,
                    capabilities: capabilities,
                    filter: filter,
                    approvalModeCeiling: approval,
                    authorityFingerprint: authority,
                    grantFingerprint: fingerprint,
                    revocationGeneration:
                        revocation,
                    expiresAt: draft.expiresAt)
                let current =
                    try await MCPDurableSessionState
                        .load(from: log)
                let prior = current.grants.values
                    .filter {
                        $0.attachmentID
                            == attachment.attachmentID
                            && $0.agentID
                                == agent.agentID
                    }
                var events = prior.map {
                    Event.mcpGrantRevoked(.init(
                        grantID: $0.grantID,
                        server: $0.server,
                        attachmentID:
                            $0.attachmentID,
                        agentID: $0.agentID,
                        reason: .user,
                        revocationGeneration:
                            revocation))
                }
                events.append(
                    .mcpGrantGranted(.init(
                        grant: grant)))
                _ = try await log.append(events)
                await authorityChanged()
            },
            revoke: { grant in
                _ = try await log.append(
                    .mcpGrantRevoked(.init(
                        grantID: grant.grantID,
                        server: grant.server,
                        attachmentID:
                            grant.attachmentID,
                        agentID: grant.agentID,
                        reason: .user,
                        revocationGeneration:
                            Self.newRevocation())))
                await authorityChanged()
            },
            explicitConnect: explicitConnect,
            disconnect: disconnect,
            refresh: refresh,
            publishRoots: {
                let state =
                    try await MCPDurableSessionState
                        .load(from: log)
                let roots =
                    try await rootAuthorities()
                let revision =
                    MCPPolicyRevision(
                        rawValue:
                            IDGen.random(
                                prefix:
                                    "mcppolicy_roots"))
                _ = try await log.append(
                    .mcpRootsPolicyUpdated(.init(
                        revision: revision,
                        previousRevision:
                            state.rootsPolicyRevision,
                        roots: roots,
                        revocationGeneration:
                            Self.newRevocation(),
                        actorAgentID: nil)))
                await authorityChanged()
            },
            inspect: inspect)
    }

    private static func newRevocation()
        -> MCPRevocationGeneration {
        MCPRevocationGeneration(
            rawValue: IDGen.random(
                prefix: "mcprevocation"))
    }

    private static func sha256(
        _ fields: [String]
    ) -> String {
        let data = Data(
            fields.joined(separator: "|").utf8)
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func moreRestrictive(
        _ lhs: MCPApprovalMode,
        _ rhs: MCPApprovalMode
    ) -> MCPApprovalMode {
        MCPApprovalPolicy.mostRestrictive(lhs, rhs)
    }

    private static func intersection(
        _ filters: [MCPNameFilter]
    ) -> MCPNameFilter {
        let allowLists = filters.compactMap(\.allowList)
        let allow: [String]?
        if let first = allowLists.first {
            var values = Set(first)
            for list in allowLists.dropFirst() {
                values.formIntersection(list)
            }
            allow = values.sorted()
        } else {
            allow = nil
        }
        return MCPNameFilter(
            allowList: allow,
            denyList: Array(Set(
                filters.flatMap(\.denyList))).sorted())
    }
}

enum MCPProjectSettingsError:
    Error, LocalizedError, Equatable
{
    case alreadyAttached
    case stalePolicy
    case reviewerCannotReceiveAccess
    case nativeCodexRootRequired
    case emptyEffectiveGrant
    case missingRequiredCapabilities
    case invalidAuthorityFingerprint

    var errorDescription: String? {
        switch self {
        case .alreadyAttached:
            return "This MCP server is already attached to the session."
        case .stalePolicy:
            return "The MCP attachment policy changed; reload before saving."
        case .reviewerCannotReceiveAccess:
            return "The permission reviewer cannot receive MCP access."
        case .nativeCodexRootRequired:
            return "Only the exact Code root or Cowork @main session-root Agent can receive native Codex MCP access."
        case .emptyEffectiveGrant:
            return "The requested MCP access is empty after intersecting the template, parent, and CapabilityLease ceilings."
        case .missingRequiredCapabilities:
            return "The effective Agent grant does not include every capability required by this immutable server revision."
        case .invalidAuthorityFingerprint:
            return "The data plane did not provide a valid exact MCP authority fingerprint."
        }
    }
}

@MainActor
private final class MCPProjectSettingsModel:
    ObservableObject
{
    @Published var state = MCPDurableSessionState()
    @Published var inventory:
        [MCPServerInventoryRecord] = []
    @Published var agents:
        [MCPProductAgentDescriptor] = []
    @Published var templates:
        [MCPProductAgentAccessTemplate] = []
    @Published var inspection:
        MCPProjectRuntimeInspection?
    @Published var isWorking = false
    @Published var errorMessage: String?
    @Published var lastResult: String?

    let host: MCPProjectSettingsHost

    init(host: MCPProjectSettingsHost) {
        self.host = host
    }

    func reload() async {
        do {
            async let state = host.state()
            async let inventory = host.inventory()
            async let agents = host.agents()
            async let templates = host.templates()
            self.state = try await state
            self.inventory = try await inventory
            self.agents = try await agents.sorted {
                $0.agentID.rawValue
                    < $1.agentID.rawValue
            }
            self.templates = try await templates
            inspection = await host.inspect()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func perform(
        success: String,
        _ operation:
            @escaping @Sendable () async throws -> Void
    ) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        lastResult = nil
        do {
            try await operation()
            lastResult = success
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }

    func performSnapshot(
        success: String,
        _ operation:
            @escaping @Sendable () async throws
                -> MCPConnectionSetSnapshot
    ) async {
        await perform(success: success) {
            _ = try await operation()
        }
    }
}

struct MCPProjectSettingsView: View {
    @StateObject private var model:
        MCPProjectSettingsModel
    private let contentHost:
        MCPConversationContentHost?
    @State private var showsAttach = false
    @State private var showsContent = false
    @State private var policyTarget:
        MCPAttachmentTarget?
    @State private var detachTarget:
        MCPAttachmentTarget?
    @State private var grantTarget:
        MCPProjectGrantTarget?

    init(
        host: MCPProjectSettingsHost,
        contentHost: MCPConversationContentHost? = nil
    ) {
        _model = StateObject(
            wrappedValue:
                MCPProjectSettingsModel(host: host))
        self.contentHost = contentHost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MCP Project Settings")
                        .font(IntatisTypography.system(.title2, bold: true))
                    Text(
                        "Session \(model.host.sessionID.rawValue)")
                        .font(IntatisTypography.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                if contentHost != nil {
                    Button {
                        showsContent = true
                    } label: {
                        Label(
                            "Browse Content",
                            systemImage:
                                "shippingbox.and.arrow.backward")
                    }
                    .help(
                        "Browse granted MCP resources, prompts, tasks, and calls")
                }
                Button {
                    Task { await model.reload() }
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                Button {
                    showsAttach = true
                } label: {
                    Label("Attach Server", systemImage: "link.badge.plus")
                }
                .buttonStyle(.borderedProminent)
            }
            attachedServers
            Divider()
            agentAccess
            Divider()
            rootsPolicy
            status
        }
        .padding(20)
        .task { await model.reload() }
        .sheet(isPresented: $showsAttach) {
            MCPAttachServerSheet(model: model)
        }
        .sheet(isPresented: $showsContent) {
            if let contentHost {
                MCPConversationCenterSheet(
                    host: contentHost)
            }
        }
        .sheet(item: $policyTarget) { target in
            MCPAttachmentPolicySheet(
                model: model,
                attachment: target.attachment)
        }
        .sheet(item: $grantTarget) { target in
            MCPGrantEditorSheet(
                model: model,
                target: target)
        }
        .alert(
            "Detach MCP Server?",
            isPresented: Binding(
                get: { detachTarget != nil },
                set: {
                    if !$0 { detachTarget = nil }
                }),
            presenting: detachTarget
        ) { target in
            Button("Cancel", role: .cancel) {}
            Button("Detach", role: .destructive) {
                Task {
                    await model.perform(
                        success:
                            "Detached the exact MCP server revision and drained its live authority."
                    ) {
                        try await model.host.detach(
                            target.attachment,
                            nil)
                    }
                }
            }
        } message: { _ in
            Text(
                "Detaching revokes the attachment and all of its Agent grants. The session EventLog remains the audit record.")
        }
    }

    private var rootsPolicy: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Authorized Roots")
                        .font(IntatisTypography.system(.headline))
                    Text(
                        "Publish the current exact Agent workspace leases and root identities. This sends roots/listChanged when supported, advances durable policy, and retires every old connection generation.")
                        .font(IntatisTypography.system(.callout))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await model.perform(
                            success:
                                "Published the complete current MCP roots policy and retired old generations."
                        ) {
                            try await model.host
                                .publishRoots()
                        }
                    }
                } label: {
                    Label(
                        "Publish Current Roots",
                        systemImage:
                            "folder.badge.gearshape")
                }
                .disabled(model.isWorking)
            }
            if let revision =
                    model.state.rootsPolicyRevision {
                Text(
                    "Current policy revision: \(revision.rawValue)")
                    .font(IntatisTypography.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                Text(
                    "No MCP roots policy has been published for this session.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var attachedServers: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Attached Servers")
                .font(IntatisTypography.system(.headline))
            if model.state.attachments.isEmpty {
                ContentUnavailableView(
                    "No attached MCP servers",
                    systemImage: "link.badge.plus",
                    description: Text(
                        "Attaching records session authority only. It does not connect until an explicit Connect, Send, Resume, or Retry action."))
            }
            ForEach(
                model.state.attachments.values.sorted {
                    $0.server.serverID.rawValue
                        < $1.server.serverID.rawValue
                },
                id: \.attachmentID
            ) { attachment in
                MCPAttachmentRow(
                    attachment: attachment,
                    live: liveConnection(attachment),
                    isWorking: model.isWorking,
                    onConnect: {
                        connect(attachment)
                    },
                    onDisconnect: {
                        Task {
                            await model.perform(
                                success:
                                    "Disconnected and drained the MCP server authority."
                            ) {
                                try await model.host
                                    .disconnect(attachment)
                            }
                        }
                    },
                    onRefresh: {
                        refresh(attachment)
                    },
                    onPolicy: {
                        policyTarget = MCPAttachmentTarget(
                            attachment: attachment)
                    },
                    onDetach: {
                        detachTarget = MCPAttachmentTarget(
                            attachment: attachment)
                    })
            }
        }
    }

    private var agentAccess: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Access")
                .font(IntatisTypography.system(.headline))
            Text(
                "Absence of an exact grant is denial. New workers start with zero MCP access. The permission reviewer always has zero access and cannot be targeted. Child access is the intersection of the selected template, parent ancestry, live CapabilityLease ceiling, attachment policy, and server filter.")
                .font(IntatisTypography.system(.callout))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12) {
                GridRow {
                    Text("Agent").font(IntatisTypography.system(.caption, bold: true))
                    ForEach(
                        model.state.attachments.values.sorted {
                            $0.server.serverID.rawValue
                                < $1.server.serverID.rawValue
                        },
                        id: \.attachmentID
                    ) { attachment in
                        Text(serverName(attachment))
                            .font(IntatisTypography.system(.caption, bold: true))
                            .lineLimit(1)
                    }
                }
                Divider()
                ForEach(model.agents) { agent in
                    GridRow {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.displayName)
                            Text(agent.agentID.rawValue)
                                .font(IntatisTypography.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            if agent.isWorker {
                                Text("Worker")
                                    .font(IntatisTypography.system(.caption2))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(
                            model.state.attachments.values.sorted {
                                $0.server.serverID.rawValue
                                    < $1.server.serverID.rawValue
                            },
                            id: \.attachmentID
                        ) { attachment in
                            accessCell(
                                agent: agent,
                                attachment: attachment)
                        }
                    }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func accessCell(
        agent: MCPProductAgentDescriptor,
        attachment: MCPServerAttachment
    ) -> some View {
        if agent.isPermissionReviewer
            || agent.agentID.rawValue
                == "permission-reviewer" {
            Label("No access", systemImage: "lock.fill")
                .font(IntatisTypography.system(.caption))
                .foregroundStyle(.secondary)
        } else if !agent.supportsNativeCodexMCP {
            if let existing = grant(
                agent: agent,
                attachment: attachment)
            {
                Menu {
                    Text("Not available to this Codex Agent")
                    Button(
                        "Revoke Old Grant",
                        role: .destructive
                    ) {
                        Task {
                            await model.perform(
                                success:
                                    "Revoked the old non-shipping MCP grant."
                            ) {
                                try await model.host.revoke(
                                    existing)
                            }
                        }
                    }
                } label: {
                    Label(
                        "Root only",
                        systemImage: "lock.fill")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
            } else {
                Label("Root only", systemImage: "lock.fill")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
        } else if let grant = grant(
            agent: agent,
            attachment: attachment)
        {
            Menu {
                Button("Edit Grant…") {
                    grantTarget = MCPProjectGrantTarget(
                        agent: agent,
                        attachment: attachment,
                        existing: grant)
                }
                Button(
                    "Revoke Grant",
                    role: .destructive
                ) {
                    Task {
                        await model.perform(
                            success:
                                "Revoked the exact Agent MCP grant."
                        ) {
                            try await model.host.revoke(grant)
                        }
                    }
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(nativeGrantLabel(grant))
                        .font(IntatisTypography.system(.caption))
                    Text(grant.approvalModeCeiling.rawValue)
                        .font(IntatisTypography.system(.caption2))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
        } else {
            Button("Grant…") {
                grantTarget = MCPProjectGrantTarget(
                    agent: agent,
                    attachment: attachment,
                    existing: nil)
            }
            .font(IntatisTypography.system(.caption))
        }
    }

    @ViewBuilder
    private var status: some View {
        if let result = model.lastResult {
            Label(result, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        }
        if let error = model.errorMessage {
            Label(error, systemImage: "exclamationmark.octagon")
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func serverName(
        _ attachment: MCPServerAttachment
    ) -> String {
        model.inventory.first {
            $0.serverID == attachment.server.serverID
        }?.alias ?? attachment.server.serverID.rawValue
    }

    private func liveConnection(
        _ attachment: MCPServerAttachment
    ) -> MCPConnectionSnapshot? {
        model.inspection?.snapshot?.connections.first {
            $0.bindingIdentity.server == attachment.server
                && $0.reuseIdentity.authority
                    .attachmentID
                    == attachment.attachmentID
        }
    }

    private func preferredAgent()
        -> MCPProductAgentDescriptor?
    {
        model.agents.first {
            $0.supportsNativeCodexMCP
                && !$0.isPermissionReviewer
                && $0.taskID == nil
        }
    }

    private func connect(
        _ attachment: MCPServerAttachment
    ) {
        guard let agent = preferredAgent() else {
            model.errorMessage =
                "No eligible Agent is available for an explicit MCP connection."
            return
        }
        Task {
            await model.performSnapshot(
                success:
                    "Connected the exact MCP server revision."
            ) {
                try await model.host.explicitConnect(
                    attachment,
                    agent)
            }
        }
    }

    private func refresh(
        _ attachment: MCPServerAttachment
    ) {
        guard let agent = preferredAgent() else {
            model.errorMessage =
                "No eligible Agent is available for an MCP refresh."
            return
        }
        Task {
            await model.performSnapshot(
                success:
                    "Published a fully discovered replacement MCP catalog."
            ) {
                try await model.host.refresh(
                    attachment,
                    agent)
            }
        }
    }

    private func grant(
        agent: MCPProductAgentDescriptor,
        attachment: MCPServerAttachment
    ) -> MCPGrant? {
        model.state.grants.values.first {
            $0.agentID == agent.agentID
                && $0.capabilityLeaseID
                    == agent.capabilityLeaseID
                && $0.taskID == agent.taskID
                && $0.attachmentID
                    == attachment.attachmentID
                && $0.isActive()
        }
    }

    private func nativeGrantLabel(
        _ grant: MCPGrant
    ) -> String {
        Set(grant.capabilities)
                == CodexRuntimeMCPProjector
                    .requiredNativeSurfaceCapabilities
            && grant.expiresAt == nil
            ? "Native Interactive"
            : "Needs upgrade"
    }
}

private struct MCPAttachmentTarget: Identifiable {
    let attachment: MCPServerAttachment
    var id: MCPAttachmentID {
        attachment.attachmentID
    }
}

private struct MCPAttachmentRow: View {
    let attachment: MCPServerAttachment
    let live: MCPConnectionSnapshot?
    let isWorking: Bool
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onRefresh: () -> Void
    let onPolicy: () -> Void
    let onDetach: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName:
                live == nil
                    ? "bolt.slash"
                    : "bolt.horizontal.circle.fill")
                .foregroundStyle(
                    live == nil
                        ? Color.secondary
                        : Color.green)
            VStack(alignment: .leading, spacing: 3) {
                Text(attachment.server.serverID.rawValue)
                    .font(IntatisTypography.system(.body, design: .monospaced))
                Text(
                    "\(attachment.policy.required ? "Required" : "Optional") · \(attachment.policy.approvalMode.rawValue) · \(attachment.policy.parallelCalls ? "parallel" : "serial")")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
                Text(
                    attachment.server.serverRevision.rawValue)
                    .font(IntatisTypography.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if live == nil {
                Button("Connect", action: onConnect)
            } else {
                Button("Refresh", action: onRefresh)
                Button("Disconnect", action: onDisconnect)
            }
            Menu {
                Button("Edit Attachment Policy…", action: onPolicy)
                Divider()
                Button(
                    "Detach",
                    role: .destructive,
                    action: onDetach)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .disabled(isWorking)
        .padding(.vertical, 5)
    }
}

private struct MCPAttachServerSheet: View {
    @ObservedObject var model: MCPProjectSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedServer: MCPServerID?
    @State private var required = false
    @State private var approval = MCPApprovalMode.prompt
    @State private var parallel = false

    private var available:
        [MCPServerInventoryRecord]
    {
        model.inventory.filter { record in
            record.enabled
                && record.currentRevision != nil
                && !model.state.attachments.values
                    .contains {
                        $0.server.serverID
                            == record.serverID
                    }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Server", selection: $selectedServer) {
                    Text("Select…")
                        .tag(nil as MCPServerID?)
                    ForEach(available) { server in
                        Text(
                            "\(server.alias) — \(server.displayName)")
                            .tag(
                                Optional(server.serverID))
                    }
                }
                Toggle("Required", isOn: $required)
                Toggle(
                    "Allow parallel calls",
                    isOn: $parallel)
                Picker("Approval", selection: $approval) {
                    Text("Prompt").tag(MCPApprovalMode.prompt)
                    Text("Writes").tag(MCPApprovalMode.writes)
                    Text("Auto").tag(MCPApprovalMode.auto)
                    Text("Approve").tag(MCPApprovalMode.approve)
                }
                Text(
                    "Attach records the current immutable server revision in the Session EventLog. It does not connect and it grants no Agent access.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Attach MCP Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach") {
                        guard let record = available.first(
                            where: {
                                $0.serverID
                                    == selectedServer
                            })
                        else { return }
                        let revision =
                            MCPPolicyRevision(
                                rawValue: IDGen.random(
                                    prefix: "mcppolicy"))
                        let policy =
                            MCPAttachmentPolicy(
                                revision: revision,
                                required: required,
                                approvalMode: approval,
                                parallelCalls: parallel,
                                filter: MCPCatalogFilter(
                                    revision: revision))
                        Task {
                            await model.perform(
                                success:
                                    "Attached the exact MCP server revision without connecting."
                            ) {
                                try await model.host.attach(
                                    record,
                                    policy,
                                    nil)
                            }
                            if model.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(selectedServer == nil)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private struct MCPAttachmentPolicySheet: View {
    @ObservedObject var model: MCPProjectSettingsModel
    let attachment: MCPServerAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var required: Bool
    @State private var approval: MCPApprovalMode
    @State private var parallel: Bool
    @State private var toolAllow: String
    @State private var toolDeny: String
    @State private var resourceAllow: String
    @State private var resourceDeny: String
    @State private var promptAllow: String
    @State private var promptDeny: String

    init(
        model: MCPProjectSettingsModel,
        attachment: MCPServerAttachment
    ) {
        self.model = model
        self.attachment = attachment
        _required = State(
            initialValue:
                attachment.policy.required)
        _approval = State(
            initialValue:
                attachment.policy.approvalMode)
        _parallel = State(
            initialValue:
                attachment.policy.parallelCalls)
        _toolAllow = State(initialValue:
            Self.lines(
                attachment.policy.filter.tools.allowList))
        _toolDeny = State(initialValue:
            Self.lines(
                attachment.policy.filter.tools.denyList))
        _resourceAllow = State(initialValue:
            Self.lines(
                attachment.policy.filter.resources.allowList))
        _resourceDeny = State(initialValue:
            Self.lines(
                attachment.policy.filter.resources.denyList))
        _promptAllow = State(initialValue:
            Self.lines(
                attachment.policy.filter.prompts.allowList))
        _promptDeny = State(initialValue:
            Self.lines(
                attachment.policy.filter.prompts.denyList))
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle("Required", isOn: $required)
                Toggle(
                    "Allow parallel calls",
                    isOn: $parallel)
                Picker("Approval", selection: $approval) {
                    Text("Prompt").tag(MCPApprovalMode.prompt)
                    Text("Writes").tag(MCPApprovalMode.writes)
                    Text("Auto").tag(MCPApprovalMode.auto)
                    Text("Approve").tag(MCPApprovalMode.approve)
                }
                MCPFilterEditor(
                    title: "Tools",
                    allow: $toolAllow,
                    deny: $toolDeny)
                MCPFilterEditor(
                    title: "Resources",
                    allow: $resourceAllow,
                    deny: $resourceDeny)
                MCPFilterEditor(
                    title: "Prompts",
                    allow: $promptAllow,
                    deny: $promptDeny)
                Text(
                    "Saving publishes a fresh policy revision and revocation generation. Existing connection authority must be re-established explicitly.")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Attachment Policy")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let revision =
                            MCPPolicyRevision(
                                rawValue: IDGen.random(
                                    prefix: "mcppolicy"))
                        let policy = MCPAttachmentPolicy(
                            revision: revision,
                            required: required,
                            approvalMode: approval,
                            parallelCalls: parallel,
                            filter: MCPCatalogFilter(
                                revision: revision,
                                tools: Self.filter(
                                    toolAllow,
                                    toolDeny),
                                resources: Self.filter(
                                    resourceAllow,
                                    resourceDeny),
                                prompts: Self.filter(
                                    promptAllow,
                                    promptDeny),
                                completions:
                                    attachment.policy.filter
                                        .completions))
                        Task {
                            await model.perform(
                                success:
                                    "Updated the exact MCP attachment policy."
                            ) {
                                try await model.host
                                    .updatePolicy(
                                        attachment,
                                        policy,
                                        nil)
                            }
                            if model.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 680, minHeight: 620)
    }

    private static func lines(
        _ values: [String]?
    ) -> String {
        values?.joined(separator: "\n") ?? ""
    }

    private static func lines(
        _ values: [String]
    ) -> String {
        values.joined(separator: "\n")
    }

    private static func filter(
        _ allow: String,
        _ deny: String
    ) -> MCPNameFilter {
        let allowed =
            MCPServerEditorDraft.entries(allow)
        return MCPNameFilter(
            allowList:
                allowed.isEmpty ? nil : allowed,
            denyList:
                MCPServerEditorDraft.entries(deny))
    }
}

private struct MCPProjectGrantTarget: Identifiable {
    let agent: MCPProductAgentDescriptor
    let attachment: MCPServerAttachment
    let existing: MCPGrant?

    var id: String {
        "\(agent.id)|\(attachment.attachmentID.rawValue)"
    }
}

private struct MCPGrantEditorSheet: View {
    @ObservedObject var model: MCPProjectSettingsModel
    let target: MCPProjectGrantTarget
    @Environment(\.dismiss) private var dismiss
    @State private var approval: MCPApprovalMode

    init(
        model: MCPProjectSettingsModel,
        target: MCPProjectGrantTarget
    ) {
        self.model = model
        self.target = target
        _approval = State(
            initialValue:
                target.existing?.approvalModeCeiling
                    ?? .prompt)
    }

    private var nativeCapabilities:
        Set<MCPGrantedCapability> {
        CodexRuntimeMCPProjector
            .requiredNativeSurfaceCapabilities
    }

    private var canSave: Bool {
        target.agent.supportsNativeCodexMCP
            && target.agent.taskID == nil
            && nativeCapabilities.isSubset(
                of: target.agent.mcpCapabilityCeiling)
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Agent") {
                    Text(target.agent.displayName)
                }
                Section("Codex Native Interactive") {
                    Label(
                        "Complete native MCP surface",
                        systemImage: "checkmark.shield.fill")
                    Text(
                        nativeCapabilities.map(\.rawValue)
                            .sorted()
                            .joined(separator: ", "))
                        .font(IntatisTypography.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Text(
                        "Codex owns this server as one native MCP surface. Approval policy and tool filters may narrow actions; capabilities cannot be partially granted and this authority does not expire.")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                }
                Picker(
                    "Approval ceiling",
                    selection: $approval
                ) {
                    Text("Prompt").tag(MCPApprovalMode.prompt)
                    Text("Writes").tag(MCPApprovalMode.writes)
                    Text("Auto").tag(MCPApprovalMode.auto)
                    Text("Approve").tag(MCPApprovalMode.approve)
                }
                Section("Effective grant") {
                    Text(
                        canSave
                            ? "Complete Interactive · session-root"
                            : "Unavailable for this Agent authority")
                        .font(IntatisTypography.system(.body, design: .monospaced))
                    Text(
                        "The saved grant remains bound to this exact Agent, CapabilityLease, attachment revision, consent, and revocation generation.")
                        .font(IntatisTypography.system(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Agent MCP Access")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Grant") {
                        let revision =
                            MCPPolicyRevision(
                                rawValue: IDGen.random(
                                    prefix: "mcppolicy"))
                        let draft = MCPProjectGrantDraft(
                            capabilities:
                                nativeCapabilities,
                            approvalModeCeiling:
                                approval,
                            filter: MCPCatalogFilter(
                                revision: revision),
                            expiresAt: nil,
                            templateID: nil)
                        Task {
                            await model.perform(
                                success:
                                    "Saved the exact Codex Native Interactive MCP grant."
                            ) {
                                try await model.host.grant(
                                    target.attachment,
                                    target.agent,
                                    draft)
                            }
                            if model.errorMessage == nil {
                                dismiss()
                            }
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 680)
    }
}
#endif
