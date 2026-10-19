import AppKit
import Observation
import SwiftUI

/// Per-window state the scene needs from AppKit.
@Observable
final class SceneHost {
    /// False while the desktop is fully covered, so animation can pause.
    var visible = true
    /// The pointer is over the record pile.
    var stackHovered = false
}

struct DesktopSceneView: View {
    let nowPlaying: NowPlaying
    let settings: AppSettings
    let host: SceneHost

    var body: some View {
        SceneCanvas(kind: settings.scene, nowPlaying: nowPlaying, animate: host.visible, stackHovered: host.stackHovered)
            .ignoresSafeArea()
    }
}

/// A borderless window that sits just above the system wallpaper and below the
/// desktop icons, on every Space.
final class DesktopWindow: NSWindow {
    let host = SceneHost()

    init(screen: NSScreen, nowPlaying: NowPlaying, settings: AppSettings) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: DesktopSceneView(nowPlaying: nowPlaying, settings: settings, host: host))
        hosting.sizingOptions = []
        contentView = hosting
        setFrame(screen.frame, display: false)

        NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: self)
    }

    @objc private func occlusionChanged() {
        let visible = occlusionState.contains(.visible)
        if host.visible != visible { host.visible = visible }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class DesktopController {
    private let nowPlaying: NowPlaying
    private let settings: AppSettings
    private var windows: [DesktopWindow] = []
    private var hotspots: [StackHotspotWindow] = []
    private var hideWork: DispatchWorkItem?
    private var isShown = false

    init(nowPlaying: NowPlaying, settings: AppSettings) {
        self.nowPlaying = nowPlaying
        self.settings = settings
    }

    private var shouldShow: Bool {
        settings.wallpaperEnabled && (!settings.hideWhenPaused || nowPlaying.isPlaying)
    }

    func start() {
        rebuild()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        track()
    }

    /// The record pile is clickable in the room scenes once there's something on it.
    private var shouldShowHotspots: Bool {
        isShown && settings.scene != .turntable && !nowPlaying.recentTracks.isEmpty
    }

    private func track() {
        withObservationTracking {
            _ = shouldShow
            _ = settings.scene
            _ = nowPlaying.recentTracks.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply(animated: true)
                self?.updateHotspots()
                self?.track()
            }
        }
    }

    private func updateHotspots() {
        let show = shouldShowHotspots
        for hotspot in hotspots {
            if show { hotspot.orderFrontRegardless() } else { hotspot.orderOut(nil) }
        }
        if !show { RecentsPanel.shared.close() }
    }

    private func rebuild() {
        windows.forEach { $0.orderOut(nil) }
        hotspots.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { DesktopWindow(screen: $0, nowPlaying: nowPlaying, settings: settings) }
        hotspots = zip(NSScreen.screens, windows).map { screen, window in
            StackHotspotWindow(screen: screen, host: window.host, nowPlaying: nowPlaying)
        }
        isShown = false
        windows.forEach { $0.alphaValue = 0 }
        apply(animated: false)
    }

    private func apply(animated: Bool) {
        hideWork?.cancel()
        hideWork = nil
        if shouldShow {
            setShown(true, animated: animated)
        } else {
            // A short grace period rides over the brief pause between tracks.
            let delay = settings.wallpaperEnabled ? 1.5 : 0
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.setShown(false, animated: animated) }
            }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func setShown(_ show: Bool, animated: Bool) {
        guard show != isShown else { return }
        isShown = show
        updateHotspots()
        if show { windows.forEach { $0.orderFront(nil) } }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? 0.7 : 0
            for window in windows { window.animator().alphaValue = show ? 1 : 0 }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.windows.forEach { $0.orderOut(nil) }
            }
        }
    }
}
