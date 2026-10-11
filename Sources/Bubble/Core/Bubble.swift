import SwiftUI

extension EnvironmentValues {
    /// False for screens on hidden sections, so their bubbles stop moving and their
    /// animations don't keep the render loop busy.
    @Entry var screenVisible = true
}

/// A soap bubble drawn with gradients: a nearly clear film, an iridescent rim where
/// the film is thinnest, and a window-light highlight. It holds still; the moving
/// bubbles are the hero cluster's Core Animation layers.
struct BubbleView: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                // Faint body: the film is almost clear in the middle.
                Circle()
                    .fill(RadialGradient(colors: [Color.white.opacity(0.02), Palette.accent.opacity(0.10)],
                                         center: .center, startRadius: s * 0.15, endRadius: s * 0.5))
                // Colour pools near the edge, where the film is thinnest.
                Circle()
                    .fill(AngularGradient(colors: Palette.iris, center: .center))
                    .opacity(0.35)
                    .mask(Circle().fill(RadialGradient(colors: [.clear, .clear, .white],
                                                       center: .center, startRadius: 0, endRadius: s * 0.5)))
                // The rim.
                Circle()
                    .strokeBorder(AngularGradient(colors: Palette.iris, center: .center), lineWidth: max(1.5, s * 0.022))
                    .opacity(0.9)
                // Window light: a soft arc and a bright point, top left.
                Circle()
                    .trim(from: 0.57, to: 0.71)
                    .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: max(1.5, s * 0.035), lineCap: .round))
                    .padding(s * 0.09)
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: s * 0.06, height: s * 0.06)
                    .offset(x: -s * 0.2, y: -s * 0.27)
                // A faint second reflection, bottom right.
                Circle()
                    .trim(from: 0.08, to: 0.17)
                    .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: max(1, s * 0.018), lineCap: .round))
                    .padding(s * 0.08)
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

/// Watches Low Power Mode so bubbles stop moving while it's on.
@Observable
@MainActor
final class PowerState {
    static let shared = PowerState()
    var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

    private init() {
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                PowerState.shared.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}

// MARK: - Core Animation bubbles
//
// Everything that moves is a Core Animation animation, so the motion runs in the
// window server and an idle screen costs the app almost nothing. Nothing here
// redraws per frame from Swift.

/// Layer builders for the hero cluster.
@MainActor
private enum BubbleLayers {
    /// Slow drifts read just as smoothly at 30 fps, and it halves the window server's work
    /// (or better, on a 120 Hz display).
    static let calmRate = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)

    static func cg(_ c: Color) -> CGColor { NSColor(c).cgColor }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func setScale(_ layer: CALayer, _ scale: CGFloat) {
        layer.contentsScale = scale
        layer.mask.map { setScale($0, scale) }
        layer.sublayers?.forEach { setScale($0, scale) }
    }

    /// A slow back-and-forth on one key path, added on top of the model value.
    static func sway(_ keyPath: String, by amount: CGFloat, period: Double, phase: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = -amount
        a.toValue = amount
        a.isAdditive = true
        a.duration = period / 2
        a.autoreverses = true
        a.repeatCount = .infinity
        a.preferredFrameRateRange = BubbleLayers.calmRate
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        a.timeOffset = phase * period
        return a
    }

    /// Soft squash and stretch: width grows while height shrinks, like a wobbling film.
    static func squash(_ layer: CALayer, amount: CGFloat, period: Double, phase: Double) {
        for (key, sign) in [("transform.scale.x", 1.0), ("transform.scale.y", -1.0)] {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = 1 - amount * sign
            a.toValue = 1 + amount * sign
            a.duration = period / 2
            a.autoreverses = true
            a.repeatCount = .infinity
            a.preferredFrameRateRange = BubbleLayers.calmRate
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.timeOffset = phase * period
            layer.add(a, forKey: key)
        }
    }

