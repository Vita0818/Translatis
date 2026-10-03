import Foundation
import IntatisCore

/// Durable model-facing history, separate in meaning from UI/audit events.
///
/// These records preserve the ordered items needed to build a later provider
/// request. Display events may remain bounded or redacted independently.
public enum ModelHistoryItemKind: String, Codable, Equatable, Sendable {
    case message
    case functionCallBatch = "function_call_batch"
    case functionCallOutput = "function_call_output"
    case toolSearchOutput = "tool_search_output"
    case reasoning
}

public enum ModelHistoryMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

/// Distinguishes durable user-role items that look identical on the provider
/// wire but have different compaction lifecycles.
///
/// Legacy `model_history_item` records omit this field. A projector may treat a
/// missing classification on a user message as `realUser`; keeping the wire
/// field optional preserves exact decoding of those records.
public enum ModelHistoryMessageClassification: String, Codable, Equatable, Sendable {
    case realUser = "real_user"
    case contextual
    case compactionSummary = "compaction_summary"
}

public enum ModelHistoryCallKind: String, Codable, Equatable, Sendable {
    case function
    case toolSearch = "tool_search"
}

public struct ModelHistoryFunctionCall: Codable, Equatable, Sendable {
    public var callID: String
    public var name: String
    /// The JSON argument string that may be sent back to the provider.
    /// Sensitive calls use a fixed valid placeholder instead of raw input.
    public var arguments: String
    public var argumentsRedacted: Bool
    /// Provider-native call kind. Missing values in v1 history decode as the
    /// historical function-call shape.
    public var kind: ModelHistoryCallKind
    /// Responses namespace for a deferred function. The execution registry
    /// continues to use `name` as its exact flat routing key.
    public var namespace: String?
    public var status: String?
    public var execution: String?

    public init(
        callID: String,
        name: String,
        arguments: String,
        argumentsRedacted: Bool = false,
        kind: ModelHistoryCallKind = .function,
        namespace: String? = nil,
        status: String? = nil,
        execution: String? = nil
    ) {
        self.callID = callID
        self.name = name
        self.arguments = arguments
        self.argumentsRedacted = argumentsRedacted
        self.kind = kind
        self.namespace = namespace
        self.status = status
        self.execution = execution
    }

    private enum CodingKeys: String, CodingKey {
        case callID
        case name
        case arguments
        case argumentsRedacted
        case kind
        case namespace
        case status
        case execution
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        callID = try container.decode(String.self, forKey: .callID)
        name = try container.decode(String.self, forKey: .name)
        arguments = try container.decode(String.self, forKey: .arguments)
        argumentsRedacted = try container.decodeIfPresent(
            Bool.self,
            forKey: .argumentsRedacted) ?? false
        kind = try container.decodeIfPresent(
            ModelHistoryCallKind.self,
            forKey: .kind) ?? .function
        namespace = try container.decodeIfPresent(
            String.self,
            forKey: .namespace)
        status = try container.decodeIfPresent(
            String.self,
            forKey: .status)
        execution = try container.decodeIfPresent(
            String.self,
            forKey: .execution)
    }
}

/// Provider-neutral payload for a Responses `tool_search_output` input item.
///
/// The returned deferred tool definitions belong to history, not the next
/// request's top-level `tools` array. This is the contract used by Codex to
/// make searched tools callable without widening subsequent tool exposure.
public struct ModelToolSearchOutput: Codable, Equatable, Sendable {
    public var status: String
    public var execution: String
    public var tools: [JSONValue]

    public init(
        status: String = "completed",
        execution: String = "client",
        tools: [JSONValue]
    ) {
        self.status = status
        self.execution = execution
        self.tools = tools
    }
}

public enum ModelHistoryImageReferenceValidationError:
    Error, Equatable, Sendable
{
    case emptyArtifactID
    case unsupportedMIMEType(String)
    case invalidByteCount(Int)
    case nonCanonicalSHA256
}

