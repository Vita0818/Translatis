import Foundation
import IntatisCore

/// Product-owned naming used by new Knowledge files and identities. The
/// shared Swift implementation remains Intatis; an embedding host installs a
/// different application identity before constructing Knowledge services.
enum KnowledgeHostIdentity {
    static var host: IntatisHostApplicationIdentity {
        IntatisHostApplication.identity
    }

    static var stem: String { host.fileNameStem }
    static var bundleDirectory: String {
        host.knowledgeBundleDirectoryName
    }
    static var storeFile: String { host.knowledgeStoreFileName }
    static var snapshotsDirectory: String {
        host.knowledgeSnapshotsDirectoryName
    }
    static var hostDirectory: String { host.knowledgeHostDirectoryName }

    static func bundlePath(_ suffix: String) -> String {
        bundleDirectory + "/" + suffix
    }

    static func schema(_ suffix: String) -> String {
        stem + "-" + suffix
    }

    static func namespaced(_ suffix: String) -> String {
        host.namespacedIdentifier(suffix)
    }

    static func reverseDomain(_ suffix: String) -> String {
        "org.vita." + stem + "." + suffix
    }

    static func localSchemaURL(_ suffix: String) -> String {
        "https://schemas." + stem + ".local/" + suffix
    }
}
