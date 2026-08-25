import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

// The app icon, drawn rather than painted, so the shape, the palette and the
// sizes stay one set of numbers. Same teal and same squircle as the SwiftProj
// icon - only the artwork inside differs, which is what makes a family read as
// a family.

struct Palette {
    var top: CGColor
    var bottom: CGColor
}

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func white(_ a: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }

let palettes: [String: Palette] = [
    "teal": Palette(top: rgb(66, 205, 190), bottom: rgb(10, 98, 122))
]

/// A superellipse, which is the continuous-corner shape Apple's icons use. A
/// plain rounded rectangle joins its arcs to the straight edges abruptly, and at
/// icon size that join is visible as a flat spot.
func squircle(in rect: CGRect, n: CGFloat = 4.7) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    for step in 0...steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Pieces the variants are built from
//
// Everything is a fraction of the art square it is handed, so one description
// serves 1024 and 16 alike.

/// How the iris is inked. `seamSide` is the one that matters: see `aperture`.
struct ApertureStyle {
    var white: CGFloat = 0.84
    /// Which side of the hexagon-edge line the dark seam lies on:
    /// -1 inside it, 0 straddling it, +1 outside it.
    var seamSide: CGFloat = -1
}

/// The iris of a lens: a ring with a hexagonal opening, and the seams where one
/// blade laps over the next.
///
/// A blade has one straight edge, and that line does two jobs - it bounds the
/// opening, and it bounds the gap where the next blade slides under it. So the
/// seam has to lie wholly on one side of the line rather than straddle it;
/// straddling snaps the opening's edge sideways by half a band at each vertex.
/// Which side is a matter of taste, hence `seamSide`.
///
/// Where the seam stops is not a matter of taste: it stops at the opening. That
/// is left to a clip of the blade ring - the disc with the hexagon taken out of
/// it - so each seam is cut by the very edge it has to meet, at any offset and
/// any size, rather than by an endpoint worked out per seam.
func aperture(_ ctx: CGContext, centre c: CGPoint, radius R: CGFloat,
              seam: CGColor, style: ApertureStyle = ApertureStyle()) {
    let inner = R * 0.52
    let turn = CGFloat.pi / 6
    let band = R * 0.10
    let disc = CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2)

    func vertex(_ i: Int) -> CGPoint {
        let a = CGFloat(i) * .pi / 3 + turn
        return CGPoint(x: c.x + inner * cos(a), y: c.y + inner * sin(a))
    }

    let hex = CGMutablePath()
    for i in 0..<6 {
        let p = vertex(i)
        if i == 0 { hex.move(to: p) } else { hex.addLine(to: p) }
    }
    hex.closeSubpath()

    let ring = CGMutablePath()
    ring.addEllipse(in: disc)
    ring.addPath(hex)
    ctx.setFillColor(white(style.white))
    ctx.addPath(ring)
    ctx.fillPath(using: .evenOdd)

    // The blades themselves, so a seam can neither spill past the rim nor creep
    // into the opening.
    ctx.saveGState()
    ctx.addPath(ring)
    ctx.clip(using: .evenOdd)
    ctx.setStrokeColor(seam)
    ctx.setLineWidth(band)
    ctx.setLineCap(.butt)
    for i in 0..<6 {
        let v = vertex(i), u = vertex(i - 1)
        var d = CGPoint(x: v.x - u.x, y: v.y - u.y)
        let len = hypot(d.x, d.y)
        d = CGPoint(x: d.x / len, y: d.y / len)

        // Outward normal of the hexagon edge this seam continues.
        let mid = CGPoint(x: (u.x + v.x) / 2, y: (u.y + v.y) / 2)
        var n = CGPoint(x: mid.x - c.x, y: mid.y - c.y)
        let nlen = hypot(n.x, n.y)
        n = CGPoint(x: n.x / nlen, y: n.y / nlen)
        let shift = style.seamSide * band / 2

        // Drawn from the far vertex so the run along the opening is there to be
        // clipped away; what survives starts exactly where the opening ends.
        let a = CGPoint(x: u.x + n.x * shift, y: u.y + n.y * shift)
        ctx.move(to: a)
        ctx.addLine(to: CGPoint(x: a.x + d.x * R * 2.4, y: a.y + d.y * R * 2.4))
    }
    ctx.strokePath()
    ctx.restoreGState()
}