/// Durable, provider-neutral identity for one image admitted into model
/// history. Provider wire data (for example a base64 data URL) is deliberately
/// materialized only for an exact request and never stored here.
public struct ModelHistoryImageReference: Codable, Equatable, Sendable {
    public static let supportedMIMETypes: Set<String> = [
        "image/jpeg",
        "image/png",
    ]

    public var artifactID: ArtifactID
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String

    public init(
        artifactID: ArtifactID,
        mimeType: String,
        byteCount: Int,
        sha256: String
    ) {
        self.artifactID = artifactID
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }

    public func validate() throws {
        guard !artifactID.rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            throw ModelHistoryImageReferenceValidationError.emptyArtifactID
        }
        guard Self.supportedMIMETypes.contains(mimeType) else {
            throw ModelHistoryImageReferenceValidationError
                .unsupportedMIMEType(mimeType)
        }
        guard byteCount > 0 else {
            throw ModelHistoryImageReferenceValidationError
                .invalidByteCount(byteCount)
        }
        let digestBytes = Array(sha256.utf8)
        guard digestBytes.count == 64,
              digestBytes.allSatisfy({ byte in
                  (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                      || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
              }) else {
            throw ModelHistoryImageReferenceValidationError.nonCanonicalSHA256
        }
    }
}

public enum ModelHistoryItemPayloadValidationError:
    Error, Equatable, Sendable
{
    case unsupportedSchemaVersion(Int)
    case invalidShape(String)
    case invalidImageReference(
        index: Int,
        reason: ModelHistoryImageReferenceValidationError)
}

public struct ModelHistoryItemPayload: Codable, Equatable, Sendable {
    /// Text-only legacy/default schema. This remains the default for writers
    /// that do not carry verified media.
    public static let currentSchemaVersion = 1
    public static let mediaSchemaVersion = 2

    public var schemaVersion: Int
    public var itemID: String
    public var turnID: TurnID
    public var agent: AgentID
    public var taskID: TaskID?
    public var submissionID: SubmissionID?
    public var taskAttempt: Int?
    public var kind: ModelHistoryItemKind

    public var role: ModelHistoryMessageRole?
    public var messageClassification: ModelHistoryMessageClassification?
    public var content: String?
    public var attachmentIDs: [ArtifactID]?
    public var imageReferences: [ModelHistoryImageReference]?
    public var functionCalls: [ModelHistoryFunctionCall]?
    public var callID: String?
    public var output: String?
    public var toolSearchOutput: ModelToolSearchOutput?
    public var reasoningSummary: [String]?
    public var reasoningContent: String?
    public var encryptedReasoningContent: String?

    public init(
        schemaVersion: Int = ModelHistoryItemPayload.currentSchemaVersion,
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID? = nil,
        submissionID: SubmissionID? = nil,
        taskAttempt: Int? = nil,
        kind: ModelHistoryItemKind,
        role: ModelHistoryMessageRole? = nil,
        messageClassification: ModelHistoryMessageClassification? = nil,
        content: String? = nil,
        attachmentIDs: [ArtifactID]? = nil,
        imageReferences: [ModelHistoryImageReference]? = nil,
        functionCalls: [ModelHistoryFunctionCall]? = nil,
        callID: String? = nil,
        output: String? = nil,
        toolSearchOutput: ModelToolSearchOutput? = nil,
        reasoningSummary: [String]? = nil,
        reasoningContent: String? = nil,
        encryptedReasoningContent: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.itemID = itemID
        self.turnID = turnID
        self.agent = agent
        self.taskID = taskID
        self.submissionID = submissionID
        self.taskAttempt = taskAttempt
        self.kind = kind
        self.role = role
        self.messageClassification = messageClassification
        self.content = content
        self.attachmentIDs = attachmentIDs
        self.imageReferences = imageReferences
        self.functionCalls = functionCalls
        self.callID = callID
        self.output = output
        self.toolSearchOutput = toolSearchOutput
        self.reasoningSummary = reasoningSummary
        self.reasoningContent = reasoningContent
        self.encryptedReasoningContent = encryptedReasoningContent
    }

