import Foundation

/// Stable identities and discovery roots for host-authored, product-bundled
/// Skills. These resources remain contextual instructions: discovering or
/// activating one never grants a tool, lease, workspace, or permission.
public enum IntatisBundledSkills {
    public static let coworkAgentOrchestrationName =
        "cowork-agent-orchestration"

    /// SwiftPM copies `BundledSkills` as one directory in the IntatisSkills
    /// resource bundle. Returning an empty list is the fail-closed behavior for
    /// a malformed product bundle; the Cowork system prompt then applies its
    /// conservative no-spawn fallback.
    public static let discoveryRoots: [URL] = {
        guard let root = Bundle.module.url(
            forResource: "BundledSkills",
            withExtension: nil)
        else {
            return []
        }
        return [root]
    }()
}
