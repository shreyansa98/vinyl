import AppKit
import SwiftUI

// MARK: - List UI

/// "Recently Played" card: the last five songs, click one to put it back on.
struct RecentlyPlayedList: View {
    let nowPlaying: NowPlaying
    let onPlay: (RecentTrack) -> Void

    var body: some View {
        let recent = nowPlaying.recentTracks
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recently Played")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if !recent.isEmpty {
                    Text("Click to play")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            if recent.isEmpty {
                Text("Songs you play will stack up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
            } else {
                VStack(spacing: 2) {
                    ForEach(recent) { item in
                        RecentRow(item: item) { onPlay(item) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
        }
        .frame(width: 330)
    }
}

private struct RecentRow: View {
    let item: RecentTrack
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                CoverThumb(art: item.artwork, size: 42, showPlay: hovering)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.track.title.isEmpty ? "Unknown" : item.track.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(item.playedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var subtitle: String {
        [item.track.artist, item.track.sourceName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct CoverThumb: View {
    let art: Artwork?
    let size: CGFloat
    var showPlay = false

    var body: some View {
        Image(nsImage: (art ?? .placeholder).image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            .overlay {
                if showPlay {
                    ZStack {
                        RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).fill(Color.black.opacity(0.35))
                        Image(systemName: "play.fill")
                            .font(.system(size: size * 0.32, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
                }
            }
    }
}

// MARK: - Floating panel

/// A borderless panel that can take clicks without activating Vinyl.
private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Shows the Recently Played card next to the record pile on the desktop.
@MainActor
final class RecentsPanel {
    static let shared = RecentsPanel()

    private var panel: NSPanel?
    private var monitors: [Any] = []
    /// Window whose clicks toggle the panel (so they shouldn't also dismiss it).
    private weak var anchorWindow: NSWindow?

    var isShown: Bool { panel != nil }

    func toggle(nowPlaying: NowPlaying, anchor: NSRect, from window: NSWindow) {
        if isShown { close() } else { show(nowPlaying: nowPlaying, anchor: anchor, from: window) }
    }

    func show(nowPlaying: NowPlaying, anchor: NSRect, from window: NSWindow) {
        close()
        anchorWindow = window
        let content = RecentlyPlayedList(nowPlaying: nowPlaying) { [weak self] item in
            nowPlaying.play(item)
            self?.close()
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.12)))

        let hosting = NSHostingView(rootView: content)
        let size = hosting.fittingSize
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        panel.contentView = hosting

        // Above the pile, nudged inside the screen.
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + 6)
        if origin.y + size.height > visible.maxY { origin.y = anchor.minY - size.height - 6 }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        panel.setFrameOrigin(origin)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
        self.panel = panel

        // Dismiss on a click anywhere else or Escape.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            let isKey = event.type == .keyDown
            let window = event.window
            let swallow: Bool = MainActor.assumeIsolated {
                guard let self else { return false }
                if isEscape { self.close(); return true }
                if !isKey && window !== self.panel && window !== self.anchorWindow { self.close() }
                return false
            }
            return swallow ? nil : event
        }) { monitors.append(local) }
    }

    func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Click target over the pile

/// The desktop scene sits below Finder's icon layer, so it can't be clicked. This small
/// transparent panel sits just above the icons (still below every app window), exactly
/// over the record pile, and opens the Recently Played card.
final class StackHotspotWindow: NSPanel {
    private let hotspot: HotspotView

    init(screen: NSScreen, host: SceneHost, nowPlaying: NowPlaying) {
        hotspot = HotspotView(host: host)
        super.init(contentRect: Self.frame(for: screen), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = false
        contentView = hotspot

        hotspot.onClick = { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                RecentsPanel.shared.toggle(nowPlaying: nowPlaying, anchor: self.frame, from: self)
            }
        }
    }

    /// The pile's rectangle on screen, using the same stage fit as `SceneCanvas`.
    static func frame(for screen: NSScreen) -> NSRect {
        let size = screen.frame.size
        let design = StageLayout.design
        let s = min(size.width / design.width, size.height / design.height)
        let layout = StageLayout(full: CGSize(width: size.width / s, height: size.height / s))
        let center = layout.p(RecordPile.stageCenter.x, RecordPile.stageCenter.y)
        let width = 400 * s, height = 210 * s
        return NSRect(x: screen.frame.minX + center.x * s - width / 2,
                      y: screen.frame.maxY - center.y * s - height / 2,
                      width: width, height: height)
    }
}

private final class HotspotView: NSView {
    var onClick: (() -> Void)?
    private let host: SceneHost
    private let label: NSHostingView<HoverLabel>

    init(host: SceneHost) {
        self.host = host
        label = NSHostingView(rootView: HoverLabel(host: host))
        super.init(frame: .zero)
        wantsLayer = true
        // A sliver of alpha so the window server delivers clicks here instead of to Finder.
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.01).cgColor
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        label.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseEntered(with event: NSEvent) {
        host.stackHovered = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        host.stackHovered = false
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

private struct HoverLabel: View {
    let host: SceneHost

    var body: some View {
        VStack {
            if host.stackHovered {
                Label("Recently Played", systemImage: "square.stack.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            Spacer()
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: host.stackHovered)
        .allowsHitTesting(false)
    }
}
