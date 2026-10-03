import Foundation

/// A strongly-typed identifier backed by a `String`.
///
/// Conforming types encode/decode as a bare JSON string (not an object), so the
/// wire format stays compact and human-readable in the event log.
public protocol TypedID: Hashable, Codable, Sendable, CustomStringConvertible {
    var rawValue: String { get }
    init(rawValue: String)
}

public extension TypedID {
    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Generates short, prefixed, URL-safe identifiers (e.g. `sess_a1b2c3d4`).
public enum IDGen {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    public static func random(prefix: String, length: Int = 8) -> String {
        let suffix = String((0..<length).map { _ in alphabet.randomElement()! })
        return "\(prefix)_\(suffix)"
    }
}

public struct SessionID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> SessionID { SessionID(rawValue: IDGen.random(prefix: "sess")) }
}

/// Identifies one user-selected folder project independently from any
/// conversation stored beneath it. Project membership is app-local metadata;
/// it does not replace a session's own identity or EventLog.
public struct ProjectID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ProjectID {
        ProjectID(rawValue: IDGen.random(prefix: "project"))
    }
}

public struct ThreadID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ThreadID { ThreadID(rawValue: IDGen.random(prefix: "thr")) }
}

public struct MessageID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> MessageID { MessageID(rawValue: IDGen.random(prefix: "msg")) }
}

/// Stable identity of one user-submitted intent across queueing and retries.
///
/// This is deliberately distinct from ``MessageID``: a submission can produce
/// multiple streamed assistant messages and multiple execution attempts while
/// retaining one immutable user payload.
public struct SubmissionID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> SubmissionID { SubmissionID(rawValue: IDGen.random(prefix: "sub")) }
}

public struct AgentID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct TaskID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> TaskID { TaskID(rawValue: IDGen.random(prefix: "task")) }
}

/// Identifies a durable user-visible unit of planned work.
///
/// This is intentionally distinct from ``TaskID``, which identifies an
/// execution-layer agent invocation.
public struct WorkTaskID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> WorkTaskID { WorkTaskID(rawValue: IDGen.random(prefix: "wt")) }
}

/// Identifies a durable objective that can span multiple continuation runs.
public struct GoalID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> GoalID { GoalID(rawValue: IDGen.random(prefix: "goal")) }
}

/// Identifies one ordinary turn or one continuation of a durable goal.
public struct ContinuationRunID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ContinuationRunID { ContinuationRunID(rawValue: IDGen.random(prefix: "run")) }
}

public struct TaskGroupID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> TaskGroupID { TaskGroupID(rawValue: IDGen.random(prefix: "taskgrp")) }
}

public struct WorkspaceID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> WorkspaceID { WorkspaceID(rawValue: IDGen.random(prefix: "ws")) }
}

public struct WorkspaceLeaseID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> WorkspaceLeaseID { WorkspaceLeaseID(rawValue: IDGen.random(prefix: "wlease")) }
}

public struct CapabilityLeaseID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> CapabilityLeaseID { CapabilityLeaseID(rawValue: IDGen.random(prefix: "clease")) }
}

public struct ArtifactID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> ArtifactID { ArtifactID(rawValue: IDGen.random(prefix: "art")) }
}

public struct ModelID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Identifies one configured inference connection independently from a model
/// vendor name. A connection is the host-controlled request/egress boundary;
/// credentials remain referenced and resolved outside durable protocol data.
public struct InferenceConnectionID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Opaque immutable revision of an inference connection definition. Pairing
/// it with `InferenceConnectionID` prevents endpoint, wire, credential-ref, or
/// trust-policy changes from silently retaining the same durable route identity.
public struct InferenceConnectionRevision: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Stable logical identity for an inference profile. Runtime and durable agent
/// bindings always pair this ID with an exact immutable revision.
public struct InferenceProfileID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Opaque immutable revision identity for an inference profile. It may be a
/// version, content-derived digest, or another catalog-owned stable value; core
/// deliberately does not interpret it.
public struct InferenceProfileRevision: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Exact reference used by durable session state. A profile ID without its
/// revision is only a mutable catalog selection and is not sufficient for
/// replay or authorization.
public struct InferenceProfileRef: Codable, Hashable, Sendable {
    public let inferenceProfileID: InferenceProfileID
    public let inferenceProfileRevision: InferenceProfileRevision

    public init(inferenceProfileID: InferenceProfileID,
                inferenceProfileRevision: InferenceProfileRevision) {
        self.inferenceProfileID = inferenceProfileID
        self.inferenceProfileRevision = inferenceProfileRevision
    }
}

/// Correlates a request (e.g. a permission ask) with its later response.
public struct RequestID: TypedID {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static func new() -> RequestID { RequestID(rawValue: IDGen.random(prefix: "req")) }
}
