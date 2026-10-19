import AppKit
import SwiftUI

// MARK: - Wood

/// Procedural wood: a base gradient, soft figure bands and hundreds of wavy grain lines.
/// Seeded so it draws identically every time.
struct WoodGrain: View, Equatable {
    enum Kind: Equatable { case desk, topDown, oak, birch }

    let kind: Kind
    var seed: UInt64 = 1

    private struct Look {
        var base: [UInt32]
        var dark: UInt32
        var light: UInt32
        var spacing: CGFloat
        var wave: CGFloat
        var perspective: Bool
        var bands: Int
        var darkAlpha: Double
    }

    private var look: Look {
        switch kind {
        case .desk:
            Look(base: [0x5E2C13, 0x7C3E1B, 0x96502A, 0x8C4722, 0x6A3216], dark: 0x2A1005, light: 0xD8935A,
                 spacing: 3.0, wave: 2.5, perspective: true, bands: 16, darkAlpha: 0.22)
        case .topDown:
            Look(base: [0xA9591F, 0xBE6E2E, 0xB4652A, 0xC67832, 0xA65720], dark: 0x4A2006, light: 0xF0A868,
                 spacing: 2.4, wave: 6, perspective: false, bands: 22, darkAlpha: 0.22)
        case .oak:
            Look(base: [0xC9A679, 0xB89366, 0xAA8556], dark: 0x6A4B2C, light: 0xEAD2A9,
                 spacing: 1.7, wave: 1.2, perspective: false, bands: 4, darkAlpha: 0.2)
        case .birch:
            Look(base: [0xE9E2D6, 0xDDD5C6, 0xD3C9B8], dark: 0x8F7F64, light: 0xFFFFFF,
                 spacing: 2.6, wave: 5, perspective: false, bands: 8, darkAlpha: 0.10)
        }
    }

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let look = look
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .linearGradient(
            Gradient(colors: look.base.map { Color(hex: $0) }),
            startPoint: .zero, endPoint: CGPoint(x: size.width * 0.12, y: size.height)))

        var rng = SplitMix(seed)
        let dark = Color(hex: look.dark), light = Color(hex: look.light)

        func yFor(_ t: CGFloat) -> CGFloat { look.perspective ? size.height * pow(t, 1.45) : size.height * t }

        func wavyBand(y: CGFloat, thickness: CGFloat, amp: CGFloat, f: Double, phase: Double) -> Path {
            var top: [CGPoint] = [], bottom: [CGPoint] = []
            var x: CGFloat = -20
            while x <= size.width + 20 {
                let w = amp * CGFloat(sin(f * Double(x) + phase))
                top.append(CGPoint(x: x, y: y + w))
                bottom.append(CGPoint(x: x, y: y + w + thickness * CGFloat(0.7 + 0.3 * sin(f * 1.7 * Double(x) + phase))))
                x += 24
            }
            var p = Path()
            p.addLines(top + bottom.reversed())
            p.closeSubpath()
            return p
        }

        // Broad figure.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 12))
            for _ in 0..<look.bands {
                let t = CGFloat(rng.unit())
                let isDark = rng.unit() < 0.55
                let thickness = look.perspective ? 6 + 46 * t : CGFloat(rng.range(8, 46))
                let band = wavyBand(y: yFor(t), thickness: thickness, amp: look.wave * 2,
                                    f: rng.range(0.002, 0.007), phase: rng.range(0, 6.28))
                l.fill(band, with: .color((isDark ? dark : light).opacity(isDark ? 0.16 : 0.09)))
            }
        }

        // Fine grain.
        let count = max(1, Int(size.height / look.spacing))
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(max(count - 1, 1))
            let y0 = yFor(t) + CGFloat(rng.range(-0.8, 0.8))
            let amp = look.wave * (look.perspective ? (0.3 + t) : 1) * CGFloat(rng.range(0.4, 1.4))
            let f1 = rng.range(0.0015, 0.005), p1 = rng.range(0, 6.28)
            let f2 = rng.range(0.01, 0.03), p2 = rng.range(0, 6.28)
            var path = Path()
            var x: CGFloat = -10
            path.move(to: CGPoint(x: x, y: y0 + amp * CGFloat(sin(f1 * Double(x) + p1))))
            while x < size.width + 10 {
                x += 10
                let y = y0 + amp * CGFloat(sin(f1 * Double(x) + p1)) + amp * 0.25 * CGFloat(sin(f2 * Double(x) + p2))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            let isDark = rng.unit() < 0.7
            let alpha = isDark ? 0.04 + look.darkAlpha * rng.unit() : 0.03 + 0.08 * rng.unit()
            let width = CGFloat(rng.range(0.4, 1.7)) * (look.perspective ? 0.5 + t * 1.3 : 1)
            ctx.stroke(path, with: .color((isDark ? dark : light).opacity(alpha)), lineWidth: width)
        }

        // Gentle vignette.
        ctx.fill(Path(rect), with: .radialGradient(
            Gradient(colors: [.clear, .black.opacity(kind == .birch ? 0.04 : 0.18)]),
            center: CGPoint(x: size.width / 2, y: size.height * 0.4), startRadius: min(size.width, size.height) * 0.3,
            endRadius: max(size.width, size.height) * 0.85))
    }
}

