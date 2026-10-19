// ac-menubar brand generator.
//
// One set of shapes drives every output, so the PNGs and the SVGs can't drift apart:
//   Resources/Brand/icon.svg, wordmark.svg, glyph.svg
//   Resources/Brand/png/icon-{1024,512,256,128,64,32,16}.png, wordmark@2x.png, wordmark-dark@2x.png
//   Resources/AppIcon.icns  (built with iconutil from a temporary .iconset)
//
// Usage, from the repo root:   swift tools/make_icon.swift [repo-root]
//
// Edit the shapes here, not the SVGs: the SVGs are regenerated on every run.
// Coordinates are a 1024 × 1024 canvas with y pointing down, like SVG.

import AppKit
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

typealias P = CGPoint

enum Cmd {
    case move(P), line(P), cubic(P, P, P), close
}

struct Path {
    var cmds: [Cmd] = []

    mutating func move(_ p: P) { cmds.append(.move(p)) }
    mutating func line(_ p: P) { cmds.append(.line(p)) }
    mutating func cubic(_ c1: P, _ c2: P, _ to: P) { cmds.append(.cubic(c1, c2, to)) }
    mutating func close() { cmds.append(.close) }
    mutating func append(_ other: Path) { cmds += other.cmds }

    var cg: CGPath {
        let path = CGMutablePath()
        for cmd in cmds {
            switch cmd {
            case .move(let p): path.move(to: p)
            case .line(let p): path.addLine(to: p)
            case .cubic(let c1, let c2, let p): path.addCurve(to: p, control1: c1, control2: c2)
            case .close: path.closeSubpath()
            }
        }
        return path
    }

    var svg: String {
        cmds.map { cmd -> String in
            switch cmd {
            case .move(let p): return "M\(f(p))"
            case .line(let p): return "L\(f(p))"
            case .cubic(let c1, let c2, let p): return "C\(f(c1)) \(f(c2)) \(f(p))"
            case .close: return "Z"
            }
        }.joined()
    }

    /// Converts a CoreGraphics path (for example glyph outlines) into commands. Quadratics become cubics.
    init(cg path: CGPath) {
        var out: [Cmd] = []
        var current = P.zero, start = P.zero
        path.applyWithBlock { el in
            let pts = el.pointee.points
            switch el.pointee.type {
            case .moveToPoint: current = pts[0]; start = current; out.append(.move(current))
            case .addLineToPoint: current = pts[0]; out.append(.line(current))
            case .addQuadCurveToPoint:
                let q = pts[0], to = pts[1]
                let c1 = P(x: current.x + 2 / 3 * (q.x - current.x), y: current.y + 2 / 3 * (q.y - current.y))
                let c2 = P(x: to.x + 2 / 3 * (q.x - to.x), y: to.y + 2 / 3 * (q.y - to.y))
                current = to; out.append(.cubic(c1, c2, to))
            case .addCurveToPoint: current = pts[2]; out.append(.cubic(pts[0], pts[1], pts[2]))
            case .closeSubpath: current = start; out.append(.close)
            @unknown default: break
            }
        }
        cmds = out
    }

    init() {}
}

func f(_ v: CGFloat) -> String {
    let rounded = (v * 100).rounded() / 100
    var s = String(format: "%.2f", rounded)
    while s.contains(".") && (s.hasSuffix("0") || s.hasSuffix(".")) { s.removeLast() }
    return s == "-0" ? "0" : s
}

func f(_ p: P) -> String { "\(f(p.x)) \(f(p.y))" }

func + (a: P, b: P) -> P { P(x: a.x + b.x, y: a.y + b.y) }
func * (k: CGFloat, p: P) -> P { P(x: k * p.x, y: k * p.y) }

