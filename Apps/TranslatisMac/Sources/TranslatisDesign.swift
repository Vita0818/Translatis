//
//  TranslatisDesign.swift
//  TranslatisMac
//
//  Translatis delegates its palette to macOS. The window canvas, content material,
//  separators, accent, and Liquid Glass all remain dynamic system resources;
//  no sampled or fixed light/dark background values live here.
//

#if canImport(SwiftUI)
import SwiftUI
import IntatisSharedUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Color tokens

enum TranslatisTheme {
    static func deepText(_: ColorScheme) -> Color { .primary }
    static func softText(_: ColorScheme) -> Color { .secondary }
    static func tertiaryText(_: ColorScheme) -> Color { .secondary.opacity(0.72) }
    static func accent(_: ColorScheme) -> Color { .accentColor }

    static func separator(_: ColorScheme) -> Color {
        #if canImport(AppKit)
        return Color(nsColor: .separatorColor)
        #else
        return .secondary.opacity(0.28)
        #endif
    }

    static func selectedStroke(_: ColorScheme) -> Color {
        .accentColor.opacity(0.72)
    }
}

/// The native window surface. On current systems SwiftUI resolves
/// `windowBackground` from the active appearance, wallpaper tint, contrast,
/// transparency, and window state rather than from a fixed RGB value.
struct TranslatisSystemCanvas: View {
    @ViewBuilder var body: some View {
        if #available(macOS 14.0, *) {
            Rectangle().fill(.windowBackground)
        } else {
            legacyWindowBackground
        }
    }

    @ViewBuilder private var legacyWindowBackground: some View {
        #if canImport(AppKit)
        IntatisLegacyWindowBackground()
        #else
        Rectangle().fill(.background)
        #endif
    }
}

#if canImport(AppKit)
/// macOS 13 fallback for the same semantic window material.
private struct IntatisLegacyWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
#endif

// MARK: - Typography

/// Compatibility name for existing macOS call sites. The role definitions
/// live in SharedUI so iOS Chat uses the same nominal sizes, weights and font
/// designs while applying its own Dynamic Type scaling.
typealias TranslatisType = IntatisTypography

extension IntatisThreadStyle {
    static func translatisMac(_ scheme: ColorScheme) -> IntatisThreadStyle {
        IntatisThreadStyle(
            primaryText: TranslatisTheme.deepText(scheme),
            secondaryText: TranslatisTheme.softText(scheme),
            tertiaryText: TranslatisTheme.tertiaryText(scheme),
            accent: TranslatisTheme.accent(scheme),
            stroke: TranslatisTheme.separator(scheme),
            cardStroke: TranslatisTheme.separator(scheme),
            error: .red)
    }
}

// MARK: - Native content surfaces

private struct IntatisCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(.regularMaterial, in: shape)
            .overlay {
                shape.stroke(TranslatisTheme.separator(scheme), lineWidth: 1)
            }
    }
}

extension View {
    func translatisCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(IntatisCardModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Shared header

/// Page header: a serif title plus a system-secondary subtitle.
struct TranslatisPageHeader: View {
    let title: String
    var subtitle: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(TranslatisType.largeTitle(30))
                .foregroundStyle(TranslatisTheme.deepText(scheme))
            if let subtitle {
                Text(subtitle)
                    .font(TranslatisType.caption(13, .medium))
                    .foregroundStyle(TranslatisTheme.softText(scheme))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
