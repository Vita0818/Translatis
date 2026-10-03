import Foundation
import IntatisProtocol

/// A localized-UI-neutral activity derived from one or more exact Codex App
/// Server presentation events. The original events remain independently
/// durable in EventLog; this value only lets the default Code/Cowork surface
/// present their user-facing meaning without exposing wire method names.
public struct CodexActivityPresentation: Equatable, Sendable {
    public enum Category: String, Equatable, Sendable {
        case turn
        case command
        case fileChanges
        case tool
        case mcpTool
        case webSearch
        case image
        case collaboration
        case subagent
        case plan
        case reasoning
        case retry
        case approvalReview
        case compaction
        case review
        case waiting
        case runtime
    }

    public enum State: String, Equatable, Sendable {
        case running
        case completed
        case failed
        case cancelled

        public var isTerminal: Bool {
            self != .running
        }
    }

    public let id: String
    public var category: Category
    public var state: State?
    public var text: String
    public var rawMethods: [String]
    public var itemType: String?
    public var rawStatus: String?
    public var turnID: String?
    public var retryAttempt: Int?
    public var retryLimit: Int?
    public var isComplete: Bool
    public var hidesWhenTerminal: Bool

    public init(
        id: String,
        category: Category,
        state: State?,
        text: String = "",
        rawMethods: [String] = [],
        itemType: String? = nil,
        rawStatus: String? = nil,
        turnID: String? = nil,
        retryAttempt: Int? = nil,
        retryLimit: Int? = nil,
        isComplete: Bool,
        hidesWhenTerminal: Bool = false
    ) {
        self.id = id
        self.category = category
        self.state = state
        self.text = text
        self.rawMethods = rawMethods
        self.itemType = itemType
        self.rawStatus = rawStatus
        self.turnID = turnID
        self.retryAttempt = retryAttempt
        self.retryLimit = retryLimit
        self.isComplete = isComplete
        self.hidesWhenTerminal = hidesWhenTerminal
    }

    public var isFailure: Bool {
        state == .failed
    }
}

/// Converts the complete raw App Server event projection into the semantic
/// default transcript. This is deliberately downstream of EventLog and
/// CodeProjection: the backend execution-trace switch can still return every
/// original method/scalar row byte-for-byte as before.
public enum CodexActivityPresentationReducer {
    public static func displayedItems(_ items: [CodeItem]) -> [CodeItem] {
        var result: [CodeItem] = []
        result.reserveCapacity(items.count)

        var activityIndexByID: [String: Int] = [:]
        var sourceEventIDsByActivityID: [String: Set<String>] = [:]
        var terminalTurnIDs: Set<String> = []

        for item in items {
            guard item.kind == .runtimeEvent else {
                result.append(item)
                continue
            }

            guard let payload = item.codexAppServerEvent else {
                let activity = CodexActivityPresentation(
                    id: "codex-activity:legacy:\(item.id)",
                    category: .runtime,
                    state: nil,
                    text: "",
                    rawMethods: item.title.isEmpty ? [] : [item.title],
                    isComplete: item.complete)
                result.append(semanticItem(from: item, activity: activity))
                continue
            }
            if payload.method == "turn/completed",
               let turnID = payload.turnID {
                terminalTurnIDs.insert(turnID)
            }

            switch classify(item: item, payload: payload) {
            case .consumedElsewhere:
                continue
            case .activity(let incoming):
                if let index = activityIndexByID[incoming.id],
                   result.indices.contains(index),
                   var existing = result[index].codexActivity {
                    let isDuplicateRepresentation =
                        sourceEventIDsByActivityID[incoming.id]?
                            .contains(payload.eventID) == true
                    merge(
                        incoming,
                        into: &existing,
                        duplicateRepresentation: isDuplicateRepresentation)
                    sourceEventIDsByActivityID[incoming.id, default: []]
                        .insert(payload.eventID)
                    result[index].codexActivity = existing
                    result[index].title = existing.category.rawValue
                    result[index].body = existing.text
                    result[index].complete = existing.isComplete
                    result[index].isFailure = existing.isFailure
                } else {
                    activityIndexByID[incoming.id] = result.count
                    sourceEventIDsByActivityID[incoming.id] = [payload.eventID]
                    result.append(semanticItem(from: item, activity: incoming))
                }
            }
        }

        return result.filter { item in
            guard let activity = item.codexActivity else { return true }
            if activity.category == .retry,
               let turnID = activity.turnID,
               terminalTurnIDs.contains(turnID) {
                return false
            }
            return !(activity.hidesWhenTerminal
                && activity.state?.isTerminal == true)
        }
    }

