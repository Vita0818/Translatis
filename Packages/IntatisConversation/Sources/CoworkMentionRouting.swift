import Foundation
import IntatisCore

public enum CoworkMentionRouteError: Error, Equatable, Sendable {
    case noAgents
    case emptyMessage
    case emptyMention
    case unknownMention(String)
    case invalidMention(String)
    case ambiguousMention(String, [AgentID])
    case ambiguousDefault([AgentID])

    public var message: String {
        switch self {
        case .noAgents:
            return "Add an agent before sending a Cowork message."
        case .emptyMessage:
            return "Enter a message before sending."
        case .emptyMention:
            return "Type an agent name after @."
        case .unknownMention(let name):
            return "No attached agent matches @\(name)."
        case .invalidMention(let name):
            return "@\(name) is not a valid agent name. Use ASCII letters, digits, '-' or '_'."
        case .ambiguousMention(let name, let agents):
            return "Ambiguous @\(name): " + agents.map { "@\($0.rawValue)" }.joined(separator: ", ")
        case .ambiguousDefault(let agents):
            return "Use @Name to choose an agent: " + agents.map { "@\($0.rawValue)" }.joined(separator: ", ")
        }
    }
}

public struct CoworkMentionRoute: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case send(text: String, target: AgentID)
        case blocked(CoworkMentionRouteError)
    }

    public var originalInput: String
    public var outcome: Outcome

    public init(originalInput: String, outcome: Outcome) {
        self.originalInput = originalInput
        self.outcome = outcome
    }
}

public enum CoworkMentionRouter {
    /// Freezes the user's requested route without consulting the live roster.
    /// A missing/unresolved target is an execution-admission failure after the
    /// immutable submission has been preserved, not a reason to discard Send.
    public static func routeSubmittedIntent(
        input: String,
        defaultTarget: AgentID
    ) -> CoworkMentionRoute {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.emptyMessage))
        }
        guard trimmed.hasPrefix("@") else {
            return CoworkMentionRoute(
                originalInput: input,
                outcome: .send(text: trimmed, target: defaultTarget))
        }

        let rest = trimmed.dropFirst()
        guard let first = rest.first, !first.isWhitespaceOrNewline else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.emptyMention))
        }
        let splitIndex = rest.firstIndex { $0.isWhitespaceOrNewline }
        let mention = String(splitIndex.map { rest[..<$0] } ?? rest[...])
        guard isValidFrozenAgentName(mention) else {
            return CoworkMentionRoute(
                originalInput: input,
                outcome: .blocked(.invalidMention(mention)))
        }
        let message: String
        if let splitIndex {
            let afterSpace = rest.index(after: splitIndex)
            message = String(rest[afterSpace...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = ""
        }
        guard !message.isEmpty else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.emptyMessage))
        }
        return CoworkMentionRoute(
            originalInput: input,
            outcome: .send(text: message, target: AgentID(rawValue: mention)))
    }

    public static func route(input: String, attachedAgents: [AgentID]) -> CoworkMentionRoute {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.emptyMessage))
        }
        guard !attachedAgents.isEmpty else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.noAgents))
        }

        if trimmed.hasPrefix("@") {
            return routeMention(trimmed, originalInput: input, attachedAgents: attachedAgents)
        }

        guard attachedAgents.count == 1, let target = attachedAgents.first else {
            return CoworkMentionRoute(originalInput: input, outcome: .blocked(.ambiguousDefault(attachedAgents)))
        }
        return CoworkMentionRoute(originalInput: input, outcome: .send(text: trimmed, target: target))
    }

    private static func routeMention(_ trimmed: String,
                                     originalInput: String,
                                     attachedAgents: [AgentID]) -> CoworkMentionRoute {
        let rest = trimmed.dropFirst()
        guard let first = rest.first, !first.isWhitespaceOrNewline else {
            return CoworkMentionRoute(originalInput: originalInput, outcome: .blocked(.emptyMention))
        }

        let splitIndex = rest.firstIndex { $0.isWhitespaceOrNewline }
        let mention = String(splitIndex.map { rest[..<$0] } ?? rest[...])
        guard !mention.isEmpty else {
            return CoworkMentionRoute(originalInput: originalInput, outcome: .blocked(.emptyMention))
        }

        let message: String
        if let splitIndex {
            let afterSpace = rest.index(after: splitIndex)
            message = String(rest[afterSpace...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            message = ""
        }
        guard !message.isEmpty else {
            return CoworkMentionRoute(originalInput: originalInput, outcome: .blocked(.emptyMessage))
        }

        switch resolveMention(mention, attachedAgents: attachedAgents) {
        case .success(let target):
            return CoworkMentionRoute(originalInput: originalInput, outcome: .send(text: message, target: target))
        case .failure(let error):
            return CoworkMentionRoute(originalInput: originalInput, outcome: .blocked(error))
        }
    }

    private static func resolveMention(_ mention: String,
                                       attachedAgents: [AgentID]) -> Result<AgentID, CoworkMentionRouteError> {
        let exact = attachedAgents.filter { $0.rawValue == mention }
        if exact.count == 1, let target = exact.first {
            return .success(target)
        }
        if exact.count > 1 {
            return .failure(.ambiguousMention(mention, exact))
        }

        let folded = mention.lowercased()
        let caseInsensitive = attachedAgents.filter { $0.rawValue.lowercased() == folded }
        if caseInsensitive.count == 1, let target = caseInsensitive.first {
            return .success(target)
        }
        if caseInsensitive.count > 1 {
            return .failure(.ambiguousMention(mention, caseInsensitive))
        }
        return .failure(.unknownMention(mention))
    }

    private static func isValidFrozenAgentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              isASCIIAlphaNumeric(first) else { return false }
        return name.unicodeScalars.allSatisfy {
            isASCIIAlphaNumeric($0) || $0.value == 45 || $0.value == 95
        }
    }

    private static func isASCIIAlphaNumeric(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            return true
        default:
            return false
        }
    }
}

private extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
