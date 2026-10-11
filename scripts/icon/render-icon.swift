// Draws Bubble's app icon (an iridescent soap bubble on a deep-blue tile) and builds
// assets/AppIcon.icns from it. Everything is drawn with CoreGraphics and CoreImage; there
// is no external art.
//
// Run from anywhere:
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/icon/render-icon.swift [out.icns]
// The default output is assets/AppIcon.icns in the repo.
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : repo.appendingPathComponent("assets/AppIcon.icns")

let S: CGFloat = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ciCtx = CIContext(options: [.workingColorSpace: cs])

// MARK: - Helpers

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}
func white(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [1, 1, 1, a])! }
func black(_ a: CGFloat) -> CGColor { CGColor(colorSpace: cs, components: [0, 0, 0, a])! }

func makeCtx(_ w: Int, _ h: Int) -> CGContext {
    let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.setAllowsAntialiasing(true); c.setShouldAntialias(true)
    return c
}
/// Flips so (0,0) is top-left, like a design tool.
func flip(_ c: CGContext, _ h: CGFloat) { c.translateBy(x: 0, y: h); c.scaleBy(x: 1, y: -1) }

func savePNG(_ img: CGImage, _ url: URL) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, nil); CGImageDestinationFinalize(d)
}

func lin(_ c: CGContext, _ colors: [CGColor], _ locs: [CGFloat]? = nil, from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    c.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func rad(_ c: CGContext, _ colors: [CGColor], _ locs: [CGFloat]? = nil, center: CGPoint, r: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
    c.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: r, options: [.drawsAfterEndLocation])
}
func withClip(_ c: CGContext, _ p: CGPath, _ body: () -> Void) {
    c.saveGState(); c.addPath(p); c.clip(); body(); c.restoreGState()
}
func fill(_ c: CGContext, _ p: CGPath, _ col: CGColor) { c.saveGState(); c.addPath(p); c.setFillColor(col); c.fillPath(); c.restoreGState() }
func ellipse(_ r: CGRect) -> CGPath { CGPath(ellipseIn: r, transform: nil) }

/// A macOS-style continuous-corner tile (a superellipse).
func squircle(_ r: CGRect, n: CGFloat = 4.4) -> CGPath {
    let p = CGMutablePath(); let cx = r.midX, cy = r.midY, a = r.width / 2, b = r.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath(); return p
}

// MARK: - Tile

/// The icon grid: an 824pt tile centred in 1024, as in Apple's macOS icon template.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = squircle(tileRect)

/// Draws `body` on the tile, adds the tile's edge light and the macOS drop shadow.
func renderIcon(_ body: (CGContext) -> Void) -> CGImage {
    let L = makeCtx(Int(S), Int(S)); flip(L, S)
    L.saveGState(); L.addPath(tilePath); L.clip()
    body(L)
    // A hair of light on the top edge, faint dark on the bottom.
    L.addPath(tilePath); L.setLineWidth(5); L.replacePathWithStrokedPath(); L.clip()
    lin(L, [white(0.55), white(0.0), black(0.0), black(0.18)], [0, 0.25, 0.75, 1],
        from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    L.restoreGState()
    let layer = L.makeImage()!

    // Drop shadow: a tight one plus a soft ambient one.
    let M = makeCtx(Int(S), Int(S))
    M.saveGState()
    M.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: black(0.30))
    M.draw(layer, in: CGRect(x: 0, y: 0, width: S, height: S))
    M.restoreGState()
    M.saveGState()
    M.setShadow(offset: CGSize(width: 0, height: -24), blur: 60, color: black(0.16))
    M.draw(layer, in: CGRect(x: 0, y: 0, width: S, height: S))
    M.restoreGState()
    return M.makeImage()!
}

/// Subtle film grain for the tile. Deterministic LCG noise, so every run draws the same icon.
let grain: CGImage = {
    let n = 512; var px = [UInt8](repeating: 0, count: n * n * 4); var s: UInt32 = 0x1234567
    for i in 0..<(n * n) {
        s = s &* 1664525 &+ 1013904223; let v = UInt8((s >> 24) & 255)
        px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
    }
    let c = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let raw = c.makeImage()!
    let ci = CIImage(cgImage: raw).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.8])
        .cropped(to: CGRect(x: 0, y: 0, width: n, height: n))
    return ciCtx.createCGImage(ci, from: ci.extent)!
}()

