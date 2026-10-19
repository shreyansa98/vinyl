import AppKit
import SwiftUI

// MARK: - Colors

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    func mixed(with other: NSColor, _ fraction: CGFloat) -> NSColor {
        blended(withFraction: fraction, of: other) ?? self
    }
}

// MARK: - Deterministic randomness (textures must not shimmer between redraws)

struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

// MARK: - Palette extracted from album art

struct ArtPalette: Equatable {
    /// Three prominent colours, most prominent first.
    var colors: [NSColor]
    var average: NSColor

    static let fallback = ArtPalette(
        colors: [NSColor(hex: 0xC4553A), NSColor(hex: 0x23305A), NSColor(hex: 0xE8D9B8)],
        average: NSColor(hex: 0x8A5A44)
    )

    init(colors: [NSColor], average: NSColor) {
        self.colors = colors
        self.average = average
    }

    init(image: CGImage?) {
        guard let image else { self = .fallback; return }
        let n = 24
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let ctx = CGContext(
                data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drew else { self = .fallback; return }

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, count = 0.0 }
        var buckets: [Int: Bucket] = [:]
        var tr = 0.0, tg = 0.0, tb = 0.0
        for i in 0..<(n * n) {
            let r = Double(pixels[i * 4]) / 255
            let g = Double(pixels[i * 4 + 1]) / 255
            let b = Double(pixels[i * 4 + 2]) / 255
            tr += r; tg += g; tb += b
            let key = Int(r * 5.99) * 36 + Int(g * 5.99) * 6 + Int(b * 5.99)
            var bucket = buckets[key, default: Bucket()]
            bucket.r += r; bucket.g += g; bucket.b += b; bucket.count += 1
            buckets[key] = bucket
        }
        let total = Double(n * n)
        let average = NSColor(srgbRed: tr / total, green: tg / total, blue: tb / total, alpha: 1)

        let ranked: [(NSColor, Double)] = buckets.values.map { b in
            let c = NSColor(srgbRed: b.r / b.count, green: b.g / b.count, blue: b.b / b.count, alpha: 1)
            return (c, b.count * (0.35 + c.saturationComponent))
        }.sorted { $0.1 > $1.1 }

        func distance(_ a: NSColor, _ b: NSColor) -> Double {
            let dr = a.redComponent - b.redComponent
            let dg = a.greenComponent - b.greenComponent
            let db = a.blueComponent - b.blueComponent
            return Double((dr * dr + dg * dg + db * db).squareRoot())
        }

        var picked: [NSColor] = []
        for (c, _) in ranked where picked.allSatisfy({ distance($0, c) > 0.25 }) {
            picked.append(c)
            if picked.count == 3 { break }
        }
        while picked.count < 3 {
            picked.append((picked.last ?? average).mixed(with: .black, 0.35))
        }
        self.init(colors: picked, average: average)
    }
}

// MARK: - Artwork

/// One piece of album art plus everything derived from it. Identity (`id`) is what
/// caches key on, so a new `Artwork` is created only when the picture really changes.
final class Artwork: Identifiable, Equatable {
    let id = UUID()
    let image: NSImage
    let cgImage: CGImage?
    let palette: ArtPalette
    let isPlaceholder: Bool

    init(image: NSImage, isPlaceholder: Bool = false) {
        self.image = image
        self.cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        self.palette = isPlaceholder ? .fallback : ArtPalette(image: cgImage)
        self.isPlaceholder = isPlaceholder
    }

    static func == (lhs: Artwork, rhs: Artwork) -> Bool { lhs.id == rhs.id }

    var pixelWidth: Int { cgImage?.width ?? 0 }

    static let placeholder = Artwork(image: PlaceholderArt.make(), isPlaceholder: true)

    func jpegData() -> Data? {
        guard let cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }
}

/// A quiet, Bauhaus-ish sleeve shown before anything has been played.
enum PlaceholderArt {
    static func make() -> NSImage {
        let size = NSSize(width: 640, height: 640)
        let image = NSImage(size: size)
        image.lockFocusFlipped(true)
        defer { image.unlockFocus() }

        NSColor(hex: 0xEDE4D3).setFill()
        NSRect(origin: .zero, size: size).fill()

        NSColor(hex: 0x23305A).setFill()
        NSRect(x: 84, y: 120, width: 230, height: 330).fill()

        NSColor(hex: 0xC9573B).setFill()
        NSBezierPath(ovalIn: NSRect(x: 220, y: 150, width: 330, height: 330)).fill()

        NSColor(hex: 0xD8A84A).setFill()
        NSRect(x: 84, y: 470, width: 470, height: 10).fill()

        NSColor(hex: 0x1D1A17).setFill()
        NSRect(x: 84, y: 520, width: 470, height: 1.5).fill()

        let style = NSMutableParagraphStyle()
        style.alignment = .left
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
            .foregroundColor: NSColor(hex: 0x1D1A17),
            .kern: 9,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: "VINYL", attributes: attrs).draw(at: NSPoint(x: 84, y: 540))
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor(hex: 0x1D1A17).withAlphaComponent(0.6),
            .kern: 3,
        ]
        NSAttributedString(string: "SIDE A", attributes: small).draw(at: NSPoint(x: 484, y: 546))
        return image
    }
}