    static func spin(seconds: Double, clockwise: Bool) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = (clockwise ? 1 : -1) * 2 * Double.pi
        a.duration = seconds
        a.repeatCount = .infinity
        a.preferredFrameRateRange = BubbleLayers.calmRate
        return a
    }

    /// A seamless loop through `values` (the first value is repeated at the end).
    static func loop(_ keyPath: String, _ values: [Any], duration: Double, phase: Double = 0,
                     additive: Bool = false) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values + [values[0]]
        a.calculationMode = .cubic
        a.duration = duration
        a.repeatCount = .infinity
        a.preferredFrameRateRange = BubbleLayers.calmRate
        a.isAdditive = additive
        a.timeOffset = phase * duration
        return a
    }

    /// A small closed drift path, as additive position offsets.
    static func driftValues(_ radius: CGFloat, seed: Double) -> [Any] {
        (0..<6).map { i -> Any in
            let t = Double(i) / 6 * 2 * .pi
            let x = radius * cos(t + seed) * (0.7 + 0.3 * sin(2 * t + seed))
            let y = radius * 0.8 * sin(t * 2 + seed * 1.7)
            return NSValue(point: CGPoint(x: x, y: y))
        }
    }

    // MARK: Blob outline

    /// A closed, smooth outline through `offsets.count` points around a circle, each
    /// pushed in or out by its offset (fraction of the radius). Catmull-Rom curves keep
    /// it free of corners, and every shape has the same elements so paths interpolate.
    static func blobPath(radius r: CGFloat, center c: CGPoint, offsets: [CGFloat]) -> CGPath {
        let n = offsets.count
        let pts = (0..<n).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(n) * 2 * .pi
            let rr = r * (1 + offsets[i])
            return CGPoint(x: c.x + rr * cos(t), y: c.y + rr * sin(t))
        }
        let p = CGMutablePath()
        p.move(to: pts[0])
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            p.addCurve(to: p2,
                       control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                       control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6))
        }
        p.closeSubpath()
        return p
    }

    /// Five gentle shapes: nearly round, softly squarish, lopsided and between.
    /// Each is a sum of low harmonics, scaled so the radius stays within ±`amplitude`.
    static func morphShapes(amplitude: CGFloat, seed: UInt64, points n: Int = 12) -> [[CGFloat]] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        func rand() -> CGFloat {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat((state >> 33) % 10_000) / 10_000
        }
        // Weights of the 2nd, 3rd and 4th harmonic, and each shape's share of the amplitude.
        let recipes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.5, 0.3, 0.2, 0.45),   // nearly round
            (0.4, 0.8, 0.3, 0.9),
            (0.25, 0.2, 1.0, 1.0),   // softly squarish
            (1.0, 0.5, 0.2, 1.0),    // lopsided
            (0.5, 0.7, 0.4, 0.75),
        ]
        return recipes.map { w2, w3, w4, share in
            let p2 = rand() * 2 * .pi, p3 = rand() * 2 * .pi, p4 = rand() * 2 * .pi
            let raw = (0..<n).map { i -> CGFloat in
                let t = CGFloat(i) / CGFloat(n) * 2 * .pi
                return w2 * sin(2 * t + p2) + w3 * sin(3 * t + p3) + w4 * sin(4 * t + p4)
            }
            let peak = raw.map(abs).max() ?? 1
            return raw.map { $0 / peak * amplitude * share }
        }
    }

    /// A shape layer that follows a morphing outline.
    static func blobShape(_ paths: [CGPath], period: Double, live: Bool, phase: Double = 0) -> CAShapeLayer {
        let l = CAShapeLayer()
        l.path = paths[0]
        if live { l.add(loop("path", paths, duration: period, phase: phase), forKey: "morph") }
        return l
    }

    static func radial(_ frame: CGRect, colors: [CGColor], locations: [NSNumber]) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .radial
        g.frame = frame
        g.colors = colors
        g.locations = locations
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 1)
        return g
    }

    static func conic(_ frame: CGRect) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.type = .conic
        g.frame = frame
        g.colors = Palette.iris.map(cg)
        g.startPoint = CGPoint(x: 0.5, y: 0.5)
        g.endPoint = CGPoint(x: 0.5, y: 0)
        return g
    }

    // MARK: The glass hero blob

    /// The hero: a slowly morphing glass drop with a cyan-to-blue interior, a violet
    /// lobe refracting inside, an iridescent rim and a soft specular highlight.
    /// `side` is the box it lives in; the outline never leaves it.
    static func glassBlob(side d: CGFloat, live: Bool) -> CALayer {
        let box = CGRect(x: 0, y: 0, width: d, height: d)
        let c = CGPoint(x: d / 2, y: d / 2)
        let r = d * 0.43
        let period = 9.0
        let outline = morphShapes(amplitude: 0.07, seed: 7).map { blobPath(radius: r, center: c, offsets: $0) }

        let root = CALayer()
        root.frame = box

        // Everything inside the glass is clipped to the morphing outline.
        let inside = CALayer()
        inside.frame = box
        let clip = blobShape(outline, period: period, live: live)
        clip.fillColor = NSColor.white.cgColor
        inside.mask = clip
        root.addSublayer(inside)

        // Thin-film colours, seen where the interior fades out near the edge.
        let film = conic(box.insetBy(dx: -d * 0.1, dy: -d * 0.1))
        inside.addSublayer(film)
        if live { film.add(spin(seconds: 36, clockwise: true), forKey: "spin") }

        // Interior: deep blue darkening to violet at the edge, then clear so the film shows.
        let core = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        inside.addSublayer(radial(core.insetBy(dx: -r * 0.06, dy: -r * 0.06),
            colors: [rgb(0x2563EB, 0.96), rgb(0x1D4ED8, 0.95), rgb(0x312E81, 0.9), rgb(0x4C1D95, 0.55), rgb(0x4C1D95, 0)],
            locations: [0, 0.5, 0.74, 0.86, 0.98]))

        // Bright cyan light pooling upper right.
        let glow = radial(CGRect(x: c.x - r * 0.62 + r * 0.2, y: c.y - r * 0.62 - r * 0.2, width: r * 1.24, height: r * 1.24),
            colors: [rgb(0x7DF3FF, 1), rgb(0x22D3EE, 0.8), rgb(0x0EA5E9, 0)], locations: [0, 0.5, 1])
        inside.addSublayer(glow)
        if live { glow.add(loop("position", driftValues(r * 0.05, seed: 1.3), duration: period * 2, additive: true), forKey: "drift") }

        // Refraction lobes: smaller translucent shapes drifting inside, each on its own clock.
        func lobe(radius lr: CGFloat, at o: CGPoint, fill: CGColor, period p: Double, seed: UInt64) {
            let lbox = CGRect(x: 0, y: 0, width: lr * 2.4, height: lr * 2.4)
            let shapes = morphShapes(amplitude: 0.07, seed: seed).map {
                blobPath(radius: lr, center: CGPoint(x: lbox.midX, y: lbox.midY), offsets: $0)
            }
            let l = blobShape(shapes, period: p, live: live, phase: 0.3)
            l.frame = lbox
            l.position = CGPoint(x: c.x + o.x, y: c.y + o.y)
            l.fillColor = fill
            l.strokeColor = NSColor.white.withAlphaComponent(0.16).cgColor
            l.lineWidth = 1
            inside.addSublayer(l)
            if live { l.add(loop("position", driftValues(r * 0.07, seed: Double(seed)), duration: p * 1.7, additive: true), forKey: "drift") }
        }
        lobe(radius: r * 0.62, at: CGPoint(x: r * 0.12, y: -r * 0.02), fill: rgb(0x60A5FA, 0.13), period: 11.3, seed: 3)
        lobe(radius: r * 0.44, at: CGPoint(x: -r * 0.34, y: r * 0.32), fill: rgb(0x8B5CF6, 0.4), period: 7.7, seed: 11)

        // Specular highlights: a big soft oval top right and a faint one lower left.
        func highlight(_ size: CGSize, at o: CGPoint, angle: CGFloat, alpha: CGFloat, drift: CGFloat, seed: Double) {
            let h = radial(CGRect(origin: .zero, size: size),
                colors: [NSColor.white.withAlphaComponent(alpha).cgColor,
                         NSColor.white.withAlphaComponent(alpha * 0.75).cgColor,
                         NSColor.white.withAlphaComponent(0).cgColor],
                locations: [0, 0.5, 1])
            h.position = CGPoint(x: c.x + o.x, y: c.y + o.y)
            h.setAffineTransform(CGAffineTransform(rotationAngle: angle))
            inside.addSublayer(h)
            if live { h.add(loop("position", driftValues(drift, seed: seed), duration: period, additive: true), forKey: "drift") }
        }
        highlight(CGSize(width: r * 0.62, height: r * 0.44), at: CGPoint(x: r * 0.34, y: -r * 0.44),
                  angle: 0.55, alpha: 0.9, drift: r * 0.045, seed: 0.4)
        highlight(CGSize(width: r * 0.34, height: r * 0.16), at: CGPoint(x: -r * 0.5, y: r * 0.52),
                  angle: 0.8, alpha: 0.28, drift: r * 0.03, seed: 2.2)

        // The iridescent rim: a second film masked to a stroke of the outline, with a
        // wider faint stroke for the glow fringe.
        let rimFilm = conic(box.insetBy(dx: -d * 0.1, dy: -d * 0.1))
        if live { rimFilm.add(spin(seconds: 44, clockwise: false), forKey: "spin") }
        let rimMask = CALayer()
        rimMask.frame = box
        for (width, alpha) in [(r * 0.09, 0.14), (r * 0.045, 1.0)] {
            let s = blobShape(outline, period: period, live: live)
            s.fillColor = nil
            s.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            s.lineWidth = width
            rimMask.addSublayer(s)
        }
        let rim = CALayer()
        rim.frame = box
        rim.opacity = 0.9
        rim.addSublayer(rimFilm)
        rim.mask = rimMask
        root.addSublayer(rim)

        // Thin bright lines along parts of the edge.
        for (start, end, alpha) in [(0.2, 0.47, 0.55), (0.8, 0.92, 0.4)] as [(CGFloat, CGFloat, CGFloat)] {
            let s = blobShape(outline, period: period, live: live)
            s.fillColor = nil
            s.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
            s.lineWidth = max(1, d * 0.004)
            s.lineCap = .round
            s.strokeStart = start
            s.strokeEnd = end
            root.addSublayer(s)
        }
        return root
    }

    // MARK: The soap bubble

    /// The round soap bubble (the same drawing as `BubbleView`) as layers. When
    /// `live`, its film and rim colours drift and the highlight glints.
    static func soap(side s: CGFloat, live: Bool, filmPeriod: Double = 40, rimPeriod: Double = 40) -> CALayer {
        let local = CGRect(x: 0, y: 0, width: s, height: s)
        let root = CALayer()
        root.frame = local

        let body = radial(local, colors: [NSColor.white.withAlphaComponent(0.02).cgColor, cg(Palette.accent.opacity(0.10))],
                          locations: [0, 1])
        let bodyMask = CAShapeLayer()
        bodyMask.path = CGPath(ellipseIn: local, transform: nil)
        body.mask = bodyMask
        root.addSublayer(body)

        // Colour pooling near the edge.
        let film = conic(local)
        film.opacity = 0.35
        let filmClip = CAShapeLayer()
        filmClip.path = CGPath(ellipseIn: local, transform: nil)
        film.mask = filmClip
        let filmHolder = CALayer()
        filmHolder.frame = local
        filmHolder.addSublayer(film)
        filmHolder.mask = radial(local, colors: [NSColor.clear.cgColor, NSColor.clear.cgColor, NSColor.white.cgColor],
                                 locations: [0, 0.5, 1])
        root.addSublayer(filmHolder)
        if live { film.add(spin(seconds: filmPeriod, clockwise: true), forKey: "spin") }

        // The iridescent rim.
        let rim = conic(local)
        rim.opacity = 0.9
        let ring = CAShapeLayer()
        let w = max(1.5, s * 0.022)
        ring.path = CGPath(ellipseIn: local.insetBy(dx: w / 2, dy: w / 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.white.cgColor
        ring.lineWidth = w
        let rimHolder = CALayer()
        rimHolder.frame = local
        rimHolder.addSublayer(rim)
        rimHolder.mask = ring
        root.addSublayer(rimHolder)
        if live { rim.add(spin(seconds: rimPeriod, clockwise: false), forKey: "spin") }

        // Window light: an arc and a bright point, top left (flipped coordinates).
        let light = CALayer()
        light.frame = local
        light.addSublayer(arc(in: local.insetBy(dx: s * 0.09, dy: s * 0.09), from: 0.57, to: 0.71,
                              width: max(1.5, s * 0.035), alpha: 0.75))
        let dot = CAShapeLayer()
        let dd = s * 0.06
        dot.path = CGPath(ellipseIn: CGRect(x: s / 2 - s * 0.2 - dd / 2, y: s / 2 - s * 0.27 - dd / 2, width: dd, height: dd), transform: nil)
        dot.fillColor = NSColor.white.withAlphaComponent(0.9).cgColor
        light.addSublayer(dot)
        light.addSublayer(arc(in: local.insetBy(dx: s * 0.08, dy: s * 0.08), from: 0.08, to: 0.17,
                              width: max(1, s * 0.018), alpha: 0.25))
        root.addSublayer(light)
        if live {
            // The highlight glints as the film turns.
            let glint = CABasicAnimation(keyPath: "opacity")
            glint.fromValue = 1
            glint.toValue = 0.7
            glint.duration = filmPeriod / 8
            glint.autoreverses = true
            glint.repeatCount = .infinity
            glint.preferredFrameRateRange = BubbleLayers.calmRate
            glint.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            light.add(glint, forKey: "glint")
        }
        return root
    }

    /// An arc matching SwiftUI's Circle().trim(from:to:), which starts at 3 o'clock and runs clockwise.
    static func arc(in r: CGRect, from: CGFloat, to: CGFloat, width: CGFloat, alpha: CGFloat) -> CAShapeLayer {
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: r.width / 2,
                    startAngle: from * 2 * .pi, endAngle: to * 2 * .pi, clockwise: false)
        let l = CAShapeLayer()
        l.path = path
        l.fillColor = nil
        l.strokeColor = NSColor.white.withAlphaComponent(alpha).cgColor
        l.lineWidth = width
        l.lineCap = .round
        return l
    }

    /// A tiny soap bubble for the rising ones: a tinted ring and a white glint.
    static func tinyBubbleImage(tint: CGColor) -> CGImage? {
        let px = 48
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: px, height: px).insetBy(dx: 4, dy: 4)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.07))
        ctx.fillEllipse(in: rect)
        ctx.setStrokeColor(tint.copy(alpha: 0.85) ?? tint)
        ctx.setLineWidth(2.5)
        ctx.strokeEllipse(in: rect)
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: 13, y: 28, width: 7, height: 7))
        return ctx.makeImage()
    }
}