/// A rounded rectangle with Apple-style continuous ("squircle") corners, using Figma's
/// corner-smoothing construction. smoothing 0.6 is close to the iOS/macOS icon shape.
func squircle(_ r: CGRect, radius: CGFloat, smoothing: CGFloat = 0.6) -> Path {
    let half = min(r.width, r.height) / 2
    let R = min(radius, half)
    var s = smoothing
    var p = (1 + s) * R
    if p > half { p = half; s = max(0, half / R - 1) }

    let deg = CGFloat.pi / 180
    let arcMeasure = 90 * (1 - s)                       // degrees of true circular arc
    let arcLen = sin(arcMeasure / 2 * deg) * R * sqrt(2)
    let alpha = (90 - arcMeasure) / 2
    let p3p4 = R * tan(alpha / 2 * deg)
    let beta = 45 * s
    let c = p3p4 * cos(beta * deg)
    let d = c * tan(beta * deg)
    let b = (p - arcLen - c - d) / 3
    let a = 2 * b

    // Each corner is drawn in a local frame: u runs along the edge arriving at the corner,
    // v along the edge leaving it. Local (X, Y) maps to K + (X - p)·u + Y·v.
    var path = Path()
    let corners: [(K: P, u: P, v: P)] = [
        (P(x: r.maxX, y: r.minY), P(x: 1, y: 0), P(x: 0, y: 1)),
        (P(x: r.maxX, y: r.maxY), P(x: 0, y: 1), P(x: -1, y: 0)),
        (P(x: r.minX, y: r.maxY), P(x: -1, y: 0), P(x: 0, y: -1)),
        (P(x: r.minX, y: r.minY), P(x: 0, y: -1), P(x: 1, y: 0)),
    ]
    for (i, k) in corners.enumerated() {
        func map(_ x: CGFloat, _ y: CGFloat) -> P { k.K + (x - p) * k.u + y * k.v }
        if i == 0 { path.move(map(0, 0)) } else { path.line(map(0, 0)) }
        path.cubic(map(a, 0), map(a + b, 0), map(a + b + c, d))
        // Circular arc around local centre (p - R, R), from -45° - θ/2 to -45° + θ/2.
        let theta = arcMeasure * deg
        let a0 = -CGFloat.pi / 4 - theta / 2, a1 = -CGFloat.pi / 4 + theta / 2
        let kk = 4 / 3 * tan(theta / 4) * R
        let cx = p - R, cy = R
        let s0 = (cx + R * cos(a0), cy + R * sin(a0)), s1 = (cx + R * cos(a1), cy + R * sin(a1))
        path.cubic(map(s0.0 - kk * sin(a0), s0.1 + kk * cos(a0)),
                   map(s1.0 + kk * sin(a1), s1.1 - kk * cos(a1)),
                   map(s1.0, s1.1))
        let ex = s1.0, ey = s1.1
        path.cubic(map(ex + d, ey + c), map(ex + d, ey + b + c), map(ex + d, ey + a + b + c))
    }
    path.close()
    return path
}

/// A vertical airflow line: one gentle period, x(y) = x0 - amp·sin(2π·t), built from Hermite
/// segments with exact tangents. amp 0 gives a straight line.
func wave(x0: CGFloat, top: CGFloat, bottom: CGFloat, amp: CGFloat) -> Path {
    let len = bottom - top
    let w = 2 * CGFloat.pi / len
    func x(_ y: CGFloat) -> CGFloat { x0 - amp * sin(w * (y - top)) }
    func dx(_ y: CGFloat) -> CGFloat { -amp * w * cos(w * (y - top)) }
    let n = 8
    let h = len / CGFloat(n)
    var p = Path()
    p.move(P(x: x(top), y: top))
    for i in 0..<n {
        let y0 = top + CGFloat(i) * h, y1 = y0 + h
        p.cubic(P(x: x(y0) + h / 3 * dx(y0), y: y0 + h / 3),
                P(x: x(y1) - h / 3 * dx(y1), y: y1 - h / 3),
                P(x: x(y1), y: y1))
    }
    return p
}

// MARK: - Paint

struct RGBA {
    var r, g, b, a: CGFloat
    init(_ hex: UInt32, _ a: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255; g = CGFloat((hex >> 8) & 0xFF) / 255; b = CGFloat(hex & 0xFF) / 255
        self.a = a
    }
    var cg: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
}

enum Paint {
    case solid(RGBA)
    case ink(RGBA)              // solid in the PNG; `currentColor` in the SVG, so CSS can recolour it
    case linear(P, P, [(CGFloat, RGBA)])
}

