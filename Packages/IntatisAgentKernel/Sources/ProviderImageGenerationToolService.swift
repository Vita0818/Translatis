import Foundation
import IntatisCore
import IntatisProviders
import IntatisTools

/// Bridges the generic image tools to the configured provider catalog without
/// making IntatisTools depend on provider code.
public struct ProviderImageGenerationToolService: ImageGenerationToolService {
    private let registry: ProviderRegistry

    public init(registry: ProviderRegistry) {
        self.registry = registry
    }

    public func generateImage(prompt: String,
                              size: String,
                              count: Int,
                              outputPath: String,
                              workspaceRoot: URL) async throws -> ToolObservation {
        guard let provider = try await registry.defaultImageProvider(),
              let model = await registry.imageModel() else {
            throw IntatisError.config("image generation is not configured")
        }

        let outputURL = try PathConfinement.resolve(outputPath, within: workspaceRoot)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let images = try await provider.generate(ImageRequest(model: model, prompt: prompt, size: size, n: count))
        guard !images.isEmpty else {
            throw IntatisError.provider("image provider returned no images")
        }

        var changed: [String] = []
        for (index, image) in images.enumerated() {
            let url = images.count == 1 ? outputURL : numberedURL(outputURL, index: index + 1)
            try image.data.write(to: url, options: .atomic)
            changed.append(PathConfinement.relativePath(of: url, root: workspaceRoot))
        }

        return ToolObservation(
            text: "generated \(images.count) image(s) with \(model.rawValue): \(changed.joined(separator: ", "))",
            changedFiles: changed)
    }

    public func editImage(image: Data,
                          filename: String,
                          mime: String,
                          prompt: String,
                          outputPath: String,
                          workspaceRoot: URL) async throws -> ToolObservation {
        guard let provider = try await registry.defaultImageEditingProvider(),
              let model = await registry.imageModel() else {
            throw IntatisError.config("image editing is not configured")
        }

        let outputURL = try PathConfinement.resolve(outputPath, within: workspaceRoot)
        let edited = try await provider.edit(ImageEditRequest(
            model: model,
            prompt: prompt,
            image: image,
            filename: filename,
            mime: mime))
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try edited.data.write(to: outputURL, options: .atomic)

        let changed = PathConfinement.relativePath(of: outputURL, root: workspaceRoot)
        return ToolObservation(
            text: "edited image with \(model.rawValue): \(changed)",
            changedFiles: [changed])
    }

    private func numberedURL(_ url: URL, index: Int) -> URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let directory = url.deletingLastPathComponent()
        let suffix = String(format: "%02d", index)
        let filename = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        return directory.appendingPathComponent(filename)
    }
}