/// Pause and resume every animation under a layer (used while the window is hidden).
private extension CALayer {
    func setPaused(_ paused: Bool) {
        if paused, speed != 0 {
            let t = convertTime(CACurrentMediaTime(), from: nil)
            speed = 0
            timeOffset = t
        } else if !paused, speed == 0 {
            let p = timeOffset
            speed = 1
            timeOffset = 0
            beginTime = 0
            beginTime = convertTime(CACurrentMediaTime(), from: nil) - p
        }
    }
}

/// A view that stops its layers' clocks while its window is fully covered or minimised.
class OcclusionAwareView: NSView {
    let root = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(root)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            occlusionChanged()
        } else {
            root.setPaused(true)
        }
    }

    @objc private func occlusionChanged() {
        root.setPaused(!(window?.occlusionState.contains(.visible) ?? false))
    }

    func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}

// MARK: - The hero cluster

/// The hero group: a morphing glass bubble with two small soap-bubble companions,
/// each floating on its own slow path, and a few tiny bubbles rising behind them.
/// Fully still on hidden screens, with Reduce Motion and in Low Power Mode.
struct BubbleCluster: View {
    @Environment(\.screenVisible) private var visible
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var power = PowerState.shared

    var body: some View {
        ClusterLayers(live: visible && !reduceMotion && !power.lowPower)
            .frame(width: 380, height: 380)
            .accessibilityHidden(true)
    }
}

