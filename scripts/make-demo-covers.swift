// Draws the fictional album covers used for README screenshots, so the repo never
// ships real (copyrighted) artwork. Usage: swift scripts/make-demo-covers.swift docs/covers
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/covers")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let size = NSSize(width: 800, height: 800)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func text(_ s: String, _ font: NSFont, _ c: NSColor, at p: NSPoint, kern: CGFloat = 0) {
    NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c, .kern: kern]).draw(at: p)
}

func grain(_ amount: CGFloat, seed: UInt64) {
    var state = seed
    func rand() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1) }
    for _ in 0..<9000 {
        (rand() > 0.5 ? NSColor.white : NSColor.black).withAlphaComponent(amount * rand()).setFill()
        NSRect(x: rand() * 800, y: rand() * 800, width: 1.6, height: 1.6).fill()
    }
}

func cover(_ name: String, _ draw: () -> Void) {
    let image = NSImage(size: size)
    image.lockFocus()
    draw()
    image.unlockFocus()
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    try! rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!.write(to: outDir.appendingPathComponent("\(name).jpg"))
    print("wrote \(name).jpg")
}

let serif = { (s: CGFloat) in NSFont(name: "Georgia-Bold", size: s) ?? .boldSystemFont(ofSize: s) }
let sans = { (s: CGFloat, w: NSFont.Weight) in NSFont.systemFont(ofSize: s, weight: w) }

cover("golden-hour") {
    NSGradient(colors: [color(0xF6C177), color(0xE8825A), color(0x9C3D54)])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    color(0xFFE9B8).setFill(); NSBezierPath(ovalIn: NSRect(x: 230, y: 300, width: 340, height: 340)).fill()
    for i in 0..<9 {
        color(0x9C3D54, 0.55 + CGFloat(i) * 0.05).setFill()
        NSRect(x: 0, y: 300 - CGFloat(i) * 34, width: 800, height: 14 + CGFloat(i) * 2).fill()
    }
    text("GOLDEN HOUR", serif(54), color(0xFFF4E0), at: NSPoint(x: 60, y: 690), kern: 4)
    text("SAFFRON LANE", sans(20, .medium), color(0xFFF4E0, 0.85), at: NSPoint(x: 62, y: 655), kern: 8)
    grain(0.06, seed: 1)
}

cover("night-swim") {
    NSGradient(colors: [color(0x0B1B3A), color(0x12355B), color(0x1F5C7A)])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    color(0xEDE6D6).setFill(); NSBezierPath(ovalIn: NSRect(x: 480, y: 520, width: 170, height: 170)).fill()
    for i in 0..<14 {
        let path = NSBezierPath()
        let y = 60 + CGFloat(i) * 24
        path.move(to: NSPoint(x: 0, y: y))
        for x in stride(from: 0.0, through: 800.0, by: 20) { path.line(to: NSPoint(x: x, y: y + 8 * sin(x / 60 + Double(i)))) }
        color(0x9FD3E8, 0.12 + CGFloat(i) * 0.02).setStroke(); path.lineWidth = 3; path.stroke()
    }
    text("night swim", serif(64), color(0xEDE6D6), at: NSPoint(x: 60, y: 120))
    text("PAPER MOONS", sans(18, .semibold), color(0xEDE6D6, 0.8), at: NSPoint(x: 64, y: 90), kern: 7)
    grain(0.05, seed: 2)
}

cover("velvet-static") {
    color(0x2A1033).setFill(); NSRect(origin: .zero, size: size).fill()
    for i in 0..<5 {
        color([0xFF5F9E, 0xB14AED, 0x5B4FE9, 0xFF9F68, 0xFFD166][i], 0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: 80 + CGFloat(i) * 40, y: 120 + CGFloat(i) * 70, width: 640 - CGFloat(i) * 80, height: 60), xRadius: 30, yRadius: 30).fill()
    }
    text("VELVET", sans(96, .black), color(0xFFFFFF), at: NSPoint(x: 70, y: 600))
    text("STATIC", sans(96, .black), color(0xFF5F9E), at: NSPoint(x: 70, y: 500))
    text("THE LOW HUMS", sans(18, .bold), color(0xFFFFFF, 0.8), at: NSPoint(x: 74, y: 60), kern: 6)
    grain(0.12, seed: 3)
}

cover("tangerine") {
    color(0xF2E8D5).setFill(); NSRect(origin: .zero, size: size).fill()
    color(0xF28C28).setFill(); NSBezierPath(ovalIn: NSRect(x: 140, y: 180, width: 460, height: 460)).fill()
    color(0x1E3D59).setFill(); NSRect(x: 420, y: 120, width: 260, height: 260).fill()
    color(0x2E8B57).setFill(); NSBezierPath(ovalIn: NSRect(x: 330, y: 560, width: 90, height: 140)).fill()
    color(0x1C1C1C).setFill(); NSRect(x: 60, y: 90, width: 680, height: 3).fill()
    text("Tangerine", serif(52), color(0x1C1C1C), at: NSPoint(x: 60, y: 30))
    text("ODA RIVERS", sans(16, .bold), color(0x1C1C1C, 0.7), at: NSPoint(x: 580, y: 46), kern: 4)
    grain(0.05, seed: 4)
}

cover("slow-lights") {
    NSGradient(colors: [color(0x121212), color(0x1F1A24)])!.draw(in: NSRect(origin: .zero, size: size), angle: -90)
    var state: UInt64 = 9
    func rand() -> CGFloat { state = state &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(state >> 33) / CGFloat(UInt32.max >> 1) }
    for _ in 0..<40 {
        let r = 20 + rand() * 90
        color([0xFFB347, 0xFF6F61, 0x7FD1B9, 0xF7F0C6][Int(rand() * 3.99)], 0.12 + rand() * 0.3).setFill()
        NSBezierPath(ovalIn: NSRect(x: rand() * 800 - r, y: 200 + rand() * 600 - r, width: r * 2, height: r * 2)).fill()
    }
    text("slow lights", sans(70, .ultraLight), color(0xF7F0C6), at: NSPoint(x: 60, y: 110))
    text("KINFOLK RADIO", sans(16, .semibold), color(0xF7F0C6, 0.7), at: NSPoint(x: 64, y: 80), kern: 6)
    grain(0.08, seed: 5)
}

cover("afterglow") {
    NSGradient(colors: [color(0x0F4C5C), color(0x2C7873), color(0xE36414)])!.draw(in: NSRect(origin: .zero, size: size), angle: -60)
    for i in 0..<12 {
        let r = 60 + CGFloat(i) * 28
        let ring = NSBezierPath(ovalIn: NSRect(x: 400 - r, y: 430 - r, width: r * 2, height: r * 2))
        color(0xFFF1D0, 0.5 - CGFloat(i) * 0.035).setStroke(); ring.lineWidth = 2; ring.stroke()
    }
    text("AFTERGLOW", sans(60, .heavy), color(0xFFF1D0), at: NSPoint(x: 60, y: 80), kern: 6)
    text("MIRA SOL", sans(18, .semibold), color(0xFFF1D0, 0.8), at: NSPoint(x: 64, y: 50), kern: 8)
    grain(0.06, seed: 6)
}