/// Tile background: a diagonal gradient, a glow from the top left, a soft vignette and grain.
func tileBG(_ c: CGContext, _ top: UInt32, _ bottom: UInt32, glow: CGFloat, grainA: CGFloat = 0.07) {
    lin(c, [rgb(top), rgb(bottom)], from: CGPoint(x: 380, y: 100), to: CGPoint(x: 644, y: 924))
    rad(c, [white(glow), white(0)], center: CGPoint(x: 400, y: 240), r: 640)
    rad(c, [black(0), black(0.18)], [0.55, 1], center: CGPoint(x: 512, y: 512), r: 640)
    c.saveGState(); c.setAlpha(grainA); c.setBlendMode(.overlay)
    c.draw(grain, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)); c.restoreGState()
}

// MARK: - The bubble

func drawBubble(_ c: CGContext) {
    tileBG(c, 0x2340E0, 0x0D1670, glow: 0.14)
    let ctr = CGPoint(x: 512, y: 512), r: CGFloat = 300
    let circ = ellipse(CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))
    // Faint glow behind.
    rad(c, [white(0.10), white(0)], [0.7, 1], center: ctr, r: r * 1.25)
    withClip(c, circ) {
        rad(c, [white(0.04), white(0.10), white(0.42)], [0, 0.72, 1], center: ctr, r: r)
        // Thin-film colours: thin wedges stepping through cyan, pink, yellow and green
        // (CoreGraphics has no conic gradient), then cut out of the middle so they
        // only show near the rim.
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        let stops: [(CGFloat, CGFloat, CGFloat)] = [(0.49, 0.97, 1.0), (1.0, 0.48, 0.90), (1.0, 0.89, 0.42), (0.55, 1.0, 0.62), (0.49, 0.97, 1.0)]
        let N = 240
        for i in 0..<N {
            let u = CGFloat(i) / CGFloat(N) * 4; let k = min(3, Int(u)); let f = u - CGFloat(k)
            let a = stops[k], b = stops[k + 1]
            let cr: CGFloat = a.0 + (b.0 - a.0) * f; let cg: CGFloat = a.1 + (b.1 - a.1) * f; let cb: CGFloat = a.2 + (b.2 - a.2) * f
            let col = CGColor(colorSpace: cs, components: [cr, cg, cb, 0.95])!
            let step: CGFloat = 2 * CGFloat.pi / CGFloat(N); let t0: CGFloat = 0.9 + CGFloat(i) * step; let t1: CGFloat = t0 + step * 1.2
            let w = CGMutablePath(); w.move(to: ctr); w.addLine(to: CGPoint(x: ctr.x + cos(t0) * r * 1.1, y: ctr.y + sin(t0) * r * 1.1))
            w.addLine(to: CGPoint(x: ctr.x + cos(t1) * r * 1.1, y: ctr.y + sin(t1) * r * 1.1)); w.closeSubpath()
            fill(c, w, col)
        }
        c.setBlendMode(.destinationOut)
        rad(c, [black(1), black(1), black(0)], [0, 0.62, 1], center: ctr, r: r)
        c.endTransparencyLayer()
    }
    // Rim line.
    c.saveGState(); c.addPath(circ); c.setLineWidth(5); c.setStrokeColor(white(0.55)); c.strokePath(); c.restoreGState()
    // Window reflection (top left) and a small glint (bottom right).
    let hl = CGMutablePath(); hl.addArc(center: ctr, radius: r - 46, startAngle: CGFloat.pi * 1.06, endAngle: CGFloat.pi * 1.42, clockwise: false)
    fill(c, hl.copy(strokingWithWidth: 44, lineCap: .round, lineJoin: .round, miterLimit: 4), white(0.92))
    let hl2 = CGMutablePath(); hl2.addArc(center: ctr, radius: r - 40, startAngle: CGFloat.pi * 0.18, endAngle: CGFloat.pi * 0.30, clockwise: false)
    fill(c, hl2.copy(strokingWithWidth: 22, lineCap: .round, lineJoin: .round, miterLimit: 4), white(0.6))
}

/// High-quality downscale: halve repeatedly, then draw at the final size.
func downscale(_ img: CGImage, to px: Int) -> CGImage {
    var cur = img
    while cur.width / 2 >= px * 2 {
        let w = cur.width / 2
        let c = makeCtx(w, w); c.draw(cur, in: CGRect(x: 0, y: 0, width: w, height: w)); cur = c.makeImage()!
    }
    if cur.width == px { return cur }
    let c = makeCtx(px, px); c.draw(cur, in: CGRect(x: 0, y: 0, width: px, height: px)); return c.makeImage()!
}

// MARK: - Iconset and .icns

let icon = renderIcon(drawBubble)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Bubble-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    savePNG(downscale(icon, to: points), iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    savePNG(downscale(icon, to: points * 2), iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", output.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed (exit \(iconutil.terminationStatus))\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output.path)")