private struct ClusterLayers: NSViewRepresentable {
    var live: Bool
    func makeNSView(context: Context) -> ClusterLayerView {
        let v = ClusterLayerView()
        v.live = live
        return v
    }
    func updateNSView(_ view: ClusterLayerView, context: Context) { view.live = live }
}

final class ClusterLayerView: OcclusionAwareView {
    /// One bubble in the cluster and how it moves.
    private struct Spec {
        var side: CGFloat
        var offset: CGPoint          // from the cluster's centre (y down)
        var swayX: (CGFloat, Double) // amplitude, period
        var swayY: (CGFloat, Double)
        var squash: (CGFloat, Double)
        var drift: (film: Double, rim: Double)
        var depth: CGFloat           // how far it leans from the pointer
        var poppable: Bool
        var glass = false
    }

    private let specs: [Spec] = [
        Spec(side: 300, offset: .zero, swayX: (5, 12.7), swayY: (7, 8.9), squash: (0, 1),
             drift: (36, 44), depth: 4, poppable: false, glass: true),
        Spec(side: 54, offset: CGPoint(x: 150, y: -150), swayX: (5, 9.3), swayY: (6, 6.1), squash: (0.025, 3.1),
             drift: (26, 31), depth: 9, poppable: true),
        Spec(side: 26, offset: CGPoint(x: -160, y: 130), swayX: (4, 7.4), swayY: (5, 5.3), squash: (0.03, 2.4),
             drift: (20, 23), depth: 12, poppable: true),
    ]