// MARK: - Album art surfaces

struct ArtPrint: View {
    let art: Artwork
    let size: CGFloat
    var gloss: Double = 0.12

    var body: some View {
        Image(nsImage: art.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
            .overlay(LinearGradient(
                stops: [
                    .init(color: .white.opacity(gloss), location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(gloss * 0.9), location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }
}

/// Album sleeve propped up on a wooden ledge (room scenes).
struct AlbumStand: View {
    let art: Artwork

    var body: some View {
        ZStack {
            // Shadow cast on the wall behind.
            Rectangle()
                .fill(Color.black.opacity(0.26))
                .frame(width: 318, height: 318)
                .blur(radius: 16)
                .offset(x: 26, y: -10)

            ArtPrint(art: art, size: 326)
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.18), lineWidth: 0.8))
                .id(art.id)
                .transition(.opacity)
                .rotation3DEffect(.degrees(-7), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.45)
                .rotation3DEffect(.degrees(5), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.45)
                .rotationEffect(.degrees(-0.7))
                .offset(y: -6)

            Ledge()
                .frame(width: 352, height: 52)
                .offset(x: 8, y: 166)
        }
        .frame(width: 420, height: 440)
    }
}

private struct Ledge: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                ctx.drawLayer { l in
                    l.addFilter(.blur(radius: 9))
                    l.fill(Path(roundedRect: CGRect(x: -6, y: size.height - 16, width: size.width + 24, height: 26), cornerRadius: 12),
                           with: .color(.black.opacity(0.55)))
                }
                var top = Path()
                top.move(to: CGPoint(x: 6, y: 0))
                top.addLine(to: CGPoint(x: size.width - 6, y: 0))
                top.addLine(to: CGPoint(x: size.width, y: 12))
                top.addLine(to: CGPoint(x: 0, y: 12))
                top.closeSubpath()
                ctx.fill(top, with: .linearGradient(Gradient(colors: [Color(hex: 0xB28A57), Color(hex: 0xDDB884)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: 12)))
            }
            WoodGrain(kind: .oak, seed: 21)
                .frame(height: 40)
                .overlay(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
                .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.7)).frame(height: 1) }
                .offset(y: 12)
        }
    }
}

/// The last few records, piled on the desk with the most recent on top.
struct RecordPile: View {
    let recent: [RecentTrack]
    /// Shown alone when nothing has been played yet.
    let fallback: Artwork
    var hovered = false

    static let size = CGSize(width: 440, height: 230)
    /// Where the pile sits on the room stage; the click target is laid over this.
    static let stageCenter = CGPoint(x: 1172, y: 630)

    // Bottom-to-top placement: each record lies a little higher and askew.
    private static let layout: [(rotation: Double, x: CGFloat, y: CGFloat)] = [
        (13, 44, 14), (-13, -40, 8), (8, 28, 2), (-8, -24, -4), (-3, 0, -10),
    ]

