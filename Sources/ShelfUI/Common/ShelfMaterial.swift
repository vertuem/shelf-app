import AppKit
import SwiftUI

/// The one place that decides how Shelf's floating surfaces are drawn.
///
/// Liquid Glass on macOS 26, `.ultraThinMaterial` on 14 and 15, and an opaque
/// window background when Reduce Transparency is on. If the glass API changes
/// between macOS releases, only this file changes.
public enum ShelfAppearance {
    /// Debug default to see the macOS 14 look on a macOS 26 machine.
    public static var forceLegacy: Bool { UserDefaults.standard.bool(forKey: "debugForceLegacyChrome") }

    public static var usesGlass: Bool {
        if forceLegacy { return false }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// Text size relative to the default, following the system accessibility text size.
    public static var textScale: CGFloat {
        let body = NSFont.preferredFont(forTextStyle: .body).pointSize
        return max(1, body / 13)
    }
}

struct ShelfMaterial: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .windowBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.15), lineWidth: 1))
        } else if ShelfAppearance.usesGlass, #available(macOS 26, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.5 : 0.12), lineWidth: 1))
        }
    }
}

extension View {
    func shelfMaterial(cornerRadius: CGFloat = 28) -> some View {
        modifier(ShelfMaterial(cornerRadius: cornerRadius))
    }

    /// Glass buttons on macOS 26, borderless elsewhere.
    @ViewBuilder
    func shelfButtonStyle() -> some View {
        if ShelfAppearance.usesGlass, #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.borderless)
        }
    }

    /// A round glass button for a lone symbol: the settings gear, plus, close.
    func shelfIconButtonStyle() -> some View {
        shelfButtonStyle().buttonBorderShape(.circle)
    }

    /// The main action of a window. The standard style, which macOS 26 already
    /// draws in Liquid Glass; the `.glass` styles are for controls floating over
    /// content, and in a window they drew a bare black label in dark mode.
    func shelfProminentButtonStyle() -> some View {
        buttonStyle(.borderedProminent)
    }

    /// Secondary actions next to a prominent one.
    func shelfSecondaryButtonStyle() -> some View {
        buttonStyle(.bordered)
    }

    /// Liquid Glass behind a small custom control on macOS 26; `fallback` elsewhere.
    @ViewBuilder
    func shelfGlass(in shape: some Shape, interactive: Bool = false, fallback: some ShapeStyle = .thinMaterial) -> some View {
        if ShelfAppearance.usesGlass, #available(macOS 26, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(fallback, in: shape)
        }
    }
}

/// Groups custom glass so it renders together and morphs between shapes
/// (Apple: "Applying Liquid Glass to custom views"). A plain container before macOS 26.
struct ShelfGlassContainer<Content: View>: View {
    var spacing: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        if ShelfAppearance.usesGlass, #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A white symbol on a colored rounded square, as in System Settings.
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Keys drawn as small key caps: "⌘P", or "←" and "→" side by side.
struct KeyCaps: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .frame(minWidth: 24, minHeight: 22)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
