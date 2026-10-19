import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Vinyl --snapshot <out-dir> [art] [width] [height] [recent-art…]` renders every scene to PNG.
@MainActor
enum Snapshotter {
    static func run(_ args: [String]) {
        guard let outDir = args.first else {
            print("usage: --snapshot <out-dir> [art] [width] [height] [recent-art…]")
            return
        }
        let art = args.count > 1 ? NSImage(contentsOfFile: args[1]) : nil
        let width = args.count > 2 ? Double(args[2]) ?? 1512 : 1512
        let height = args.count > 3 ? Double(args[3]) ?? 982 : 982
        let recent = args.dropFirst(4).compactMap { NSImage(contentsOfFile: $0) }
        let model = NowPlaying.preview(settings: AppSettings(), art: art, recent: recent, playing: true)
        let dir = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for kind in SceneKind.allCases {
            let renderer = ImageRenderer(content:
                SceneCanvas(kind: kind, nowPlaying: model, animate: false)
                    .frame(width: width, height: height)
            )
            renderer.scale = Double(ProcessInfo.processInfo.environment["VINYL_SNAPSHOT_SCALE"] ?? "") ?? 1
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                print("failed to render \(kind.rawValue)")
                continue
            }
            let url = dir.appendingPathComponent("\(kind.rawValue).png")
            try? data.write(to: url)
            print("wrote \(url.path)")
        }

        // The menu uses AppKit-backed controls, so draw it through a real hosting view.
        let views: [(String, NSAppearance.Name, AnyView)] = [
            ("menu-light", .aqua, AnyView(MenuView(nowPlaying: model, settings: AppSettings()))),
            ("menu-dark", .darkAqua, AnyView(MenuView(nowPlaying: model, settings: AppSettings()))),
            ("recents-dark", .darkAqua, AnyView(RecentlyPlayedList(nowPlaying: model) { _ in })),
        ]
        for (name, appearance, view) in views {
            let hosting = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
            hosting.appearance = NSAppearance(named: appearance)
            hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { continue }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = dir.appendingPathComponent("\(name).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
            print("wrote \(url.path)")
        }
    }
}

/// `Vinyl --render-icon <dir.iconset>` writes the app icon at every size `iconutil` expects.
@MainActor
enum IconRenderer {
    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, CGFloat)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            let renderer = ImageRenderer(content: AppIconView().frame(width: 1024, height: 1024))
            renderer.scale = px / 1024
            guard let image = renderer.cgImage,
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { continue }
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}

struct AppIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 186, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0xF3E6D0), Color(hex: 0xD9C1A0)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: 186, style: .continuous)
                        .fill(RadialGradient(colors: [.white.opacity(0.5), .clear], center: UnitPoint(x: 0.3, y: 0.2), startRadius: 0, endRadius: 600))
                )
                .overlay(RoundedRectangle(cornerRadius: 186, style: .continuous).strokeBorder(Color.black.opacity(0.08), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 14)

            ZStack {
                Circle().fill(Color(hex: 0x111111))
                ForEach(0..<18) { i in
                    Circle()
                        .stroke(Color.white.opacity(i % 4 == 0 ? 0.1 : 0.045), lineWidth: 2)
                        .frame(width: CGFloat(250 + i * 19), height: CGFloat(250 + i * 19))
                }
                Circle()
                    .fill(AngularGradient(
                        gradient: Gradient(stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0.28), location: 0.07),
                            .init(color: .white.opacity(0), location: 0.16),
                            .init(color: .white.opacity(0), location: 0.5),
                            .init(color: .white.opacity(0.2), location: 0.57),
                            .init(color: .white.opacity(0), location: 0.66),
                        ]),
                        center: .center, angle: .degrees(-25)))
                    .mask(Circle().strokeBorder(Color.black, lineWidth: 170))
                Circle()
                    .fill(LinearGradient(colors: [Color(hex: 0xE9744A), Color(hex: 0xB4402A)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 210, height: 210)
                Circle().fill(Color(hex: 0xF3E6D0)).frame(width: 22, height: 22)
            }
            .frame(width: 590, height: 590)
            .shadow(color: .black.opacity(0.35), radius: 18, x: 8, y: 14)
            .offset(x: -46, y: 28)

            // Tonearm.
            Path { p in
                p.move(to: CGPoint(x: 760, y: 250))
                p.addLine(to: CGPoint(x: 700, y: 560))
                p.addLine(to: CGPoint(x: 640, y: 640))
            }
            .stroke(LinearGradient(colors: [Color(hex: 0xF4F4F4), Color(hex: 0x9A9A9A)], startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 6, y: 8)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(hex: 0x1C1C1C))
                .frame(width: 44, height: 76)
                .rotationEffect(.degrees(37))
                .position(x: 630, y: 652)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0x4A4A4A), Color(hex: 0x151515)], center: .center, startRadius: 0, endRadius: 50))
                .frame(width: 92, height: 92)
                .overlay(Circle().stroke(Color(hex: 0xD8D8D8), lineWidth: 6))
                .position(x: 760, y: 250)
        }
        .frame(width: 1024, height: 1024)
    }
}

/// `Vinyl --gif <out.gif> <art> [recent-art…]` renders one seamless revolution of the
/// Turntable scene's record as an animated GIF (used in the README).
@MainActor
enum GIFRenderer {
    static func run(_ args: [String]) {
        guard args.count >= 2 else {
            print("usage: --gif <out.gif> <art> [recent-art…]")
            return
        }
        let model = NowPlaying.preview(settings: AppSettings(), art: NSImage(contentsOfFile: args[1]),
                                       recent: args.dropFirst(2).compactMap { NSImage(contentsOfFile: $0) }, playing: true)
        let frames = 30
        let outputWidth = 560
        // The deck on the 1440×900 stage, with a little desk around it.
        let crop = CGRect(x: 585, y: 165, width: 676, height: 612)
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[0]) as CFURL,
                                                                UTType.gif.identifier as CFString, frames, nil) else { return }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for i in 0..<frames {
            let spin = 2 * Double.pi * Double(i) / Double(frames)
            let renderer = ImageRenderer(content:
                SceneCanvas(kind: .turntable, nowPlaying: model, animate: false)
                    .environment(\.stillSpin, spin)
                    .frame(width: 1440, height: 900)
            )
            renderer.scale = 1
            guard let full = renderer.cgImage, let cropped = full.cropping(to: crop) else { continue }
            let height = Int(Double(outputWidth) * crop.height / crop.width)
            guard let ctx = CGContext(data: nil, width: outputWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.interpolationQuality = .high
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outputWidth, height: height))
            guard let frame = ctx.makeImage() else { continue }
            // 33⅓ rpm: one revolution takes 1.8 s.
            CGImageDestinationAddImage(destination, frame, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.8 / Double(frames)],
            ] as CFDictionary)
        }
        if CGImageDestinationFinalize(destination) { print("wrote \(args[0])") }
    }
}
