import Foundation
import IntatisProviders

struct PendingImageAttachment {
    var name: String
    var data: Data
    var mime: String

    var providerAttachment: ImageAttachment {
        .base64(
            mime: mime,
            base64: data.base64EncodedString())
    }
}

/// Files queued for the next message: images become vision input; UTF-8 text
/// files are inlined as context.
struct PendingAttachments {
    var images: [PendingImageAttachment] = []
    var textFiles: [(name: String, content: String)] = []

    var isEmpty: Bool { images.isEmpty && textFiles.isEmpty }
    var count: Int { images.count + textFiles.count }
    mutating func clear() { images.removeAll(); textFiles.removeAll() }
}

enum LoadedAttachment {
    case image(PendingImageAttachment)
    case text(name: String, content: String)
    case failure(String)
}

enum AttachmentLoader {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp"]

    /// image → vision attachment; UTF-8 text → inline text block; else `.failure`.
    static func load(_ path: String) -> LoadedAttachment {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url) else { return .failure("cannot read \(path)") }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            let mime = (ext == "jpg") ? "image/jpeg" : "image/\(ext)"
            return .image(PendingImageAttachment(
                name: url.lastPathComponent,
                data: data,
                mime: mime))
        }
        if let text = String(data: data, encoding: .utf8) {
            return .text(name: url.lastPathComponent, content: text)
        }
        return .failure("unsupported file type '.\(ext)' (only images and UTF-8 text)")
    }
}