    private enum Classification {
        case consumedElsewhere
        case activity(CodexActivityPresentation)
    }

    private static func classify(
        item: CodeItem,
        payload: CodexAppServerEventPayload
    ) -> Classification {
        switch payload.method {
        case "turn/started":
            guard let turnID = payload.turnID else {
                return .activity(unknownActivity(item: item, payload: payload))
            }
            return .activity(CodexActivityPresentation(
                id: "codex-activity:turn:\(turnID)",
                category: .turn,
                state: .running,
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: turnID,
                isComplete: false,
                hidesWhenTerminal: true))

        case "turn/completed":
            guard let turnID = payload.turnID else {
                return .activity(unknownActivity(item: item, payload: payload))
            }
            return .activity(CodexActivityPresentation(
                id: "codex-activity:turn:\(turnID)",
                category: .turn,
                state: state(from: payload.status) ?? .completed,
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: turnID,
                isComplete: true,
                hidesWhenTerminal: true))

        case "error":
            if payload.willRetry == true,
               let turnID = payload.turnID {
                let progress = retryProgress(from: payload.message)
                return .activity(CodexActivityPresentation(
                    id: "codex-activity:retry:\(turnID)",
                    category: .retry,
                    state: .running,
                    text: joinedText(payload.details),
                    rawMethods: [payload.method],
                    rawStatus: payload.status,
                    turnID: turnID,
                    retryAttempt: progress?.attempt,
                    retryLimit: progress?.limit,
                    isComplete: false))
            }
            if payload.willRetry == false {
                return .activity(CodexActivityPresentation(
                    id: "codex-activity:error:\(payload.turnID ?? payload.eventID)",
                    category: .runtime,
                    state: .failed,
                    text: joinedText(payload.message, payload.details),
                    rawMethods: [payload.method],
                    rawStatus: payload.status,
                    turnID: payload.turnID,
                    isComplete: true))
            }
            return .consumedElsewhere

        case "warning", "guardianWarning",
             "deprecationNotice", "configWarning":
            return .activity(CodexActivityPresentation(
                id: "codex-activity:notice:\(payload.eventID)",
                category: .runtime,
                state: nil,
                text: joinedText(payload.message, payload.details),
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: true))

        case "item/mcpToolCall/progress":
            return .activity(CodexActivityPresentation(
                id: activityID(payload),
                category: .mcpTool,
                state: .running,
                text: joinedText(payload.message),
                rawMethods: [payload.method],
                itemType: payload.itemType,
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: false))

        case "mcpServer/startupStatus/updated",
             "mcpServer/oauthLogin/completed":
            let activityState = state(from: payload.status)
            return .activity(CodexActivityPresentation(
                id: "codex-activity:mcp-status:\(payload.eventID)",
                category: .mcpTool,
                state: activityState,
                text: joinedText(payload.message, payload.details),
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: activityState?.isTerminal ?? true))

        case "item/autoApprovalReview/started",
             "item/autoApprovalReview/completed":
            let completed = payload.method.hasSuffix("/completed")
            return .activity(CodexActivityPresentation(
                id: activityID(payload),
                category: .approvalReview,
                state: completed ? .completed : .running,
                rawMethods: [payload.method],
                itemType: payload.itemType,
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: completed))

        case "hook/started", "hook/completed":
            let completed = payload.method == "hook/completed"
            return .activity(CodexActivityPresentation(
                id: activityID(payload),
                category: .tool,
                state: completed
                    ? state(from: payload.status) ?? .completed
                    : .running,
                text: joinedText(payload.message),
                rawMethods: [payload.method],
                itemType: payload.itemType,
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: completed))

        case "model/rerouted":
            return .activity(CodexActivityPresentation(
                id: "codex-activity:model-reroute:\(payload.turnID ?? payload.eventID)",
                category: .runtime,
                state: .failed,
                text: joinedText(
                    [payload.fromModel, payload.toModel]
                        .compactMap { $0 }
                        .joined(separator: " → "),
                    payload.reason),
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: true))

        case "model/safetyBuffering/updated":
            let activityState = state(from: payload.status)
            return .activity(CodexActivityPresentation(
                id: "codex-activity:safety-buffer:\(payload.turnID ?? payload.eventID)",
                category: .runtime,
                state: activityState,
                text: joinedText(payload.message),
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: activityState?.isTerminal ?? true))

        case "thread/compacted":
            return .activity(CodexActivityPresentation(
                id: "codex-activity:compaction:\(payload.turnID ?? payload.eventID)",
                category: .compaction,
                state: .completed,
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: true))

        case "turn/plan/updated":
            let activityState = state(from: payload.status) ?? .running
            return .activity(CodexActivityPresentation(
                id: "codex-activity:turn-plan:\(payload.turnID ?? payload.eventID)",
                category: .plan,
                state: activityState,
                text: joinedText(payload.message),
                rawMethods: [payload.method],
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: activityState.isTerminal))

        case "item/reasoning/summaryTextDelta",
             "item/reasoning/textDelta":
            return .activity(textActivity(
                item: item,
                payload: payload,
                category: .reasoning))

        case "item/reasoning/summaryPartAdded":
            return .activity(CodexActivityPresentation(
                id: activityID(payload),
                category: .reasoning,
                state: .running,
                rawMethods: [payload.method],
                itemType: payload.itemType,
                rawStatus: payload.status,
                turnID: payload.turnID,
                isComplete: false))

        case "item/plan/delta":
            return .activity(textActivity(
                item: item,
                payload: payload,
                category: .plan))

        case "item/started", "item/completed":
            guard let itemType = payload.itemType else {
                return .activity(unknownActivity(item: item, payload: payload))
            }
            if itemType == "agentMessage" || itemType == "userMessage" {
                // The corresponding user-visible message is the semantic
                // presentation of this lifecycle event.
                return .consumedElsewhere
            }
            let isCompleted = payload.method == "item/completed"
            let activityState = isCompleted
                ? state(from: payload.status) ?? .completed
                : .running
            return .activity(CodexActivityPresentation(
                id: activityID(payload),
                category: category(for: itemType),
                state: activityState,
                rawMethods: [payload.method],
                itemType: itemType,
                rawStatus: payload.status,
                isComplete: isCompleted))

        case "thread/tokenUsage/updated",
             "thread/goal/updated",
             "thread/goal/cleared",
             "thread/started",
             "thread/status/changed",
             "thread/archived",
             "thread/unarchived",
             "thread/closed",
             "thread/deleted",
             "serverRequest/resolved",
             "item/agentMessage/delta":
            // These events already update a dedicated product surface or a
            // typed message/error lifecycle. Consuming them must not create a
            // second transcript row.
            return .consumedElsewhere

        case "skills/changed",
             "thread/name/updated",
             "thread/settings/updated",
             "turn/diff/updated",
             "command/exec/outputDelta",
             "process/outputDelta",
             "process/exited",
             "item/commandExecution/outputDelta",
             "item/commandExecution/terminalInteraction",
             "item/fileChange/outputDelta",
             "item/fileChange/patchUpdated",
             "account/updated",
             "account/rateLimits/updated",
             "app/list/updated",
             "remoteControl/status/changed",
             "externalAgentConfig/import/progress",
             "externalAgentConfig/import/completed",
             "fs/changed",
             "model/verification",
             "turn/moderationMetadata",
             "fuzzyFileSearch/sessionUpdated",
             "fuzzyFileSearch/sessionCompleted",
             "thread/realtime/started",
             "thread/realtime/itemAdded",
             "thread/realtime/transcript/delta",
             "thread/realtime/transcript/done",
             "thread/realtime/outputAudio/delta",
             "thread/realtime/sdp",
             "thread/realtime/error",
             "thread/realtime/closed",
             "windows/worldWritableWarning",
             "windowsSandbox/setupCompleted",
             "account/login/completed":
            // These exact pinned notifications belong to settings, search,
            // platform, account, or high-volume output surfaces that Code/
            // Cowork does not expose in its conversation transcript. Their
            // bounded method projection remains available in backend trace.
            return .consumedElsewhere

        default:
            return .activity(unknownActivity(item: item, payload: payload))
        }
    }

