import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case clean = "Clean", apps = "Apps", optimize = "Optimize", analyze = "Analyze", status = "Status"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .clean: "bubbles.and.sparkles"
        case .apps: "square.grid.2x2"
        case .optimize: "gauge.with.dots.needle.67percent"
        case .analyze: "rectangle.split.3x3"
        case .status: "waveform.path.ecg"
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Bubble's palette: deep blue ink, a thin water-film edge, and the iridescent sheen
/// of a soap bubble, which is used only on the bubble itself and the main action.
enum Palette {
    static let abyss = Color(hex: 0x0A0F24)       // window
    static let depth = Color(hex: 0x121938)       // raised surfaces
    static let sidebar = Color(hex: 0x0D1330)     // a shade lighter than the window
    static let card = Color.white.opacity(0.045)
    static let cardStroke = Color.white.opacity(0.08)   // "film": hairline edges
    static let primary = Color(hex: 0xEEF1FF)
    static let secondary = Color(hex: 0xA3ACD3)
    static let tertiary = Color(hex: 0x6E78A8)
    static let accent = Color(hex: 0x9AA8FF)      // periwinkle, from the bubble's rim
    static let green = Color(hex: 0x6EE7B7)
    static let blue = Color(hex: 0x7DA2FF)
    static let amber = Color(hex: 0xFBC56B)
    static let red = Color(hex: 0xFB7185)

    /// Thin-film interference colours, in the order they appear around a soap bubble.
    static let iris: [Color] = [0x67E8F9, 0xA78BFA, 0xF472B6, 0xFDE68A, 0x6EE7B7, 0x67E8F9].map { Color(hex: $0) }
}

/// The window background: deep ink with light falling in from the top left, as through water.
struct AppBackground: View {
    var body: some View {
        ZStack {
            Palette.abyss
            RadialGradient(colors: [Color(hex: 0x1E2A5E).opacity(0.85), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(hex: 0x3B1E5E).opacity(0.35), .clear],
                           center: .bottomTrailing, startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Tokens

/// Six-step type scale. SF Pro everywhere; tabular digits for numbers; SF Mono only for file paths.
enum TypeStep: CGFloat {
    // macOS proportions: 13pt body, as in Finder and System Settings.
    case caption = 11, secondary = 12, body = 13, section = 17, title = 24, hero = 34
}

extension Font {
    static func ui(_ step: TypeStep, _ weight: Font.Weight = .regular) -> Font {
        .system(size: step.rawValue, weight: weight, design: step.rawValue >= 24 ? .rounded : .default)
    }
    /// Numbers that change or line up in columns (sizes, percentages, PIDs).
    static func num(_ step: TypeStep, _ weight: Font.Weight = .regular) -> Font {
        .system(size: step.rawValue, weight: weight, design: step.rawValue >= 17 ? .rounded : .default).monospacedDigit()
    }
    /// File system paths, the one place a code face earns its keep.
    static func path(_ step: TypeStep = .secondary) -> Font {
        .system(size: step.rawValue, design: .monospaced)
    }
}

/// 4pt grid. Every screen uses the same gutter so edges line up across tabs.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let gutter: CGFloat = 24
}

/// Three radii: panels, rows/controls, and capsules (implicit).
enum Radius {
    static let panel: CGFloat = 18
    static let row: CGFloat = 10
    static let control: CGFloat = 6
}

enum Motion {
    /// The one spring for everything a click causes.
    static let spring = Animation.spring(response: 0.35, dampingFraction: 0.86)
    /// Switching sections cross-fades the screens.
    static let tab = Animation.easeInOut(duration: 0.3)
    static let reduced = Animation.easeInOut(duration: 0.15)
}

private struct MotionModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.screenVisible) private var visible
    let value: V
    func body(content: Content) -> some View {
        // Hidden tabs still receive data (Status updates every second); animating
        // them would keep the render loop busy for nothing.
        content.animation(!visible ? nil : reduce ? Motion.reduced : Motion.spring, value: value)
    }
}

private struct RowHover: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.row).fill(Color.white.opacity(hovering ? 0.06 : 0)))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

extension View {
    /// Soft highlight under a list row while the pointer is over it.
    func rowHover() -> some View { modifier(RowHover()) }

    /// Animates changes to `value` with the shared spring, or a short fade under Reduce Motion.
    func motion<V: Equatable>(_ value: V) -> some View { modifier(MotionModifier(value: value)) }

    /// The card look: a faint fill inside a hairline edge.
    func panel(radius: CGFloat = Radius.panel, stroke: Color = Palette.cardStroke, style: RoundedCornerStyle = .circular) -> some View {
        panel(radius: radius, fill: Palette.card, stroke: stroke, style: style)
    }

    func panel<Fill: ShapeStyle>(radius: CGFloat = Radius.panel, fill: Fill, stroke: Color = Palette.cardStroke,
                                 style: RoundedCornerStyle = .circular) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: style)
        return background(fill, in: shape).overlay(shape.stroke(stroke))
    }
}

extension AnyTransition {
    /// State changes (idle → scanning → found) rise slightly as they fade in.
    static func phase(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity)
    }
}

/// Replaces `.plain`: same look, but with hover and pressed feedback. Keeps the
/// system focus ring for Full Keyboard Access.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { QuietBody(configuration: configuration) }

    private struct QuietBody: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            // Opacity only: filters like .brightness() force CPU-rendered layers.
            configuration.label
                .contentShape(Rectangle())
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.6 : hovering ? 1 : 0.88)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}
