import SwiftUI

/// Bytes that count up when the value changes (used for the "found" reveal).
struct CountingBytes: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    var body: some View { Text(Fmt.bytes(value)) }
}

struct Card<Content: View>: View {
    var padding: CGFloat = Space.l
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .panel(style: .continuous)
    }
}

/// The primary action on a screen. One per screen.
struct PillButton: View {
    let title: String
    var width: CGFloat = 240
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.abyss)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, Space.xl)
                .frame(minWidth: min(width, 200), minHeight: 40)
                .background(
                    LinearGradient(colors: [Color(hex: 0xA5F3FC), Color(hex: 0xC4B5FD), Color(hex: 0xF5D0FE)],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.5), lineWidth: 1))
                .shadow(color: Color(hex: 0xA78BFA).opacity(hovering ? 0.45 : 0.25), radius: hovering ? 16 : 10, y: 2)
        }
        .buttonStyle(PillPress())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private struct PillPress: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.ui(.caption, .medium))
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// Checkbox drawn to match the dark theme, with a mixed (dash) state SwiftUI's
/// Toggle lacks. Exposed to VoiceOver as a toggle with a checked/mixed value.
struct CheckBox: View {
    var on: Bool
    var mixed = false
    var tint: Color
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5)
                .fill(on || mixed ? tint.opacity(0.85) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(on || mixed ? .clear : Palette.tertiary, lineWidth: 1.5))
                .overlay {
                    Image(systemName: mixed ? "minus" : "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .opacity(on || mixed ? 1 : 0)
                        .scaleEffect(on || mixed ? 1 : 0.5)
                }
                .frame(width: 18, height: 18)
                .motion(on || mixed)
        }
        .buttonStyle(.quiet)
        .accessibilityLabel(label)
        .accessibilityValue(mixed ? "Partly selected" : on ? "Selected" : "Not selected")
        .accessibilityAddTraits(.isToggle)
    }
}

struct LinkButton: View {
    let title: String
    var color: Color = Palette.secondary
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).lineLimit(1).fixedSize() }
            .buttonStyle(.quiet)
            .foregroundStyle(color)
    }
}

/// Icon-only toolbar button with a VoiceOver label and tooltip.
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = TypeStep.body.rawValue
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: size)).frame(width: 28, height: 28)
        }
        .buttonStyle(.quiet)
        .foregroundStyle(Palette.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Idle and result screens: words and the one action on the left, the bubble on the right.
struct HeroView<Content: View>: View {
    private static var bubbleSide: CGFloat { 380 }
    /// Eases the bubble back when results arrive, so the number takes focus.
    var recede = false
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: Space.xxl) {
            // A minimum width stops the text column collapsing (and wrapping a letter per
            // line) when the split view measures it at zero width.
            VStack(alignment: .leading, spacing: Space.l) { content }
                .frame(minWidth: 320, maxWidth: 460, alignment: .leading)
            // At the narrowest window the text and the bubble share the squeeze: the
            // bubble shrinks (down to 260pt) instead of pushing the hero wider than the
            // detail column. The hero's minimum width is 724pt.
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .frame(minWidth: 260, maxWidth: Self.bubbleSide, maxHeight: Self.bubbleSide)
                .overlay {
                    GeometryReader { geo in
                        let side = min(geo.size.width, geo.size.height)
                        BubbleCluster()
                            .scaleEffect(side / Self.bubbleSide * (recede ? 0.86 : 1))
                            .frame(width: geo.size.width, height: geo.size.height)
                    }
                }
                .opacity(recede ? 0.85 : 1)
                .motion(recede)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The screen's headline.
struct Headline: View {
    let text: String
    var body: some View {
        Text(text).font(.ui(.hero, .bold)).foregroundStyle(Palette.primary)
    }
}

/// One plain sentence under a headline: what this screen does.
struct Lede: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .foregroundStyle(Palette.secondary)
            .lineSpacing(3)
    }
}

/// Small reassurance under an action ("Scanning only looks…").
struct Hint: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.ui(.secondary))
            .foregroundStyle(Palette.tertiary)
    }
}

/// Banner at the bottom of a screen (e.g. missing Full Disk Access).
struct NoticeBar: View {
    let icon: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onClose: (() -> Void)?
    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: icon).foregroundStyle(Palette.amber).accessibilityHidden(true)
            Text(text).foregroundStyle(.white.opacity(0.8))
            Spacer()
            if let actionTitle, let action {
                Button(action: action) { Text(actionTitle).lineLimit(1).fixedSize() }
                    .buttonStyle(.quiet)
                    .padding(.horizontal, Space.m).padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: Capsule())
            }
            if let onClose {
                IconButton(systemName: "xmark", label: "Dismiss", action: onClose)
            }
        }
        .font(.ui(.secondary))
        .padding(.horizontal, Space.l).padding(.vertical, Space.m)
        .panel(radius: Radius.row, fill: .regularMaterial)
    }
}

/// A spinner with the step that's running.
struct ProgressLine: View {
    let text: String
    var body: some View {
        HStack(spacing: Space.s) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.2), value: text)
        }
        .font(.ui(.body))
        .accessibilityElement(children: .combine)
    }
}

/// Command output in a dark box: the last `tail` lines, one row each, or with `tail`
/// nil every line in a scroll view that follows new output and can be selected.
struct LogBox: View {
    let lines: [String]
    var tail: Int?
    /// Shown in place of the lines while there are none yet (tail mode).
    var placeholder: String?
    /// Keeps a tail-mode box from growing as the first lines arrive.
    var minHeight: CGFloat = 0

    var body: some View {
        Group {
            if let tail {
                VStack(alignment: .leading, spacing: Space.xs) {
                    ForEach(Array(lines.suffix(tail).enumerated()), id: \.offset) { _, l in
                        Text(l).lineLimit(1).truncationMode(.middle)
                    }
                    if lines.isEmpty, let placeholder { Text(placeholder).foregroundStyle(Palette.tertiary) }
                }
                .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                                Text(l).textSelection(.enabled).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    .onChange(of: lines.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .font(.path())
        .foregroundStyle(.white.opacity(0.65))
        .padding(Space.m)
        .panel(radius: Radius.row, fill: Color.black.opacity(0.25), style: .continuous)
    }
}

/// A list section's title with its item count.
struct SectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: Space.s) {
            Text(title).font(.ui(.body, .semibold))
            Text("\(count)").font(.num(.secondary)).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.m).padding(.bottom, Space.xs)
    }
}