    public static func message(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        role: ModelHistoryMessageRole,
        content: String,
        attachmentIDs: [ArtifactID]? = nil,
        imageReferences: [ModelHistoryImageReference]? = nil,
        messageClassification: ModelHistoryMessageClassification? = nil
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            schemaVersion: imageReferences == nil
                ? Self.currentSchemaVersion
                : Self.mediaSchemaVersion,
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .message,
            role: role,
            messageClassification: imageReferences == nil
                ? messageClassification
                : (messageClassification ?? .realUser),
            content: content,
            attachmentIDs: attachmentIDs,
            imageReferences: imageReferences)
    }

    public static func functionCallBatch(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        content: String?,
        calls: [ModelHistoryFunctionCall]
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .functionCallBatch,
            content: content,
            functionCalls: calls)
    }

    public static func functionCallOutput(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        callID: String,
        output: String,
        imageReferences: [ModelHistoryImageReference]? = nil
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            schemaVersion: imageReferences == nil
                ? Self.currentSchemaVersion
                : Self.mediaSchemaVersion,
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .functionCallOutput,
            imageReferences: imageReferences,
            callID: callID,
            output: output)
    }

    public static func toolSearchOutput(
        itemID: String,
        turnID: TurnID,
        agent: AgentID,
        taskID: TaskID?,
        submissionID: SubmissionID?,
        taskAttempt: Int?,
        callID: String,
        status: String = "completed",
        execution: String = "client",
        tools: [JSONValue]
    ) -> ModelHistoryItemPayload {
        ModelHistoryItemPayload(
            itemID: itemID,
            turnID: turnID,
            agent: agent,
            taskID: taskID,
            submissionID: submissionID,
            taskAttempt: taskAttempt,
            kind: .toolSearchOutput,
            callID: callID,
            toolSearchOutput: ModelToolSearchOutput(
                status: status,
                execution: execution,
                tools: tools))
    }

    public func validate() throws {
        func invalid(_ reason: String) throws -> Never {
            throw ModelHistoryItemPayloadValidationError.invalidShape(reason)
        }
        guard schemaVersion == Self.currentSchemaVersion
                || schemaVersion == Self.mediaSchemaVersion else {
            throw ModelHistoryItemPayloadValidationError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard !itemID.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            try invalid("itemID is empty")
        }
        if let taskAttempt, taskAttempt < 1 {
            try invalid("taskAttempt must be one-based")
        }

        if schemaVersion == Self.currentSchemaVersion {
            guard imageReferences == nil else {
                try invalid("schema v1 cannot carry image references")
            }
        } else {
            guard let imageReferences, !imageReferences.isEmpty else {
                try invalid("schema v2 requires non-empty image references")
            }
            for (index, reference) in imageReferences.enumerated() {
                do {
                    try reference.validate()
                } catch let error as ModelHistoryImageReferenceValidationError {
                    throw ModelHistoryItemPayloadValidationError
                        .invalidImageReference(index: index, reason: error)
                }
            }
        }

        let hasReasoningFields = reasoningSummary != nil
            || reasoningContent != nil
            || encryptedReasoningContent != nil
        switch kind {
        case .message:
            guard let role,
                  content != nil,
                  functionCalls == nil,
                  callID == nil,
                  output == nil,
                  toolSearchOutput == nil,
                  !hasReasoningFields else {
                try invalid("message fields are inconsistent")
            }
            switch role {
            case .assistant:
                guard messageClassification == nil,
                      attachmentIDs == nil,
                      imageReferences == nil else {
                    try invalid("assistant message fields are inconsistent")
                }
            case .user:
                guard messageClassification != .compactionSummary else {
                    try invalid("direct history cannot contain a compaction summary")
                }
                if messageClassification == .contextual {
                    guard attachmentIDs == nil,
                          imageReferences == nil else {
                        try invalid("contextual messages cannot carry media")
                    }
                }
                if schemaVersion == Self.mediaSchemaVersion {
                    guard messageClassification == .realUser,
                          let attachmentIDs,
                          attachmentIDs == imageReferences?.map(\.artifactID) else {
                        try invalid("v2 user media does not match attachment IDs")
                    }
                }
            }

        case .functionCallBatch:
            guard role == nil,
                  messageClassification == nil,
                  attachmentIDs == nil,
                  imageReferences == nil,
                  let functionCalls,
                  !functionCalls.isEmpty,
                  callID == nil,
                  output == nil,
                  toolSearchOutput == nil,
                  !hasReasoningFields else {
                try invalid("function-call batch fields are inconsistent")
            }
            for call in functionCalls {
                guard !call.callID.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                      !call.name.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty,
                      Self.isJSONObject(call.arguments) else {
                    try invalid("function call has an invalid ID, name, or JSON argument object")
                }
            }

        case .functionCallOutput:
            guard role == nil,
                  messageClassification == nil,
                  attachmentIDs == nil,
                  functionCalls == nil,
                  let callID,
                  !callID.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  output != nil,
                  toolSearchOutput == nil,
                  !hasReasoningFields else {
                try invalid("function-call output fields are inconsistent")
            }

        case .toolSearchOutput:
            guard role == nil,
                  messageClassification == nil,
                  attachmentIDs == nil,
                  imageReferences == nil,
                  functionCalls == nil,
                  output == nil,
                  let callID,
                  !callID.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  let toolSearchOutput,
                  !toolSearchOutput.status.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  !toolSearchOutput.execution.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  !hasReasoningFields else {
                try invalid("tool-search output fields are inconsistent")
            }

        case .reasoning:
            guard role == nil,
                  messageClassification == nil,
                  attachmentIDs == nil,
                  imageReferences == nil,
                  functionCalls == nil,
                  callID == nil,
                  output == nil,
                  toolSearchOutput == nil,
                  hasReasoningFields else {
                try invalid("reasoning fields are inconsistent")
            }
        }
    }

    private static func isJSONObject(_ string: String) -> Bool {
        guard let data = string.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                  with: data,
                  options: [.fragmentsAllowed]) else {
            return false
        }
        return value is [String: Any]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case itemID
        case turnID
        case agent
        case taskID
        case submissionID
        case taskAttempt
        case kind
        case role
        case messageClassification
        case content
        case attachmentIDs
        case imageReferences
        case functionCalls
        case callID
        case output
        case toolSearchOutput
        case reasoningSummary
        case reasoningContent
        case encryptedReasoningContent
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        itemID = try container.decode(String.self, forKey: .itemID)
        turnID = try container.decode(TurnID.self, forKey: .turnID)
        agent = try container.decode(AgentID.self, forKey: .agent)
        taskID = try container.decodeIfPresent(TaskID.self, forKey: .taskID)
        submissionID = try container.decodeIfPresent(
            SubmissionID.self,
            forKey: .submissionID)
        taskAttempt = try container.decodeIfPresent(Int.self, forKey: .taskAttempt)
        kind = try container.decode(ModelHistoryItemKind.self, forKey: .kind)
        role = try container.decodeIfPresent(ModelHistoryMessageRole.self, forKey: .role)
        messageClassification = try container.decodeIfPresent(
            ModelHistoryMessageClassification.self,
            forKey: .messageClassification)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        attachmentIDs = try container.decodeIfPresent(
            [ArtifactID].self,
            forKey: .attachmentIDs)
        imageReferences = try container.decodeIfPresent(
            [ModelHistoryImageReference].self,
            forKey: .imageReferences)
        functionCalls = try container.decodeIfPresent(
            [ModelHistoryFunctionCall].self,
            forKey: .functionCalls)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        output = try container.decodeIfPresent(String.self, forKey: .output)
        toolSearchOutput = try container.decodeIfPresent(
            ModelToolSearchOutput.self,
            forKey: .toolSearchOutput)
        reasoningSummary = try container.decodeIfPresent(
            [String].self,
            forKey: .reasoningSummary)
        reasoningContent = try container.decodeIfPresent(
            String.self,
            forKey: .reasoningContent)
        encryptedReasoningContent = try container.decodeIfPresent(
            String.self,
            forKey: .encryptedReasoningContent)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "model history item payload is invalid")
        }
    }

    public func encode(to encoder: Encoder) throws {
        do {
            try validate()
        } catch {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "model history item payload is invalid"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(turnID, forKey: .turnID)
        try container.encode(agent, forKey: .agent)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encodeIfPresent(submissionID, forKey: .submissionID)
        try container.encodeIfPresent(taskAttempt, forKey: .taskAttempt)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(
            messageClassification,
            forKey: .messageClassification)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(attachmentIDs, forKey: .attachmentIDs)
        try container.encodeIfPresent(imageReferences, forKey: .imageReferences)
        try container.encodeIfPresent(functionCalls, forKey: .functionCalls)
        try container.encodeIfPresent(callID, forKey: .callID)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(toolSearchOutput, forKey: .toolSearchOutput)
        try container.encodeIfPresent(reasoningSummary, forKey: .reasoningSummary)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(
            encryptedReasoningContent,
            forKey: .encryptedReasoningContent)
    }
}