struct Shadow {
    var dx: CGFloat = 0, dy: CGFloat, sigma: CGFloat, color: RGBA
}

enum Mode {
    case fill(evenOdd: Bool)
    case stroke(width: CGFloat)
}

struct Item {
    var path: Path
    var mode: Mode = .fill(evenOdd: false)
    var paint: Paint
    var shadow: Shadow? = nil
    var clip: Path? = nil
}

/// Live SVG text; the PNG renderer draws the same text from glyph outlines (`outline`).
struct TextRun {
    var text: String
    var weight: Int            // CSS weight, mapped to NSFont.Weight for the PNG
}

struct TextLine {
    var origin: P              // baseline start
    var size: CGFloat
    var tracking: CGFloat      // extra space after every character, in points (SVG letter-spacing)
    var runs: [TextRun]
}

// MARK: - Brand

/// Monochrome palette: a near-black tile with a white mark. Nothing in the brand carries colour.
let tileStops: [(CGFloat, RGBA)] = [(0, RGBA(0x1C1C1E)), (1, RGBA(0x0B0B0C))]          // top → bottom
let rimStops: [(CGFloat, RGBA)] = [(0, RGBA(0xFFFFFF, 0.22)), (0.45, RGBA(0xFFFFFF, 0.06)), (1, RGBA(0xFFFFFF, 0.10))]
let black = RGBA(0x0B0B0C), white = RGBA(0xFFFFFF)

/// The emblem: the indoor unit as a solid rounded bar with a fine outlet cut along its base, and
/// three airflow lines below in one line weight with round caps.
struct Mark {
    var unit: CGRect                   // bounds of the unit
    var radius: CGFloat                // its corner radius
    var weight: CGFloat                // airflow line weight
    var outlet: (inset: CGFloat, y: CGFloat, weight: CGFloat)?   // cut: inset from the unit's sides, centre y, thickness
    var flowXs: [CGFloat]
    var flowTop: CGFloat, flowBottom: CGFloat, flowAmp: CGFloat

    /// Full-size emblem: fine lines and generous space around it.
    static let regular = Mark(
        unit: CGRect(x: 262, y: 288, width: 500, height: 120), radius: 40, weight: 24,
        outlet: (inset: 64, y: 372, weight: 24),
        flowXs: [408, 512, 616], flowTop: 490, flowBottom: 715, flowAmp: 7)

    /// 16 and 32 px: bigger and heavier, snapped to the 32 px grid (32 units = 1 px there), so the
    /// outlet cut is one crisp pixel and the airflow lines are straight, two pixels wide with
    /// two-pixel gaps.
    static let small = Mark(
        unit: CGRect(x: 208, y: 224, width: 608, height: 192), radius: 60, weight: 64,
        outlet: (inset: 96, y: 368, weight: 32),
        flowXs: [384, 512, 640], flowTop: 512, flowBottom: 768, flowAmp: 0)

    /// 16 px: snapped to the 16 px grid (64 units = 1 px). The bar spans 3–13 px with no outlet
    /// (it can't survive at this size); three 2 px lines with 1 px gaps sit centred below it.
    static let tiny = Mark(
        unit: CGRect(x: 192, y: 192, width: 640, height: 192), radius: 64, weight: 128,
        outlet: nil,
        flowXs: [320, 512, 704], flowTop: 576, flowBottom: 768, flowAmp: 0)

    /// Menu bar template glyph: the full-size silhouette with gentle curves, weighted so the lines
    /// come out about 1.5 pt at 18 pt, like a regular-weight SF Symbol.
    static let glyph = Mark(
        unit: CGRect(x: 262, y: 280, width: 500, height: 136), radius: 44, weight: 44,
        outlet: (inset: 70, y: 378, weight: 30),
        flowXs: [404, 512, 620], flowTop: 498, flowBottom: 730, flowAmp: 8)

    static func forPixels(_ px: Int) -> Mark { px <= 16 ? .tiny : px <= 32 ? .small : .regular }