    var body: some View {
        let sleeves: [Artwork?] = recent.isEmpty ? [nil, nil, fallback] : recent.prefix(5).map(\.artwork).reversed()
        let start = Self.layout.count - sleeves.count
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .frame(width: 340, height: 340)
                .rotationEffect(.degrees(-3))
                .scaleEffect(x: 1, y: 0.44)
                .blur(radius: hovered ? 14 : 9)
                .offset(x: 10, y: 14)
            ForEach(Array(sleeves.enumerated()), id: \.offset) { index, art in
                let place = Self.layout[start + index]
                Sleeve(art: art, blank: index == 0 && recent.isEmpty ? 0xF3EEE4 : 0xE6DECF)
                    .rotationEffect(.degrees(place.rotation))
                    .scaleEffect(x: 1, y: 0.44)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, x: 0, y: 1.5)
                    .offset(x: place.x, y: place.y - (hovered ? CGFloat(index) * 3 : 0))
            }
        }
        .offset(y: hovered ? -6 : 0)
        .brightness(hovered ? 0.04 : 0)
        .frame(width: Self.size.width, height: Self.size.height)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: hovered)
        .animation(.easeInOut(duration: 0.6), value: recent.map(\.id))
    }

    private struct Sleeve: View {
        let art: Artwork?
        let blank: UInt32

        var body: some View {
            Group {
                if let art {
                    ArtPrint(art: art, size: 318, gloss: 0.16)
                } else {
                    Rectangle().fill(Color(hex: blank)).frame(width: 318, height: 318)
                }
            }
            .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
        }
    }
}

/// Top-down album sleeve (Turntable scene).
struct AlbumSleeve: View {
    let art: Artwork

    var body: some View {
        ArtPrint(art: art, size: 478, gloss: 0.10)
            .overlay(Rectangle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
            .id(art.id)
            .transition(.opacity)
            .shadow(color: .black.opacity(0.45), radius: 3, x: 1, y: 2)
            .shadow(color: .black.opacity(0.4), radius: 22, x: 14, y: 18)
            .rotationEffect(.degrees(-2.4))
    }
}

// MARK: - Framed print on the wall

struct WallFrame: View {
    let palette: ArtPalette
    let night: Bool

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.3))
                .frame(width: 390, height: 258)
                .blur(radius: 14)
                .offset(x: 12, y: 14)
            if night {
                Rectangle()
                    .fill(Color(hex: 0xFF9442).opacity(0.85))
                    .frame(width: 400, height: 268)
                    .blur(radius: 24)
            }
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0x6E4C2F), Color(hex: 0x4A3020)], startPoint: .top, endPoint: .bottom))
                .overlay(Rectangle().strokeBorder(
                    LinearGradient(colors: [Color(hex: 0xA27A55), Color(hex: 0x2E1C10)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2.5))
                .frame(width: 386, height: 256)
            Rectangle()
                .fill(Color(hex: 0xEFEAE0))
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.22), lineWidth: 3).blur(radius: 2))
                .frame(width: 364, height: 234)
            ColorFieldPainting(palette: palette)
                .frame(width: 276, height: 156)
                .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1.5).padding(-2))
                .overlay(Rectangle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1).padding(-3.5))
                .offset(y: -12)
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0), location: 0.25),
                    .init(color: .white.opacity(0.13), location: 0.4),
                    .init(color: .white.opacity(0), location: 0.55),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 364, height: 234)
                .allowsHitTesting(false)
        }
        .frame(width: 430, height: 300)
        .animation(.easeInOut(duration: 1.2), value: palette)
    }
}

/// A colour-field painting in the current album's colours.
struct ColorFieldPainting: View {
    let palette: ArtPalette

    var body: some View {
        let c = palette.colors
        ZStack {
            Rectangle().fill(Color(nsColor: c[2].mixed(with: .black, 0.5)))
            VStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c[0]))
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: c[1])).frame(height: 40)
            }
            .padding(13)
            .blur(radius: 2.4)
            Canvas { ctx, size in
                var rng = SplitMix(77)
                for _ in 0..<500 {
                    let p = CGRect(x: rng.range(0, Double(size.width)), y: rng.range(0, Double(size.height)), width: 1.2, height: 1.2)
                    ctx.fill(Path(ellipseIn: p), with: .color((rng.unit() < 0.5 ? Color.white : Color.black).opacity(0.08)))
                }
            }
        }
        .clipped()
    }
}

