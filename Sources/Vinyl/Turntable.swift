import AppKit
import SwiftUI

// MARK: - Geometry

/// Turntable layout in "top-down" deck coordinates (origin at the deck's back-left corner).
/// A single orthographic projection (`k` squashes depth, `z` lifts toward the viewer)
/// lets the same deck render as a 3/4 view in the room scenes and flat from above.
struct DeckGeometry: Equatable {
    var width: CGFloat
    var depth: CGFloat
    var corner: CGFloat
    var k: CGFloat
    var frontHeight: CGFloat
    var center: CGPoint
    var recordRadius: CGFloat
    var platterRadius: CGFloat
    var platterHeight: CGFloat
    var pivot: CGPoint
    var armLength: CGFloat
    var pillarHeight: CGFloat
    var restAngle: Double
    var knob: CGPoint
    var knobRadius: CGFloat
    var knobHeight: CGFloat
    var button: CGPoint?
    var badge: CGPoint?
    var margin: CGSize
    var armScale: CGFloat

    var isPerspective: Bool { k < 0.99 }
    var recordZ: CGFloat { isPerspective ? platterHeight + 2 : 0 }
    var restZ: CGFloat { pillarHeight * 0.45 }

    var frameSize: CGSize {
        CGSize(width: width + margin.width * 2, height: depth * k + frontHeight + margin.height * 2)
    }

    /// Projects a deck point at height `z` into the rig's frame.
    func s(_ p: CGPoint, z: CGFloat = 0) -> CGPoint {
        CGPoint(x: margin.width + p.x, y: margin.height + p.y * k - z)
    }

    func needle(at angle: Double) -> CGPoint {
        CGPoint(x: pivot.x + armLength * CGFloat(cos(angle)), y: pivot.y + armLength * CGFloat(sin(angle)))
    }

    var restPost: CGPoint {
        CGPoint(x: pivot.x + armLength * 0.62 * CGFloat(cos(restAngle)), y: pivot.y + armLength * 0.62 * CGFloat(sin(restAngle)))
    }

    /// Arm angle that puts the stylus on the groove for a given track progress.
    func playAngle(progress: Double) -> Double {
        let r = recordRadius * (0.93 - 0.53 * clamp01(progress))
        let dx = center.x - pivot.x, dy = center.y - pivot.y
        let d = (dx * dx + dy * dy).squareRoot()
        let ux = dx / d, uy = dy / d
        let a = (armLength * armLength - r * r + d * d) / (2 * d)
        let h = max(0, armLength * armLength - a * a).squareRoot()
        let nx = pivot.x + a * ux + h * uy
        let ny = pivot.y + a * uy - h * ux
        return atan2(ny - pivot.y, nx - pivot.x)
    }

    static let room = DeckGeometry(
        width: 464, depth: 380, corner: 6, k: 0.40, frontHeight: 48,
        center: CGPoint(x: 182, y: 192), recordRadius: 150, platterRadius: 157, platterHeight: 12,
        pivot: CGPoint(x: 395, y: 74), armLength: 232, pillarHeight: 34,
        restAngle: atan2(1, -0.09),
        knob: CGPoint(x: 420, y: 318), knobRadius: 12, knobHeight: 9,
        button: CGPoint(x: 380, y: 330), badge: nil,
        margin: CGSize(width: 30, height: 60), armScale: 0.8
    )

    static let topDown = DeckGeometry(
        width: 646, depth: 582, corner: 22, k: 1, frontHeight: 0,
        center: CGPoint(x: 262, y: 280), recordRadius: 236, platterRadius: 247, platterHeight: 0,
        pivot: CGPoint(x: 555, y: 122), armLength: 262, pillarHeight: 0,
        restAngle: atan2(1, -0.12),
        knob: CGPoint(x: 562, y: 470), knobRadius: 34, knobHeight: 0,
        button: nil, badge: CGPoint(x: 80, y: 545),
        margin: CGSize(width: 50, height: 50), armScale: 1.25
    )
}

// MARK: - Motion

/// Integrates platter speed and tonearm swing, so the record spins up, coasts down, and
/// the arm lifts, travels and lowers instead of snapping. Spin and arm run on separate
/// clocks: the arm only needs 60 fps while it's moving and creeps along at 1 Hz while a
/// song plays, which keeps a wallpaper that animates all day cheap.
@Observable
final class DeckMotion {
    /// The platter is turning or coasting.
    var spinning = true
    /// The arm is lifting, swinging or lowering.
    var armMoving = true

    @ObservationIgnored private var spin: Double = 0
    @ObservationIgnored private var speed: Double = 0
    @ObservationIgnored private var lastSpin: Date?
    @ObservationIgnored private var arm: Double?
    @ObservationIgnored private var lift: Double = 0
    @ObservationIgnored private var lastArm: Date?

    struct Pose {
        var arm: Double
        var lift: Double
    }

    static let rpm33: Double = 2 * .pi * (100.0 / 3.0) / 60.0

    func wake() {
        lastSpin = nil
        lastArm = nil
        if !spinning { spinning = true }
        if !armMoving { armMoving = true }
    }