/// One provider-history item inside a full replacement-history checkpoint.
///
/// Unlike `ModelHistoryItemPayload`, this value deliberately has no durable
/// turn, task, agent, or attempt correlation. Compaction creates a synthetic
/// provider history whose user summary cannot truthfully inherit one earlier
/// invocation's task identity. The containing checkpoint scopes the array to
/// one agent.
public struct ModelHistoryReplacementItem: Codable, Equatable, Sendable {
    /// Stable item identity assigned before the checkpoint is persisted.
    public var itemID: String
    /// Optional provenance for retained real-user messages. Synthetic context
    /// and compaction summaries normally leave this nil.
    public var sourceSubmissionID: SubmissionID?
    public var kind: ModelHistoryItemKind

    public var role: ModelHistoryMessageRole?
    public var messageClassification: ModelHistoryMessageClassification?
    public var content: String?
    /// True only when compaction retained a UTF-8-safe newest suffix of one
    /// real user message. Nil/false means the content must exactly match its
    /// accepted durable submission.
    public var contentTruncated: Bool?
    public var attachmentIDs: [ArtifactID]?
    public var imageReferences: [ModelHistoryImageReference]?
    public var functionCalls: [ModelHistoryFunctionCall]?
    public var callID: String?
    public var output: String?
    public var toolSearchOutput: ModelToolSearchOutput?
    public var reasoningSummary: [String]?
    public var reasoningContent: String?
    public var encryptedReasoningContent: String?

