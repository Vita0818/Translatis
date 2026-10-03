import Foundation
import IntatisProtocol

public enum GoalInputParseError: Error, Equatable, Sendable {
    case empty
    case missingGoal

    public var message: String {
        switch self {
        case .empty:
            return "Enter a message."
        case .missingGoal:
            return "Enter a goal after /goal."
        }
    }
}

public struct ParsedUserInput: Equatable, Sendable {
    public static let goalTag = "Goal"

    public var text: String
    public var goal: String?
    public var tags: [String]

    public init(text: String, goal: String? = nil, tags: [String] = []) {
        self.text = text
        self.goal = goal
        self.tags = tags
    }

    public var isGoal: Bool { goal != nil }

    public var userMessagePayload: UserMessagePayload {
        UserMessagePayload(
            text: text,
            tags: tags.isEmpty ? nil : tags,
            goal: goal)
    }
}

public enum GoalInputParser {
    public static func parse(_ rawInput: String) -> Result<ParsedUserInput, GoalInputParseError> {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        guard startsWithGoalCommand(trimmed) else {
            return .success(ParsedUserInput(text: trimmed))
        }

        let afterCommand = String(trimmed.dropFirst("/goal".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterCommand.isEmpty else {
            return .failure(.missingGoal)
        }
        return .success(ParsedUserInput(
            text: afterCommand,
            goal: afterCommand,
            tags: [ParsedUserInput.goalTag]))
    }

    private static func startsWithGoalCommand(_ input: String) -> Bool {
        guard input.hasPrefix("/goal") else { return false }
        if input.count == "/goal".count { return true }
        let boundaryIndex = input.index(input.startIndex, offsetBy: "/goal".count)
        return input[boundaryIndex].isWhitespaceOrNewline
    }
}

private extension Character {
    var isWhitespaceOrNewline: Bool {
        unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