    var flows: [Path] {
        flowXs.map { wave(x0: $0, top: flowTop, bottom: flowBottom, amp: flowAmp) }
    }

    /// Bounds of everything the mark paints, caps included.
    var bounds: CGRect {
        let h = weight / 2
        let flow = CGRect(x: flowXs.min()! - flowAmp - h, y: flowTop - h,
                          width: flowXs.max()! - flowXs.min()! + 2 * (flowAmp + h), height: flowBottom - flowTop + weight)
        return unit.union(flow)
    }

    func items(_ ink: Paint) -> [Item] {
        var body = squircle(unit, radius: radius)
        if let o = outlet {
            let cut = CGRect(x: unit.minX + o.inset, y: o.y - o.weight / 2, width: unit.width - 2 * o.inset, height: o.weight)
            body.append(squircle(cut, radius: o.weight / 2))
        }
        return [Item(path: body, mode: .fill(evenOdd: true), paint: ink)]
            + flows.map { Item(path: $0, mode: .stroke(width: weight), paint: ink) }
    }
}

let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185.4

func iconItems(pixels: Int) -> [Item] {
    let small = pixels <= 32
    let tile = squircle(tileRect, radius: tileRadius)
    var items = [
        Item(path: tile, paint: .linear(P(x: 512, y: 100), P(x: 512, y: 924), tileStops),
             shadow: Shadow(dy: 12, sigma: 14, color: RGBA(0x000000, 0.30))),
    ]
    if !small {
        // Hairline rim, brightest along the top edge (clipped to the tile, so only the inner half shows).
        items.append(Item(path: tile, mode: .stroke(width: 5),
                          paint: .linear(P(x: 512, y: 100), P(x: 512, y: 924), rimStops), clip: tile))
    }
    return items + Mark.forPixels(pixels).items(.solid(white))
}

/// Template glyph for the menu bar: black, in a tight square.
let glyphMark = Mark.glyph
let glyphBox: CGRect = {
    let b = glyphMark.bounds, side = max(b.width, b.height) + 16
    return CGRect(x: b.midX - side / 2, y: b.midY - side / 2, width: side, height: side)
}()

// MARK: - CoreGraphics renderer

func cgGradient(_ stops: [(CGFloat, RGBA)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
               colors: stops.map { $0.1.cg } as CFArray, locations: stops.map { $0.0 })!
}

/// Draws items into `ctx`, whose CTM maps the design space to the device; `scale` is the
/// device-pixels-per-design-unit factor, needed because CG shadows ignore the CTM.
func draw(_ items: [Item], in ctx: CGContext, scale: CGFloat) {
    for item in items {
        ctx.saveGState()
        if let clip = item.clip { ctx.addPath(clip.cg); ctx.clip() }
        if let s = item.shadow {
            // Device space is y-up, so a downward shadow has a negative height. CG's blur is ~2σ.
            ctx.setShadow(offset: CGSize(width: s.dx * scale, height: -s.dy * scale), blur: 2 * s.sigma * scale, color: s.color.cg)
        }
        let cgPath = item.path.cg
        switch item.paint {
        case .solid(let c), .ink(let c):
            ctx.addPath(cgPath)
            switch item.mode {
            case .fill(let eo):
                ctx.setFillColor(c.cg)
                ctx.fillPath(using: eo ? .evenOdd : .winding)
            case .stroke(let w):
                ctx.setStrokeColor(c.cg); ctx.setLineWidth(w); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        case .linear(let a, let b, let stops):
            if item.shadow != nil { ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
            var rule = CGPathFillRule.winding
            switch item.mode {
            case .fill(let eo): ctx.addPath(cgPath); rule = eo ? .evenOdd : .winding
            case .stroke(let w): ctx.addPath(cgPath.copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10))
            }
            ctx.clip(using: rule)
            ctx.drawLinearGradient(cgGradient(stops), start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            if item.shadow != nil { ctx.endTransparencyLayer() }
        }
        ctx.restoreGState()
    }
}

/// Renders a y-down design space of `designSize` into a transparent `width` × `height` bitmap.
func render(width: Int, height: Int, designSize: CGSize, _ body: (CGContext, CGFloat) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(width) / designSize.width
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: scale, y: -scale)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    body(ctx, scale)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ url: URL, dpi: Int = 72) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi] as CFDictionary)
    precondition(CGImageDestinationFinalize(dest), "could not write \(url.path)")
}