    public init(
        itemID: String,
        sourceSubmissionID: SubmissionID? = nil,
        kind: ModelHistoryItemKind,
        role: ModelHistoryMessageRole? = nil,
        messageClassification: ModelHistoryMessageClassification? = nil,
        content: String? = nil,
        contentTruncated: Bool? = nil,
        attachmentIDs: [ArtifactID]? = nil,
        imageReferences: [ModelHistoryImageReference]? = nil,
        functionCalls: [ModelHistoryFunctionCall]? = nil,
        callID: String? = nil,
        output: String? = nil,
        toolSearchOutput: ModelToolSearchOutput? = nil,
        reasoningSummary: [String]? = nil,
        reasoningContent: String? = nil,
        encryptedReasoningContent: String? = nil
    ) {
        self.itemID = itemID
        self.sourceSubmissionID = sourceSubmissionID
        self.kind = kind
        self.role = role
        self.messageClassification = messageClassification
        self.content = content
        self.contentTruncated = contentTruncated
        self.attachmentIDs = attachmentIDs
        self.imageReferences = imageReferences
        self.functionCalls = functionCalls
        self.callID = callID
        self.output = output
        self.toolSearchOutput = toolSearchOutput
        self.reasoningSummary = reasoningSummary
        self.reasoningContent = reasoningContent
        self.encryptedReasoningContent = encryptedReasoningContent
    }
}

