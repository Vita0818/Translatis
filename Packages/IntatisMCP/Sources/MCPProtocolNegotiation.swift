import Foundation
import IntatisProtocol
import MCP

/// The protocol versions implemented by the pinned client derivative, in
/// ascending order. Negotiation is always scoped to one immutable server
/// revision; no process-global "latest" value is used by Intatis.
public enum MCPProtocolNegotiationPolicy {
    public static let supportedVersions: [MCPProtocolVersion] = [
        MCPProtocolVersion(rawValue: "2024-11-05"),
        MCPProtocolVersion(rawValue: "2025-03-26"),
        .v2025_06_18,
        .v2025_11_25,
    ]

    public static func request(
        profile: MCPProtocolProfile,
        configuredMaximum: MCPProtocolVersion
    ) throws -> MCPProtocolNegotiationRequest {
        guard let configuredIndex = supportedVersions.firstIndex(of: configuredMaximum),
              let profileIndex = supportedVersions.firstIndex(
                  of: profile.defaultMaximumVersion),
              configuredIndex <= profileIndex else {
            throw MCPClientSessionError.unsupportedConfiguredProtocolVersion(
                configuredMaximum.rawValue)
        }

        let allowed = Set(
            supportedVersions[...configuredIndex].map(\.rawValue))
        guard allowed.isSubset(of: Version.supported) else {
            throw MCPClientSessionError.sdkProtocolCoverageMismatch
        }
        return MCPProtocolNegotiationRequest(
            profile: profile,
            requestedVersion: configuredMaximum,
            allowedVersions: allowed)
    }
}

public struct MCPProtocolNegotiationRequest: Equatable, Sendable {
    public let profile: MCPProtocolProfile
    public let requestedVersion: MCPProtocolVersion
    public let allowedVersions: Set<String>

    public init(
        profile: MCPProtocolProfile,
        requestedVersion: MCPProtocolVersion,
        allowedVersions: Set<String>
    ) {
        self.profile = profile
        self.requestedVersion = requestedVersion
        self.allowedVersions = allowedVersions
    }

    public func validateSelectedVersion(
        _ rawValue: String
    ) throws -> MCPNegotiatedProtocolVersion {
        guard allowedVersions.contains(rawValue) else {
            throw MCPClientSessionError.serverSelectedProtocolVersionOutsideProfile(
                selected: rawValue,
                requested: requestedVersion.rawValue,
                profile: profile.rawValue)
        }
        return MCPNegotiatedProtocolVersion(
            MCPProtocolVersion(rawValue: rawValue))
    }
}

/// Wire cancellation is request-kind specific. This is intentionally a closed
/// enum so an initialize or experimental task request cannot accidentally use
/// the ordinary JSON-RPC cancellation notification.
public enum MCPOutboundRequestKind: Equatable, Sendable {
    case initialize
    case ordinary
    case taskAugmented(remoteTaskID: String?)
}

public enum MCPOutboundCancellationAction: Equatable, Sendable {
    case retireConnectionGeneration
    case sendCancelledNotification
    case sendTasksCancel(remoteTaskID: String)
    case retireTaskGenerationWithoutRemoteTaskID
}

public enum MCPOutboundCancellationPolicy {
    public static func action(
        for kind: MCPOutboundRequestKind
    ) -> MCPOutboundCancellationAction {
        switch kind {
        case .initialize:
            return .retireConnectionGeneration
        case .ordinary:
            return .sendCancelledNotification
        case .taskAugmented(let remoteTaskID):
            guard let remoteTaskID, !remoteTaskID.isEmpty else {
                return .retireTaskGenerationWithoutRemoteTaskID
            }
            return .sendTasksCancel(remoteTaskID: remoteTaskID)
        }
    }
}

