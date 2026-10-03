import Foundation
import IntatisCore
import IntatisProtocol
import IntatisProviders

public struct AgentModelHistoryCheckpointCursor: Equatable, Sendable {
    public var sequence: Int
    public var payload: ModelHistoryCompactedPayload

    public init(sequence: Int, payload: ModelHistoryCompactedPayload) {
        self.sequence = sequence
        self.payload = payload
    }
}

/// Durable media provenance aligned one-for-one with projected messages.
/// A nil entry means the corresponding message has no durable image carrier.
public enum ProjectedImageBinding: Equatable, Sendable {
    case userVerified([ModelHistoryImageReference])
    case userLegacy([ArtifactID])
    case toolVerified(
        callID: String,
        imageReferences: [ModelHistoryImageReference])
}

public struct AgentModelHistoryProjection: Equatable, Sendable {
    public var messages: [AgentMessage]
    public var imageBindings: [ProjectedImageBinding?]
    public var realUserMessages: [AgentModelHistoryRealUserMessage]
    /// Checkpoint selected as the base of the reconstructed provider history.
    /// This may be older than `latestCheckpoint` after a whole-task retry.
    public var baseCheckpoint: AgentModelHistoryCheckpointCursor?
    /// Newest valid durable window in the lineage. New checkpoints must always
    /// advance from this cursor even when reconstruction used an older base.
    public var latestCheckpoint: AgentModelHistoryCheckpointCursor?
    public var latestAgentHistorySequence: Int?

    public init(
        messages: [AgentMessage],
        imageBindings: [ProjectedImageBinding?]? = nil,
        realUserMessages: [AgentModelHistoryRealUserMessage],
        baseCheckpoint: AgentModelHistoryCheckpointCursor? = nil,
        latestCheckpoint: AgentModelHistoryCheckpointCursor?,
        latestAgentHistorySequence: Int?
    ) {
        self.messages = messages
        let resolvedBindings = imageBindings
            ?? [ProjectedImageBinding?](
                repeating: nil,
                count: messages.count)
        precondition(
            resolvedBindings.count == messages.count,
            "projected image bindings must align with messages")
        self.imageBindings = resolvedBindings
        self.realUserMessages = realUserMessages
        self.baseCheckpoint = baseCheckpoint
        self.latestCheckpoint = latestCheckpoint
        self.latestAgentHistorySequence = latestAgentHistorySequence
    }
}

/// Rebuilds the model-facing Cowork `@main` history from durable
/// `model_history_item` records and the newest eligible full replacement
/// checkpoint.
///
/// This is deliberately separate from `ConversationProjection` and the
/// bounded tool-call audit events. It follows the same split as Codex's
/// rollout ResponseItems versus its UI events: only records written at the
/// provider/tool boundaries are allowed to become provider history.
public struct AgentModelHistoryProjector: Sendable {
    public init() {}

    public func project(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) throws -> [AgentMessage] {
        let projection = try projectState(
            agentID: agentID,
            currentTask: currentTask,
            events: events)
        guard projection.imageBindings.allSatisfy({ $0 == nil }) else {
            throw AgentModelHistoryProjectionError
                .mediaBindingsRequireProjectionState
        }
        return projection.messages
    }