    /// Flips an observed flag outside the current render pass, and only when it changes:
    /// re-assigning an observed value re-renders the view, which would loop forever.
    private func set(_ keyPath: ReferenceWritableKeyPath<DeckMotion, Bool>, _ value: Bool) {
        guard self[keyPath: keyPath] != value else { return }
        DispatchQueue.main.async {
            if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
    }

    func spinStep(_ date: Date, playing: Bool) -> Double {
        let dt = min(max(date.timeIntervalSince(lastSpin ?? date), 0), 0.1)
        lastSpin = date
        let omega = playing ? Self.rpm33 : 0
        speed += (omega - speed) * min(1, dt * (playing ? 1.9 : 1.1))
        if abs(omega - speed) < 0.003 { speed = omega }
        spin = (spin + speed * dt).truncatingRemainder(dividingBy: 2 * .pi)
        if !playing && speed == 0 { set(\.spinning, false) }
        return spin
    }

    func armStep(_ date: Date, playing: Bool, target: Double, rest: Double) -> Pose {
        let dt = min(max(date.timeIntervalSince(lastArm ?? date), 0), 0.1)
        lastArm = date
        var angle = arm ?? rest
        let goal = playing ? target : rest
        let gap = abs(goal - angle)
        let travelling = gap > 0.02 || (gap > 0.002 && lift > 0.05)
        if travelling {
            lift += (1 - lift) * min(1, dt * 5)
            if lift > 0.8 { angle += (goal - angle) * min(1, dt * 2.4) }
        } else {
            // Following the groove: the target creeps a fraction of a degree per second.
            angle = goal
            lift += (0 - lift) * min(1, dt * 5)
            if lift < 0.01 { lift = 0 }
        }
        arm = angle
        set(\.armMoving, travelling || lift > 0)
        return Pose(arm: angle, lift: lift)
    }
}

// MARK: - Record image

enum RecordRenderer {
    /// Draws a record (grooves, track gaps, label with album art, spindle) once.
    /// Spinning it is then just a transform on a cached bitmap.
    static func render(label: CGImage?, pixels: Int) -> CGImage? {
        let size = max(64, pixels)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        let R = CGFloat(size) / 2
        let c = CGPoint(x: R, y: R)
        func circle(_ r: CGFloat) -> CGRect { CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2) }
        func gray(_ g: CGFloat, _ a: CGFloat) -> CGColor { CGColor(gray: g, alpha: a) }

        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.055, alpha: 1))
        ctx.fillEllipse(in: circle(R))

        // Grooves: hundreds of faint concentric rings.
        var rng = SplitMix(0xC0FFEE)
        var r = R * 0.37
        ctx.setLineWidth(max(0.5, R * 0.0022))
        while r < R * 0.962 {
            let v = rng.unit()
            ctx.setStrokeColor(v > 0.45 ? gray(1, 0.02 + 0.05 * v) : gray(0, 0.4))
            ctx.strokeEllipse(in: circle(r))
            r += R * (0.0030 + 0.0030 * rng.unit())
        }

        // Glossy gaps between songs.
        for gap: CGFloat in [0.47, 0.585, 0.70, 0.835] {
            ctx.setLineWidth(R * 0.011)
            ctx.setStrokeColor(gray(0, 0.7))
            ctx.strokeEllipse(in: circle(R * gap))
            ctx.setLineWidth(max(0.5, R * 0.0028))
            ctx.setStrokeColor(gray(1, 0.07))
            ctx.strokeEllipse(in: circle(R * gap + R * 0.0075))
        }

        // Lead-in band and rim.
        ctx.setLineWidth(R * 0.03)
        ctx.setStrokeColor(gray(0.03, 1))
        ctx.strokeEllipse(in: circle(R * 0.982))
        ctx.setLineWidth(max(1, R * 0.005))
        ctx.setStrokeColor(gray(1, 0.13))
        ctx.strokeEllipse(in: circle(R * 0.995))

        // Dead wax around the label.
        ctx.setFillColor(gray(0.035, 1))
        ctx.fillEllipse(in: circle(R * 0.37))
        ctx.setLineWidth(max(0.5, R * 0.003))
        ctx.setStrokeColor(gray(1, 0.08))
        ctx.strokeEllipse(in: circle(R * 0.368))

        // Label.
        let lr = R * 0.33
        ctx.saveGState()
        ctx.addEllipse(in: circle(lr))
        ctx.clip()
        if let label {
            let iw = CGFloat(label.width), ih = CGFloat(label.height)
            let scale = max(2 * lr / iw, 2 * lr / ih)
            let w = iw * scale, h = ih * scale
            ctx.interpolationQuality = .high
            ctx.draw(label, in: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h))
        } else {
            ctx.setFillColor(CGColor(srgbRed: 0.79, green: 0.34, blue: 0.23, alpha: 1))
            ctx.fill(circle(lr))
        }
        if let vignette = CGGradient(colorsSpace: space, colors: [gray(0, 0), gray(0, 0), gray(0, 0.28)] as CFArray, locations: [0, 0.7, 1]) {
            ctx.drawRadialGradient(vignette, startCenter: c, startRadius: 0, endCenter: c, endRadius: lr, options: [])
        }
        ctx.restoreGState()
        ctx.setLineWidth(max(1, R * 0.006))
        ctx.setStrokeColor(gray(0, 0.55))
        ctx.strokeEllipse(in: circle(lr))

        // Spindle.
        ctx.setFillColor(gray(0.25, 1))
        ctx.fillEllipse(in: circle(R * 0.028))
        if let metal = CGGradient(colorsSpace: space, colors: [gray(0.98, 1), gray(0.62, 1)] as CFArray, locations: [0, 1]) {
            ctx.saveGState()
            ctx.addEllipse(in: circle(R * 0.02))
            ctx.clip()
            ctx.drawRadialGradient(metal, startCenter: CGPoint(x: c.x - R * 0.006, y: c.y + R * 0.006), startRadius: 0,
                                   endCenter: c, endRadius: R * 0.02, options: [])
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

@MainActor
enum RecordCache {
    private static var cache: [String: CGImage] = [:]

    static func image(for art: Artwork, pixels: Int) -> CGImage? {
        let key = "\(art.id)-\(pixels)"
        if let hit = cache[key] { return hit }
        if cache.count > 12 { cache.removeAll() }
        let image = RecordRenderer.render(label: art.cgImage, pixels: pixels)
        cache[key] = image
        return image
    }
}

/// The light reflected off the grooves stays put while the record turns under it.
struct RecordSheen: View {
    let radius: CGFloat

    var body: some View {
        Circle()
            .fill(AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .white.opacity(0), location: 0),
                    .init(color: .white.opacity(0.22), location: 0.07),
                    .init(color: .white.opacity(0), location: 0.16),
                    .init(color: .white.opacity(0), location: 0.5),
                    .init(color: .white.opacity(0.15), location: 0.57),
                    .init(color: .white.opacity(0), location: 0.66),
                    .init(color: .white.opacity(0), location: 1),
                ]),
                center: .center,
                angle: .degrees(-25)
            ))
            .mask(Circle().strokeBorder(Color.black, lineWidth: radius * 0.6))
            .frame(width: radius * 2, height: radius * 2)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }
}

