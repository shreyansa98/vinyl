import AppKit
import SwiftUI

struct MenuView: View {
    let nowPlaying: NowPlaying
    @Bindable var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            NowPlayingCard(nowPlaying: nowPlaying)

            VStack(alignment: .leading, spacing: 14) {
                if let source = nowPlaying.permissionNeeded {
                    PermissionBanner(source: source)
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Scene")
                    HStack(spacing: 8) {
                        ForEach(SceneKind.allCases) { kind in
                            SceneTile(kind: kind, isSelected: settings.scene == kind, nowPlaying: nowPlaying) {
                                settings.scene = kind
                            }
                        }
                    }
                }

                if !nowPlaying.recentTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Recently Played")
                        HStack(spacing: 8) {
                            ForEach(nowPlaying.recentTracks) { item in
                                RecentCover(item: item) { nowPlaying.play(item) }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle("Settings")
                    VStack(spacing: 0) {
                        SettingRow(symbol: "photo.on.rectangle.angled", tint: .blue, title: "Show on Desktop") {
                            Toggle("", isOn: $settings.wallpaperEnabled)
                        }
                        RowDivider()
                        SettingRow(symbol: "pause.fill", tint: .orange, title: "Hide When Paused") {
                            Toggle("", isOn: $settings.hideWhenPaused)
                        }
                        RowDivider()
                        SettingRow(symbol: "power", tint: .green, title: "Launch at Login", note: settings.loginItemNote) {
                            Toggle("", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                        }
                        RowDivider()
                        SettingRow(symbol: "music.note", tint: .pink, title: "Music Source") {
                            Picker("", selection: $settings.source) {
                                ForEach(SourcePreference.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
            .padding(14)

            Divider().opacity(0.6)

            HStack(spacing: 6) {
                Image(systemName: "record.circle")
                    .foregroundStyle(.secondary)
                Text("Vinyl").font(.system(size: 12, weight: .semibold))
                Text(appVersion).font(.system(size: 11)).foregroundStyle(.tertiary)
                Text("BETA")
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                Spacer()
                Button("Quit Vinyl") { NSApp.terminate(nil) }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .keyboardShortcut("q")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 344)
        .onAppear { settings.refreshLoginItemStatus() }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 2)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().padding(.leading, 44)
    }
}

private struct SettingRow<Accessory: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var note: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let note {
                    Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Now playing card

private struct NowPlayingCard: View {
    let nowPlaying: NowPlaying

    var body: some View {
        let art = nowPlaying.artwork
        let track = nowPlaying.track
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: art.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.15)))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                    .id(art.id)
                    .transition(.opacity)

                VStack(alignment: .leading, spacing: 3) {
                    StatusPill(nowPlaying: nowPlaying)
                    Text(track?.title ?? "Nothing playing")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(track?.artist ?? "Play something in YouTube Music, Spotify, Apple Music or your browser")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(track == nil ? 2 : 1)
                    if let album = track?.album, !album.isEmpty {
                        Text(album)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.52))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }

            if track != nil {
                ProgressRow(nowPlaying: nowPlaying)
                TransportControls(nowPlaying: nowPlaying)
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(nsColor: art.palette.average.mixed(with: .black, 0.35))
                Image(nsImage: art.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.5)
                    .blur(radius: 40)
                    .saturation(1.35)
                    .opacity(0.85)
                LinearGradient(colors: [.black.opacity(0.18), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
            }
            .clipped()
        }
        .clipped()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.45), value: art.id)
    }
}

private struct StatusPill: View {
    let nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 5) {
            if nowPlaying.isPlaying {
                EqualizerBars()
            } else {
                Circle().fill(Color.white.opacity(0.5)).frame(width: 5, height: 5)
            }
            Text(statusText)
                .font(.system(size: 9.5, weight: .bold))
                .tracking(0.8)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.white.opacity(0.14)))
    }

    private var statusText: String {
        guard nowPlaying.track != nil else { return "IDLE" }
        let source = nowPlaying.track?.sourceName.uppercased() ?? ""
        return (nowPlaying.isPlaying ? "PLAYING" : "PAUSED") + (source.isEmpty ? "" : " · \(source)")
    }
}

private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: 2, height: 3 + 5 * CGFloat(abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i)))))
                }
            }
            .frame(height: 8, alignment: .bottom)
        }
    }
}

private struct ProgressRow: View {
    let nowPlaying: NowPlaying

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !nowPlaying.isPlaying)) { context in
            let position = nowPlaying.currentPosition(at: context.date)
            let duration = nowPlaying.track?.duration ?? 0
            let fraction = duration > 0 ? position / duration : 0
            VStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.22))
                        Capsule().fill(Color.white).frame(width: max(4, geo.size.width * fraction))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(Self.format(position))
                    Spacer()
                    Text("-" + Self.format(max(0, duration - position)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct TransportControls: View {
    let nowPlaying: NowPlaying

    var body: some View {
        HStack(spacing: 26) {
            Spacer()
            TransportButton(symbol: "backward.fill", size: 15) { nowPlaying.previousTrack() }
            TransportButton(symbol: nowPlaying.isPlaying ? "pause.fill" : "play.fill", size: 20, prominent: true) { nowPlaying.playPause() }
            TransportButton(symbol: "forward.fill", size: 15) { nowPlaying.nextTrack() }
            Spacer()
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    let size: CGFloat
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: prominent ? 42 : 32, height: prominent ? 42 : 32)
                .background(Circle().fill(Color.white.opacity(prominent ? (hovering ? 0.3 : 0.2) : (hovering ? 0.14 : 0))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Scene picker

private struct SceneTile: View {
    let kind: SceneKind
    let isSelected: Bool
    let nowPlaying: NowPlaying
    let action: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.primary.opacity(0.08))
                    }
                }
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
                .shadow(color: .black.opacity(hovering ? 0.25 : 0.12), radius: hovering ? 6 : 3, y: 2)

                Text(kind.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .task(id: nowPlaying.artwork.id) {
            thumbnail = SceneThumbnails.image(for: kind, nowPlaying: nowPlaying)
        }
    }
}

@MainActor
enum SceneThumbnails {
    private static var cache: [String: NSImage] = [:]

    static func image(for kind: SceneKind, nowPlaying: NowPlaying) -> NSImage? {
        let key = "\(kind.rawValue)-\(nowPlaying.artwork.id)-" + nowPlaying.recentTracks.map { $0.artwork?.id.uuidString ?? $0.id }.joined()
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content:
            SceneCanvas(kind: kind, nowPlaying: nowPlaying, animate: false)
                .frame(width: 320, height: 200)
        )
        renderer.scale = 1.5
        guard let image = renderer.nsImage else { return nil }
        if cache.count > 24 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

// MARK: - Permission

private struct PermissionBanner: View {
    let source: PlayerSource

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("Vinyl can’t see \(source.displayName)")
                    .font(.system(size: 12, weight: .semibold))
                Text("Allow Vinyl under Privacy & Security › Automation so it can read what’s playing.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

// MARK: - Recently played

private struct RecentCover: View {
    let item: RecentTrack
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            CoverThumb(art: item.artwork, size: 56, showPlay: hovering)
                .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 5 : 2, y: 1)
                .scaleEffect(hovering ? 1.05 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help([item.track.title, item.track.artist].filter { !$0.isEmpty }.joined(separator: " — "))
    }
}