/// The four mounts an old album used to hold a print by its corners: a right
/// triangle at each corner of the print, hypotenuse facing in.
func photoCorners(_ ctx: CGContext, print p: CGRect, leg: CGFloat, alpha: CGFloat = 0.95) {
    ctx.setFillColor(white(alpha))
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: p.minX, y: p.minY),  1,  1),
        (CGPoint(x: p.maxX, y: p.minY), -1,  1),
        (CGPoint(x: p.maxX, y: p.maxY), -1, -1),
        (CGPoint(x: p.minX, y: p.maxY),  1, -1)
    ]
    for (corner, sx, sy) in corners {
        let tri = CGMutablePath()
        tri.move(to: CGPoint(x: corner.x + leg * sx, y: corner.y))
        tri.addLine(to: corner)
        tri.addLine(to: CGPoint(x: corner.x, y: corner.y + leg * sy))
        tri.closeSubpath()
        ctx.addPath(tri)
    }
    ctx.fillPath()
}

/// The corner brackets a viewfinder or a crop tool draws.
func brackets(_ ctx: CGContext, frame f: CGRect, arm: CGFloat, weight: CGFloat, alpha: CGFloat = 0.95) {
    ctx.setStrokeColor(white(alpha))
    ctx.setLineWidth(weight)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: f.minX, y: f.minY),  1,  1),
        (CGPoint(x: f.maxX, y: f.minY), -1,  1),
        (CGPoint(x: f.maxX, y: f.maxY), -1, -1),
        (CGPoint(x: f.minX, y: f.maxY),  1, -1)
    ]
    for (corner, sx, sy) in corners {
        ctx.move(to: CGPoint(x: corner.x + arm * sx, y: corner.y))
        ctx.addLine(to: corner)
        ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + arm * sy))
    }
    ctx.strokePath()
}

func roundedRect(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}


/// A print held by its four mounts: the paper, its edge, and the corners.
func mountedPrint(_ ctx: CGContext, _ p: CGRect, w: CGFloat) {
    ctx.setFillColor(white(0.16))
    ctx.addRect(p)
    ctx.fillPath()
    ctx.setStrokeColor(white(0.42))
    ctx.setLineWidth(w * 0.020)
    ctx.addRect(p)
    ctx.strokePath()
    photoCorners(ctx, print: p, leg: w * 0.145)
}

// MARK: - The variants