// MARK: - Rig

private struct StageScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

extension EnvironmentValues {
    var stageScale: CGFloat {
        get { self[StageScaleKey.self] }
        set { self[StageScaleKey.self] = newValue }
    }

    /// Record angle for still renders (thumbnails, snapshots, README animation).
    var stillSpin: Double {
        get { self[StillSpinKey.self] }
        set { self[StillSpinKey.self] = newValue }
    }
}

private struct StillSpinKey: EnvironmentKey { static let defaultValue: Double = 0.6 }

struct TurntableRig: View {
    let g: DeckGeometry
    let nowPlaying: NowPlaying
    let animate: Bool

    @State private var motion = DeckMotion()
    @Environment(\.stageScale) private var stageScale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.stillSpin) private var stillSpin

    var body: some View {
        let pixelScale = max(2, stageScale * max(displayScale, 2))
        let pixels = Int(min(2400, (g.recordRadius * 2 * pixelScale).rounded()))
        let record = RecordCache.image(for: nowPlaying.artwork, pixels: pixels)

        ZStack(alignment: .topLeading) {
            DeckBody(g: g).equatable()
            if animate {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !motion.spinning)) { context in
                    RecordDisc(g: g, record: record, spin: motion.spinStep(context.date, playing: nowPlaying.isPlaying))
                }
                // Smooth while the arm moves; once a second while it just follows the groove.
                TimelineView(.animation(minimumInterval: motion.armMoving ? 1.0 / 60 : 1, paused: !motion.armMoving && !nowPlaying.isPlaying)) { context in
                    ToneArm(g: g, pose: motion.armStep(
                        context.date,
                        playing: nowPlaying.isPlaying,
                        target: g.playAngle(progress: nowPlaying.progress(at: context.date)),
                        rest: g.restAngle
                    ))
                }
            } else {
                let arm = nowPlaying.isPlaying ? g.playAngle(progress: nowPlaying.progress(at: Date())) : g.restAngle
                RecordDisc(g: g, record: record, spin: stillSpin)
                ToneArm(g: g, pose: .init(arm: arm, lift: 0))
            }
        }
        .frame(width: g.frameSize.width, height: g.frameSize.height, alignment: .topLeading)
        .onChange(of: nowPlaying.isPlaying) { motion.wake() }
        .onChange(of: nowPlaying.track?.key) { motion.wake() }
        .onChange(of: animate) { motion.wake() }
    }
}

private struct RecordDisc: View {
    let g: DeckGeometry
    let record: CGImage?
    let spin: Double

    var body: some View {
        let c = g.s(g.center, z: g.recordZ)
        let d = g.recordRadius * 2
        ZStack(alignment: .topLeading) {
            Group {
                if let record {
                    Image(decorative: record, scale: 1).resizable().interpolation(.high)
                } else {
                    Circle().fill(Color.black)
                }
            }
            .frame(width: d, height: d)
            .rotationEffect(.radians(spin))
            .scaleEffect(x: 1, y: g.k)
            .position(c)

            RecordSheen(radius: g.recordRadius)
                .scaleEffect(x: 1, y: g.k)
                .position(c)
        }
        .frame(width: g.frameSize.width, height: g.frameSize.height, alignment: .topLeading)
    }
}