    public func projectState(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        guard currentTask.kind == .root,
              currentTask.issuer == nil,
              currentTask.assignee == agentID,
              let currentSubmissionID = currentTask.submissionID else {
            return AgentModelHistoryProjection(
                messages: [],
                realUserMessages: [],
                baseCheckpoint: nil,
                latestCheckpoint: nil,
                latestAgentHistorySequence: nil)
        }

        let accepted = Self.acceptedSubmissions(from: events)
        guard let current = accepted[currentSubmissionID] else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                currentSubmissionID)
        }
        guard !current.conflicted else {
            throw AgentModelHistoryProjectionError.conflictingAcceptedSubmission(
                currentSubmissionID)
        }

        let checkpoints = try Self.validatedCheckpointChain(
            agentID: agentID,
            accepted: accepted,
            events: events)
        let eligibleCheckpoint = checkpoints.last { checkpoint in
            Self.isEligibleBase(
                checkpoint,
                currentSubmissionID: currentSubmissionID,
                current: current,
                accepted: accepted,
                agentID: agentID,
                events: events)
        }
        if let eligibleCheckpoint {
            var projection = try checkpointedProjection(
                agentID: agentID,
                currentTask: currentTask,
                currentSubmissionID: currentSubmissionID,
                current: current,
                accepted: accepted,
                checkpoint: eligibleCheckpoint,
                events: events)
            projection.latestCheckpoint = checkpoints.last.map {
                AgentModelHistoryCheckpointCursor(
                    sequence: $0.sequence,
                    payload: $0.payload)
            }
            return projection
        }
        var projection = try uncheckpointedProjection(
            agentID: agentID,
            currentTask: currentTask,
            events: events)
        projection.latestCheckpoint = checkpoints.last.map {
            AgentModelHistoryCheckpointCursor(
                sequence: $0.sequence,
                payload: $0.payload)
        }
        return projection
    }

    /// Reconstructs one visible Code conversation from the same durable
    /// model-history/checkpoint protocol used by Cowork `@main`. Code has no
    /// root `TaskContract`, so the accepted `SubmissionID` and stable AgentID
    /// form the exact binding and every direct item must keep `taskID == nil`.
    public func projectConversationState(
        agentID: AgentID,
        currentSubmissionID: SubmissionID,
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        let accepted = Self.acceptedSubmissions(from: events)
        guard let current = accepted[currentSubmissionID] else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                currentSubmissionID)
        }
        guard !current.conflicted else {
            throw AgentModelHistoryProjectionError
                .conflictingAcceptedSubmission(currentSubmissionID)
        }
        guard current.payload.to == nil
                || current.payload.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "accepted-submission:\(currentSubmissionID.rawValue)",
                "accepted Code user target does not match the current agent")
        }

        let checkpoints = try Self.validatedCheckpointChain(
            agentID: agentID,
            accepted: accepted,
            events: events)
        let eligibleCheckpoint = checkpoints.last { checkpoint in
            Self.isEligibleBase(
                checkpoint,
                currentSubmissionID: currentSubmissionID,
                current: current,
                accepted: accepted,
                agentID: agentID,
                events: events)
        }
        var projection: AgentModelHistoryProjection
        if let eligibleCheckpoint {
            projection = try conversationCheckpointedProjection(
                agentID: agentID,
                currentSubmissionID: currentSubmissionID,
                current: current,
                accepted: accepted,
                checkpoint: eligibleCheckpoint,
                events: events)
        } else {
            projection = try conversationUncheckpointedProjection(
                agentID: agentID,
                currentSubmissionID: currentSubmissionID,
                current: current,
                accepted: accepted,
                events: events)
        }
        projection.latestCheckpoint = checkpoints.last.map {
            AgentModelHistoryCheckpointCursor(
                sequence: $0.sequence,
                payload: $0.payload)
        }
        return projection
    }

    /// Rebuilds the just-committed replacement without replaying the complete
    /// event log. Callers must invoke this only after the checkpoint append
    /// succeeds; replay still uses `projectState`/`projectConversationState`
    /// so accepted-submission provenance and checkpoint lineage are checked.
    public func projectReplacementState(
        _ payload: ModelHistoryCompactedPayload
    ) throws -> AgentModelHistoryProjection {
        do {
            try payload.validate()
        } catch {
            throw AgentModelHistoryProjectionError.invalidCheckpoint(
                sequence: 0,
                reason: "replacement payload failed v1/v2 structural validation")
        }

        var messages: [AgentMessage] = []
        var imageBindings: [ProjectedImageBinding?] = []
        var realUsers: [AgentModelHistoryRealUserMessage] = []
        for item in payload.replacementHistory {
            guard let content = item.content else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: 0,
                    reason: "replacement message has no content")
            }
            messages.append(.user(content))
            imageBindings.append(nil)
            if item.messageClassification == .realUser {
                realUsers.append(AgentModelHistoryRealUserMessage(
                    content: content,
                    submissionID: item.sourceSubmissionID,
                    attachmentIDs: nil,
                    imageReferences: nil,
                    contentTruncated: item.contentTruncated == true))
            }
        }
        return AgentModelHistoryProjection(
            messages: messages,
            imageBindings: imageBindings,
            realUserMessages: realUsers,
            baseCheckpoint: nil,
            latestCheckpoint: nil,
            latestAgentHistorySequence: nil)
    }

    private func conversationUncheckpointedProjection(
        agentID: AgentID,
        currentSubmissionID: SubmissionID,
        current: AcceptedSubmission,
        accepted: [SubmissionID: AcceptedSubmission],
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        let priorSubmissionIDs = Self.priorConversationSubmissionIDs(
            currentSubmissionID: currentSubmissionID,
            current: current,
            accepted: accepted,
            agentID: agentID)
        let direct = try Self.conversationDirectTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            events: events)
        var turns = Self.conversationLegacyTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            events: events)
        for (submissionID, turn) in direct {
            turns[submissionID] = turn
        }
        var ordered = Array(turns.values)
        ordered.append(contentsOf:
            Self.uncorrelatedLegacyConversationTurns(
                agentID: agentID,
                beforeSequence: current.sequence,
                events: events))
        ordered.sort {
            if $0.acceptedSequence == $1.acceptedSequence {
                return $0.firstHistorySequence < $1.firstHistorySequence
            }
            return $0.acceptedSequence < $1.acceptedSequence
        }
        return AgentModelHistoryProjection(
            messages: ordered.flatMap(\.messages),
            imageBindings: ordered.flatMap(\.imageBindings),
            realUserMessages: ordered.compactMap(\.realUser),
            baseCheckpoint: nil,
            latestCheckpoint: nil,
            latestAgentHistorySequence: Self.latestAgentHistorySequence(
                agentID: agentID,
                events: events))
    }

    private func conversationCheckpointedProjection(
        agentID: AgentID,
        currentSubmissionID: SubmissionID,
        current: AcceptedSubmission,
        accepted: [SubmissionID: AcceptedSubmission],
        checkpoint: SequencedCheckpoint,
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        let priorSubmissionIDs = Self.priorConversationSubmissionIDs(
            currentSubmissionID: currentSubmissionID,
            current: current,
            accepted: accepted,
            agentID: agentID)
        let base = try Self.projectReplacement(
            checkpoint,
            agentID: agentID,
            accepted: accepted,
            bindings: nil)
        let directSuffix = try Self.conversationDirectTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            events: events,
            afterSequence: checkpoint.sequence,
            allowsCheckpointContinuation: true)
        let directSubmissionsAnywhere = Set(events.compactMap {
            envelope -> SubmissionID? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.agent == agentID,
                  payload.taskID == nil else {
                return nil
            }
            return payload.submissionID
        })
        let baseRealSubmissionIDs = Set(
            base.realUserMessages.compactMap(\.submissionID))
        var suffixTurns = Array(directSuffix.values)
        for (submissionID, legacy) in Self.conversationLegacyTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            events: events)
        where legacy.firstHistorySequence > checkpoint.sequence
            && !directSubmissionsAnywhere.contains(submissionID)
        {
            let alreadyRetained =
                baseRealSubmissionIDs.contains(submissionID)
            suffixTurns.append(ProjectedTurn(
                acceptedSequence: legacy.acceptedSequence,
                firstHistorySequence: legacy.firstHistorySequence,
                messages: alreadyRetained
                    ? Array(legacy.messages.dropFirst())
                    : legacy.messages,
                imageBindings: alreadyRetained
                    ? Array(legacy.imageBindings.dropFirst())
                    : legacy.imageBindings,
                realUser: alreadyRetained ? nil : legacy.realUser))
        }
        suffixTurns.sort {
            if $0.firstHistorySequence == $1.firstHistorySequence {
                return $0.acceptedSequence < $1.acceptedSequence
            }
            return $0.firstHistorySequence < $1.firstHistorySequence
        }

        var realUsers = base.realUserMessages
        var seen = Set(realUsers.compactMap(\.submissionID))
        for user in suffixTurns.compactMap(\.realUser) {
            if let submissionID = user.submissionID,
               !seen.insert(submissionID).inserted {
                continue
            }
            realUsers.append(user)
        }
        return AgentModelHistoryProjection(
            messages: base.messages + suffixTurns.flatMap(\.messages),
            imageBindings:
                base.imageBindings
                + suffixTurns.flatMap(\.imageBindings),
            realUserMessages: realUsers,
            baseCheckpoint: AgentModelHistoryCheckpointCursor(
                sequence: checkpoint.sequence,
                payload: checkpoint.payload),
            latestCheckpoint: nil,
            latestAgentHistorySequence: Self.latestAgentHistorySequence(
                agentID: agentID,
                events: events))
    }

    private func uncheckpointedProjection(
        agentID: AgentID,
        currentTask: TaskContract,
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        guard currentTask.kind == .root,
              currentTask.issuer == nil,
              currentTask.assignee == agentID,
              let currentSubmissionID = currentTask.submissionID else {
            return AgentModelHistoryProjection(
                messages: [],
                realUserMessages: [],
                baseCheckpoint: nil,
                latestCheckpoint: nil,
                latestAgentHistorySequence: nil)
        }

        let accepted = Self.acceptedSubmissions(from: events)
        guard let current = accepted[currentSubmissionID] else {
            throw AgentModelHistoryProjectionError.missingAcceptedSubmission(
                currentSubmissionID)
        }
        guard !current.conflicted else {
            throw AgentModelHistoryProjectionError.conflictingAcceptedSubmission(
                currentSubmissionID)
        }
        guard current.payload.to == nil || current.payload.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "accepted-submission:\(currentSubmissionID.rawValue)",
                "accepted user target does not match the current root assignee")
        }

        let bindings = Self.rootBindings(
            currentTask: currentTask,
            events: events)
        try Self.requireRootBinding(
            taskID: currentTask.id,
            submissionID: currentSubmissionID,
            agentID: agentID,
            bindings: bindings)

        let priorSubmissionIDs: Set<SubmissionID> = Set(accepted.compactMap { entry in
            let (submissionID, value) = entry
            guard submissionID != currentSubmissionID,
                  !value.conflicted,
                  value.sequence < current.sequence else {
                return nil
            }
            return submissionID
        })

        let directTurns = try Self.directTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            bindings: bindings,
            events: events)
        var turnsBySubmission = Dictionary(
            uniqueKeysWithValues: AgentThreadHistoryProjector()
                .turns(
                    agentID: agentID,
                    currentTask: currentTask,
                    events: events)
                .map { legacy in
                    (
                        legacy.submissionID,
                        ProjectedTurn(
                            acceptedSequence: legacy.acceptedSequence,
                            firstHistorySequence: legacy.acceptedSequence,
                            messages: [
                                .user(legacy.userText),
                                .assistant(legacy.assistantText),
                            ],
                            imageBindings: [
                                Self.legacyUserBinding(
                                    accepted[legacy.submissionID]?
                                        .payload.attachments),
                                nil,
                            ],
                            realUser: accepted[legacy.submissionID].map {
                                acceptedSubmission in
                                AgentModelHistoryRealUserMessage(
                                    content:
                                        acceptedSubmission.payload.text,
                                    submissionID:
                                        legacy.submissionID,
                                    attachmentIDs:
                                        acceptedSubmission.payload.attachments)
                            })
                    )
                })

        // A direct model-history record is authoritative for its submission.
        // The legacy text-only bridge is used solely for turns written before
        // this event type existed.
        for (submissionID, turn) in directTurns {
            turnsBySubmission[submissionID] = turn
        }

        let ordered = turnsBySubmission.values
            .sorted { lhs, rhs in
                lhs.acceptedSequence < rhs.acceptedSequence
            }
        return AgentModelHistoryProjection(
            messages: ordered.flatMap {
                $0.messages
            },
            imageBindings: ordered.flatMap {
                $0.imageBindings
            },
            realUserMessages: ordered.compactMap {
                $0.realUser
            },
            baseCheckpoint: nil,
            latestCheckpoint: nil,
            latestAgentHistorySequence: Self.latestAgentHistorySequence(
                agentID: agentID,
                events: events))
    }

    private func checkpointedProjection(
        agentID: AgentID,
        currentTask: TaskContract,
        currentSubmissionID: SubmissionID,
        current: AcceptedSubmission,
        accepted: [SubmissionID: AcceptedSubmission],
        checkpoint: SequencedCheckpoint,
        events: [Envelope]
    ) throws -> AgentModelHistoryProjection {
        guard current.payload.to == nil
                || current.payload.to == agentID else {
            throw AgentModelHistoryProjectionError.invalidItem(
                "accepted-submission:\(currentSubmissionID.rawValue)",
                "accepted user target does not match the current root assignee")
        }
        let bindings = Self.rootBindings(
            currentTask: currentTask,
            events: events)
        try Self.requireRootBinding(
            taskID: currentTask.id,
            submissionID: currentSubmissionID,
            agentID: agentID,
            bindings: bindings)

        let priorSubmissionIDs: Set<SubmissionID> = Set(
            accepted.compactMap { submissionID, value in
                guard submissionID != currentSubmissionID,
                      !value.conflicted,
                      value.sequence < current.sequence else {
                    return nil
                }
                return submissionID
            })
        let base = try Self.projectReplacement(
            checkpoint,
            agentID: agentID,
            accepted: accepted,
            bindings: bindings)

        let directSuffix = try Self.directTurns(
            agentID: agentID,
            priorSubmissionIDs: priorSubmissionIDs,
            accepted: accepted,
            bindings: bindings,
            events: events,
            afterSequence: checkpoint.sequence,
            allowsCheckpointContinuation: true)
        let directSubmissionsAnywhere = Set(events.compactMap {
            envelope -> SubmissionID? in
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.agent == agentID else {
                return nil
            }
            return payload.submissionID
        })
        let baseRealSubmissionIDs = Set(
            base.realUserMessages.compactMap {
                $0.submissionID
            })
        var suffixTurns = Array(directSuffix.values)
        for legacy in AgentThreadHistoryProjector().turns(
            agentID: agentID,
            currentTask: currentTask,
            events: events)
        where legacy.completedSequence > checkpoint.sequence
            && !directSubmissionsAnywhere.contains(legacy.submissionID)
        {
            let acceptedUser = accepted[legacy.submissionID]?.payload
            let alreadyRetained =
                baseRealSubmissionIDs.contains(legacy.submissionID)
            suffixTurns.append(ProjectedTurn(
                acceptedSequence: legacy.acceptedSequence,
                firstHistorySequence: legacy.completedSequence,
                messages: alreadyRetained
                    ? [.assistant(legacy.assistantText)]
                    : [
                        .user(legacy.userText),
                        .assistant(legacy.assistantText),
                    ],
                imageBindings: alreadyRetained
                    ? [nil]
                    : [
                        Self.legacyUserBinding(
                            acceptedUser?.attachments),
                        nil,
                    ],
                realUser: alreadyRetained
                    ? nil
                    : acceptedUser.map {
                        AgentModelHistoryRealUserMessage(
                            content: $0.text,
                            submissionID: legacy.submissionID,
                            attachmentIDs: $0.attachments)
                    }))
        }
        suffixTurns.sort {
            if $0.firstHistorySequence == $1.firstHistorySequence {
                return $0.acceptedSequence < $1.acceptedSequence
            }
            return $0.firstHistorySequence < $1.firstHistorySequence
        }

        var realUsers = base.realUserMessages
        var seenRealSubmissionIDs = Set(
            realUsers.compactMap {
                $0.submissionID
            })
        for user in suffixTurns.compactMap(\.realUser) {
            if let submissionID = user.submissionID {
                guard seenRealSubmissionIDs.insert(submissionID).inserted else {
                    continue
                }
            }
            realUsers.append(user)
        }
        return AgentModelHistoryProjection(
            messages:
                base.messages
                + suffixTurns.flatMap(\.messages),
            imageBindings:
                base.imageBindings
                + suffixTurns.flatMap(\.imageBindings),
            realUserMessages: realUsers,
            baseCheckpoint: AgentModelHistoryCheckpointCursor(
                sequence: checkpoint.sequence,
                payload: checkpoint.payload),
            latestCheckpoint: nil,
            latestAgentHistorySequence: Self.latestAgentHistorySequence(
                agentID: agentID,
                events: events))
    }

    private struct AcceptedSubmission {
        var sequence: Int
        var payload: UserMessagePayload
        var conflicted: Bool
    }

    private struct RootBinding: Hashable {
        var submissionID: SubmissionID
        var assignee: AgentID
    }

    private struct SequencedItem {
        var sequence: Int
        var payload: ModelHistoryItemPayload
    }

    private struct ProjectedTurn {
        var acceptedSequence: Int
        var firstHistorySequence: Int
        var messages: [AgentMessage]
        var imageBindings: [ProjectedImageBinding?]
        var realUser: AgentModelHistoryRealUserMessage?
    }

    private struct SequencedOutput {
        var sequence: Int
        var payload: ModelHistoryItemPayload
    }

    private struct CallKey: Hashable {
        var turnID: TurnID
        var callID: String
    }

    private struct SequencedCheckpoint {
        var sequence: Int
        var payload: ModelHistoryCompactedPayload
        var coveredSubmissions: Set<SubmissionID>
    }

    private struct ReplacementProjection {
        var messages: [AgentMessage]
        var imageBindings: [ProjectedImageBinding?]
        var realUserMessages: [AgentModelHistoryRealUserMessage]
    }

    private struct ProjectedInvocation {
        var messages: [AgentMessage]
        var imageBindings: [ProjectedImageBinding?]
    }

    private static func validatedCheckpointChain(
        agentID: AgentID,
        accepted: [SubmissionID: AcceptedSubmission],
        events: [Envelope]
    ) throws -> [SequencedCheckpoint] {
        let rawCheckpoints = events.sorted(by: { $0.seq < $1.seq })
            .compactMap { envelope -> SequencedCheckpoint? in
                guard case .modelHistoryCompacted(let payload) =
                        envelope.event,
                      payload.agent == agentID else {
                    return nil
                }
                return SequencedCheckpoint(
                    sequence: envelope.seq,
                    payload: payload,
                    coveredSubmissions: [])
            }
        var checkpoints: [SequencedCheckpoint] = []
        var previous: SequencedCheckpoint?
        var seenWindowIDs = Set<String>()
        for var checkpoint in rawCheckpoints {
            let payload = checkpoint.payload
            guard payload.schemaVersion
                    == ModelHistoryCompactedPayload.currentSchemaVersion
                    || payload.schemaVersion
                        == ModelHistoryCompactedPayload.mediaSchemaVersion else {
                throw AgentModelHistoryProjectionError
                    .unsupportedCheckpointSchema(
                        sequence: checkpoint.sequence,
                        version: payload.schemaVersion)
            }
            do {
                try payload.validate()
            } catch {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason:
                        "checkpoint payload failed v1/v2 structural validation")
            }
            let lowerBound = previous?.sequence ?? Int.min
            let coversV2DirectItem = events.contains { envelope in
                guard envelope.seq > lowerBound,
                      envelope.seq < checkpoint.sequence,
                      case .modelHistoryItem(let item) = envelope.event,
                      item.agent == agentID else {
                    return false
                }
                return item.schemaVersion
                    == ModelHistoryItemPayload.mediaSchemaVersion
            }
            let inheritsV2Checkpoint = previous?.payload.schemaVersion
                == ModelHistoryCompactedPayload.mediaSchemaVersion
            if payload.schemaVersion
                    == ModelHistoryCompactedPayload.currentSchemaVersion,
               coversV2DirectItem || inheritsV2Checkpoint
            {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "a v1 checkpoint cannot cover or replace v2 media history")
            }
            for (field, value) in [
                ("firstWindowID", payload.firstWindowID),
                ("previousWindowID", payload.previousWindowID),
                ("windowID", payload.windowID),
            ] {
                guard Self.isUUIDVersion7(value) else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "\(field) is not UUIDv7")
                }
            }
            guard seenWindowIDs.insert(payload.windowID).inserted else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "windowID was reused")
            }
            if let previous {
                let (expectedWindow, overflow) =
                    previous.payload.windowNumber.addingReportingOverflow(1)
                guard !overflow,
                      payload.windowNumber == expectedWindow,
                      payload.firstWindowID
                        == previous.payload.firstWindowID,
                      payload.previousWindowID
                        == previous.payload.windowID,
                      payload.windowID
                        != previous.payload.windowID else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "window lineage is not contiguous")
                }
            } else {
                guard payload.windowNumber == 1,
                      payload.previousWindowID
                        == payload.firstWindowID,
                      payload.windowID
                        != payload.firstWindowID else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "first checkpoint has an invalid initial window")
                }
            }
            _ = try Self.projectReplacement(
                checkpoint,
                agentID: agentID,
                accepted: accepted,
                bindings: nil)
            var covered = previous?.coveredSubmissions ?? []
            for envelope in events
                where envelope.seq > lowerBound
                    && envelope.seq < checkpoint.sequence
            {
                guard case .modelHistoryItem(let item) =
                        envelope.event,
                      item.agent == agentID,
                      Self.isRealUserMessage(item),
                      let submissionID = item.submissionID else {
                    continue
                }
                covered.insert(submissionID)
            }
            for item in payload.replacementHistory
                where item.messageClassification == .realUser
            {
                if let submissionID = item.sourceSubmissionID {
                    covered.insert(submissionID)
                }
            }
            checkpoint.coveredSubmissions = covered
            checkpoints.append(checkpoint)
            previous = checkpoint
        }
        return checkpoints
    }

    private static func isEligibleBase(
        _ checkpoint: SequencedCheckpoint,
        currentSubmissionID: SubmissionID,
        current: AcceptedSubmission,
        accepted: [SubmissionID: AcceptedSubmission],
        agentID: AgentID,
        events: [Envelope]
    ) -> Bool {
        guard !checkpoint.coveredSubmissions
                .contains(currentSubmissionID),
              checkpoint.coveredSubmissions.allSatisfy({
                  guard let source = accepted[$0],
                        !source.conflicted else {
                      return false
                  }
                  return source.sequence < current.sequence
              }) else {
            return false
        }

        // A newer invocation for a submission already summarized by this
        // checkpoint supersedes that summary. Until another checkpoint covers
        // the retry, reconstruct from an older base so the failed attempt
        // cannot leak into later turns.
        return !events.contains { envelope in
            guard envelope.seq > checkpoint.sequence,
                  case .modelHistoryItem(let item) = envelope.event,
                  item.agent == agentID,
                  Self.isRealUserMessage(item),
                  let submissionID = item.submissionID,
                  checkpoint.coveredSubmissions.contains(submissionID),
                  let source = accepted[submissionID] else {
                return false
            }
            return source.sequence < current.sequence
        }
    }

    private static func projectReplacement(
        _ checkpoint: SequencedCheckpoint,
        agentID: AgentID,
        accepted: [SubmissionID: AcceptedSubmission],
        bindings: [TaskID: Set<RootBinding>]?
    ) throws -> ReplacementProjection {
        let payload = checkpoint.payload
        guard !payload.replacementHistory.isEmpty,
              let final = payload.replacementHistory.last else {
            throw AgentModelHistoryProjectionError.invalidCheckpoint(
                sequence: checkpoint.sequence,
                reason: "replacement history is empty")
        }
        guard final.kind == .message,
              final.role == .user,
              final.messageClassification == .compactionSummary,
              final.content == payload.message,
              final.contentTruncated != true,
              final.sourceSubmissionID == nil else {
            throw AgentModelHistoryProjectionError.invalidCheckpoint(
                sequence: checkpoint.sequence,
                reason: "final replacement item is not the exact compaction summary")
        }

        var messages: [AgentMessage] = []
        var imageBindings: [ProjectedImageBinding?] = []
        var realUsers: [AgentModelHistoryRealUserMessage] = []
        var seenRealSubmissionIDs = Set<SubmissionID>()
        var contextualIndices: [Int] = []
        var realUserIndices: [Int] = []
        for (index, item) in payload.replacementHistory.enumerated() {
            guard item.kind == .message,
                  item.role == .user,
                  let content = item.content,
                  item.functionCalls == nil,
                  item.callID == nil,
                  item.output == nil,
                  item.toolSearchOutput == nil,
                  item.reasoningSummary == nil,
                  item.reasoningContent == nil,
                  item.encryptedReasoningContent == nil else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "replacement item \(item.itemID) has an unsupported v1/v2 shape")
            }
            if index == payload.replacementHistory.count - 1 {
                guard item.messageClassification == .compactionSummary,
                      item.contentTruncated != true else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "summary is not final")
                }
            } else if item.messageClassification == .realUser {
                guard
                      let submissionID = item.sourceSubmissionID,
                      let source = accepted[submissionID],
                      !source.conflicted,
                      source.sequence < checkpoint.sequence,
                      seenRealSubmissionIDs.insert(submissionID).inserted
                else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "retained real user \(item.itemID) lacks valid provenance")
                }
                if item.contentTruncated == true {
                    let marker = AgentModelHistoryCompactor
                        .retainedRealUserTruncationMarker
                    guard content.hasPrefix(marker) else {
                        throw AgentModelHistoryProjectionError
                            .invalidCheckpoint(
                                sequence: checkpoint.sequence,
                                reason: "truncated real user lacks its marker")
                    }
                    let suffix = String(content.dropFirst(marker.count))
                    guard !suffix.isEmpty,
                          source.payload.text.hasSuffix(suffix) else {
                        throw AgentModelHistoryProjectionError
                            .invalidCheckpoint(
                                sequence: checkpoint.sequence,
                                reason: "truncated real user is not a source suffix")
                    }
                } else {
                    guard source.payload.text == content else {
                        throw AgentModelHistoryProjectionError
                            .invalidCheckpoint(
                                sequence: checkpoint.sequence,
                                reason: "retained real user text does not match its source")
                    }
                }
                if let explicitTarget = source.payload.to,
                   explicitTarget != agentID {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "retained real user targets another agent")
                }
                if let bindings {
                    let matching = bindings.values
                        .flatMap(Array.init)
                        .filter {
                            $0.submissionID == submissionID
                                && $0.assignee == agentID
                        }
                    guard matching.count == 1 else {
                        throw AgentModelHistoryProjectionError
                            .invalidCheckpoint(
                                sequence: checkpoint.sequence,
                                reason: "retained real user has no unique root binding")
                    }
                }
                realUsers.append(AgentModelHistoryRealUserMessage(
                    content: content,
                    submissionID: submissionID,
                    attachmentIDs: nil,
                    imageReferences: nil,
                    contentTruncated: item.contentTruncated == true))
                realUserIndices.append(index)
            } else if item.messageClassification == .contextual {
                guard item.sourceSubmissionID == nil,
                      item.contentTruncated != true else {
                    throw AgentModelHistoryProjectionError.invalidCheckpoint(
                        sequence: checkpoint.sequence,
                        reason: "contextual replacement item has invalid provenance")
                }
                contextualIndices.append(index)
            } else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "replacement item \(item.itemID) has an invalid classification")
            }
            messages.append(.user(content))
            imageBindings.append(nil)
        }
        if !contextualIndices.isEmpty {
            guard let lastRealUserIndex = realUserIndices.last else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "contextual replacement items are not immediately before the newest real user")
            }
            let firstContextualIndex =
                lastRealUserIndex - contextualIndices.count
            let expectedContextualIndices =
                Array(firstContextualIndex..<lastRealUserIndex)
            guard contextualIndices.last == lastRealUserIndex - 1,
                  contextualIndices == expectedContextualIndices else {
                throw AgentModelHistoryProjectionError.invalidCheckpoint(
                    sequence: checkpoint.sequence,
                    reason: "contextual replacement items are not immediately before the newest real user")
            }
        }
        return ReplacementProjection(
            messages: messages,
            imageBindings: imageBindings,
            realUserMessages: realUsers)
    }

    private static func latestAgentHistorySequence(
        agentID: AgentID,
        events: [Envelope]
    ) -> Int? {
        events.compactMap { envelope -> Int? in
            switch envelope.event {
            case .modelHistoryItem(let payload)
                where payload.agent == agentID:
                return envelope.seq
            case .modelHistoryCompacted(let payload)
                where payload.agent == agentID:
                return envelope.seq
            default:
                return nil
            }
        }.max()
    }

    private static func isUUIDVersion7(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) {
            ($0[6] >> 4) == 0x7
                && ($0[8] & 0b1100_0000) == 0b1000_0000
        }
    }

    private static func priorConversationSubmissionIDs(
        currentSubmissionID: SubmissionID,
        current: AcceptedSubmission,
        accepted: [SubmissionID: AcceptedSubmission],
        agentID: AgentID
    ) -> Set<SubmissionID> {
        Set(accepted.compactMap { submissionID, value in
            guard submissionID != currentSubmissionID,
                  !value.conflicted,
                  value.sequence < current.sequence,
                  value.payload.to == nil
                    || value.payload.to == agentID else {
                return nil
            }
            return submissionID
        })
    }

    private static func conversationDirectTurns(
        agentID: AgentID,
        priorSubmissionIDs: Set<SubmissionID>,
        accepted: [SubmissionID: AcceptedSubmission],
        events: [Envelope],
        afterSequence: Int? = nil,
        allowsCheckpointContinuation: Bool = false
    ) throws -> [SubmissionID: ProjectedTurn] {
        var seenItemIDs: [String: ModelHistoryItemPayload] = [:]
        var grouped: [SubmissionID: [SequencedItem]] = [:]
        let terminalOutcomes = try terminalOutcomesByTurn(events: events)

        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .modelHistoryItem(let payload) = envelope.event,
                  payload.agent == agentID,
                  let submissionID = payload.submissionID,
                  priorSubmissionIDs.contains(submissionID),
                  afterSequence.map({ envelope.seq > $0 }) ?? true else {
                continue
            }
            guard payload.taskID == nil else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "Code model history must not claim a Cowork task binding")
            }
            guard let acceptedSubmission = accepted[submissionID],
                  !acceptedSubmission.conflicted,
                  envelope.seq > acceptedSubmission.sequence else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "Code item is not after one unambiguous accepted submission")
            }
            guard acceptedSubmission.payload.to == nil
                    || acceptedSubmission.payload.to == agentID else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "accepted Code user target does not match the item agent")
            }
            guard !isInvalidatedFinalAssistant(
                payload,
                terminalOutcomes: terminalOutcomes) else {
                continue
            }
            let trimmedItemID = payload.itemID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedItemID.isEmpty else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "itemID is empty")
            }
            if let existing = seenItemIDs[payload.itemID] {
                guard existing == payload else {
                    throw AgentModelHistoryProjectionError.conflictingItemID(
                        payload.itemID)
                }
                continue
            }
            seenItemIDs[payload.itemID] = payload
            grouped[submissionID, default: []].append(
                SequencedItem(sequence: envelope.seq, payload: payload))
        }

        var result: [SubmissionID: ProjectedTurn] = [:]
        for (submissionID, items) in grouped {
            guard let acceptedSubmission = accepted[submissionID] else {
                continue
            }
            let selected = try selectLatestInvocation(
                submissionID: submissionID,
                items: items,
                allowsCheckpointContinuation:
                    allowsCheckpointContinuation)
            let hasRealUser = selected.contains {
                Self.isRealUserMessage($0.payload)
            }
            let projected = try projectInvocation(
                acceptedUser:
                    hasRealUser ? acceptedSubmission.payload : nil,
                items: selected)
            let verifiedReferences = selected.first(where: {
                Self.isRealUserMessage($0.payload)
            })?.payload.imageReferences
            result[submissionID] = ProjectedTurn(
                acceptedSequence: acceptedSubmission.sequence,
                firstHistorySequence:
                    selected.first?.sequence
                    ?? acceptedSubmission.sequence,
                messages: projected.messages,
                imageBindings: projected.imageBindings,
                realUser: hasRealUser
                    ? AgentModelHistoryRealUserMessage(
                        content: acceptedSubmission.payload.text,
                        submissionID: submissionID,
                        attachmentIDs:
                            acceptedSubmission.payload.attachments,
                        imageReferences: verifiedReferences)
                    : nil)
        }
        return result
    }

    private static func conversationLegacyTurns(
        agentID: AgentID,
        priorSubmissionIDs: Set<SubmissionID>,
        accepted: [SubmissionID: AcceptedSubmission],
        events: [Envelope]
    ) -> [SubmissionID: ProjectedTurn] {
        var completedBySubmission:
            [SubmissionID: (sequence: Int, text: String)] = [:]
        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .messageCompleted(let payload) = envelope.event,
                  let submissionID = payload.submissionID,
                  priorSubmissionIDs.contains(submissionID),
                  payload.role == .assistant || payload.role == .agent,
                  payload.agent == nil || payload.agent == agentID,
                  let acceptedSubmission = accepted[submissionID],
                  envelope.seq > acceptedSubmission.sequence else {
                continue
            }
            completedBySubmission[submissionID] =
                (envelope.seq, payload.text)
        }

        return Dictionary(uniqueKeysWithValues:
            priorSubmissionIDs.compactMap { submissionID in
                guard let source = accepted[submissionID] else {
                    return nil
                }
                let completed = completedBySubmission[submissionID]
                var messages: [AgentMessage] = [
                    .user(source.payload.text),
                ]
                if let completed {
                    messages.append(.assistant(completed.text))
                }
                return (
                    submissionID,
                    ProjectedTurn(
                        acceptedSequence: source.sequence,
                        firstHistorySequence:
                            completed?.sequence ?? source.sequence,
                        messages: messages,
                        imageBindings: [
                            Self.legacyUserBinding(
                                source.payload.attachments),
                        ] + (completed == nil ? [] : [nil]),
                        realUser:
                            AgentModelHistoryRealUserMessage(
                                content: source.payload.text,
                                submissionID: submissionID,
                                attachmentIDs:
                                    source.payload.attachments))
                )
            })
    }

    /// Migration bridge for old Code/CLI logs whose UI events predate
    /// SubmissionID. These turns remain available to the summarizer, but they
    /// are intentionally not represented as provenance-bearing retained users.
    private static func uncorrelatedLegacyConversationTurns(
        agentID: AgentID,
        beforeSequence: Int,
        events: [Envelope]
    ) -> [ProjectedTurn] {
        var turns: [ProjectedTurn] = []
        for envelope in events.sorted(by: { $0.seq < $1.seq })
            where envelope.seq < beforeSequence
        {
            switch envelope.event {
            case .userMessage(let payload)
                where payload.submissionID == nil
                    && (payload.to == nil || payload.to == agentID):
                turns.append(ProjectedTurn(
                    acceptedSequence: envelope.seq,
                    firstHistorySequence: envelope.seq,
                    messages: [.user(payload.text)],
                    imageBindings: [
                        Self.legacyUserBinding(payload.attachments),
                    ],
                    realUser: nil))

            case .messageCompleted(let payload)
                where payload.submissionID == nil
                    && (payload.role == .assistant
                        || payload.role == .agent)
                    && (payload.agent == nil
                        || payload.agent == agentID):
                guard let index = turns.lastIndex(where: {
                    $0.messages.count == 1
                        && $0.messages[0].role == .user
                }) else {
                    continue
                }
                turns[index].messages.append(.assistant(payload.text))
                turns[index].imageBindings.append(nil)

            default:
                continue
            }
        }
        return turns
    }

    private static func directTurns(
        agentID: AgentID,
        priorSubmissionIDs: Set<SubmissionID>,
        accepted: [SubmissionID: AcceptedSubmission],
        bindings: [TaskID: Set<RootBinding>],
        events: [Envelope],
        afterSequence: Int? = nil,
        allowsCheckpointContinuation: Bool = false
    ) throws -> [SubmissionID: ProjectedTurn] {
        var seenItemIDs: [String: ModelHistoryItemPayload] = [:]
        var grouped: [SubmissionID: [SequencedItem]] = [:]
        let terminalOutcomes = try terminalOutcomesByTurn(events: events)

        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .modelHistoryItem(let payload) = envelope.event,
                  let submissionID = payload.submissionID,
                  priorSubmissionIDs.contains(submissionID),
                  afterSequence.map({ envelope.seq > $0 }) ?? true else {
                continue
            }
            guard let acceptedSubmission = accepted[submissionID],
                  !acceptedSubmission.conflicted,
                  envelope.seq > acceptedSubmission.sequence else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item is not after one unambiguous accepted submission")
            }
            guard let taskID = payload.taskID else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "root model history is missing taskID")
            }
            let rootBinding = try uniqueRootBinding(
                taskID: taskID,
                bindings: bindings)
            guard rootBinding.submissionID == submissionID else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item submission does not match its durable root task")
            }
            guard acceptedSubmission.payload.to == nil
                    || acceptedSubmission.payload.to == rootBinding.assignee else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "accepted user target does not match the durable root assignee")
            }
            guard payload.agent == rootBinding.assignee else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "item agent does not match the durable root assignee")
            }
            guard rootBinding.assignee == agentID else {
                continue
            }
            guard !isInvalidatedFinalAssistant(
                payload,
                terminalOutcomes: terminalOutcomes) else {
                continue
            }

            let trimmedItemID = payload.itemID.trimmingCharacters(
                in: .whitespacesAndNewlines)
            guard !trimmedItemID.isEmpty else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    payload.itemID,
                    "itemID is empty")
            }
            if let existing = seenItemIDs[payload.itemID] {
                guard existing == payload else {
                    throw AgentModelHistoryProjectionError.conflictingItemID(
                        payload.itemID)
                }
                continue
            }
            seenItemIDs[payload.itemID] = payload
            grouped[submissionID, default: []].append(
                SequencedItem(sequence: envelope.seq, payload: payload))
        }

        var result: [SubmissionID: ProjectedTurn] = [:]
        for (submissionID, items) in grouped {
            guard let acceptedSubmission = accepted[submissionID] else {
                continue
            }
            let selected = try selectLatestInvocation(
                submissionID: submissionID,
                items: items,
                allowsCheckpointContinuation:
                    allowsCheckpointContinuation)
            let hasRealUser = selected.contains {
                Self.isRealUserMessage($0.payload)
            }
            let projected = try projectInvocation(
                acceptedUser:
                    hasRealUser ? acceptedSubmission.payload : nil,
                items: selected)
            let verifiedReferences = selected.first(where: {
                Self.isRealUserMessage($0.payload)
            })?.payload.imageReferences
            result[submissionID] = ProjectedTurn(
                acceptedSequence: acceptedSubmission.sequence,
                firstHistorySequence:
                    selected.first?.sequence
                    ?? acceptedSubmission.sequence,
                messages: projected.messages,
                imageBindings: projected.imageBindings,
                realUser: hasRealUser
                    ? AgentModelHistoryRealUserMessage(
                        content: acceptedSubmission.payload.text,
                        submissionID: submissionID,
                        attachmentIDs:
                            acceptedSubmission.payload.attachments,
                        imageReferences: verifiedReferences)
                    : nil)
        }
        return result
    }

    /// `turn_outcome` is the authoritative terminal for a model turn. Older
    /// AgentLoop builds could append a final assistant item before a later
    /// runtime failure wrote a failed outcome. Keep the real user/tool
    /// transcript, but never feed that invalidated final answer into a later
    /// provider request.
    private static func terminalOutcomesByTurn(
        events: [Envelope]
    ) throws -> [TurnID: TurnOutcomePayload] {
        var result: [TurnID: TurnOutcomePayload] = [:]
        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .turnOutcome(let payload) = envelope.event else {
                continue
            }
            if let existing = result[payload.turnID] {
                guard existing == payload else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        "turn-outcome:\(payload.turnID.rawValue)",
                        "one turn has conflicting terminal outcomes")
                }
                continue
            }
            result[payload.turnID] = payload
        }
        return result
    }

    private static func isInvalidatedFinalAssistant(
        _ payload: ModelHistoryItemPayload,
        terminalOutcomes: [TurnID: TurnOutcomePayload]
    ) -> Bool {
        guard payload.kind == .message,
              payload.role == .assistant,
              let outcome = terminalOutcomes[payload.turnID] else {
            return false
        }
        return outcome.outcome == .failed || outcome.outcome == .interrupted
    }

    /// A retried submission replaces an earlier failed invocation. Within the
    /// selected attempt, a second invocation likewise replaces a partial
    /// predecessor. This prevents a restart from duplicating the same user
    /// message while retaining all items from the chosen provider turn.
    private static func selectLatestInvocation(
        submissionID: SubmissionID,
        items: [SequencedItem],
        allowsCheckpointContinuation: Bool = false
    ) throws -> [SequencedItem] {
        for item in items {
            guard item.payload.schemaVersion
                    == ModelHistoryItemPayload.currentSchemaVersion
                    || item.payload.schemaVersion
                        == ModelHistoryItemPayload.mediaSchemaVersion else {
                throw AgentModelHistoryProjectionError.unsupportedSchema(
                    itemID: item.payload.itemID,
                    version: item.payload.schemaVersion)
            }
            do {
                try item.payload.validate()
            } catch {
                throw AgentModelHistoryProjectionError.invalidItem(
                    item.payload.itemID,
                    "payload failed v1/v2 structural validation")
            }
        }

        let selectedAttempt = items.map { $0.payload.taskAttempt ?? 1 }.max() ?? 1
        let attemptItems = items.filter {
            ($0.payload.taskAttempt ?? 1) == selectedAttempt
        }
        let userItems = attemptItems.filter {
            Self.isRealUserMessage($0.payload)
        }
        if let selectedUser = userItems.max(
            by: { $0.sequence < $1.sequence })
        {
            return attemptItems
                .filter { $0.payload.turnID == selectedUser.payload.turnID }
                .sorted { $0.sequence < $1.sequence }
        }
        guard allowsCheckpointContinuation else {
            throw AgentModelHistoryProjectionError.missingUserItem(
                submissionID)
        }
        let turnIDs = Set(attemptItems.map(\.payload.turnID))
        guard turnIDs.count == 1 else {
            throw AgentModelHistoryProjectionError.invalidItem(
                attemptItems.first?.payload.itemID
                    ?? "checkpoint-suffix:\(submissionID.rawValue)",
                "checkpoint suffix without a real user spans multiple turn IDs")
        }
        return attemptItems
            .sorted { $0.sequence < $1.sequence }
    }

    private static func projectInvocation(
        acceptedUser: UserMessagePayload?,
        items: [SequencedItem]
    ) throws -> ProjectedInvocation {
        guard let first = items.first else {
            return ProjectedInvocation(messages: [], imageBindings: [])
        }
        let turnID = first.payload.turnID
        guard items.allSatisfy({ $0.payload.turnID == turnID }) else {
            throw AgentModelHistoryProjectionError.invalidItem(
                first.payload.itemID,
                "one invocation contains multiple turn IDs")
        }

        let userItems = items.filter {
            Self.isRealUserMessage($0.payload)
        }
        if let acceptedUser {
            guard userItems.count == 1,
                  let userContent = userItems[0].payload.content,
                  userContent == acceptedUser.text,
                  userItems[0].payload.attachmentIDs
                    == acceptedUser.attachments else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    userItems.first?.payload.itemID
                        ?? first.payload.itemID,
                    "durable user item does not exactly match the accepted submission")
            }
            guard let realUserIndex = items.firstIndex(where: {
                $0.payload.itemID == userItems[0].payload.itemID
            }),
                  items[..<realUserIndex].allSatisfy({
                      Self.isContextualUserMessage($0.payload)
                  }) else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    userItems[0].payload.itemID,
                    "only contextual user items may precede the real user item")
            }
        } else {
            guard userItems.isEmpty,
                  !items.contains(where: {
                      Self.isContextualUserMessage($0.payload)
                  }) else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    first.payload.itemID,
                    "checkpoint continuation contains an unexpected user item")
            }
        }

        var callSequenceByKey: [CallKey: Int] = [:]
        var outputsByKey: [CallKey: [SequencedOutput]] = [:]
        for item in items {
            try validateShape(item.payload)
            switch item.payload.kind {
            case .functionCallBatch:
                for call in item.payload.functionCalls ?? [] {
                    let key = CallKey(
                        turnID: item.payload.turnID,
                        callID: call.callID)
                    guard callSequenceByKey[key] == nil else {
                        throw AgentModelHistoryProjectionError.ambiguousCallID(
                            call.callID)
                    }
                    callSequenceByKey[key] = item.sequence
                }
            case .functionCallOutput, .toolSearchOutput:
                guard let callID = item.payload.callID else { continue }
                let key = CallKey(
                    turnID: item.payload.turnID,
                    callID: callID)
                outputsByKey[key, default: []].append(
                    SequencedOutput(
                        sequence: item.sequence,
                        payload: item.payload))
            case .message, .reasoning:
                break
            }
        }
        for (key, outputs) in outputsByKey
            where outputs.contains(where: {
                $0.payload.imageReferences?.isEmpty == false
            })
        {
            guard let callSequence = callSequenceByKey[key],
                  outputs.allSatisfy({ $0.sequence > callSequence }) else {
                throw AgentModelHistoryProjectionError.invalidItem(
                    outputs.first?.payload.itemID ?? key.callID,
                    "media tool output has no preceding matching call")
            }
        }

        var messages: [AgentMessage] = []
        var imageBindings: [ProjectedImageBinding?] = []
        for item in items {
            switch item.payload.kind {
            case .message:
                guard let role = item.payload.role,
                      let content = item.payload.content else {
                    throw AgentModelHistoryProjectionError.invalidItem(
                        item.payload.itemID,
                        "message is missing role or content")
                }
                switch role {
                case .user:
                    guard item.payload.messageClassification
                            != .compactionSummary else {
                        throw AgentModelHistoryProjectionError.invalidItem(
                            item.payload.itemID,
                            "a direct item cannot impersonate a compaction summary")
                    }
                    messages.append(.user(content))
                    if let references = item.payload.imageReferences {
                        imageBindings.append(.userVerified(references))
                    } else {
                        imageBindings.append(Self.legacyUserBinding(
                            item.payload.attachmentIDs))
                    }
                case .assistant:
                    guard item.payload.messageClassification == nil else {
                        throw AgentModelHistoryProjectionError.invalidItem(
                            item.payload.itemID,
                            "assistant messages cannot carry a user classification")
                    }
                    messages.append(.assistant(content))
                    imageBindings.append(nil)
                }

            case .functionCallBatch:
                let calls = (item.payload.functionCalls ?? []).map {
                    ToolCall(
                        id: $0.callID,
                        name: $0.name,
                        arguments: $0.arguments,
                        kind: $0.kind == .toolSearch
                            ? .toolSearch
                            : .function,
                        namespace: $0.namespace,
                        status: $0.status,
                        execution: $0.execution)
                }
                messages.append(.assistant(
                    toolCalls: calls,
                    content: item.payload.content))
                imageBindings.append(nil)
                for call in calls {
                    let key = CallKey(turnID: turnID, callID: call.id)
                    let validOutputs = (outputsByKey[key] ?? []).filter {
                        guard $0.sequence > item.sequence else {
                            return false
                        }
                        switch call.kind {
                        case .function:
                            return $0.payload.kind ==
                                .functionCallOutput
                        case .toolSearch:
                            return $0.payload.kind ==
                                .toolSearchOutput
                        }
                    }
                    guard validOutputs.count <= 1 else {
                        throw AgentModelHistoryProjectionError.conflictingOutput(
                            call.id)
                    }
                    switch call.kind {
                    case .function:
                        let output = validOutputs.first?.payload
                        messages.append(.tool(
                            id: call.id,
                            content: output?.output
                                ?? "aborted"))
                        if let references = output?.imageReferences {
                            imageBindings.append(.toolVerified(
                                callID: call.id,
                                imageReferences: references))
                        } else {
                            imageBindings.append(nil)
                        }
                    case .toolSearch:
                        messages.append(.toolSearchOutput(
                            id: call.id,
                            output: validOutputs.first?
                                .payload.toolSearchOutput
                                ?? ModelToolSearchOutput(
                                    execution:
                                        call.execution ?? "client",
                                    tools: [])))
                        imageBindings.append(nil)
                    }
                }

            case .functionCallOutput, .toolSearchOutput:
                // Outputs are emitted immediately after their matching call,
                // in call order. Orphan outputs are intentionally omitted.
                continue

            case .reasoning:
                // The current Chat Completions-shaped AgentRequest cannot
                // represent provider-native reasoning items. No writer emits
                // this kind yet; retaining the tagged schema leaves the resume
                // format additive for a provider adapter that can.
                continue
            }
        }
        return ProjectedInvocation(
            messages: messages,
            imageBindings: imageBindings)
    }

    private static func validateShape(
        _ payload: ModelHistoryItemPayload
    ) throws {
        do {
            try payload.validate()
        } catch {
            throw AgentModelHistoryProjectionError.invalidItem(
                payload.itemID,
                "payload failed v1/v2 structural validation")
        }
    }

    private static func isRealUserMessage(
        _ payload: ModelHistoryItemPayload
    ) -> Bool {
        payload.kind == .message
            && payload.role == .user
            && (payload.messageClassification == nil
                || payload.messageClassification == .realUser)
    }

    private static func isContextualUserMessage(
        _ payload: ModelHistoryItemPayload
    ) -> Bool {
        payload.kind == .message
            && payload.role == .user
            && payload.messageClassification == .contextual
    }

    private static func legacyUserBinding(
        _ attachmentIDs: [ArtifactID]?
    ) -> ProjectedImageBinding? {
        guard let attachmentIDs, !attachmentIDs.isEmpty else {
            return nil
        }
        return .userLegacy(attachmentIDs)
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

    private static func acceptedSubmissions(
        from events: [Envelope]
    ) -> [SubmissionID: AcceptedSubmission] {
        var result: [SubmissionID: AcceptedSubmission] = [:]
        for envelope in events.sorted(by: { $0.seq < $1.seq }) {
            guard case .userMessage(let payload) = envelope.event,
                  let submissionID = payload.submissionID else {
                continue
            }
            if var existing = result[submissionID] {
                if existing.payload != payload {
                    existing.conflicted = true
                    result[submissionID] = existing
                }
            } else {
                result[submissionID] = AcceptedSubmission(
                    sequence: envelope.seq,
                    payload: payload,
                    conflicted: false)
            }
        }
        return result
    }

    private static func rootBindings(
        currentTask: TaskContract,
        events: [Envelope]
    ) -> [TaskID: Set<RootBinding>] {
        var result: [TaskID: Set<RootBinding>] = [:]
        func record(_ contract: TaskContract) {
            guard contract.kind == .root,
                  contract.issuer == nil,
                  let submissionID = contract.submissionID else {
                return
            }
            result[contract.id, default: []].insert(
                RootBinding(
                    submissionID: submissionID,
                    assignee: contract.assignee))
        }
        record(currentTask)
        for envelope in events {
            guard let contract = taskContract(from: envelope.event) else {
                continue
            }
            record(contract)
        }
        return result
    }

    private static func requireRootBinding(
        taskID: TaskID,
        submissionID: SubmissionID,
        agentID: AgentID,
        bindings: [TaskID: Set<RootBinding>]
    ) throws {
        let binding = try uniqueRootBinding(
            taskID: taskID,
            bindings: bindings)
        guard binding == RootBinding(
                  submissionID: submissionID,
                  assignee: agentID) else {
            throw AgentModelHistoryProjectionError.ambiguousRootBinding(
                taskID)
        }
    }

    private static func uniqueRootBinding(
        taskID: TaskID,
        bindings: [TaskID: Set<RootBinding>]
    ) throws -> RootBinding {
        let candidates = bindings[taskID] ?? []
        guard candidates.count == 1,
              let binding = candidates.first else {
            throw AgentModelHistoryProjectionError.ambiguousRootBinding(
                taskID)
        }
        return binding
    }

    private static func taskContract(from event: Event) -> TaskContract? {
        switch event {
        case .taskCreated(let payload):
            return payload.contract
        case .taskAssigned(let payload):
            return payload.contract
        case .taskQueued(let payload):
            return payload.contract
        case .taskDelegated(let payload):
            return payload.contract
        case .delegationApproved(let payload):
            return payload.contract
        case .taskRejected(let payload):
            return payload.contract
        default:
            return nil
        }
    }
}

