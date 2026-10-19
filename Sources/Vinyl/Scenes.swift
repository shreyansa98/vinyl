import SwiftUI

/// Scenes are composed on a 1440×900 design stage. The stage is scaled to fit the
/// screen, while walls, desk and lighting extend to fill whatever is left over.
struct StageLayout {
    static let design = CGSize(width: 1440, height: 900)
    let full: CGSize

    var inset: CGPoint {
        CGPoint(x: (full.width - Self.design.width) / 2, y: (full.height - Self.design.height) / 2)
    }

    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: inset.x + x, y: inset.y + y) }
    func y(_ y: CGFloat) -> CGFloat { inset.y + y }

    /// Centre point for a turntable rig whose deck's back-left corner sits at (x, y).
    func rig(_ g: DeckGeometry, deckAt x: CGFloat, _ y: CGFloat) -> CGPoint {
        p(x - g.margin.width + g.frameSize.width / 2, y - g.margin.height + g.frameSize.height / 2)
    }
}

struct SceneCanvas: View {
    let kind: SceneKind
    let nowPlaying: NowPlaying
    var animate: Bool = true
    var stackHovered = false

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let s = max(0.01, min(size.width / StageLayout.design.width, size.height / StageLayout.design.height))
            let layout = StageLayout(full: CGSize(width: size.width / s, height: size.height / s))
            ZStack {
                switch kind {
                case .listeningRoom:
                    RoomScene(night: false, layout: layout, nowPlaying: nowPlaying, animate: animate, stackHovered: stackHovered)
                        .transition(.opacity)
                case .afterHours:
                    RoomScene(night: true, layout: layout, nowPlaying: nowPlaying, animate: animate, stackHovered: stackHovered)
                        .transition(.opacity)
                case .turntable:
                    TopDownScene(layout: layout, nowPlaying: nowPlaying, animate: animate)
                        .transition(.opacity)
                }
            }
            .frame(width: layout.full.width, height: layout.full.height)
            .scaleEffect(s)
            .frame(width: size.width, height: size.height)
            .environment(\.stageScale, s)
        }
        .animation(.easeInOut(duration: 0.9), value: kind)
        .animation(.easeInOut(duration: 0.8), value: nowPlaying.artwork.id)
        .background(Color.black)
        .clipped()
    }
}

// MARK: - Listening Room / After Hours

struct RoomScene: View {
    let night: Bool
    let layout: StageLayout
    let nowPlaying: NowPlaying
    let animate: Bool
    var stackHovered = false

    var body: some View {
        let L = layout
        let art = nowPlaying.artwork
        ZStack(alignment: .topLeading) {
            RoomBackdrop(night: night, full: L.full, deskY: L.y(470)).equatable()
            if !night {
                // Full-strength sunlight on wall and desk; objects only get a faint pass in RoomLighting.
                DaylightPattern(full: L.full, inset: L.inset)
                    .blendMode(.screen)
            }
            WallFrame(palette: art.palette, night: night)
                .position(L.p(858, 76))
            LampView(night: night).equatable()
                .position(L.p(1258, 389))
            RecordPile(recent: nowPlaying.recentTracks, fallback: art, hovered: stackHovered)
                .position(L.p(RecordPile.stageCenter.x, RecordPile.stageCenter.y))
            TurntableRig(g: .room, nowPlaying: nowPlaying, animate: animate)
                .position(L.rig(.room, deckAt: 478, 473))
            AlbumStand(art: art)
                .position(L.p(258, 486))
            RoomLighting(night: night, full: L.full, inset: L.inset).equatable()
        }
        .frame(width: L.full.width, height: L.full.height)
    }
}

struct RoomBackdrop: View, Equatable {
    let night: Bool
    let full: CGSize
    let deskY: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: night
                    ? [Color(hex: 0xE9C7A6), Color(hex: 0xF1D3B3)]
                    : [Color(hex: 0xD2C3A8), Color(hex: 0xDCCEB6)],
                startPoint: .top, endPoint: .bottom)
                .frame(width: full.width, height: deskY)
            // Ambient occlusion where the wall meets the desk.
            LinearGradient(colors: [.clear, .black.opacity(0.14)], startPoint: .top, endPoint: .bottom)
                .frame(width: full.width, height: 70)
                .offset(y: deskY - 70)
            WoodGrain(kind: .desk, seed: 11)
                .frame(width: full.width, height: max(1, full.height - deskY))
                .offset(y: deskY)
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(width: full.width, height: 16)
                .offset(y: deskY)
        }
        .frame(width: full.width, height: full.height, alignment: .topLeading)
    }
}