// MARK: - Static deck

private let metalGradient = Gradient(stops: [
    .init(color: Color(hex: 0x5C5C5C), location: 0),
    .init(color: Color(hex: 0xBDBDBD), location: 0.12),
    .init(color: Color(hex: 0x8A8A8A), location: 0.3),
    .init(color: Color(hex: 0xF2F2F2), location: 0.48),
    .init(color: Color(hex: 0xA6A6A6), location: 0.64),
    .init(color: Color(hex: 0xDADADA), location: 0.84),
    .init(color: Color(hex: 0x5E5E5E), location: 1),
])

private let brassGradient = Gradient(stops: [
    .init(color: Color(hex: 0x4A3812), location: 0),
    .init(color: Color(hex: 0xA07C3A), location: 0.28),
    .init(color: Color(hex: 0xEBD08F), location: 0.46),
    .init(color: Color(hex: 0xB8924A), location: 0.62),
    .init(color: Color(hex: 0x3E2E0E), location: 1),
])

/// Side wall of a vertical cylinder standing on the deck, already projected.
private func cylinderSide(_ g: DeckGeometry, center: CGPoint, radius r: CGFloat, z0: CGFloat, z1: CGFloat) -> Path {
    let base = g.s(center, z: z0), top = g.s(center, z: z1)
    let ry = r * g.k
    var p = Path()
    p.move(to: CGPoint(x: base.x + r, y: base.y))
    for i in 1...48 {
        let t = Double(i) / 48 * .pi
        p.addLine(to: CGPoint(x: base.x + r * CGFloat(cos(t)), y: base.y + ry * CGFloat(sin(t))))
    }
    p.addLine(to: CGPoint(x: top.x - r, y: top.y))
    for i in 1...48 {
        let t = .pi + Double(i) / 48 * .pi
        p.addLine(to: CGPoint(x: top.x + r * CGFloat(cos(t)), y: top.y + ry * CGFloat(sin(t))))
    }
    p.closeSubpath()
    return p
}

private func frontArc(_ g: DeckGeometry, center: CGPoint, radius r: CGFloat, z: CGFloat) -> Path {
    let o = g.s(center, z: z)
    var p = Path()
    p.move(to: CGPoint(x: o.x + r, y: o.y))
    for i in 1...48 {
        let t = Double(i) / 48 * .pi
        p.addLine(to: CGPoint(x: o.x + r * CGFloat(cos(t)), y: o.y + r * g.k * CGFloat(sin(t))))
    }
    return p
}

private func disc(_ g: DeckGeometry, center: CGPoint, radius r: CGFloat, z: CGFloat) -> Path {
    let o = g.s(center, z: z)
    return Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r * g.k, width: r * 2, height: r * 2 * g.k))
}

private func horizontal(_ gradient: Gradient, _ o: CGPoint, _ r: CGFloat) -> GraphicsContext.Shading {
    .linearGradient(gradient, startPoint: CGPoint(x: o.x - r, y: o.y), endPoint: CGPoint(x: o.x + r, y: o.y))
}