    /// Per bubble: the layer that leans from the pointer, and the one that pops.
    private var leaners: [CALayer] = []
    private var poppers: [CALayer] = []
    private var popped: Set<Int> = []
    private var generation = 0
    private var built: CGSize = .zero
    private var tracking: NSTrackingArea?

    var live = false {
        didSet { if live != oldValue { built = .zero; needsLayout = true } }
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, built != bounds.size else { return }
        built = bounds.size
        withoutActions(build)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        built = .zero
        needsLayout = true
    }

    private func build() {
        generation += 1
        popped = []
        root.removeAllAnimations()
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        root.frame = bounds
        leaners = []
        poppers = []
        let c = CGPoint(x: bounds.midX, y: bounds.midY)

        if live { risingBubbles(center: c).forEach(root.addSublayer) }

        for (i, s) in specs.enumerated() {
            let box = CGRect(x: 0, y: 0, width: s.side, height: s.side)
            // leaner → floater → popper → breather → drawing, each centred in the last.
            let chain = (0..<4).map { _ -> CALayer in
                let l = CALayer()
                l.bounds = box
                return l
            }
            chain[0].position = CGPoint(x: c.x + s.offset.x, y: c.y + s.offset.y)
            for k in 1..<4 {
                chain[k].position = CGPoint(x: box.midX, y: box.midY)
                chain[k - 1].addSublayer(chain[k])
            }
            let art = s.glass ? BubbleLayers.glassBlob(side: s.side, live: live)
                              : BubbleLayers.soap(side: s.side, live: live, filmPeriod: s.drift.film, rimPeriod: s.drift.rim)
            chain[3].addSublayer(art)
            root.addSublayer(chain[0])
            leaners.append(chain[0])
            poppers.append(chain[2])

            guard live else { continue }
            let phase = Double(i) * 0.37
            chain[1].add(BubbleLayers.sway("position.x", by: s.swayX.0, period: s.swayX.1, phase: phase), forKey: "floatX")
            chain[1].add(BubbleLayers.sway("position.y", by: s.swayY.0, period: s.swayY.1, phase: phase + 0.2), forKey: "floatY")
            if s.squash.0 > 0 { BubbleLayers.squash(chain[3], amount: s.squash.0, period: s.squash.1, phase: phase) }
        }
        BubbleLayers.setScale(root, window?.backingScaleFactor ?? 2)
        updateTrackingAreas()
    }