struct RoomLighting: View, Equatable {
    let night: Bool
    let full: CGSize
    let inset: CGPoint

    var body: some View {
        let lamp = CGPoint(x: inset.x + 1258 - LampView.size.width / 2 + LampView.bulb.x,
                           y: inset.y + 389 - LampView.size.height / 2 + LampView.bulb.y)
        let deskY = inset.y + 470
        let lampUnit = UnitPoint(x: lamp.x / full.width, y: lamp.y / full.height)

        ZStack(alignment: .topLeading) {
            if night {
                RadialGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: Color(red: 0.95, green: 0.83, blue: 0.72), location: 0.1),
                        .init(color: Color(red: 0.66, green: 0.48, blue: 0.38), location: 0.36),
                        .init(color: Color(red: 0.40, green: 0.27, blue: 0.21), location: 0.7),
                        .init(color: Color(red: 0.26, green: 0.17, blue: 0.13), location: 1),
                    ],
                    center: lampUnit, startRadius: 0, endRadius: 1500)
                    .blendMode(.multiply)
                // Warm spill from a light just off the left edge.
                RadialGradient(colors: [Color(hex: 0xFF8A3A).opacity(0.42), .clear],
                               center: UnitPoint(x: inset.x / full.width, y: (deskY - 20) / full.height),
                               startRadius: 0, endRadius: 360)
                    .blendMode(.screen)
                RadialGradient(colors: [Color(hex: 0xFFC37A).opacity(0.5), Color(hex: 0xFF9A48).opacity(0.16), .clear],
                               center: lampUnit, startRadius: 10, endRadius: 560)
                    .blendMode(.screen)
                Ellipse()
                    .fill(Color(hex: 0xFFA24F).opacity(0.3))
                    .frame(width: 900, height: 200)
                    .blur(radius: 50)
                    .position(x: lamp.x - 180, y: deskY + 70)
                    .blendMode(.screen)
                Circle()
                    .fill(Color(hex: 0xFFE7B8))
                    .frame(width: 70, height: 70)
                    .blur(radius: 22)
                    .position(lamp)
                    .blendMode(.screen)
                Ellipse()
                    .fill(Color.white)
                    .frame(width: 20, height: 30)
                    .blur(radius: 6)
                    .position(lamp)
            } else {
                DaylightPattern(full: full, inset: inset)
                    .opacity(0.35)
                    .blendMode(.screen)
                PlantShadow(full: full, inset: inset)
                    .blendMode(.multiply)
                RadialGradient(colors: [.white, .white, Color(red: 0.86, green: 0.82, blue: 0.77)],
                               center: .center, startRadius: 0, endRadius: max(full.width, full.height) * 0.75)
                    .blendMode(.multiply)
            }
        }
        .frame(width: full.width, height: full.height)
        .allowsHitTesting(false)
    }
}

/// Sunlight falling through a slatted window onto the wall and desk.
private struct DaylightPattern: View {
    let full: CGSize
    let inset: CGPoint

    var body: some View {
        Canvas { ctx, size in
            ctx.translateBy(x: inset.x, y: inset.y)
            let wall = Path(CGRect(x: -inset.x, y: -inset.y, width: size.width, height: 470 + inset.y))
            let light = Color(hex: 0xFFE6BE)

            // Window space (u, v) sheared onto the wall.
            func w(_ u: CGFloat, _ v: CGFloat) -> CGPoint { CGPoint(x: u + v * 0.3, y: v + u * 0.34) }

            ctx.drawLayer { l in
                l.clip(to: wall)
                l.addFilter(.blur(radius: 10))
                for (u0, u1) in [(-260.0, 390.0), (420.0, 1010.0)] as [(CGFloat, CGFloat)] {
                    var v: CGFloat = -340
                    while v < 520 {
                        var slat = Path()
                        slat.addLines([w(u0, v), w(u1, v), w(u1, v + 30), w(u0, v + 30)])
                        slat.closeSubpath()
                        l.fill(slat, with: .color(light.opacity(0.5)))
                        v += 50
                    }
                }
            }

            // The same light, stretched across the desk.
            ctx.drawLayer { l in
                l.clip(to: Path(CGRect(x: -inset.x, y: 470, width: size.width, height: size.height)))
                l.addFilter(.blur(radius: 22))
                for j in 0..<5 {
                    let x = -260 + CGFloat(j) * 130
                    var band = Path()
                    band.addLines([CGPoint(x: x, y: 470), CGPoint(x: x + 80, y: 470),
                                   CGPoint(x: x + 330, y: 900), CGPoint(x: x + 190, y: 900)])
                    band.closeSubpath()
                    l.fill(band, with: .color(light.opacity(0.18)))
                }
            }
        }
        .frame(width: full.width, height: full.height)
    }
}