public enum AgentModelHistoryProjectionError:
    Error, Equatable, Sendable, LocalizedError
{
    case missingAcceptedSubmission(SubmissionID)
    case conflictingAcceptedSubmission(SubmissionID)
    case ambiguousRootBinding(TaskID)
    case unsupportedSchema(itemID: String, version: Int)
    case unsupportedCheckpointSchema(sequence: Int, version: Int)
    case invalidCheckpoint(sequence: Int, reason: String)
    case conflictingItemID(String)
    case invalidItem(String, String)
    case missingUserItem(SubmissionID)
    case ambiguousCallID(String)
    case conflictingOutput(String)
    case mediaBindingsRequireProjectionState

    public var errorDescription: String? {
        switch self {
        case .missingAcceptedSubmission(let submissionID):
            return "Model history has no accepted user submission \(submissionID.rawValue)."
        case .conflictingAcceptedSubmission(let submissionID):
            return "Accepted user submission \(submissionID.rawValue) has conflicting durable payloads."
        case .ambiguousRootBinding(let taskID):
            return "Model history root task \(taskID.rawValue) has no unique durable submission/agent binding."
        case .unsupportedSchema(let itemID, let version):
            return "Model history item \(itemID) uses unsupported schema version \(version)."
        case .unsupportedCheckpointSchema(let sequence, let version):
            return "Model history checkpoint at sequence \(sequence) uses unsupported schema version \(version)."
        case .invalidCheckpoint(let sequence, let reason):
            return "Model history checkpoint at sequence \(sequence) is invalid: \(reason)."
        case .conflictingItemID(let itemID):
            return "Model history item ID \(itemID) was reused with conflicting payloads."
        case .invalidItem(let itemID, let reason):
            return "Model history item \(itemID) is invalid: \(reason)."
        case .missingUserItem(let submissionID):
            return "Model history for submission \(submissionID.rawValue) has no durable user item."
        case .ambiguousCallID(let callID):
            return "Model history reused tool call ID \(callID) within one provider turn."
        case .conflictingOutput(let callID):
            return "Model history contains multiple outputs for tool call ID \(callID)."
        case .mediaBindingsRequireProjectionState:
            return "Model history contains durable image bindings; use projectState so media cannot be silently discarded."
        }
    }
}