public enum ModelHistoryCompactedPayloadValidationError:
    Error, Equatable, Sendable
{
    case unsupportedSchemaVersion(Int)
    case emptySummary
    case emptyReplacementHistory
    case unsupportedReplacementItemShape(index: Int)
    case invalidReplacementItemClassification(index: Int)
    case invalidRealUserProvenance(index: Int)
    case finalSummaryMismatch
    case nonCanonicalWindowID(field: String)
    case nonUUIDv7WindowID(field: String)
    case invalidInitialWindow
    case emptyReplacementItemID(index: Int)
    case duplicateReplacementItemID(itemID: String)
    case invalidImageReference(
        itemIndex: Int,
        referenceIndex: Int,
        reason: ModelHistoryImageReferenceValidationError)
}

/// Durable full replacement-history checkpoint, mirroring Codex's compacted
/// rollout item while adding the agent identity required by Intatis's shared
/// multi-agent EventLog.
public struct ModelHistoryCompactedPayload: Codable, Equatable, Sendable {
    /// Text-only legacy/default checkpoint schema.
    public static let currentSchemaVersion = 1
    public static let mediaSchemaVersion = 2

    public var schemaVersion: Int
    public var agent: AgentID
    public var message: String
    public var replacementHistory: [ModelHistoryReplacementItem]
    public var windowNumber: UInt64
    public var firstWindowID: String
    public var previousWindowID: String
    public var windowID: String

    public init(
        schemaVersion: Int = ModelHistoryCompactedPayload.currentSchemaVersion,
        agent: AgentID,
        message: String,
        replacementHistory: [ModelHistoryReplacementItem],
        windowNumber: UInt64,
        firstWindowID: String,
        previousWindowID: String,
        windowID: String
    ) {
        self.schemaVersion = schemaVersion
        self.agent = agent
        self.message = message
        self.replacementHistory = replacementHistory
        self.windowNumber = windowNumber
        self.firstWindowID = firstWindowID
        self.previousWindowID = previousWindowID
        self.windowID = windowID
    }

    /// Validates the complete v1/v2 checkpoint shape before it can become
    /// canonical history.
    ///
    /// A v1 replacement contains only user-role messages: retained real-user
    /// text, optional turn-scoped context, and one exact final compaction
    /// summary. Future replacement item shapes require a new schema version
    /// instead of being silently accepted by an older projector.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion
                || schemaVersion == Self.mediaSchemaVersion else {
            throw ModelHistoryCompactedPayloadValidationError
                .unsupportedSchemaVersion(schemaVersion)
        }
        guard !message.trimmingCharacters(
            in: .whitespacesAndNewlines).isEmpty else {
            throw ModelHistoryCompactedPayloadValidationError.emptySummary
        }
        guard !replacementHistory.isEmpty else {
            throw ModelHistoryCompactedPayloadValidationError
                .emptyReplacementHistory
        }

        for (field, value) in [
            ("firstWindowID", firstWindowID),
            ("previousWindowID", previousWindowID),
            ("windowID", windowID),
        ] {
            guard let uuid = UUID(uuidString: value),
                  uuid.uuidString.lowercased() == value else {
                throw ModelHistoryCompactedPayloadValidationError
                    .nonCanonicalWindowID(field: field)
            }
            var raw = uuid.uuid
            let isUUIDv7 = withUnsafeBytes(of: &raw) {
                ($0[6] >> 4) == 0x7
                    && ($0[8] & 0b1100_0000) == 0b1000_0000
            }
            guard isUUIDv7 else {
                throw ModelHistoryCompactedPayloadValidationError
                    .nonUUIDv7WindowID(field: field)
            }
        }
        guard windowNumber > 0 else {
            throw ModelHistoryCompactedPayloadValidationError
                .invalidInitialWindow
        }
        if windowNumber == 1 {
            guard previousWindowID == firstWindowID,
                  windowID != firstWindowID else {
                throw ModelHistoryCompactedPayloadValidationError
                    .invalidInitialWindow
            }
        }