struct DeckBody: View, Equatable {
    let g: DeckGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in drawShadows(&ctx) }
            if g.isPerspective {
                WoodGrain(kind: .oak, seed: 3)
                    .frame(width: g.width, height: g.frontHeight)
                    .offset(x: g.margin.width, y: g.margin.height + g.depth * g.k)
            } else {
                WoodGrain(kind: .birch, seed: 9)
                    .frame(width: g.width, height: g.depth)
                    .clipShape(RoundedRectangle(cornerRadius: g.corner, style: .continuous))
                    .offset(x: g.margin.width, y: g.margin.height)
            }
            Canvas { ctx, _ in
                if g.isPerspective { drawPerspective(&ctx) } else { drawTopDown(&ctx) }
            }
        }
        .frame(width: g.frameSize.width, height: g.frameSize.height, alignment: .topLeading)
    }

    private var topRect: CGRect { CGRect(x: 0, y: 0, width: g.width, height: g.depth) }

    private var topPath: Path {
        Path(roundedRect: topRect, cornerRadius: g.corner, style: .continuous)
            .applying(CGAffineTransform(a: 1, b: 0, c: 0, d: g.k, tx: g.margin.width, ty: g.margin.height))
    }

    private func drawShadows(_ ctx: inout GraphicsContext) {
        let mx = g.margin.width, my = g.margin.height
        if g.isPerspective {
            let bottom = my + g.depth * g.k + g.frontHeight
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 12))
                l.fill(Path(roundedRect: CGRect(x: mx - 8, y: bottom - 14, width: g.width + 30, height: 26), cornerRadius: 12),
                       with: .color(.black.opacity(0.55)))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 2.5))
                l.fill(Path(CGRect(x: mx + 2, y: bottom - 3, width: g.width - 2, height: 5)), with: .color(.black.opacity(0.6)))
            }
        } else {
            let rect = CGRect(x: mx, y: my, width: g.width, height: g.depth)
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 26))
                l.fill(Path(roundedRect: rect.offsetBy(dx: 18, dy: 24), cornerRadius: g.corner), with: .color(.black.opacity(0.55)))
            }
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 3))
                l.fill(Path(roundedRect: rect.offsetBy(dx: 2, dy: 3), cornerRadius: g.corner), with: .color(.black.opacity(0.4)))
            }
        }
    }

    // MARK: 3/4 view

    private func drawPerspective(_ ctx: inout GraphicsContext) {
        let mx = g.margin.width, my = g.margin.height
        let frontTop = my + g.depth * g.k

        // Lacquered top.
        ctx.fill(topPath, with: .linearGradient(
            Gradient(colors: [Color(hex: 0xEFEBE3), Color(hex: 0xE4DFD5), Color(hex: 0xD8D2C6)]),
            startPoint: CGPoint(x: 0, y: my), endPoint: CGPoint(x: 0, y: frontTop)))
        ctx.fill(topPath, with: .radialGradient(
            Gradient(colors: [.white.opacity(0.45), .white.opacity(0)]),
            center: CGPoint(x: mx + g.width * 0.25, y: my + g.depth * g.k * 0.2), startRadius: 0, endRadius: 260))
        ctx.stroke(topPath, with: .color(.black.opacity(0.14)), lineWidth: 0.8)

        // Front face shading and bevel.
        let front = CGRect(x: mx, y: frontTop, width: g.width, height: g.frontHeight)
        ctx.fill(Path(front), with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.10), location: 0),
                .init(color: .black.opacity(0), location: 0.3),
                .init(color: .black.opacity(0.28), location: 1),
            ]),
            startPoint: CGPoint(x: 0, y: front.minY), endPoint: CGPoint(x: 0, y: front.maxY)))
        ctx.fill(Path(CGRect(x: mx, y: frontTop - 0.5, width: g.width, height: 1.4)), with: .color(.white.opacity(0.85)))
        ctx.fill(Path(CGRect(x: mx, y: frontTop + 0.9, width: g.width, height: 1)), with: .color(.black.opacity(0.18)))
        ctx.fill(Path(CGRect(x: mx, y: frontTop, width: 1.2, height: g.frontHeight)), with: .color(.black.opacity(0.2)))
        ctx.fill(Path(CGRect(x: mx + g.width - 1.2, y: frontTop, width: 1.2, height: g.frontHeight)), with: .color(.black.opacity(0.3)))

        let engraving = Text("VINYL  ·  33⅓").font(.system(size: 8.5, weight: .bold, design: .serif)).tracking(3.2)
        let at = CGPoint(x: mx + 120, y: frontTop + g.frontHeight * 0.55)
        ctx.draw(engraving.foregroundColor(.white.opacity(0.22)), at: CGPoint(x: at.x, y: at.y + 0.8))
        ctx.draw(engraving.foregroundColor(.black.opacity(0.38)), at: at)

        // Platter.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.fill(disc(g, center: CGPoint(x: g.center.x + 8, y: g.center.y + 10), radius: g.platterRadius, z: 0),
                   with: .color(.black.opacity(0.35)))
        }
        let pBase = g.s(g.center)
        ctx.fill(cylinderSide(g, center: g.center, radius: g.platterRadius, z0: 0, z1: g.platterHeight),
                 with: horizontal(metalGradient, pBase, g.platterRadius))
        for z in [g.platterHeight * 0.33, g.platterHeight * 0.66] {
            ctx.stroke(frontArc(g, center: g.center, radius: g.platterRadius, z: z), with: .color(.black.opacity(0.22)), lineWidth: 0.8)
            ctx.stroke(frontArc(g, center: g.center, radius: g.platterRadius, z: z - 0.9), with: .color(.white.opacity(0.35)), lineWidth: 0.6)
        }
        ctx.fill(disc(g, center: g.center, radius: g.platterRadius, z: g.platterHeight), with: horizontal(metalGradient, pBase, g.platterRadius))
        ctx.fill(cylinderSide(g, center: g.center, radius: g.recordRadius, z0: g.platterHeight, z1: g.recordZ),
                 with: .color(Color(hex: 0x0B0B0B)))

        // Tonearm pillar and arm rest.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 3))
            l.fill(disc(g, center: CGPoint(x: g.pivot.x + 6, y: g.pivot.y + 8), radius: 17, z: 0), with: .color(.black.opacity(0.4)))
        }
        let pv = g.s(g.pivot)
        ctx.fill(cylinderSide(g, center: g.pivot, radius: 16, z0: 0, z1: g.pillarHeight),
                 with: horizontal(Gradient(colors: [Color(hex: 0x0E0E0E), Color(hex: 0x4A4A4A), Color(hex: 0x1C1C1C), Color(hex: 0x050505)]), pv, 16))
        ctx.fill(disc(g, center: g.pivot, radius: 16, z: g.pillarHeight), with: .color(Color(hex: 0x262626)))
        ctx.stroke(disc(g, center: g.pivot, radius: 15, z: g.pillarHeight), with: .color(.white.opacity(0.35)), lineWidth: 1)

        let post = g.restPost
        ctx.fill(cylinderSide(g, center: post, radius: 3.5, z0: 0, z1: g.restZ - 2),
                 with: horizontal(Gradient(colors: [Color(hex: 0x111111), Color(hex: 0x555555), Color(hex: 0x111111)]), g.s(post), 3.5))

        // Speed knob and start button.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 2))
            l.fill(disc(g, center: CGPoint(x: g.knob.x + 4, y: g.knob.y + 5), radius: g.knobRadius, z: 0), with: .color(.black.opacity(0.4)))
        }
        let kb = g.s(g.knob)
        ctx.fill(cylinderSide(g, center: g.knob, radius: g.knobRadius, z0: 0, z1: g.knobHeight), with: horizontal(brassGradient, kb, g.knobRadius))
        ctx.fill(disc(g, center: g.knob, radius: g.knobRadius, z: g.knobHeight), with: .radialGradient(
            Gradient(colors: [Color(hex: 0xF3DCA2), Color(hex: 0xB89050)]),
            center: g.s(CGPoint(x: g.knob.x - 4, y: g.knob.y - 4), z: g.knobHeight), startRadius: 0, endRadius: g.knobRadius * 1.2))
        if let button = g.button {
            ctx.fill(disc(g, center: button, radius: 4.5, z: 0.5), with: .color(Color(hex: 0x141414)))
            ctx.fill(disc(g, center: CGPoint(x: button.x - 1.2, y: button.y - 1.2), radius: 1.6, z: 0.8), with: .color(.white.opacity(0.25)))
        }
    }

    // MARK: Top-down view

    private func drawTopDown(_ ctx: inout GraphicsContext) {
        let mx = g.margin.width, my = g.margin.height
        let rect = CGRect(x: mx, y: my, width: g.width, height: g.depth)
        let plate = Path(roundedRect: rect, cornerRadius: g.corner, style: .continuous)

        ctx.fill(plate, with: .linearGradient(
            Gradient(stops: [
                .init(color: .white.opacity(0.22), location: 0),
                .init(color: .white.opacity(0), location: 0.45),
                .init(color: .black.opacity(0.12), location: 1),
            ]),
            startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
        ctx.stroke(Path(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerRadius: g.corner - 1.5, style: .continuous),
                   with: .linearGradient(Gradient(colors: [.white.opacity(0.75), .white.opacity(0.1), .black.opacity(0.2)]),
                                         startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
                   lineWidth: 2)
        ctx.stroke(plate, with: .color(.black.opacity(0.35)), lineWidth: 1)

        // Platter ring.
        let c = g.s(g.center)
        let platter = Path(ellipseIn: CGRect(x: c.x - g.platterRadius, y: c.y - g.platterRadius, width: g.platterRadius * 2, height: g.platterRadius * 2))
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 8))
            l.fill(platter.offsetBy(dx: 6, dy: 8), with: .color(.black.opacity(0.4)))
        }
        ctx.fill(platter, with: .conicGradient(
            Gradient(colors: [Color(hex: 0xEDEDED), Color(hex: 0x8C8C8C), Color(hex: 0xF7F7F7), Color(hex: 0x9A9A9A),
                              Color(hex: 0xE6E6E6), Color(hex: 0x7E7E7E), Color(hex: 0xEDEDED)]),
            center: c, angle: .degrees(20)))
        ctx.stroke(platter, with: .color(.black.opacity(0.35)), lineWidth: 1)

        // Pivot base.
        let pv = g.s(g.pivot)
        func ring(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: pv.x - r, y: pv.y - r, width: r * 2, height: r * 2)) }
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 5))
            l.fill(ring(36).offsetBy(dx: 5, dy: 7), with: .color(.black.opacity(0.45)))
        }
        ctx.fill(ring(36), with: .color(Color(hex: 0x1A1A1A)))
        ctx.stroke(ring(33), with: .conicGradient(Gradient(colors: [Color(hex: 0xF0F0F0), Color(hex: 0x777777), Color(hex: 0xF0F0F0), Color(hex: 0x6A6A6A), Color(hex: 0xF0F0F0)]), center: pv), lineWidth: 4)
        ctx.fill(ring(20), with: .color(Color(hex: 0x2B2B2B)))

        // Arm rest.
        let rp = g.s(g.restPost)
        let rest = Path(ellipseIn: CGRect(x: rp.x - 9, y: rp.y - 9, width: 18, height: 18))
        ctx.fill(rest.offsetBy(dx: 2, dy: 3), with: .color(.black.opacity(0.3)))
        ctx.fill(rest, with: .color(Color(hex: 0x1E1E1E)))
        ctx.stroke(rest, with: .color(.white.opacity(0.25)), lineWidth: 1)

        // Knob.
        let kc = g.s(g.knob)
        let kr = g.knobRadius
        let knob = Path(ellipseIn: CGRect(x: kc.x - kr, y: kc.y - kr, width: kr * 2, height: kr * 2))
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 6))
            l.fill(knob.offsetBy(dx: 7, dy: 10), with: .color(.black.opacity(0.5)))
        }
        ctx.fill(knob, with: .radialGradient(Gradient(colors: [Color(hex: 0x9E7B52), Color(hex: 0x6E4E2F), Color(hex: 0x4A321C)]),
                                             center: CGPoint(x: kc.x - kr * 0.3, y: kc.y - kr * 0.3), startRadius: 0, endRadius: kr * 1.4))
        for i in 0..<60 {
            let a = Double(i) / 60 * 2 * .pi
            var tick = Path()
            tick.move(to: CGPoint(x: kc.x + (kr - 4) * CGFloat(cos(a)), y: kc.y + (kr - 4) * CGFloat(sin(a))))
            tick.addLine(to: CGPoint(x: kc.x + kr * CGFloat(cos(a)), y: kc.y + kr * CGFloat(sin(a))))
            ctx.stroke(tick, with: .color(.black.opacity(0.35)), lineWidth: 1)
        }
        let cap = Path(ellipseIn: CGRect(x: kc.x - kr * 0.74, y: kc.y - kr * 0.74, width: kr * 1.48, height: kr * 1.48))
        ctx.fill(cap, with: .conicGradient(Gradient(colors: [Color(hex: 0x8C6A44), Color(hex: 0xC9A57A), Color(hex: 0x6E5034), Color(hex: 0xB89468), Color(hex: 0x8C6A44)]), center: kc))
        ctx.stroke(cap, with: .color(.black.opacity(0.3)), lineWidth: 1)
        var mark = Path()
        mark.move(to: CGPoint(x: kc.x - kr * 0.18, y: kc.y - kr * 0.18))
        mark.addLine(to: CGPoint(x: kc.x - kr * 0.55, y: kc.y - kr * 0.55))
        ctx.stroke(mark, with: .color(.white.opacity(0.7)), style: StrokeStyle(lineWidth: 2, lineCap: .round))

        // Badge.
        if let badge = g.badge {
            let b = g.s(badge)
            let rect = CGRect(x: b.x - 4, y: b.y - 13, width: 104, height: 26)
            ctx.fill(Path(roundedRect: rect.offsetBy(dx: 1, dy: 2), cornerRadius: 4), with: .color(.black.opacity(0.25)))
            ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(Color(hex: 0x2C2C2C)))
            ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 4), with: .color(.white.opacity(0.18)), lineWidth: 1)
            ctx.draw(Text("VINYL  ·  33⅓").font(.system(size: 8.5, weight: .semibold)).tracking(2.2).foregroundColor(Color(hex: 0xD6D6D6)),
                     at: CGPoint(x: rect.midX, y: rect.midY))
        }
    }
}

