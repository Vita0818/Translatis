#if os(macOS) && canImport(SwiftUI)
import SwiftUI
import UniformTypeIdentifiers

/// The macOS composer attachment control shared verbatim by Chat and Cowork.
/// Surface-specific code supplies only the current draft and its callbacks.
public struct IntatisMacComposerAttachmentAccessory: View {
    let attachments: [IntatisComposerDraftAttachment]
    let accessibilityPrefix: String
    var isBusy = false
    var isDisabled = false
    let onAttach: () -> Void
    let onRemove: (IntatisComposerDraftAttachment.ID) -> Void

    public init(
        attachments: [IntatisComposerDraftAttachment],
        accessibilityPrefix: String,
        isBusy: Bool = false,
        isDisabled: Bool = false,
        onAttach: @escaping () -> Void,
        onRemove:
            @escaping (IntatisComposerDraftAttachment.ID) -> Void
    ) {
        self.attachments = attachments
        self.accessibilityPrefix = accessibilityPrefix
        self.isBusy = isBusy
        self.isDisabled = isDisabled
        self.onAttach = onAttach
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(
            alignment: .center,
            spacing: IntatisComposerControlMetrics.rowSpacing
        ) {
            Button(action: onAttach) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .frame(
                            width: IntatisComposerControlMetrics.iconLabelExtent,
                            height: IntatisComposerControlMetrics.iconLabelExtent)
                } else {
                    Label(
                        IntatisLocalization.string("Attach files"),
                        systemImage: "paperclip")
                        .intatisComposerIconLabel()
                }
            }
            .intatisCompactIconButton()
            .help(IntatisLocalization.string("Attach files"))
            .accessibilityLabel(IntatisLocalization.string("Attach files"))
            .accessibilityIdentifier("\(accessibilityPrefix).composer.attach")
            .disabled(isDisabled || isBusy)

            if !attachments.isEmpty {
                Menu {
                    ForEach(attachments) { attachment in
                        Button(IntatisLocalization.format(
                            "Remove %@",
                            attachment.name)) {
                            onRemove(attachment.id)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(IntatisLocalization.format(
                            "%lld attached",
                            Int64(attachments.count)))
                            .font(IntatisTypography.body(13, .semibold))
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.down")
                            .font(IntatisTypography.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .intatisComposerSelectionLabel()
                }
                .intatisComposerSelectionMenu()
                .accessibilityIdentifier(
                    "\(accessibilityPrefix).composer.attachments")
                .disabled(isDisabled || isBusy)
            }
        }
        .frame(
            minHeight: IntatisComposerControlMetrics.controlHeight,
            alignment: .center)
    }
}

private struct IntatisMacComposerAttachmentImportModifier: ViewModifier {
    @Binding var isPresented: Bool
    let onImport: ([URL]) -> Void
    let onFailure: (Error) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.data, .content],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    onImport(urls)
                case .failure(let error):
                    onFailure(error)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty else { return false }
                onImport(urls)
                return true
            }
    }
}

public extension View {
    func intatisComposerAttachmentImport(
        isPresented: Binding<Bool>,
        onImport: @escaping ([URL]) -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> some View {
        modifier(IntatisMacComposerAttachmentImportModifier(
            isPresented: isPresented,
            onImport: onImport,
            onFailure: onFailure))
    }
}
#endif
