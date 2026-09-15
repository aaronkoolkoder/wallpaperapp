import SwiftUI

private struct OffscreenRenderingKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the view tree is being drawn by `ImageRenderer` rather than by the compositor.
    var isOffscreenRendering: Bool {
        get { self[OffscreenRenderingKey.self] }
        set { self[OffscreenRenderingKey.self] = newValue }
    }
}

extension View {
    /// Liquid Glass where it can actually work, an equivalent material where it cannot.
    ///
    /// `.glassEffect()` draws **nothing at all** under `ImageRenderer` — it does not degrade to a
    /// plain surface, it swallows its content and renders an empty rectangle. Verified against a
    /// probe rendering a plain background and a glass one side by side: the plain one appears,
    /// the glass one is blank.
    ///
    /// That matters beyond aesthetics. Without this fallback the offscreen interface harness
    /// reports a successful render while showing empty cards, which is precisely the kind of
    /// false confidence that lets a broken layout reach a user. Any future thumbnailing or
    /// preview path in the app would hit the same wall.
    @ViewBuilder
    func adaptiveGlass(cornerRadius: CGFloat = 12) -> some View {
        modifier(AdaptiveGlassModifier(cornerRadius: cornerRadius))
    }
}

private struct AdaptiveGlassModifier: ViewModifier {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if isOffscreenRendering {
            content.background(.quaternary, in: .rect(cornerRadius: cornerRadius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }
}