// MARK: - Tonearm

private struct ToneArm: View {
    let g: DeckGeometry
    let pose: DeckMotion.Pose

    var body: some View {
        Canvas { ctx, _ in
            let a = g.armScale
            let P = g.pivot
            let dir = CGVector(dx: CGFloat(cos(pose.arm)), dy: CGFloat(sin(pose.arm)))
            let N = g.needle(at: pose.arm)
            let distance = hypot(N.x - g.center.x, N.y - g.center.y)
            let over = CGFloat(clamp01(Double((g.recordRadius + 12 - distance) / 28)))
            let lift = CGFloat(pose.lift)

            let zNeedle: CGFloat = g.isPerspective ? (g.recordZ + 3) * over + g.restZ * (1 - over) + lift * 10 : 0
            let zPivot: CGFloat = g.isPerspective ? g.pillarHeight + 6 * a : 0

            let headAngle = pose.arm + 0.42
            let hd = CGVector(dx: CGFloat(cos(headAngle)), dy: CGFloat(sin(headAngle)))
            let perp = CGVector(dx: -hd.dy, dy: hd.dx)
            let headLen = 40 * a
            let B = CGPoint(x: N.x - hd.dx * headLen * 0.72, y: N.y - hd.dy * headLen * 0.72)
            let zHead = zNeedle + 4 * a

            func along(_ d: CGFloat) -> CGPoint { CGPoint(x: P.x + dir.dx * d, y: P.y + dir.dy * d) }
            func rect(from p: CGPoint, length: CGFloat, width w: CGFloat, start: CGFloat) -> [CGPoint] {
                let s0 = CGPoint(x: p.x + hd.dx * start, y: p.y + hd.dy * start)
                let s1 = CGPoint(x: s0.x + hd.dx * length, y: s0.y + hd.dy * length)
                return [
                    CGPoint(x: s0.x + perp.dx * w / 2, y: s0.y + perp.dy * w / 2),
                    CGPoint(x: s1.x + perp.dx * w / 2, y: s1.y + perp.dy * w / 2),
                    CGPoint(x: s1.x - perp.dx * w / 2, y: s1.y - perp.dy * w / 2),
                    CGPoint(x: s0.x - perp.dx * w / 2, y: s0.y - perp.dy * w / 2),
                ]
            }

            let shell = rect(from: B, length: headLen, width: 15 * a, start: 0)
            let cartridge = rect(from: B, length: headLen * 0.42, width: 12 * a, start: headLen * 0.5)
            let counter0 = along(-14 * a), counter1 = along(-46 * a)
            let fingerBase = CGPoint(x: B.x + hd.dx * headLen * 0.35, y: B.y + hd.dy * headLen * 0.35)
            let fingerTip = CGPoint(x: fingerBase.x - perp.dx * 14 * a, y: fingerBase.y - perp.dy * 14 * a)

            // Where an arm point's shadow lands (on the record if above it, on the deck otherwise).
            func shadowPoint(_ p: CGPoint, _ z: CGFloat) -> CGPoint {
                if g.isPerspective {
                    let onRecord = hypot(p.x - g.center.x, p.y - g.center.y) < g.recordRadius
                    let surface = onRecord ? g.recordZ : 0
                    let h = max(0, z - surface)
                    let q = g.s(p, z: surface)
                    return CGPoint(x: q.x + h * 0.45 + 2, y: q.y + h * 0.3 + 1)
                } else {
                    let q = g.s(p)
                    let h = 7 + 12 * lift
                    return CGPoint(x: q.x + h * a, y: q.y + h * 1.3 * a)
                }
            }

            func polygon(_ pts: [CGPoint], _ map: (CGPoint) -> CGPoint) -> Path {
                var path = Path()
                path.addLines(pts.map(map))
                path.closeSubpath()
                return path
            }

            func line(_ p0: CGPoint, _ p1: CGPoint) -> Path {
                var path = Path()
                path.move(to: p0)
                path.addLine(to: p1)
                return path
            }

            // Shadow pass.
            ctx.drawLayer { l in
                l.addFilter(.blur(radius: 3 + 3 * lift))
                let shade = GraphicsContext.Shading.color(.black.opacity(0.32))
                l.stroke(line(shadowPoint(counter0, zPivot), shadowPoint(counter1, zPivot)), with: shade,
                         style: StrokeStyle(lineWidth: 17 * a, lineCap: .round))
                l.stroke(line(shadowPoint(P, zPivot), shadowPoint(B, zHead)), with: shade, lineWidth: 5 * a)
                l.fill(polygon(shell) { shadowPoint($0, zHead) }, with: shade)
            }

            let pivotTop = g.s(P, z: zPivot)

            // Vertical bearing post.
            if g.isPerspective {
                let base = g.s(P, z: g.pillarHeight)
                ctx.fill(Path(CGRect(x: base.x - 3.5 * a, y: pivotTop.y, width: 7 * a, height: base.y - pivotTop.y)),
                         with: horizontal(metalGradient, base, 3.5 * a))
            }

            // Counterweight.
            let cw0 = g.s(counter0, z: zPivot), cw1 = g.s(counter1, z: zPivot)
            ctx.stroke(line(cw0, cw1), with: .color(Color(hex: 0x1F1F1F)), style: StrokeStyle(lineWidth: 17 * a, lineCap: .butt))
            ctx.stroke(line(cw0, cw1), with: .color(Color(hex: 0x5A5A5A)), style: StrokeStyle(lineWidth: 4 * a, lineCap: .butt))
            ctx.stroke(line(g.s(along(-46 * a), z: zPivot), g.s(along(-50 * a), z: zPivot)), with: .color(Color(hex: 0xB8B8B8)),
                       style: StrokeStyle(lineWidth: 14 * a, lineCap: .butt))

            // Tube.
            let t0 = pivotTop, t1 = g.s(B, z: zHead)
            ctx.stroke(line(t0, t1), with: .color(Color(hex: 0x4E4E4E)), style: StrokeStyle(lineWidth: 6 * a, lineCap: .round))
            ctx.stroke(line(t0, t1), with: .color(Color(hex: 0xD4D4D4)), style: StrokeStyle(lineWidth: 4.4 * a, lineCap: .round))
            ctx.stroke(line(CGPoint(x: t0.x, y: t0.y - 0.9 * a), CGPoint(x: t1.x, y: t1.y - 0.9 * a)),
                       with: .color(.white.opacity(0.85)), style: StrokeStyle(lineWidth: 1.2 * a, lineCap: .round))

            // Headshell, cartridge, finger lift.
            let map: (CGPoint) -> CGPoint = { g.s($0, z: zHead) }
            ctx.fill(polygon(shell, map), with: .color(Color(hex: 0x1C1C1C)))
            ctx.stroke(polygon(shell, map), with: .color(.white.opacity(0.35)), lineWidth: 0.8)
            ctx.fill(polygon(cartridge, map), with: .color(Color(hex: 0xD2782F)))
            ctx.stroke(polygon(cartridge, map), with: .color(.black.opacity(0.4)), lineWidth: 0.6)
            ctx.stroke(line(map(fingerBase), map(fingerTip)), with: .color(Color(hex: 0xC8C8C8)),
                       style: StrokeStyle(lineWidth: 2.2 * a, lineCap: .round))

            // Pivot housing.
            let hr = (g.isPerspective ? 9 : 15) * a
            let housing = Path(ellipseIn: CGRect(x: pivotTop.x - hr, y: pivotTop.y - hr, width: hr * 2, height: hr * 2))
            ctx.fill(housing, with: .radialGradient(Gradient(colors: [Color(hex: 0xF4F4F4), Color(hex: 0x9C9C9C), Color(hex: 0x4A4A4A)]),
                                                    center: CGPoint(x: pivotTop.x - hr * 0.35, y: pivotTop.y - hr * 0.35),
                                                    startRadius: 0, endRadius: hr * 1.3))
            ctx.stroke(housing, with: .color(.black.opacity(0.4)), lineWidth: 0.8)
        }
        .frame(width: g.frameSize.width, height: g.frameSize.height)
        .allowsHitTesting(false)
    }
}