func drawArt(_ ctx: CGContext, in rect: CGRect, variant: String, seam: CGColor,
             style: ApertureStyle) {
    let w = rect.width
    let c = CGPoint(x: rect.midX, y: rect.midY)

    switch variant {

    // 1. The iris alone, filling the tile. The most camera thing there is, and
    //    the one shape that still reads at 16 points.
    case "aperture":
        aperture(ctx, centre: c, radius: w * 0.325, seam: seam, style: style)

    // 2. The front element seen head on: a barrel ring, the glass, and the
    //    reflection a coated element throws.
    case "lens":
        let R = w * 0.335
        ctx.setStrokeColor(white(0.95))
        ctx.setLineWidth(w * 0.055)
        ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: R * 2, height: R * 2))
        ctx.strokePath()

        let glass = R * 0.72
        ctx.setFillColor(white(0.20))
        ctx.addEllipse(in: CGRect(x: c.x - glass, y: c.y - glass, width: glass * 2, height: glass * 2))
        ctx.fillPath()

        let iris = R * 0.44
        ctx.setStrokeColor(white(0.9))
        ctx.setLineWidth(w * 0.030)
        ctx.addEllipse(in: CGRect(x: c.x - iris, y: c.y - iris, width: iris * 2, height: iris * 2))
        ctx.strokePath()

        // The glint, an arc of the glass rather than a blob stuck on top.
        ctx.setStrokeColor(white(0.55))
        ctx.setLineWidth(w * 0.038)
        ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: glass * 0.78, startAngle: .pi * 0.62, endAngle: .pi * 0.95, clockwise: false)
        ctx.strokePath()

    // 3. Four album mounts holding a print laid on the page. Two things make
    //    it read as a photograph rather than a fullscreen button: the tilt, and
    //    a faint fill so the rectangle is paper instead of a hole.
    case "corners":
        ctx.saveGState()
        ctx.translateBy(x: c.x, y: c.y)
        ctx.rotate(by: -.pi / 24)
        ctx.translateBy(x: -c.x, y: -c.y)
        mountedPrint(ctx, CGRect(x: rect.minX + w * 0.170, y: rect.minY + w * 0.215,
                                 width: w * 0.660, height: w * 0.570), w: w)
        ctx.restoreGState()

    // 4. The same print squared up to the tile, for a steadier, more clinical
    //    mark than the tilt gives.
    case "corners-square":
        mountedPrint(ctx, rect.insetBy(dx: w * 0.155, dy: w * 0.195), w: w)

    // 5. A body seen from the front: shoulders, the prism hump, and the mount
    //    punched clean through so the gradient itself becomes the glass.
    case "body":
        let body = CGRect(x: rect.minX + w * 0.115, y: rect.minY + w * 0.275,
                          width: w * 0.770, height: w * 0.430)
        let hump = CGMutablePath()
        hump.move(to: CGPoint(x: rect.minX + w * 0.395, y: body.maxY - w * 0.01))
        hump.addLine(to: CGPoint(x: rect.minX + w * 0.430, y: body.maxY + w * 0.085))
        hump.addLine(to: CGPoint(x: rect.minX + w * 0.590, y: body.maxY + w * 0.085))
        hump.addLine(to: CGPoint(x: rect.minX + w * 0.625, y: body.maxY - w * 0.01))
        hump.closeSubpath()

        let mount = CGPoint(x: rect.midX, y: body.midY)
        let mR = w * 0.155
        let shell = CGMutablePath()
        shell.addPath(hump)
        shell.addPath(roundedRect(body, w * 0.075))
        shell.addEllipse(in: CGRect(x: mount.x - mR, y: mount.y - mR, width: mR * 2, height: mR * 2))
        ctx.setFillColor(white(0.95))
        ctx.addPath(shell)
        ctx.fillPath(using: .evenOdd)

        // The glass sitting inside the mount, and the shutter release.
        ctx.setFillColor(white(0.30))
        let g = mR * 0.62
        ctx.addEllipse(in: CGRect(x: mount.x - g, y: mount.y - g, width: g * 2, height: g * 2))
        ctx.fillPath()
        ctx.setFillColor(white(0.55))
        let s = w * 0.030
        ctx.addEllipse(in: CGRect(x: rect.minX + w * 0.760 - s, y: body.maxY + w * 0.030 - s,
                                  width: s * 2, height: s * 2))
        ctx.fillPath()

    // 6. The mounts and the iris together: the print and the camera in one
    //    mark, which is what this app actually stands between.
    case "corners-aperture":
        let p = rect.insetBy(dx: w * 0.130, dy: w * 0.175)
        photoCorners(ctx, print: p, leg: w * 0.155)
        aperture(ctx, centre: c, radius: w * 0.205, seam: seam)

    // 7. A viewfinder's corner brackets around the iris - lighter than the
    //    solid mounts, and the brackets survive shrinking better than a
    //    triangle's point does.
    case "finder":
        let f = rect.insetBy(dx: w * 0.145, dy: w * 0.185)
        brackets(ctx, frame: f, arm: w * 0.145, weight: w * 0.055)
        aperture(ctx, centre: c, radius: w * 0.175, seam: seam)

    // 8. A frame of 35mm film: the strip, its sprockets, and one exposed
    //    frame. Every hole is punched with the same even-odd fill as the rest,
    //    so it shows the tile through it - clearing the pixels instead would
    //    take the gradient away with the white and leave a real hole.
    case "film":
        let strip = CGRect(x: rect.minX + w * 0.100, y: rect.minY + w * 0.245,
                           width: w * 0.800, height: w * 0.510)
        let window = CGRect(x: strip.minX + w * 0.070, y: strip.minY + w * 0.130,
                            width: strip.width - w * 0.140, height: strip.height - w * 0.260)
        let shell = CGMutablePath()
        shell.addPath(roundedRect(strip, w * 0.045))
        shell.addPath(roundedRect(window, w * 0.022))
        let holeW = w * 0.062, holeH = w * 0.052
        let pitch = w * 0.171
        for i in 0..<4 {
            let x = strip.minX + w * 0.058 + CGFloat(i) * pitch
            for y in [strip.minY + w * 0.039, strip.maxY - w * 0.039 - holeH] {
                shell.addPath(roundedRect(CGRect(x: x, y: y, width: holeW, height: holeH), w * 0.016))
            }
        }
        ctx.setFillColor(white(0.95))
        ctx.addPath(shell)
        ctx.fillPath(using: .evenOdd)

    default:
        break
    }
}