func iconImage(pixels: Int) -> CGImage {
    let items = iconItems(pixels: pixels)
    return render(width: pixels, height: pixels, designSize: CGSize(width: 1024, height: 1024)) { ctx, s in
        draw(items, in: ctx, scale: s)
    }
}

// MARK: - Text

let fontFamily = "'SF Pro Display', 'SF Pro', -apple-system, BlinkMacSystemFont, system-ui, 'Helvetica Neue', Helvetica, Arial, sans-serif"

func brandFont(size: CGFloat, weight: Int) -> NSFont {
    let weights: [(Int, NSFont.Weight)] = [(700, .bold), (600, .semibold), (500, .medium), (400, .regular), (300, .light)]
    return NSFont.systemFont(ofSize: size, weight: weights.first { weight >= $0.0 }?.1 ?? .thin)
}

/// Glyph outlines of each run, laid out one after the other on the baseline, in y-down space.
/// Returns each run's outline and advance (tracking included).
func outline(_ line: TextLine) -> [(TextRun, Path, CGFloat)] {
    var x = line.origin.x
    var out: [(TextRun, Path, CGFloat)] = []
    for run in line.runs {
        let font = brandFont(size: line.size, weight: run.weight)
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: run.text, attributes: [.font: font, .kern: line.tracking]))
        let path = CGMutablePath()
        for glyphRun in CTLineGetGlyphRuns(ct) as! [CTRun] {
            let attrs = CTRunGetAttributes(glyphRun) as NSDictionary
            let runFont = attrs[kCTFontAttributeName] as! CTFont
            let count = CTRunGetGlyphCount(glyphRun)
            var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(glyphRun, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(glyphRun, CFRange(location: 0, length: 0), &positions)
            for (g, pos) in zip(glyphs, positions) {
                var t = CGAffineTransform(translationX: x + pos.x, y: line.origin.y).scaledBy(x: 1, y: -1)
                if let gp = CTFontCreatePathForGlyph(runFont, g, &t) { path.addPath(gp) }
            }
        }
        let advance = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
        out.append((run, Path(cg: path), advance))
        x += advance
    }
    return out
}

// MARK: - SVG writer

final class SVG {
    private var defs: [String] = []
    private var ids: [String: String] = [:]
    private let prefix: String
    init(prefix: String) { self.prefix = prefix }

    private func def(_ key: String, _ make: (String) -> String) -> String {
        if let id = ids[key] { return id }
        let id = "\(prefix)\(ids.count)"
        ids[key] = id
        defs.append(make(id))
        return id
    }

    private func stops(_ s: [(CGFloat, RGBA)]) -> String {
        s.map { o, c in
            let op = c.a < 1 ? " stop-opacity=\"\(f(c.a))\"" : ""
            return "<stop offset=\"\(f(o))\" stop-color=\"\(c.hex)\"\(op)/>"
        }.joined()
    }

    func paint(_ p: Paint) -> (value: String, opacity: CGFloat) {
        switch p {
        case .solid(let c): return (c.hex, c.a)
        case .ink(let c): return ("currentColor", c.a)
        case .linear(let a, let b, let s):
            let id = def("lin\(f(a))\(f(b))\(stops(s))") {
                "<linearGradient id=\"\($0)\" x1=\"\(f(a.x))\" y1=\"\(f(a.y))\" x2=\"\(f(b.x))\" y2=\"\(f(b.y))\" gradientUnits=\"userSpaceOnUse\">\(stops(s))</linearGradient>"
            }
            return ("url(#\(id))", 1)
        }
    }

