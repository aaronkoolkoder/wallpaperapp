import SwiftUI

/// Shared visual language.
///
/// Centralised so spacing and radii stay consistent across the window, the popover and the
/// inspector. Tahoe leans on generous radii and layered translucency rather than borders and
/// hairlines, so most separation here comes from depth rather than from lines.
enum Design {
    enum Radius {
        static let card: CGFloat = 14
        static let thumbnail: CGFloat = 10
        static let panel: CGFloat = 18
        static let chip: CGFloat = 8
    }

    enum Space {
        static let gutter: CGFloat = 20
        static let card: CGFloat = 14
        static let tight: CGFloat = 8
        static let grid: CGFloat = 18
    }

    /// Grid cards are sized so a 16:10 preview reads clearly at a glance without the window
    /// feeling sparse at small widths.
    enum Grid {
        static let minimum: CGFloat = 230
        static let maximum: CGFloat = 320
        static let aspect: CGFloat = 16.0 / 10.0
    }
}

/// A soft, layered surface. The default panel treatment.
struct PanelSurface: ViewModifier {
    @Environment(\.isOffscreenRendering) private var isOffscreenRendering
    var radius: CGFloat = Design.Radius.card

    func body(content: Content) -> some View {
        if isOffscreenRendering {
            content.background(.quaternary, in: .rect(cornerRadius: radius))
        } else {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        }
    }
}

extension View {
    func panelSurface(radius: CGFloat = Design.Radius.card) -> some View {
        modifier(PanelSurface(radius: radius))
    }
}

/// A small label chip — wallpaper type, tag, rating.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text).font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(tint ?? .secondary)
        .background(
            (tint ?? Color.secondary).opacity(0.14),
            in: .rect(cornerRadius: Design.Radius.chip)
        )
    }
}

extension WallpaperTypeAppearance {
    /// Type is the single most useful thing to distinguish at a glance in a dense grid, so each
    /// gets its own symbol and hue rather than relying on text alone.
    var tint: Color {
        switch self {
        case .scene: .purple
        case .video: .blue
        case .web: .teal
        case .image: .orange
        case .unsupported: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .scene: "cube.transparent.fill"
        case .video: "film.fill"
        case .web: "globe"
        case .image: "photo.fill"
        case .unsupported: "exclamationmark.triangle.fill"
        }
    }

    var label: String {
        switch self {
        case .scene: "Scene"
        case .video: "Video"
        case .web: "Web"
        case .image: "Image"
        case .unsupported: "Unsupported"
        }
    }
}

/// How a wallpaper presents in the UI, independent of the format's own type enum.
enum WallpaperTypeAppearance {
    case scene, video, web, image, unsupported
}
