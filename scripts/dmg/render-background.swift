// Draws the DMG window background: a pale blue field with a few faint soap bubbles (the app
// icon's colors), an arrow from where Bubble.app sits to the Applications shortcut, and a
// "Drag Bubble to Applications" hint. Writes assets/dmg-background.png (660x400) and
// assets/dmg-background@2x.png; dmgbuild combines the two into one HiDPI TIFF.
//
// The icon positions in scripts/dmg/settings.py must match APP_X / APPS_X / ICON_Y here.
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/dmg/render-background.swift
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let W: CGFloat = 660, H: CGFloat = 400
let APP_X: CGFloat = 170, APPS_X: CGFloat = 490, ICON_Y: CGFloat = 185   // icon centres, top-left origin
let ICON: CGFloat = 128
let cs = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: cs, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, a])!
}

/// Draws the background in points with a top-left origin; `scale` is 1 or 2.
func render(scale: Int) -> CGImage {
    let c = CGContext(data: nil, width: Int(W) * scale, height: Int(H) * scale, bitsPerComponent: 8, bytesPerRow: 0,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)

    // Field: pale blue, a little deeper at the bottom.
    let field = CGGradient(colorsSpace: cs, colors: [rgb(0xF6F8FF), rgb(0xE2E9FC)] as CFArray, locations: nil)!
    c.drawLinearGradient(field, start: .zero, end: CGPoint(x: 0, y: H), options: [])
    // A soft glow behind each icon slot.
    for x in [APP_X, APPS_X] {
        let glow = CGGradient(colorsSpace: cs, colors: [rgb(0xFFFFFF, 0.85), rgb(0xFFFFFF, 0)] as CFArray, locations: nil)!
        c.drawRadialGradient(glow, startCenter: CGPoint(x: x, y: ICON_Y), startRadius: 0,
                             endCenter: CGPoint(x: x, y: ICON_Y), endRadius: 120, options: [])
    }

    // Faint bubbles in the corners: an iridescent rim (cyan, pink, gold, mint as in the icon).
    func bubble(_ ctr: CGPoint, _ r: CGFloat, _ alpha: CGFloat) {
        let hues: [UInt32] = [0x7DF7FF, 0xFF7AE6, 0xFFE36B, 0x8CFF9E, 0x7DF7FF]
        // Segments drawn opaque inside a transparency layer, then faded as one, so they don't seam.
        c.saveGState(); c.setAlpha(alpha); c.beginTransparencyLayer(auxiliaryInfo: nil)
        let n = 120
        for i in 0..<n {
            let u = CGFloat(i) / CGFloat(n) * 4, k = min(3, Int(u)), f = u - CGFloat(k)
            let a = rgb(hues[k]).components!, b = rgb(hues[k + 1]).components!
            let col = CGColor(colorSpace: cs, components: [a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f, a[2] + (b[2] - a[2]) * f, 1])!
            let t0 = CGFloat(i) / CGFloat(n) * 2 * .pi + 0.9, t1 = t0 + 2 * .pi / CGFloat(n) * 1.15
            let p = CGMutablePath(); p.addArc(center: ctr, radius: r, startAngle: t0, endAngle: t1, clockwise: false)
            c.addPath(p.copy(strokingWithWidth: max(2, r * 0.06), lineCap: .butt, lineJoin: .round, miterLimit: 4))
            c.setFillColor(col); c.fillPath()
        }
        c.endTransparencyLayer(); c.restoreGState()
        c.addEllipse(in: CGRect(x: ctr.x - r, y: ctr.y - r, width: 2 * r, height: 2 * r))
        c.setStrokeColor(rgb(0x2340E0, alpha * 0.35)); c.setLineWidth(1); c.strokePath()
        // Window reflection.
        let hl = CGMutablePath(); hl.addArc(center: ctr, radius: r * 0.78, startAngle: .pi * 1.08, endAngle: .pi * 1.4, clockwise: false)
        c.addPath(hl.copy(strokingWithWidth: r * 0.09, lineCap: .round, lineJoin: .round, miterLimit: 4))
        c.setFillColor(rgb(0xFFFFFF, min(1, alpha * 2.2))); c.fillPath()
    }
    bubble(CGPoint(x: 52, y: 60), 70, 0.30)
    bubble(CGPoint(x: 120, y: 18), 22, 0.28)
    bubble(CGPoint(x: 618, y: 352), 84, 0.26)
    bubble(CGPoint(x: 548, y: 386), 26, 0.24)
    bubble(CGPoint(x: 625, y: 48), 16, 0.22)

    // Arrow from the app to Applications: a gentle arc with a rounded head, brand blue.
    let x0 = APP_X + ICON / 2 + 26, x1 = APPS_X - ICON / 2 - 26
    let y = ICON_Y - 4
    let shaft = CGMutablePath()
    shaft.move(to: CGPoint(x: x0, y: y))
    shaft.addQuadCurve(to: CGPoint(x: x1, y: y), control: CGPoint(x: (x0 + x1) / 2, y: y - 30))
    let stroked = shaft.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 4)
    // Head, pointing along the curve's end tangent (from the control point to the end).
    let tip = CGPoint(x: x1, y: y)
    let ang = atan2(30.0, Double((x1 - x0) / 2))
    let dir = CGPoint(x: CGFloat(cos(ang)), y: CGFloat(sin(ang)))
    let nrm = CGPoint(x: -dir.y, y: dir.x)
    let back = CGPoint(x: tip.x - dir.x * 22, y: tip.y - dir.y * 22)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: back.x + nrm.x * 14, y: back.y + nrm.y * 14))
    head.addLine(to: tip)
    head.addLine(to: CGPoint(x: back.x - nrm.x * 14, y: back.y - nrm.y * 14))
    let headStroke = head.copy(strokingWithWidth: 7, lineCap: .round, lineJoin: .round, miterLimit: 4)
    let arrow = CGMutablePath(); arrow.addPath(stroked); arrow.addPath(headStroke)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 2), blur: 6, color: rgb(0x0D1670, 0.25))
    c.addPath(arrow); c.clip()
    let ag = CGGradient(colorsSpace: cs, colors: [rgb(0x6F86FF), rgb(0x2340E0)] as CFArray, locations: nil)!
    c.drawLinearGradient(ag, start: CGPoint(x: x0, y: 0), end: CGPoint(x: x1, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()

    // Hint text, centred near the bottom. CoreText draws upright in a y-up space.
    c.saveGState()
    c.translateBy(x: 0, y: H); c.scaleBy(x: 1, y: -1)
    let font = CTFontCreateUIFontForLanguage(.system, 15, nil)!
    let bold = CTFontCreateCopyWithSymbolicTraits(font, 15, nil, .traitBold, .traitBold) ?? font
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): bold,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): rgb(0x1B2A6B, 0.72),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Drag Bubble to Applications", attributes: attrs))
    let bounds = CTLineGetImageBounds(line, c)
    c.textPosition = CGPoint(x: (W - bounds.width) / 2 - bounds.minX, y: 62)
    CTLineDraw(line, c)
    c.restoreGState()
    return c.makeImage()!
}

func savePNG(_ img: CGImage, _ url: URL, dpi: Int) {
    let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, img, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    CGImageDestinationFinalize(d)
    print("Wrote \(url.path) (\(img.width)x\(img.height))")
}
savePNG(render(scale: 1), repo.appendingPathComponent("assets/dmg-background.png"), dpi: 72)
savePNG(render(scale: 2), repo.appendingPathComponent("assets/dmg-background@2x.png"), dpi: 144)