public struct MCPNegotiatedCapabilitySet: Equatable, Sendable {
    public let capabilities: Set<MCPGrantedCapability>
    public let toolsListChanged: Bool
    public let resourcesListChanged: Bool
    public let resourceSubscriptions: Bool
    public let promptsListChanged: Bool
    /// `tasks/get` and `tasks/result` are mandatory whenever the peer's
    /// `tasks` capability is negotiated; they are not gated by `tasks.list`.
    public let remoteTaskGetAndResult: Bool
    public let remoteTaskList: Bool
    public let remoteTaskCancel: Bool
    public let remoteTaskToolCall: Bool
    public let clientHostedTaskList: Bool
    public let clientHostedTaskCancel: Bool
    public let clientHostedTaskSampling: Bool
    public let clientHostedTaskElicitation: Bool

    public init(
        capabilities: Set<MCPGrantedCapability> = [],
        toolsListChanged: Bool = false,
        resourcesListChanged: Bool = false,
        resourceSubscriptions: Bool = false,
        promptsListChanged: Bool = false,
        remoteTaskGetAndResult: Bool = false,
        remoteTaskList: Bool = false,
        remoteTaskCancel: Bool = false,
        remoteTaskToolCall: Bool = false,
        clientHostedTaskList: Bool = false,
        clientHostedTaskCancel: Bool = false,
        clientHostedTaskSampling: Bool = false,
        clientHostedTaskElicitation: Bool = false
    ) {
        self.capabilities = capabilities
        self.toolsListChanged = toolsListChanged
        self.resourcesListChanged = resourcesListChanged
        self.resourceSubscriptions = resourceSubscriptions
        self.promptsListChanged = promptsListChanged
        self.remoteTaskGetAndResult = remoteTaskGetAndResult
        self.remoteTaskList = remoteTaskList
        self.remoteTaskCancel = remoteTaskCancel
        self.remoteTaskToolCall = remoteTaskToolCall
        self.clientHostedTaskList = clientHostedTaskList
        self.clientHostedTaskCancel = clientHostedTaskCancel
        self.clientHostedTaskSampling = clientHostedTaskSampling
        self.clientHostedTaskElicitation = clientHostedTaskElicitation
    }

    public static let none = MCPNegotiatedCapabilitySet()

    public init(
        server: RemoteServerCapabilities,
        client: Client.Capabilities
    ) {
        var capabilities: Set<MCPGrantedCapability> = [.progress]
        if server.tools != nil { capabilities.insert(.tools) }
        if server.resources != nil { capabilities.insert(.resources) }
        if server.prompts != nil { capabilities.insert(.prompts) }
        if server.completions != nil { capabilities.insert(.completions) }
        if server.logging != nil { capabilities.insert(.logging) }
        if server.resources?.subscribe == true {
            capabilities.insert(.subscriptions)
        }
        if client.roots != nil { capabilities.insert(.roots) }
        if client.sampling != nil { capabilities.insert(.sampling) }
        if client.elicitation != nil { capabilities.insert(.elicitation) }
        if server.tasks != nil, client.tasks != nil {
            capabilities.insert(.tasks)
        }

        self.capabilities = capabilities
        self.toolsListChanged = server.tools?.listChanged == true
        self.resourcesListChanged = server.resources?.listChanged == true
        self.resourceSubscriptions = server.resources?.subscribe == true
        self.promptsListChanged = server.prompts?.listChanged == true
        self.remoteTaskGetAndResult =
            server.tasks != nil && client.tasks != nil
        self.remoteTaskList = server.tasks?.list != nil
        self.remoteTaskCancel = server.tasks?.cancel != nil
        self.remoteTaskToolCall =
            server.tasks?.requests?.tools?.call != nil
        self.clientHostedTaskList = client.tasks?.list != nil
        self.clientHostedTaskCancel = client.tasks?.cancel != nil
        self.clientHostedTaskSampling =
            client.tasks?.requests?.sampling?.createMessage != nil
        self.clientHostedTaskElicitation =
            client.tasks?.requests?.elicitation?.create != nil
    }

    public func validateRequired(
        _ required: Set<MCPGrantedCapability>
    ) throws {
        let missing = required.subtracting(capabilities)
        guard missing.isEmpty else {
            throw MCPClientSessionError.missingRequiredCapabilities(
                missing.map(\.rawValue).sorted())
        }
    }
}
