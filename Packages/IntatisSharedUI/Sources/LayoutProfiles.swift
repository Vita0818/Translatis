#if canImport(SwiftUI)
import SwiftUI

private struct IntatisWindowContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

public extension EnvironmentValues {
    /// Width of the complete app-window content canvas when a host can prove
    /// it. Standalone previews and fixtures intentionally fall back to nil.
    var intatisWindowContentWidth: CGFloat? {
        get { self[IntatisWindowContentWidthKey.self] }
        set { self[IntatisWindowContentWidthKey.self] = newValue }
    }
}

/// Places an overlay on the full app-window horizontal midpoint while the
/// overlay itself remains owned by a leading detail/thread surface.
public enum IntatisWindowCenteredOverlayLayoutPolicy {
    public static func horizontalOffset(
        windowWidth rawWindowWidth: CGFloat?,
        detailWidth rawDetailWidth: CGFloat,
        overlaySurfaceWidth rawOverlaySurfaceWidth: CGFloat
    ) -> CGFloat {
        guard let rawWindowWidth,
              rawWindowWidth.isFinite,
              rawWindowWidth > 0,
              rawDetailWidth.isFinite,
              rawDetailWidth > 0,
              rawOverlaySurfaceWidth.isFinite,
              rawOverlaySurfaceWidth > 0,
              rawWindowWidth >= rawDetailWidth,
              rawDetailWidth >= rawOverlaySurfaceWidth
        else {
            return 0
        }

        return rawDetailWidth
            - rawWindowWidth / 2
            - rawOverlaySurfaceWidth / 2
    }
}

public struct IntatisSplitColumnLayout: Equatable {
    public var sidebarMin: CGFloat
    public var sidebarIdeal: CGFloat
    public var contentMin: CGFloat
    public var contentIdeal: CGFloat
    public var detailMin: CGFloat
    public var detailIdeal: CGFloat

    public init(sidebarMin: CGFloat,
                sidebarIdeal: CGFloat,
                contentMin: CGFloat,
                contentIdeal: CGFloat,
                detailMin: CGFloat,
                detailIdeal: CGFloat) {
        self.sidebarMin = sidebarMin
        self.sidebarIdeal = sidebarIdeal
        self.contentMin = contentMin
        self.contentIdeal = contentIdeal
        self.detailMin = detailMin
        self.detailIdeal = detailIdeal
    }

    public static let chatInspector = IntatisSplitColumnLayout(
        sidebarMin: 160,
        sidebarIdeal: 210,
        contentMin: 300,
        contentIdeal: 560,
        detailMin: 210,
        detailIdeal: 300)

    public static let workspace = IntatisSplitColumnLayout(
        sidebarMin: 150,
        sidebarIdeal: 200,
        contentMin: 320,
        contentIdeal: 600,
        detailMin: 220,
        detailIdeal: 300)
}

/// Resolves a workspace thread and its status rail from one stable, outer
/// width proposal. The status rail never measures its already-compressed
/// thread column to decide whether it should exist; doing so creates a
/// presentation feedback loop around the activation threshold.
public struct IntatisWorkspaceInspectorLayout: Equatable {
    public let isVisible: Bool
    public let threadWidth: CGFloat
    public let inspectorWidth: CGFloat

    public init(
        isVisible: Bool,
        threadWidth: CGFloat,
        inspectorWidth: CGFloat
    ) {
        self.isVisible = isVisible
        self.threadWidth = threadWidth
        self.inspectorWidth = inspectorWidth
    }
}

public enum IntatisWorkspaceInspectorLayoutPolicy {
    public static func resolve(
        availableWidth rawAvailableWidth: CGFloat,
        isRequested: Bool,
        activationWidth: CGFloat,
        minimumThreadWidth: CGFloat,
        minimumInspectorWidth: CGFloat,
        idealInspectorWidth: CGFloat,
        maximumInspectorWidth: CGFloat,
        dividerWidth: CGFloat = 1
    ) -> IntatisWorkspaceInspectorLayout {
        let availableWidth = rawAvailableWidth.isFinite
            ? max(rawAvailableWidth, 1)
            : 1
        let normalizedDividerWidth = dividerWidth.isFinite
            ? max(dividerWidth, 0)
            : 0

        guard isRequested,
              availableWidth >= activationWidth,
              availableWidth
                >= minimumThreadWidth
                    + minimumInspectorWidth
                    + normalizedDividerWidth
        else {
            return IntatisWorkspaceInspectorLayout(
                isVisible: false,
                threadWidth: availableWidth,
                inspectorWidth: 0)
        }

        let inspectorCeiling = max(
            minimumInspectorWidth,
            min(
                maximumInspectorWidth,
                availableWidth
                    - minimumThreadWidth
                    - normalizedDividerWidth))
        let inspectorWidth = min(
            max(idealInspectorWidth, minimumInspectorWidth),
            inspectorCeiling)
        return IntatisWorkspaceInspectorLayout(
            isVisible: true,
            threadWidth: max(
                availableWidth
                    - inspectorWidth
                    - normalizedDividerWidth,
                1),
            inspectorWidth: inspectorWidth)
    }
}

/// Cowork's trailing status rail has one geometry owner: the stable outer
/// detail width. Its width never depends on the selected agent, transcript
/// length, card content, or whether a vertical scroller is currently visible.
public enum IntatisCoworkStatusRailLayoutPolicy {
    public static let activationWidth: CGFloat = 980
    public static let minimumThreadWidth: CGFloat = 620
    public static let railWidth: CGFloat = 348
    public static let scrollerClearance: CGFloat = 10
    public static let leadingInset: CGFloat = 6
    public static let trailingInset: CGFloat = 14
    public static let cardSpacing: CGFloat = 18

    public static var cardWidth: CGFloat {
        max(
            railWidth
                - scrollerClearance
                - leadingInset
                - trailingInset,
            1)
    }

    public static func resolve(
        availableWidth: CGFloat,
        isRequested: Bool
    ) -> IntatisWorkspaceInspectorLayout {
        IntatisWorkspaceInspectorLayoutPolicy.resolve(
            availableWidth: availableWidth,
            isRequested: isRequested,
            activationWidth: activationWidth,
            minimumThreadWidth: minimumThreadWidth,
            minimumInspectorWidth: railWidth,
            idealInspectorWidth: railWidth,
            maximumInspectorWidth: railWidth,
            dividerWidth: 0)
    }
}

public struct ThreeColumnShellLayout: Equatable {
    public enum Presentation: Equatable {
        case split
        case threadOnly
    }

    public var presentation: Presentation
    public var columns: IntatisSplitColumnLayout

    public init(presentation: Presentation = .split,
                columns: IntatisSplitColumnLayout = .chatInspector) {
        self.presentation = presentation
        self.columns = columns
    }

    public static let split = ThreeColumnShellLayout()
    public static let iOSChat = ThreeColumnShellLayout(presentation: .threadOnly)
}
#endif
