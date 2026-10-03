import Foundation
import IntatisCore
import IntatisConversation

/// Backend-only control for the verbose Code/Cowork execution transcript.
///
/// The EventLog and projections always retain the complete execution history.
/// This policy only decides which projected items reach the conversation UI.
/// The default path also reduces exact App Server lifecycle notifications into
/// localized-UI-neutral semantic activities; enabling the trace restores the
/// original method/scalar rows without changing durable facts.
public enum IntatisExecutionTracePresentation {
    public static var launchArgument: String {
        "-" + IntatisHostApplication.identity.storageName
            + "ShowExecutionTrace"
    }
    public static var environmentVariable: String {
        IntatisHostApplication.identity.environmentVariable(
            "SHOW_EXECUTION_TRACE")
    }

    /// Defaults to `false`. This is intentionally not backed by UserDefaults or
    /// exposed through a settings control; changing it requires a new process.
    public static var isEnabled: Bool {
        resolve(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment)
    }

    public static func resolve(
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        if arguments.contains(launchArgument) {
            return true
        }

        guard let rawValue = environment[environmentVariable] else {
            return false
        }
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on", "enabled":
            return true
        default:
            return false
        }
    }

    public static func displayedItems(_ items: [CodeItem]) -> [CodeItem] {
        displayedItems(items, showExecutionTrace: isEnabled)
    }

    public static func displayedItems(
        _ items: [CodeItem],
        showExecutionTrace: Bool
    ) -> [CodeItem] {
        guard !showExecutionTrace else { return items }
        let conversationItems = items.filter(
            \.isDefaultConversationPresentationItem)
        return CodexActivityPresentationReducer.displayedItems(
            conversationItems)
    }
}