    /// A few tiny bubbles rising slowly from below and fading out, sparse and gentle.
    /// Plain layers on long keyframe loops (a particle emitter would redraw the window
    /// at full frame rate and costs the window server far more).
    private func risingBubbles(center c: CGPoint) -> [CALayer] {
        // x offset from centre, size, seconds per rise, height risen, tint, starting phase
        let plan: [(CGFloat, CGFloat, Double, CGFloat, UInt32, Double)] = [
            (-95, 9, 17, 230, 0x67E8F9, 0.1),
            (-25, 6, 21, 190, 0xA78BFA, 0.55),
            (55, 11, 19, 260, 0xF472B6, 0.8),
            (115, 7, 23, 210, 0x6EE7B7, 0.3),
        ]
        return plan.compactMap { dx, side, period, rise, hex, phase in
            guard let image = BubbleLayers.tinyBubbleImage(tint: BubbleLayers.rgb(hex)) else { return nil }
            let l = CALayer()
            l.contents = image
            l.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            l.position = CGPoint(x: c.x + dx, y: c.y + 175)
            l.opacity = 0

            let up = CABasicAnimation(keyPath: "position.y")
            up.fromValue = 0
            up.toValue = -rise
            up.isAdditive = true
            up.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.7, 1)
            let wobble = CAKeyframeAnimation(keyPath: "position.x")
            wobble.values = [0, 7, -2, -8, 3, 0].map { $0 * side / 9 }
            wobble.calculationMode = .cubic
            wobble.isAdditive = true
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.7, 0.6, 0, 0]
            fade.keyTimes = [0, 0.18, 0.6, 0.85, 1]
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.5
            grow.toValue = 1.1

