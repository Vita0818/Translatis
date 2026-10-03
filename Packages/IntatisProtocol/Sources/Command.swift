import Foundation
import IntatisCore

// MARK: - Command params (v0.1 chat scope)

public struct SessionCreateParams: Codable, Equatable, Sendable {
    public var kind: SessionKind
    public var title: String?
    public init(kind: SessionKind, title: String? = nil) {
        self.kind = kind
        self.title = title
    }
}

public struct SessionResumeParams: Codable, Equatable, Sendable {
    public var session: SessionID
    public var fromSeq: Int
    public init(session: SessionID, fromSeq: Int = 0) {
        self.session = session
        self.fromSeq = fromSeq
    }
}

public struct MessageSendParams: Codable, Equatable, Sendable {
    public var session: SessionID
    public var text: String
    public var attachments: [ArtifactID]?
    public var to: AgentID?
    public init(session: SessionID, text: String, attachments: [ArtifactID]? = nil, to: AgentID? = nil) {
        self.session = session
        self.text = text
        self.attachments = attachments
        self.to = to
    }
}

public struct PermissionRespondParams: Codable, Equatable, Sendable {
    public var session: SessionID
    public var requestId: RequestID
    public var decision: PermissionDecision   // allow / deny
    /// Additive explicit response semantics. Nil remains the legacy wire shape
    /// and derives approve/decline from `decision`.
    public var action: PermissionResponseAction?
    public init(session: SessionID,
                requestId: RequestID,
                decision: PermissionDecision,
                action: PermissionResponseAction? = nil) {
        self.session = session
        self.requestId = requestId
        self.decision = decision
        self.action = action
    }

    public var effectiveAction: PermissionResponseAction {
        if let action { return action }
        return decision == .allow ? .approve : .decline
    }
}

public struct AgentAttachParams: Codable, Equatable, Sendable {
    public var session: SessionID
    public var name: AgentID
    public var path: String
    public var model: ModelID?
    public init(session: SessionID, name: AgentID, path: String, model: ModelID? = nil) {
        self.session = session
        self.name = name
        self.path = path
        self.model = model
    }
}

public struct ProfileSetParams: Codable, Equatable, Sendable {
    public var session: SessionID
    public var agent: AgentID
    /// manual / reviewed / autopilot / read_only / locked
    public var mode: String
    public init(session: SessionID, agent: AgentID, mode: String) {
        self.session = session
        self.agent = agent
        self.mode = mode
    }
}

// MARK: - Command

/// A client→kernel request. Maps onto a JSON-RPC request `{ method, params }`
/// when an out-of-process transport is added (v0.2+). In v0.1 the kernel runs
/// in-process, but the boundary is already this shape (ARCHITECTURE.md §5.1).
public enum Command: Codable, Equatable, Sendable {
    case sessionCreate(SessionCreateParams)
    case sessionResume(SessionResumeParams)
    case sessionList
    case messageSend(MessageSendParams)
    // v0.2
    case permissionRespond(PermissionRespondParams)
    case agentAttach(AgentAttachParams)
    case profileSet(ProfileSetParams)

    public enum Method: String, Codable, Sendable {
        case sessionCreate = "session.create"
        case sessionResume = "session.resume"
        case sessionList = "session.list"
        case messageSend = "message.send"
        case permissionRespond = "permission.respond"
        case agentAttach = "agent.attach"
        case profileSet = "profile.set"
    }

    public var method: Method {
        switch self {
        case .sessionCreate:     return .sessionCreate
        case .sessionResume:     return .sessionResume
        case .sessionList:       return .sessionList
        case .messageSend:       return .messageSend
        case .permissionRespond: return .permissionRespond
        case .agentAttach:       return .agentAttach
        case .profileSet:        return .profileSet
        }
    }

    private enum CodingKeys: String, CodingKey {
        case method, params
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let method = try c.decode(Method.self, forKey: .method)
        switch method {
        case .sessionCreate:
            self = .sessionCreate(try c.decode(SessionCreateParams.self, forKey: .params))
        case .sessionResume:
            self = .sessionResume(try c.decode(SessionResumeParams.self, forKey: .params))
        case .sessionList:
            self = .sessionList
        case .messageSend:
            self = .messageSend(try c.decode(MessageSendParams.self, forKey: .params))
        case .permissionRespond:
            self = .permissionRespond(try c.decode(PermissionRespondParams.self, forKey: .params))
        case .agentAttach:
            self = .agentAttach(try c.decode(AgentAttachParams.self, forKey: .params))
        case .profileSet:
            self = .profileSet(try c.decode(ProfileSetParams.self, forKey: .params))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(method, forKey: .method)
        switch self {
        case .sessionCreate(let p): try c.encode(p, forKey: .params)
        case .sessionResume(let p): try c.encode(p, forKey: .params)
        case .sessionList:              break
        case .messageSend(let p):       try c.encode(p, forKey: .params)
        case .permissionRespond(let p): try c.encode(p, forKey: .params)
        case .agentAttach(let p):       try c.encode(p, forKey: .params)
        case .profileSet(let p):        try c.encode(p, forKey: .params)
        }
    }
}