// MARK: - Lamp

struct LampView: View, Equatable {
    let night: Bool

    static let size = CGSize(width: 220, height: 330)
    /// Bulb position inside the view, used to aim the scene's glow.
    static let bulb = CGPoint(x: 100, y: 112)

    var body: some View {
        Canvas { ctx, _ in draw(&ctx) }
            .frame(width: Self.size.width, height: Self.size.height)
    }

    private static let shadeRect = CGRect(x: 12, y: 6, width: 176, height: 224)

    private static func halfWidth(at y: CGFloat) -> CGFloat {
        let r = shadeRect
        let dome = r.height * 0.42
        let rel = y - r.minY
        if rel < dome {
            let u = (dome - rel) / dome
            return 79 * (max(0, 1 - u * u)).squareRoot()
        }
        return 79 + 5.5 * (rel - dome) / (r.height - dome)
    }

    private static var shadePath: Path {
        let r = shadeRect
        let cx = r.midX
        var left: [CGPoint] = [], right: [CGPoint] = []
        let steps = 80
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let y = r.minY + r.height * t * t * (3 - 2 * t) * 0.5 + r.height * t * 0.5
            let hw = halfWidth(at: y)
            left.append(CGPoint(x: cx - hw, y: y))
            right.append(CGPoint(x: cx + hw, y: y))
        }
        var p = Path()
        p.addLines(left.reversed() + right)
        p.addQuadCurve(to: left.last!, control: CGPoint(x: cx, y: r.maxY + 7))
        p.closeSubpath()
        return p
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let r = Self.shadeRect
        let cx = r.midX

        // Shadow on desk and cord.
        ctx.drawLayer { l in
            l.addFilter(.blur(radius: 7))
            l.fill(Path(ellipseIn: CGRect(x: cx - 56, y: 297, width: 140, height: 18)), with: .color(.black.opacity(0.5)))
        }
        var cord = Path()
        cord.move(to: CGPoint(x: cx + 36, y: 302))
        cord.addCurve(to: CGPoint(x: 220, y: 290), control1: CGPoint(x: cx + 80, y: 316), control2: CGPoint(x: 170, y: 284))
        ctx.stroke(cord, with: .color(Color(hex: 0x15110D)), style: StrokeStyle(lineWidth: 3, lineCap: .round))

        // Brass foot.
        var foot = Path()
        foot.move(to: CGPoint(x: cx - 8, y: 240))
        foot.addLine(to: CGPoint(x: cx + 8, y: 240))
        foot.addCurve(to: CGPoint(x: cx + 50, y: 300), control1: CGPoint(x: cx + 9, y: 276), control2: CGPoint(x: cx + 30, y: 292))
        foot.addQuadCurve(to: CGPoint(x: cx - 50, y: 300), control: CGPoint(x: cx, y: 312))
        foot.addCurve(to: CGPoint(x: cx - 8, y: 240), control1: CGPoint(x: cx - 30, y: 292), control2: CGPoint(x: cx - 9, y: 276))
        foot.closeSubpath()
        let brass = Gradient(stops: [
            .init(color: Color(hex: 0x4A3812), location: 0),
            .init(color: Color(hex: 0xA07C3A), location: 0.26),
            .init(color: Color(hex: 0xEBD08F), location: 0.44),
            .init(color: Color(hex: 0xB8924A), location: 0.6),
            .init(color: Color(hex: 0x3E2E0E), location: 1),
        ])
        ctx.fill(foot, with: .linearGradient(brass, startPoint: CGPoint(x: cx - 50, y: 0), endPoint: CGPoint(x: cx + 50, y: 0)))
        var rim = Path()
        rim.move(to: CGPoint(x: cx - 50, y: 300))
        rim.addQuadCurve(to: CGPoint(x: cx + 50, y: 300), control: CGPoint(x: cx, y: 312))
        ctx.stroke(rim, with: .color(.black.opacity(0.35)), lineWidth: 1.2)
        ctx.fill(Path(roundedRect: CGRect(x: cx - 13, y: 226, width: 26, height: 16), cornerRadius: 3),
                 with: .linearGradient(brass, startPoint: CGPoint(x: cx - 13, y: 0), endPoint: CGPoint(x: cx + 13, y: 0)))