    func filter(_ s: Shadow) -> String {
        def("sh\(f(s.dx))\(f(s.dy))\(f(s.sigma))\(s.color.hex)\(f(s.color.a))") {
            "<filter id=\"\($0)\" filterUnits=\"userSpaceOnUse\" x=\"0\" y=\"0\" width=\"1024\" height=\"1024\" color-interpolation-filters=\"sRGB\">"
                + "<feDropShadow dx=\"\(f(s.dx))\" dy=\"\(f(s.dy))\" stdDeviation=\"\(f(s.sigma))\" flood-color=\"\(s.color.hex)\" flood-opacity=\"\(f(s.color.a))\"/></filter>"
        }
    }

    func element(_ item: Item) -> String {
        let (value, opacity) = paint(item.paint)
        var attrs = ""
        switch item.mode {
        case .fill(let eo):
            attrs = "fill=\"\(value)\"" + (opacity < 1 ? " fill-opacity=\"\(f(opacity))\"" : "") + (eo ? " fill-rule=\"evenodd\"" : "")
        case .stroke(let w):
            attrs = "fill=\"none\" stroke=\"\(value)\"" + (opacity < 1 ? " stroke-opacity=\"\(f(opacity))\"" : "")
                + " stroke-width=\"\(f(w))\" stroke-linecap=\"round\" stroke-linejoin=\"round\""
        }
        if let s = item.shadow { attrs += " filter=\"url(#\(filter(s)))\"" }
        if let clip = item.clip {
            let id = def("clip\(clip.svg)") { "<clipPath id=\"\($0)\"><path d=\"\(clip.svg)\"/></clipPath>" }
            attrs += " clip-path=\"url(#\(id))\""
        }
        return "<path d=\"\(item.path.svg)\" \(attrs)/>"
    }

    func text(_ line: TextLine, fontFamily: String) -> String {
        let spans = line.runs.map { "<tspan font-weight=\"\($0.weight)\">\($0.text)</tspan>" }.joined()
        return "<text x=\"\(f(line.origin.x))\" y=\"\(f(line.origin.y))\" fill=\"currentColor\" font-family=\"\(fontFamily)\" "
            + "font-size=\"\(f(line.size))\" letter-spacing=\"\(f(line.tracking))\">\(spans)</text>"
    }

    func document(width: CGFloat, height: CGFloat, viewBox: CGRect, title: String, style: String? = nil, body: [String]) -> String {
        var out = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(width))\" height=\"\(f(height))\" viewBox=\"\(f(viewBox.minX)) \(f(viewBox.minY)) \(f(viewBox.width)) \(f(viewBox.height))\">\n"
        out += "  <title>\(title)</title>\n"
        out += "  <!-- Generated by tools/make_icon.swift; edit the generator, not this file. -->\n"
        if let style { out += "  <style>\(style)</style>\n" }
        if !defs.isEmpty { out += "  <defs>\n" + defs.map { "    \($0)\n" }.joined() + "  </defs>\n" }
        out += body.map { "  \($0)\n" }.joined()
        out += "</svg>\n"
        return out
    }
}

// MARK: - Wordmark

// Laid out in points; the PNGs are rendered at 2×. The bare emblem (no tile) sits left of the name,
// a little under twice the cap height, so it works in black or white on any background.
let wmHeight: CGFloat = 120
let wmFontSize: CGFloat = 50
let wmTracking: CGFloat = 0.035 * wmFontSize
let wmMark = Mark.regular
let wmMarkHeight: CGFloat = 64
let wmPad: CGFloat = 20                // left and right margin
let wmGap: CGFloat = 28                // emblem to text

var wmMarkScale: CGFloat { wmMarkHeight / wmMark.bounds.height }

func wordmarkLine() -> TextLine {
    let cap = brandFont(size: wmFontSize, weight: 300).capHeight
    let x = wmPad + wmMark.bounds.width * wmMarkScale + wmGap
    return TextLine(origin: P(x: x, y: (wmHeight / 2 + cap / 2).rounded()), size: wmFontSize, tracking: wmTracking, runs: [
        TextRun(text: "ac", weight: 500),
        TextRun(text: "-menubar", weight: 300),
    ])
}

/// Maps the emblem's design space into the lockup: left margin, vertically centred.
var wmMarkTransform: CGAffineTransform {
    let b = wmMark.bounds, k = wmMarkScale
    return CGAffineTransform(translationX: wmPad, y: (wmHeight - b.height * k) / 2)
        .scaledBy(x: k, y: k).translatedBy(x: -b.minX, y: -b.minY)
}

