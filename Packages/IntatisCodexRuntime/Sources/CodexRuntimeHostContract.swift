/// Machine-readable identity for the source-compatible host surface exported
/// by the `IntatisCodexRuntime` Swift package product.
///
/// Other Vitemis projects should depend on that product and use only the v1
/// symbols documented in `docs/CODEX_RUNTIME_INTEGRATION.md`. The App Server
/// protocol, process owner, and agent loop are not reimplemented here; this is
/// only the compatibility identity for the existing thin official host.
public enum CodexRuntimeHostContract {
    /// Increment only when a documented v1 host declaration is removed,
    /// renamed, or changed in a source-incompatible way.
    public static let publicAPIMajorVersion = 1

    /// Stable SwiftPM identities used by downstream source packages.
    public static let packageName = "Intatis"
    public static let productName = "IntatisCodexRuntime"
    public static let moduleName = "IntatisCodexRuntime"

    /// Exact external runtime identity accepted by this host build. This is
    /// intentionally separate from the public Swift API major version.
    public static var pinnedRuntimeVersion: String {
        CodexRuntimeExecutable.pinnedVersion
    }

    public static var pinnedRuntimeDerivationID: String {
        CodexRuntimeExecutable.pinnedDerivationID
    }
}
