import CoreGraphics
import IconForge

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

/// The app's mark. The seam is inked in the dark end of the gradient so a cut
/// through the white blades reads as the tile showing through, not a grey line.
let iris: Artwork = { ctx, rect, palette in
    aperture(ctx, centre: CGPoint(x: rect.midX, y: rect.midY), radius: rect.width * 0.325,
             seam: palette.bottom.copy(alpha: 0.92)!)
}