        // Glass shade.
        let shade = Self.shadePath
        if night {
            ctx.fill(shade, with: .radialGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0xFFF8EA), location: 0),
                    .init(color: Color(hex: 0xFFD99C), location: 0.25),
                    .init(color: Color(hex: 0xF4A85C), location: 0.62),
                    .init(color: Color(hex: 0xB86A30), location: 1),
                ]),
                center: CGPoint(x: cx, y: Self.bulb.y), startRadius: 0, endRadius: 150))
        } else {
            ctx.fill(shade, with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(hex: 0x5E5646), location: 0),
                    .init(color: Color(hex: 0x8E836C), location: 0.18),
                    .init(color: Color(hex: 0xC4B799), location: 0.4),
                    .init(color: Color(hex: 0xA79A7E), location: 0.56),
                    .init(color: Color(hex: 0x7A705C), location: 0.8),
                    .init(color: Color(hex: 0x575041), location: 1),
                ]),
                startPoint: CGPoint(x: r.minX, y: 0), endPoint: CGPoint(x: r.maxX, y: 0)))
            ctx.fill(shade, with: .linearGradient(
                Gradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.12)]),
                startPoint: CGPoint(x: 0, y: r.minY), endPoint: CGPoint(x: 0, y: r.maxY)))
            // Window reflection on the glass.
            ctx.drawLayer { l in
                l.clip(to: shade)
                l.addFilter(.blur(radius: 6))
                l.fill(Path(roundedRect: CGRect(x: r.minX + 30, y: r.minY + 30, width: 14, height: r.height - 50), cornerRadius: 7),
                       with: .color(.white.opacity(0.35)))
                l.fill(Path(roundedRect: CGRect(x: r.maxX - 44, y: r.minY + 50, width: 8, height: r.height - 80), cornerRadius: 4),
                       with: .color(.white.opacity(0.18)))
            }
        }

        ctx.drawLayer { l in
            l.clip(to: shade)
            // Stem and bulb seen through the glass.
            l.fill(Path(CGRect(x: cx - 4, y: Self.bulb.y + 10, width: 8, height: r.maxY - Self.bulb.y)),
                   with: .color(Color(hex: 0x2E2416).opacity(night ? 0.55 : 0.35)))
            if !night {
                l.fill(Path(ellipseIn: CGRect(x: cx - 15, y: Self.bulb.y - 20, width: 30, height: 36)), with: .color(.white.opacity(0.16)))
            }
            // Ribs that follow the dome's curvature.
            for deg in stride(from: -84.0, through: 84.0, by: 6.0) {
                let phi = deg * .pi / 180
                var rib = Path(), groove = Path()
                var y = r.minY
                var first = true
                while y <= r.maxY + 8 {
                    let x = cx + Self.halfWidth(at: y) * CGFloat(sin(phi))
                    if first {
                        rib.move(to: CGPoint(x: x, y: y)); groove.move(to: CGPoint(x: x + 1.8, y: y)); first = false
                    } else {
                        rib.addLine(to: CGPoint(x: x, y: y)); groove.addLine(to: CGPoint(x: x + 1.8, y: y))
                    }
                    y += 4
                }
                let facing = CGFloat(cos(phi))
                let highlight = night ? Color(hex: 0xFFF3D6) : Color.white
                let shadow = night ? Color(hex: 0x8A4A1E) : Color.black
                l.stroke(rib, with: .color(highlight.opacity(0.06 + 0.16 * Double(facing))), lineWidth: 0.6 + 1.6 * facing)
                l.stroke(groove, with: .color(shadow.opacity(night ? 0.18 : 0.12)), lineWidth: 0.6 + 0.8 * facing)
            }
        }
        ctx.stroke(shade, with: .color(.black.opacity(night ? 0.12 : 0.25)), lineWidth: 0.8)
    }
}