    private static func textActivity(
        item: CodeItem,
        payload: CodexAppServerEventPayload,
        category: CodexActivityPresentation.Category
    ) -> CodexActivityPresentation {
        CodexActivityPresentation(
            id: activityID(payload),
            category: category,
            state: .running,
            text: item.body,
            rawMethods: [payload.method],
            itemType: payload.itemType,
            rawStatus: payload.status,
            turnID: payload.turnID,
            isComplete: false)
    }

    private static func unknownActivity(
        item: CodeItem,
        payload: CodexAppServerEventPayload
    ) -> CodexActivityPresentation {
        CodexActivityPresentation(
            id: "codex-activity:event:\(payload.eventID)",
            category: .runtime,
            state: state(from: payload.status),
            text: payload.textDelta == nil ? "" : item.body,
            rawMethods: [payload.method],
            itemType: payload.itemType,
            rawStatus: payload.status,
            turnID: payload.turnID,
            isComplete: payload.textDelta == nil)
    }

    private static func activityID(
        _ payload: CodexAppServerEventPayload
    ) -> String {
        if let itemID = payload.itemID {
            return "codex-activity:item:\(itemID)"
        }
        return "codex-activity:event:\(payload.eventID)"
    }

    private static func category(
        for itemType: String
    ) -> CodexActivityPresentation.Category {
        switch itemType {
        case "commandExecution":
            return .command
        case "fileChange":
            return .fileChanges
        case "dynamicToolCall":
            return .tool
        case "mcpToolCall":
            return .mcpTool
        case "webSearch":
            return .webSearch
        case "imageGeneration", "imageView":
            return .image
        case "collabAgentToolCall", "collabToolCall":
            return .collaboration
        case "subAgentActivity":
            return .subagent
        case "plan":
            return .plan
        case "reasoning":
            return .reasoning
        case "hookPrompt":
            return .tool
        case "contextCompaction":
            return .compaction
        case "enteredReviewMode", "exitedReviewMode":
            return .review
        case "sleep":
            return .waiting
        default:
            return .runtime
        }
    }