            let g = CAAnimationGroup()
            g.animations = [up, wobble, fade, grow]
            g.duration = period
            g.repeatCount = .infinity
            g.preferredFrameRateRange = BubbleLayers.calmRate
            g.timeOffset = phase * period
            l.add(g, forKey: "rise")
            return l
        }
    }

    // MARK: Pointer: lean away on hover, pop a small bubble on click

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = nil
        guard live else { return }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        guard live else { return }
        let p = convert(event.locationInWindow, from: nil)
        var v = CGPoint(x: (p.x - bounds.midX) / (bounds.width / 2), y: (p.y - bounds.midY) / (bounds.height / 2))
        let len = hypot(v.x, v.y)
        if len > 1 { v = CGPoint(x: v.x / len, y: v.y / len) }
        lean(v)
    }

    override func mouseExited(with event: NSEvent) { lean(.zero) }

    private func lean(_ v: CGPoint) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(1.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        for (i, l) in leaners.enumerated() {
            let d = specs[i].depth
            l.setAffineTransform(CGAffineTransform(translationX: -v.x * d, y: -v.y * d))
        }
        CATransaction.commit()
    }

    /// Clicks only land on the small bubbles; everywhere else passes through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard live, !isHidden else { return nil }
        return companion(at: convert(point, from: superview)) != nil ? self : nil
    }

    private func companion(at p: CGPoint) -> Int? {
        let presentRoot = root.presentation() ?? root
        for (i, s) in specs.enumerated() where s.poppable && !popped.contains(i) && i < poppers.count {
            let layer = poppers[i].presentation() ?? poppers[i]
            let frame = presentRoot.convert(layer.bounds, from: layer)
            let reach = max(s.side / 2 + 6, 16)
            if hypot(p.x - frame.midX, p.y - frame.midY) <= reach { return i }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = companion(at: convert(event.locationInWindow, from: nil)) else { return super.mouseDown(with: event) }
        pop(i)
    }

    private func pop(_ i: Int) {
        popped.insert(i)
        let popper = poppers[i]
        let presentRoot = root.presentation() ?? root
        let shown = popper.presentation() ?? popper
        let centre = presentRoot.convert(CGPoint(x: shown.bounds.midX, y: shown.bounds.midY), from: shown)
        let side = specs[i].side

        // A quick swell and fade.
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let burst = CAAnimationGroup()
        burst.animations = [grow, fade]
        burst.duration = 0.18
        burst.timingFunction = CAMediaTimingFunction(name: .easeOut)
        withoutActions { popper.opacity = 0 }
        popper.add(burst, forKey: "pop")

        // A faint ring spreading where it was.
        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        ring.position = centre
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = BubbleLayers.cg(Palette.accent.opacity(0.7))
        ring.lineWidth = 1
        ring.contentsScale = window?.backingScaleFactor ?? 2
        withoutActions { ring.opacity = 0; root.addSublayer(ring) }
        let spread = CABasicAnimation(keyPath: "transform.scale")
        spread.fromValue = 1
        spread.toValue = 1.9
        let vanish = CABasicAnimation(keyPath: "opacity")
        vanish.fromValue = 0.8
        vanish.toValue = 0
        let wave = CAAnimationGroup()
        wave.animations = [spread, vanish]
        wave.duration = 0.4
        wave.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(wave, forKey: "wave")
        CATransaction.commit()

        // It drifts back a little later.
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(Int.random(in: 6...10))) { [weak self] in
            MainActor.assumeIsolated { self?.reappear(i, generation: gen) }
        }
    }

    private func reappear(_ i: Int, generation gen: Int) {
        guard gen == generation, live, popped.contains(i) else { return }
        let popper = poppers[i]
        withoutActions { popper.opacity = 1 }
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.2
        grow.toValue = 1
        grow.damping = 9
        grow.stiffness = 60
        grow.duration = grow.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.8
        popper.add(grow, forKey: "grow")
        popper.add(fade, forKey: "fadeIn")
        popped.remove(i)
    }
}