/// Soft shadow of a houseplant somewhere off to the left.
private struct PlantShadow: View {
    let full: CGSize
    let inset: CGPoint

    var body: some View {
        Canvas { ctx, _ in
            ctx.translateBy(x: inset.x, y: inset.y)
            ctx.addFilter(.blur(radius: 7))
            let shade = GraphicsContext.Shading.color(Color(red: 0.76, green: 0.70, blue: 0.62))
            var rng = SplitMix(404)
            var stems = Path()
            for _ in 0..<5 {
                let base = CGPoint(x: rng.range(-60, 40), y: 470)
                let tip = CGPoint(x: rng.range(40, 230), y: rng.range(250, 360))
                stems.move(to: base)
                stems.addQuadCurve(to: tip, control: CGPoint(x: (base.x + tip.x) / 2 - 30, y: (base.y + tip.y) / 2))
            }
            ctx.stroke(stems, with: shade, lineWidth: 4)
            for _ in 0..<16 {
                let center = CGPoint(x: rng.range(-40, 250), y: rng.range(240, 430))
                let w = rng.range(22, 40), h = rng.range(70, 120)
                ctx.drawLayer { l in
                    l.translateBy(x: center.x, y: center.y)
                    l.rotate(by: .degrees(rng.range(-70, 70)))
                    l.fill(Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)), with: shade)
                }
            }
        }
        .frame(width: full.width, height: full.height)
    }
}

// MARK: - Turntable (top-down)

struct TopDownScene: View {
    let layout: StageLayout
    let nowPlaying: NowPlaying
    let animate: Bool

    var body: some View {
        let L = layout
        ZStack(alignment: .topLeading) {
            WoodGrain(kind: .topDown, seed: 5)
                .equatable()
                .frame(width: L.full.width, height: L.full.height)
            AlbumSleeve(art: nowPlaying.artwork)
                .position(L.p(352, 505))
            TurntableRig(g: .topDown, nowPlaying: nowPlaying, animate: animate)
                .position(L.rig(.topDown, deckAt: 600, 180))
            TopDownLighting(full: L.full, inset: L.inset).equatable()
        }
        .frame(width: L.full.width, height: L.full.height)
    }
}

private struct TopDownLighting: View, Equatable {
    let full: CGSize
    let inset: CGPoint

    var body: some View {
        ZStack {
            // Shadows of window mullions across the desk.
            Canvas { ctx, size in
                ctx.addFilter(.blur(radius: 26))
                let shade = GraphicsContext.Shading.color(Color(red: 0.46, green: 0.33, blue: 0.24))
                let slant: CGFloat = 0.36
                for i in -3..<8 {
                    let x0 = inset.x + CGFloat(i) * 420 + 20
                    let w: CGFloat = 70
                    var band = Path()
                    band.addLines([
                        CGPoint(x: x0, y: -60), CGPoint(x: x0 + w, y: -60),
                        CGPoint(x: x0 + w + slant * (size.height + 120), y: size.height + 60),
                        CGPoint(x: x0 + slant * (size.height + 120), y: size.height + 60),
                    ])
                    band.closeSubpath()
                    ctx.fill(band, with: shade)
                }
            }
            .blendMode(.multiply)
            RadialGradient(colors: [Color(hex: 0xFFD9A0).opacity(0.18), .clear],
                           center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: max(full.width, full.height) * 0.7)
                .blendMode(.screen)
            RadialGradient(colors: [.white, .white, Color(red: 0.72, green: 0.64, blue: 0.58)],
                           center: .center, startRadius: 0, endRadius: max(full.width, full.height) * 0.72)
                .blendMode(.multiply)
        }
        .frame(width: full.width, height: full.height)
        .allowsHitTesting(false)
    }
}
