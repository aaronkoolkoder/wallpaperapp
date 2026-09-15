import SwiftUI

/// The app's visual language.
///
/// Tuned toward the Space Black MacBook Pro: a deep, slightly warm neutral rather than a pure
/// black, matte instead of glossy, and almost entirely monochrome. Colour is rationed — it means
/// *status* (playing, unsupported) and nothing else. Anything that is merely a category is told
/// through a symbol and a tone, because a grid of category-coloured chips reads as a dashboard,
/// and this is meant to feel like a piece of hardware.
enum Design {

    // MARK: - Palette

    /// Surfaces, darkest to lightest. Elevation is expressed as a small step in tone rather
    /// than as a border, which is what keeps the chrome feeling machined rather than drawn.
    enum Surface {
        /// Window background. Warm-neutral near-black, not #000 — pure black on an OLED-adjacent
        /// panel reads as a hole rather than as a material.
        static let base = Color(light: .init(white: 0.97), dark: .init(red: 0.086, green: 0.086, blue: 0.094))
        /// Sidebars and rails.
        static let recessed = Color(light: .init(white: 0.94), dark: .init(red: 0.071, green: 0.071, blue: 0.078))
        /// Cards and panels sitting on `base`.
        static let raised = Color(light: .init(white: 1.0), dark: .init(red: 0.118, green: 0.118, blue: 0.129))
        /// Rows inside a raised panel.
        static let inset = Color(light: .init(white: 0.96), dark: .init(red: 0.149, green: 0.149, blue: 0.161))
    }

    enum Stroke {
        /// Hairlines are barely there by design; separation comes from tone, not lines.
        static let subtle = Color(light: .init(white: 0, opacity: 0.08), dark: .init(white: 1, opacity: 0.07))
        static let strong = Color(light: .init(white: 0, opacity: 0.14), dark: .init(white: 1, opacity: 0.13))
    }

    enum Ink {
        static let primary = Color(light: .init(white: 0.08), dark: .init(white: 0.96))
        static let secondary = Color(light: .init(white: 0.38), dark: .init(white: 0.62))
        static let tertiary = Color(light: .init(white: 0.56), dark: .init(white: 0.42))
    }

    /// The only colours in the app that are not tone.
    enum Status {
        static let playing = Color(red: 0.30, green: 0.82, blue: 0.55)
        static let warning = Color(red: 0.98, green: 0.69, blue: 0.29)
        static let error = Color(red: 0.95, green: 0.38, blue: 0.36)
    }

    // MARK: - Metrics

    enum Radius {
        static let card: CGFloat = 16
        static let thumbnail: CGFloat = 11
        static let panel: CGFloat = 20
        static let chip: CGFloat = 7
        static let control: CGFloat = 10
    }

    enum Space {
        static let gutter: CGFloat = 24
        static let card: CGFloat = 18
        static let tight: CGFloat = 8
        static let grid: CGFloat = 20
        static let section: CGFloat = 22
    }

    enum Grid {
        static let minimum: CGFloat = 250
        static let maximum: CGFloat = 340
        static let aspect: CGFloat = 16.0 / 10.0
    }

    /// Motion is quick and slightly damped. Nothing bounces — springiness reads as playful, and
    /// the target here is precise.
    enum Motion {
        static let hover = SwiftUI.Animation.smooth(duration: 0.16)
        static let selection = SwiftUI.Animation.smooth(duration: 0.2)
        static let appear = SwiftUI.Animation.smooth(duration: 0.28)
    }
}

extension Color {
    /// Explicit light and dark values rather than a semantic system colour.
    ///
    /// The palette is a deliberate, specific neutral; letting the system substitute its own
    /// greys would lose exactly the character being aimed for.
    init(light: NSColor, dark: NSColor) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(white: CGFloat, opacity: CGFloat = 1) {
        self.init(calibratedWhite: white, alpha: opacity)
    }

    convenience init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.init(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }
}

// MARK: - Surfaces

/// A raised panel: a tone step up from the background plus the faintest hairline.
struct RaisedSurface: ViewModifier {
    var radius: CGFloat = Design.Radius.card
    var fill: Color = Design.Surface.raised

    func body(content: Content) -> some View {
        content
            .background(fill, in: .rect(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Design.Stroke.subtle, lineWidth: 0.5)
            }
    }
}

extension View {
    func raisedSurface(
        radius: CGFloat = Design.Radius.card, fill: Color = Design.Surface.raised
    ) -> some View {
        modifier(RaisedSurface(radius: radius, fill: fill))
    }

    /// Liquid Glass where the compositor can draw it, the matte panel where it cannot.
    func panelSurface(radius: CGFloat = Design.Radius.card) -> some View {
        modifier(PanelSurface(radius: radius))
    }
}

struct PanelSurface: ViewModifier {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    var radius: CGFloat = Design.Radius.card

    func body(content: Content) -> some View {
        if isOffscreenRendering {
            content.raisedSurface(radius: radius)
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

// MARK: - Components

/// A small label. Monochrome unless it is carrying status.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color?
    var isProminent = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.caption2.weight(.medium))
                .tracking(0.1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .foregroundStyle(foreground)
        .background(background, in: .rect(cornerRadius: Design.Radius.chip))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.chip)
                .strokeBorder(tint == nil ? Design.Stroke.subtle : .clear, lineWidth: 0.5)
        }
    }

    private var foreground: Color {
        if isProminent { return .white }
        return tint ?? Design.Ink.secondary
    }

    private var background: Color {
        if isProminent { return tint ?? Design.Ink.primary }
        if let tint { return tint.opacity(0.15) }
        return Design.Surface.inset.opacity(0.7)
    }
}

/// Small uppercase section heading.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Design.Ink.tertiary)
            .tracking(0.9)
    }
}

/// How a wallpaper presents visually. Carries a symbol only — type is not colour-coded.
enum WallpaperTypeAppearance {
    case scene, video, web, image, unsupported

    var symbol: String {
        switch self {
        case .scene: "cube.transparent"
        case .video: "play.rectangle"
        case .web: "globe"
        case .image: "photo"
        case .unsupported: "exclamationmark.triangle"
        }
    }
}
