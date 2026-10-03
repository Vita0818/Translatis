import Foundation
import IntatisCore

/// The data-plane effect of one concrete tool invocation. This is deliberately
/// separate from control-plane mutations and from crash replay policy.
public enum PermissionDataEffect: String, Codable, Equatable, Sendable, Hashable {
    case none
    case read
    case mutate
    case execute
    case network
    case destructive
}

/// A control-plane mutation performed by a tool. These operations may append
/// events or change the Cowork roster/task graph without writing workspace files.
public enum PermissionControlEffect: String, Codable, Equatable, Sendable, Hashable {
    case message
    case createTask = "create_task"
    case updateTask = "update_task"
    case cancelTask = "cancel_task"
    case delegateTask = "delegate_task"
    case createAgent = "create_agent"
    case removeAgent = "remove_agent"
    case attachWorkspace = "attach_workspace"
    case grantCapability = "grant_capability"
    case editGoal = "edit_goal"
    case pauseGoal = "pause_goal"
    case resumeGoal = "resume_goal"
    case clearGoal = "clear_goal"
    case submitGoalVerdict = "submit_goal_verdict"
    case closeRun = "close_run"
}

public enum PermissionRisk: String, Codable, Equatable, Sendable, Hashable {
    case workspaceMutation = "workspace_mutation"
    case processExecution = "process_execution"
    case networkAccess = "network_access"
    case destructive
    case controlPlaneMutation = "control_plane_mutation"
    case capabilityGrant = "capability_grant"
    case workspaceExpansion = "workspace_expansion"
    case modelCost = "model_cost"
}

public struct PermissionResource: Codable, Equatable, Sendable, Hashable {
    public enum Kind: String, Codable, Equatable, Sendable, Hashable {
        case workspacePath = "workspace_path"
        case workspace
        case agent
        case task
        case goal
        case command
        case url
        case git
        case artifact
        case tool
    }

    public var kind: Kind
    public var value: String
    public var access: WorkspaceAccess?

    public init(kind: Kind, value: String, access: WorkspaceAccess? = nil) {
        self.kind = kind
        self.value = value
        self.access = access
    }
}

/// Structured authorization input for one invocation. CapabilityLease controls
/// whether the tool is visible, WorkspaceLease is the maximum authority ceiling,
/// and this value describes only the operation currently being authorized.
public struct PermissionIntent: Codable, Equatable, Sendable {
    public static let structuredReadOnlyExecutionClass = "structured_read_only"

    public var action: String
    public var resources: [PermissionResource]
    public var metadata: [String: JSONValue]
    public var dataEffects: Set<PermissionDataEffect>
    public var controlEffects: Set<PermissionControlEffect>
    public var risks: Set<PermissionRisk>
    public var suggestedPersistentRules: [String]
    public var replayPolicy: ToolExecutionReplayPolicy

    public init(action: String,
                resources: [PermissionResource],
                metadata: [String: JSONValue] = [:],
                dataEffects: Set<PermissionDataEffect> = [.none],
                controlEffects: Set<PermissionControlEffect> = [],
                risks: Set<PermissionRisk> = [],
                suggestedPersistentRules: [String] = [],
                replayPolicy: ToolExecutionReplayPolicy) {
        self.action = action
        self.resources = resources
        self.metadata = metadata
        self.dataEffects = dataEffects.isEmpty ? [.none] : dataEffects
        self.controlEffects = controlEffects
        self.risks = risks
        self.suggestedPersistentRules = suggestedPersistentRules
        self.replayPolicy = replayPolicy
    }

    /// Whether the concrete invocation is compatible with a read-only
    /// WorkspaceLease. Control-plane changes are intentionally not considered
    /// workspace writes; they are reviewed through `controlEffects` and risks.
    public var isReadOnlyWorkspaceCompatible: Bool {
        dataEffects.allSatisfy { $0 == .none || $0 == .read }
            || isStructuredReadOnlyExecution
    }

    /// A host-owned parser/OCR process can observe workspace data without
    /// receiving arbitrary shell or mutation authority. The marker lives in
    /// the host-built intent; model arguments cannot set it.
    public var isStructuredReadOnlyExecution: Bool {
        guard case .string(let executionClass)? = metadata["execution_class"],
              executionClass == Self.structuredReadOnlyExecutionClass,
              dataEffects.contains(.execute),
              dataEffects.allSatisfy({
                  $0 == .none || $0 == .read || $0 == .execute
              }),
              controlEffects.isEmpty,
              resources.allSatisfy({ $0.access != .readWrite }),
              risks.isDisjoint(with: [
                  .workspaceMutation,
                  .networkAccess,
                  .destructive,
                  .capabilityGrant,
                  .workspaceExpansion,
              ]) else {
            return false
        }
        return true
    }

