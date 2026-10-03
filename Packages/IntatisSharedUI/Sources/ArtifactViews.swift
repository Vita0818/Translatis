#if canImport(SwiftUI)
import SwiftUI
import IntatisConversation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// UI model for an artifact (built from `artifact_added` events). Kept in the UI
/// layer so SharedUI needn't depend on the Artifacts or Multimodal modules.
public struct ArtifactCardInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let mime: String
    public let path: String      // absolute
    public let prompt: String?
    public init(id: String, kind: String, mime: String, path: String, prompt: String?) {
        self.id = id
        self.kind = kind
        self.mime = mime
        self.path = path
        self.prompt = prompt
    }
}

/// Right-pane artifact list: image previews, transcript text, and a labeled row
/// for other kinds (ARCHITECTURE.md §3 inspector).
public struct ArtifactInspector: View {
    private let artifacts: [ArtifactCardInfo]
    private let progress: [ArtifactProgressSnapshot]

    public init(artifacts: [ArtifactCardInfo], progress: [ArtifactProgressSnapshot] = []) {
        self.artifacts = artifacts
        self.progress = progress
    }

    public var body: some View {
        if artifacts.isEmpty && progress.isEmpty {
            Text("No artifacts yet").font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
        } else {
            ForEach(progress) { ArtifactProgressRow(progress: $0) }
            ForEach(artifacts) { ArtifactCardView(artifact: $0) }
        }
    }
}

struct ArtifactProgressRow: View {
    let progress: ArtifactProgressSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(localizedState).font(IntatisTypography.system(.caption, bold: true))
                Spacer(minLength: 6)
                Text("\(Int(clampedProgress * 100))%")
                    .font(IntatisTypography.system(.caption))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: clampedProgress)
        }
        .padding(8)
        .intatisContentSurface(cornerRadius: 8)
    }

    private var clampedProgress: Double {
        min(max(progress.progress, 0), 1)
    }

    private var localizedState: String {
        switch progress.state.lowercased() {
        case "queued": return IntatisLocalization.string("queued")
        case "running": return IntatisLocalization.string("running")
        case "completed": return IntatisLocalization.string("completed")
        case "failed": return IntatisLocalization.string("failed")
        case "cancelled": return IntatisLocalization.string("cancelled")
        default: return progress.state
        }
    }
}

struct ArtifactCardView: View {
    let artifact: ArtifactCardInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(localizedKind).font(IntatisTypography.system(.caption, bold: true))
            content
            if let prompt = artifact.prompt {
                Text(prompt).font(IntatisTypography.system(.caption2)).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(8)
        .intatisContentSurface(cornerRadius: 8)
    }

    @ViewBuilder private var content: some View {
        switch artifact.kind {
        case "image":
            imagePreview
        case "transcript":
            Text(fileText).font(IntatisTypography.system(.caption)).textSelection(.enabled).lineLimit(8)
        default:
            Text(artifact.mime).font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var imagePreview: some View {
        #if canImport(AppKit)
        if let image = NSImage(contentsOfFile: artifact.path) {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("(image unavailable)").font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
        }
        #elseif canImport(UIKit)
        if let image = UIImage(contentsOfFile: artifact.path) {
            Image(uiImage: image).resizable().scaledToFit()
                .frame(maxHeight: 180).clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Text("(image unavailable)").font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
        }
        #else
        Text("(image)").font(IntatisTypography.system(.caption)).foregroundStyle(.secondary)
        #endif
    }

    private var localizedKind: String {
        switch artifact.kind.lowercased() {
        case "image": return IntatisLocalization.string("image")
        case "transcript": return IntatisLocalization.string("transcript")
        default: return artifact.kind
        }
    }

    private var fileText: String {
        (try? String(contentsOfFile: artifact.path, encoding: .utf8))
            ?? IntatisLocalization.string("(transcript)")
    }
}
#endif