        var seenItemIDs: Set<String> = []
        for (index, item) in replacementHistory.enumerated() {
            guard !item.itemID.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty else {
                throw ModelHistoryCompactedPayloadValidationError
                    .emptyReplacementItemID(index: index)
            }
            guard seenItemIDs.insert(item.itemID).inserted else {
                throw ModelHistoryCompactedPayloadValidationError
                    .duplicateReplacementItemID(itemID: item.itemID)
            }
            guard item.kind == .message,
                  item.role == .user,
                  item.content != nil,
                  item.functionCalls == nil,
                  item.callID == nil,
                  item.output == nil,
                  item.toolSearchOutput == nil,
                  item.reasoningSummary == nil,
                  item.reasoningContent == nil,
                  item.encryptedReasoningContent == nil else {
                throw ModelHistoryCompactedPayloadValidationError
                    .unsupportedReplacementItemShape(index: index)
            }

            let isFinal = index == replacementHistory.count - 1
            if isFinal {
                guard item.messageClassification == .compactionSummary,
                      item.content == message,
                      item.sourceSubmissionID == nil,
                      item.contentTruncated != true,
                      item.attachmentIDs == nil,
                      item.imageReferences == nil else {
                    throw ModelHistoryCompactedPayloadValidationError
                        .finalSummaryMismatch
                }
            } else {
                switch item.messageClassification {
                case .realUser:
                    guard let sourceSubmissionID =
                            item.sourceSubmissionID,
                          !sourceSubmissionID.rawValue
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines).isEmpty else {
                        throw ModelHistoryCompactedPayloadValidationError
                            .invalidRealUserProvenance(index: index)
                    }
                    if schemaVersion == Self.currentSchemaVersion {
                        // Legacy v1 checkpoints could retain attachment IDs.
                        // They remain decodable, but the projector no longer
                        // promotes them back into post-compaction media.
                        guard item.imageReferences == nil else {
                            throw ModelHistoryCompactedPayloadValidationError
                                .unsupportedReplacementItemShape(index: index)
                        }
                    } else {
                        // New compaction deliberately turns all earlier images
                        // into summary text. v2 marks coverage of media-aware
                        // direct history without carrying old media forward.
                        guard item.attachmentIDs == nil,
                              item.imageReferences == nil else {
                            throw ModelHistoryCompactedPayloadValidationError
                                .unsupportedReplacementItemShape(index: index)
                        }
                    }
                case .contextual:
                    guard item.sourceSubmissionID == nil,
                          item.contentTruncated != true,
                          item.attachmentIDs == nil,
                          item.imageReferences == nil else {
                        throw ModelHistoryCompactedPayloadValidationError
                            .invalidReplacementItemClassification(
                                index: index)
                    }
                case .compactionSummary, nil:
                    throw ModelHistoryCompactedPayloadValidationError
                        .invalidReplacementItemClassification(index: index)
                }
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case agent
        case message
        case replacementHistory
        case windowNumber
        case firstWindowID
        case previousWindowID
        case windowID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        agent = try container.decode(AgentID.self, forKey: .agent)
        message = try container.decode(String.self, forKey: .message)
        replacementHistory = try container.decode(
            [ModelHistoryReplacementItem].self,
            forKey: .replacementHistory)
        windowNumber = try container.decode(UInt64.self, forKey: .windowNumber)
        firstWindowID = try container.decode(String.self, forKey: .firstWindowID)
        previousWindowID = try container.decode(
            String.self,
            forKey: .previousWindowID)
        windowID = try container.decode(String.self, forKey: .windowID)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .windowID,
                in: container,
                debugDescription:
                    "model history compaction payload is invalid")
        }
    }

    public func encode(to encoder: Encoder) throws {
        do {
            try validate()
        } catch {
            throw EncodingError.invalidValue(
                self,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription:
                        "model history compaction payload is invalid"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(agent, forKey: .agent)
        try container.encode(message, forKey: .message)
        try container.encode(replacementHistory, forKey: .replacementHistory)
        try container.encode(windowNumber, forKey: .windowNumber)
        try container.encode(firstWindowID, forKey: .firstWindowID)
        try container.encode(previousWindowID, forKey: .previousWindowID)
        try container.encode(windowID, forKey: .windowID)
    }
}