    /// Compatibility adapter for tools that have not provided richer metadata.
    /// Every shipped tool still receives an action/resource intent immediately;
    /// individual tools can override it with more exact semantics.
    public static func derived(toolName: String,
                               sideEffect: SideEffect,
                               touchedPaths: [String],
                               risksNetwork: Bool) -> PermissionIntent {
        var dataEffects: Set<PermissionDataEffect>
        var risks: Set<PermissionRisk> = []
        switch sideEffect {
        case .readOnly:
            dataEffects = [.read]
        case .write:
            dataEffects = [.mutate]
            risks.insert(.workspaceMutation)
        case .exec:
            dataEffects = [.execute]
            risks.insert(.processExecution)
        case .network:
            dataEffects = [.network]
            risks.insert(.networkAccess)
        case .destructive:
            dataEffects = [.destructive]
            risks.insert(.destructive)
        }
        if risksNetwork {
            dataEffects.insert(.network)
            risks.insert(.networkAccess)
        }
        let resources = touchedPaths.isEmpty
            ? [PermissionResource(kind: .tool, value: toolName)]
            : touchedPaths.map { PermissionResource(kind: .workspacePath, value: $0) }
        return PermissionIntent(
            action: defaultAction(toolName: toolName, sideEffect: sideEffect),
            resources: resources,
            metadata: ["tool": .string(toolName)],
            dataEffects: dataEffects,
            risks: risks,
            replayPolicy: .conservative(for: sideEffect, tool: toolName))
    }

    private static func defaultAction(toolName: String, sideEffect: SideEffect) -> String {
        switch toolName {
        case "read_file", "list_files", "search_text": return "filesystem.read"
        case "write_file", "apply_patch": return "filesystem.edit"
        case "inspect_pdf": return "document.inspect.pdf"
        case "read_pdf": return "document.read.pdf"
        case "document_read": return "document.read" // Legacy only.
        case "read_docx": return "document.read.docx"
        case "continue_docx_read": return "document.read.docx.continue"
        case "read_pptx": return "document.read.pptx"
        case "continue_pptx_read": return "document.read.pptx.continue"
        case "read_xlsx": return "document.read.xlsx"
        case "continue_xlsx_read": return "document.read.xlsx.continue"
        case "read_html": return "document.read.html"
        case "continue_html_read": return "document.read.html.continue"
        case "read_epub": return "document.read.epub"
        case "continue_epub_read": return "document.read.epub.continue"
        case "document_ocr": return "document.ocr" // Legacy only.
        case "ocr_pdf": return "document.ocr.pdf"
        case "document_render": return "document.render" // Legacy only.
        case "pdf_render_page": return "document.render.pdf.page"
        case "document_export_pdf": return "document.export.pdf" // Legacy only.
        case "docx_export_pdf": return "document.export.docx.pdf"
        case "pptx_export_pdf": return "document.export.pptx.pdf"
        case "xlsx_export_pdf": return "document.export.xlsx.pdf"
        case "html_export_pdf": return "document.export.html.pdf"
        case "document_write": return "document.write" // Legacy only.
        case "compile_latex": return "document.compile.latex"
        case "generate_image": return "media.generate"
        case "edit_image": return "media.edit"
        case "web_fetch": return "network.fetch"
        case "run_shell": return "process.execute"
        default:
            if toolName.hasPrefix("docx_")
                || toolName.hasPrefix("pptx_")
                || toolName.hasPrefix("xlsx_") {
                return "document.write."
                    + toolName.replacingOccurrences(of: "_", with: ".")
            }
            if toolName.hasPrefix("git_") {
                return "git." + String(toolName.dropFirst(4)).replacingOccurrences(of: "_", with: ".")
            }
            if toolName.hasPrefix("browser_") {
                return "browser." + String(toolName.dropFirst(8)).replacingOccurrences(of: "_", with: ".")
            }
            switch sideEffect {
            case .readOnly: return "tool.observe"
            case .write: return "filesystem.edit"
            case .exec: return "process.execute"
            case .network: return "network.access"
            case .destructive: return "resource.destroy"
            }
        }
    }
}