    private static func state(
        from rawValue: String?
    ) -> CodexActivityPresentation.State? {
        guard let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: ""),
              !normalized.isEmpty else {
            return nil
        }
        switch normalized {
        case "inprogress", "running", "active", "pendinginit", "queued":
            return .running
        case "completed", "succeeded", "success", "done", "idle":
            return .completed
        case "failed", "declined", "error", "blocked", "incomplete":
            return .failed
        case "cancelled", "canceled", "interrupted", "shutdown", "stopped":
            return .cancelled
        default:
            return nil
        }
    }

    private static func merge(
        _ incoming: CodexActivityPresentation,
        into existing: inout CodexActivityPresentation,
        duplicateRepresentation: Bool
    ) {
        existing.category = incoming.category
        if let state = incoming.state {
            existing.state = state
        }
        existing.isComplete = incoming.isComplete
        existing.hidesWhenTerminal = existing.hidesWhenTerminal
            || incoming.hidesWhenTerminal
        existing.itemType = incoming.itemType ?? existing.itemType
        existing.rawStatus = incoming.rawStatus ?? existing.rawStatus
        existing.turnID = incoming.turnID ?? existing.turnID
        existing.retryAttempt = incoming.retryAttempt ?? existing.retryAttempt
        existing.retryLimit = incoming.retryLimit ?? existing.retryLimit
        for method in incoming.rawMethods
            where !existing.rawMethods.contains(method) {
            existing.rawMethods.append(method)
        }

        guard !incoming.text.isEmpty else { return }
        if incoming.category == .retry {
            existing.text = incoming.text
            return
        }
        if existing.text.isEmpty {
            existing.text = incoming.text
        } else if duplicateRepresentation {
            if incoming.text.utf8.count > existing.text.utf8.count {
                existing.text = incoming.text
            }
        } else if incoming.text != existing.text {
            existing.text += "\n" + incoming.text
        }
    }

    private static func joinedText(_ values: String?...) -> String {
        values.compactMap { value in
            guard let value else { return nil }
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: "\n")
    }

    private static func retryProgress(
        from message: String?
    ) -> (attempt: Int, limit: Int)? {
        guard let message else { return nil }
        let pattern = #"(?i)^reconnecting\.\.\.\s+([0-9]+)/([0-9]+)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: message,
                range: NSRange(message.startIndex..., in: message)),
              match.numberOfRanges == 3,
              let attemptRange = Range(match.range(at: 1), in: message),
              let limitRange = Range(match.range(at: 2), in: message),
              let attempt = Int(message[attemptRange]),
              let limit = Int(message[limitRange]),
              attempt > 0,
              limit > 0,
              attempt <= limit else {
            return nil
        }
        return (attempt, limit)
    }

    private static func semanticItem(
        from source: CodeItem,
        activity: CodexActivityPresentation
    ) -> CodeItem {
        CodeItem(
            id: activity.id,
            kind: .runtimeEvent,
            title: activity.category.rawValue,
            body: activity.text,
            complete: activity.isComplete,
            isFailure: activity.isFailure,
            timestamp: source.timestamp,
            codexActivity: activity)
    }
}