// MARK: - The icon around the artwork

/// One icon. `shaped` draws the squircle and its shadow, which is what a Mac
/// icon carries in the image itself; iOS is full bleed and masked by the system.
func drawIcon(_ ctx: CGContext, side: CGFloat, palette: Palette, variant: String, shaped: Bool,
              style: ApertureStyle = ApertureStyle()) {
    ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))

    let inset = shaped ? side * 0.098 : 0
    let shape = CGRect(x: inset, y: inset + (shaped ? side * 0.012 : 0),
                       width: side - inset * 2, height: side - inset * 2)
    let path = shaped ? squircle(in: shape) : CGPath(rect: shape, transform: nil)

    if shaped {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -side * 0.012), blur: side * 0.035,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.28))
        ctx.setFillColor(palette.bottom)
        ctx.addPath(path)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space, colors: [palette.top, palette.bottom] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: shape.maxY),
                           end: CGPoint(x: 0, y: shape.minY),
                           options: [])

    // A soft light from above, the way a physical thing catches it.
    let glow = CGGradient(colorsSpace: space, colors: [white(0.30), white(0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow,
                           startCenter: CGPoint(x: shape.midX, y: shape.maxY),
                           startRadius: 0,
                           endCenter: CGPoint(x: shape.midX, y: shape.maxY),
                           endRadius: shape.width * 0.9,
                           options: [])

    // The seam colour is the dark end of the gradient, so a cut through the
    // white artwork looks like the tile showing through rather than a grey line.
    drawArt(ctx, in: shape, variant: variant, seam: palette.bottom.copy(alpha: 0.92)!, style: style)
    ctx.restoreGState()

    // The hairline that reads as the edge of the glass rather than a border.
    if shaped {
        ctx.addPath(path)
        ctx.setStrokeColor(white(0.22))
        ctx.setLineWidth(side * 0.004)
        ctx.strokePath()
    }
}

func context(_ side: Int) -> CGContext {
    CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

func render(side: Int, palette: Palette, variant: String, shaped: Bool,
            style: ApertureStyle = ApertureStyle()) -> CGImage {
    let ctx = context(side)
    drawIcon(ctx, side: CGFloat(side), palette: palette, variant: variant, shaped: shaped, style: style)
    return ctx.makeImage()!
}

func label(_ ctx: CGContext, _ text: String, at point: CGPoint, size: CGFloat) {
    let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: CGColor(srgbRed: 0.16, green: 0.18, blue: 0.20, alpha: 1)
    ]
    let line = CTLineCreateWithAttributedString(
        CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

// MARK: - Entry
//
//   sheet <dir>   renders every variant side by side, with the small sizes
//                 under each - which is where a design either survives or not
//   app <dir>     writes the chosen variant as PNGs plus an .iconset

let args = CommandLine.arguments
guard args.count > 2 else {
    print("usage: IconGen.swift sheet <dir> | compare <dir> | app <dir> [variant]")
    exit(1)
}

let allVariants = ["aperture", "lens", "corners", "corners-square",
                   "body", "corners-aperture", "finder", "film"]
let palette = palettes["teal"]!

if args[1] == "compare" {
    let outDir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    // Which side of the hexagon-edge line the seam lies on, at the white level
    // that was settled on.
    let sides: [(String, CGFloat)] = [("inside", -1), ("straddling", 0), ("outside", 1)]

    let tile = 320, pad = 40, strip = 96
    let width = pad + sides.count * (tile + pad)
    let height = pad + tile + strip + pad
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (col, side) in sides.enumerated() {
        let style = ApertureStyle(white: 0.84, seamSide: side.1)
        let x = pad + col * (tile + pad)
        let top = height - pad - tile
        ctx.draw(render(side: 1024, palette: palette, variant: "aperture", shaped: true, style: style),
                 in: CGRect(x: x, y: top, width: tile, height: tile))
        var sx = x
        for size in [64, 32, 16] {
            ctx.draw(render(side: size, palette: palette, variant: "aperture", shaped: true, style: style),
                     in: CGRect(x: sx, y: top - 16 - size, width: size, height: size))
            sx += size + 18
        }
        label(ctx, "seam \(side.0) the line", at: CGPoint(x: x, y: top - 92), size: 23)
    }
    write(ctx.makeImage()!, to: outDir.appendingPathComponent("aperture-compare.png"))
    print("wrote aperture-compare.png to \(outDir.path)")
    exit(0)
}

if args[1] == "sheet" {
    let outDir = URL(fileURLWithPath: args[2])
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let tile = 300, pad = 34, strip = 96, cols = 4
    let rows = (allVariants.count + cols - 1) / cols
    let cellH = tile + strip
    let width = pad + cols * (tile + pad)
    let height = pad + rows * (cellH + pad)
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.95, blue: 0.96, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    for (index, variant) in allVariants.enumerated() {
        let col = index % cols, row = index / cols
        let x = pad + col * (tile + pad)
        let top = height - pad - row * (cellH + pad) - tile

        ctx.draw(render(side: 1024, palette: palette, variant: variant, shaped: true),
                 in: CGRect(x: x, y: top, width: tile, height: tile))

        var sx = x
        for size in [64, 32, 16] {
            ctx.draw(render(side: size, palette: palette, variant: variant, shaped: true),
                     in: CGRect(x: sx, y: top - 16 - size, width: size, height: size))
            sx += size + 18
        }
        label(ctx, variant, at: CGPoint(x: x, y: top - 92), size: 22)
    }

    write(ctx.makeImage()!, to: outDir.appendingPathComponent("icon-variants.png"))

    // Each one on its own as well, so a favourite can be looked at full size.
    for variant in allVariants {
        write(render(side: 1024, palette: palette, variant: variant, shaped: true),
              to: outDir.appendingPathComponent("variant-\(variant).png"))
    }
    print("wrote icon-variants.png and \(allVariants.count) full-size renders to \(outDir.path)")
    exit(0)
}

let chosen = args.count > 3 ? args[3] : "aperture"

guard args[1] == "app" else {
    print("usage: IconGen.swift sheet <dir> | compare <dir> | app <repo root>")
    exit(1)
}

// Three files, because three things ask for the icon in three shapes.
let root = URL(fileURLWithPath: args[2])
let shaped = render(side: 1024, palette: palette, variant: chosen, shaped: true)
let bleed = render(side: 1024, palette: palette, variant: chosen, shaped: false)

// The source build-app-bundle.sh sips down into the .icns. A Mac icon carries
// its own shape, padding and shadow.
write(shaped, to: root.appendingPathComponent("icons/AppIcon-1024.png"))

// The Dock icon a plain `swift run` gets, which has no bundle and so no
// Info.plist to name an .icns. Shaped for the same reason.
write(shaped, to: root.appendingPathComponent("Sources/MacPhotoMaster/Resources/AppIcon.png"))

// iOS is full bleed: the system applies the mask and the shadow itself, and
// would clip a second set of corners off one that arrived with them.
write(bleed, to: root.appendingPathComponent(
    "MacPhotoMasterPad/Sources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"))

print("wrote the \(chosen) icon into \(root.path)")