func wordmarkWidth() -> CGFloat {
    let runs = outline(wordmarkLine())
    // The last character's tracking is trailing space; leave it out of the margin.
    return (wordmarkLine().origin.x + runs.reduce(0) { $0 + $1.2 } - wmTracking + wmPad).rounded()
}

func wordmarkImage(ink: RGBA, scale: CGFloat) -> CGImage {
    let w = wordmarkWidth()
    let runs = outline(wordmarkLine())
    return render(width: Int(w * scale), height: Int(wmHeight * scale), designSize: CGSize(width: w, height: wmHeight)) { ctx, s in
        ctx.saveGState()
        ctx.concatenate(wmMarkTransform)
        draw(wmMark.items(.solid(ink)), in: ctx, scale: s * wmMarkScale)
        ctx.restoreGState()
        draw(runs.map { Item(path: $0.1, paint: .solid(ink)) }, in: ctx, scale: s)
    }
}

func wordmarkSVG() -> String {
    let w = wordmarkWidth()
    let svg = SVG(prefix: "w")
    let t = wmMarkTransform
    let mark = wmMark.items(.ink(black)).map { svg.element($0) }.joined(separator: "\n    ")
    let style = "svg { color: \(black.hex) } @media (prefers-color-scheme: dark) { svg { color: \(white.hex) } }"
    return svg.document(width: w, height: wmHeight, viewBox: CGRect(x: 0, y: 0, width: w, height: wmHeight),
                        title: "ac-menubar", style: style,
                        body: ["<g transform=\"matrix(\(f(t.a)) 0 0 \(f(t.d)) \(f(t.tx)) \(f(t.ty)))\">\n    \(mark)\n  </g>",
                               svg.text(wordmarkLine(), fontFamily: fontFamily)])
}

// MARK: - Main

let fm = FileManager.default
let root: URL = {
    if CommandLine.arguments.count > 1 { return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
    let script = URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
    return script.standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()
}()
let brand = root.appendingPathComponent("Resources/Brand", isDirectory: true)
let pngDir = brand.appendingPathComponent("png", isDirectory: true)
try fm.createDirectory(at: pngDir, withIntermediateDirectories: true)

// SVGs
do {
    let svg = SVG(prefix: "g")
    let body = iconItems(pixels: 1024).map { svg.element($0) }
    try svg.document(width: 1024, height: 1024, viewBox: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                     title: "ac-menubar", body: body)
        .write(to: brand.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)

    let gsvg = SVG(prefix: "m")
    try gsvg.document(width: 64, height: 64, viewBox: glyphBox, title: "ac-menubar glyph",
                      body: glyphMark.items(.solid(RGBA(0x000000))).map { gsvg.element($0) })
        .write(to: brand.appendingPathComponent("glyph.svg"), atomically: true, encoding: .utf8)

    try wordmarkSVG().write(to: brand.appendingPathComponent("wordmark.svg"), atomically: true, encoding: .utf8)
}

// PNGs
for px in [1024, 512, 256, 128, 64, 32, 16] {
    writePNG(iconImage(pixels: px), pngDir.appendingPathComponent("icon-\(px).png"))
}
writePNG(wordmarkImage(ink: black, scale: 2), pngDir.appendingPathComponent("wordmark@2x.png"), dpi: 144)
writePNG(wordmarkImage(ink: white, scale: 2), pngDir.appendingPathComponent("wordmark-dark@2x.png"), dpi: 144)

// .icns
let work = fm.temporaryDirectory.appendingPathComponent("ac-menubar-\(UUID().uuidString)", isDirectory: true)
let iconset = work.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }
for pt in [16, 32, 128, 256, 512] {
    writePNG(iconImage(pixels: pt), iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    writePNG(iconImage(pixels: pt * 2), iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"), dpi: 144)
}
let icns = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed with status \(iconutil.terminationStatus)") }

print("Wrote \(brand.path)/{icon,wordmark,glyph}.svg, \(pngDir.path)/*.png and \(icns.path)")
