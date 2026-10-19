import AppKit
import Observation
import os

let historyLog = Logger(subsystem: "app.vinyl.desktop", category: "history")

enum PlayerSource: String, Codable, CaseIterable {
    case spotify, music
    /// Whatever app owns the system Now Playing session (browsers, YouTube Music, …).
    case system

    /// Players Vinyl can talk to directly over AppleScript.
    static let scriptable: [PlayerSource] = [.spotify, .music]

    var bundleID: String {
        switch self {
        case .spotify: "com.spotify.client"
        case .music: "com.apple.Music"
        case .system: ""
        }
    }

    var displayName: String {
        switch self {
        case .spotify: "Spotify"
        case .music: "Apple Music"
        case .system: "Now Playing"
        }
    }

    /// Posted by the player whenever playback state or track changes.
    var notificationName: Notification.Name {
        switch self {
        case .spotify: Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .music: Notification.Name("com.apple.Music.playerInfo")
        case .system: Notification.Name("app.vinyl.unused")
        }
    }
}

enum PlayState: String { case playing, paused, stopped }

struct Track: Equatable, Codable {
    var id: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var source: PlayerSource
    var artworkURL: String?
    /// Name and bundle ID of the app actually playing, for system Now Playing tracks.
    var appName: String?
    var bundleID: String?

    var key: String { "\(source.rawValue):\(id)" }
    var albumKey: String { "\(source.rawValue):\(artist.lowercased())|\(album.lowercased())" }

    var sourceName: String {
        guard let appName, !appName.isEmpty else { return source.displayName }
        return appName.replacingOccurrences(of: "Google ", with: "")
    }
}

struct PlayerSnapshot {
    var source: PlayerSource
    var state: PlayState
    var track: Track?
    var position: Double
}

// MARK: - AppleScript bridge to one player

@MainActor
final class ScriptPlayer {
    let source: PlayerSource
    let target: AppleScriptTarget

    /// Called after the user answers the Automation prompt.
    var onPermissionResolved: (() -> Void)? {
        get { target.onPermissionResolved }
        set { target.onPermissionResolved = newValue }
    }

    init(source: PlayerSource) {
        self.source = source
        self.target = AppleScriptTarget(bundleID: source.bundleID)
    }

    var isRunning: Bool { target.isRunning }

    private func run(_ body: String) throws -> NSAppleEventDescriptor {
        try target.run(body)
    }

    /// Builds `try … end try` guarded reads so one missing property (podcasts, ads,
    /// radio streams) never sinks the whole query.
    private static func guardedReads(_ fields: [(String, String, String)]) -> String {
        fields.map { name, expr, fallback in
            "set \(name) to \(fallback)\ntry\nset \(name) to (\(expr))\nend try"
        }.joined(separator: "\n")
    }

    private var stateScript: String {
        switch source {
        case .spotify:
            return """
            set pstate to player state as string
            if pstate is "stopped" then return {pstate}
            set t to current track
            \(Self.guardedReads([
                ("tid", "id of t as string", "\"\""),
                ("tname", "name of t as string", "\"\""),
                ("tartist", "artist of t as string", "\"\""),
                ("talbum", "album of t as string", "\"\""),
                ("tdur", "(duration of t) / 1000", "0"),
                ("tpos", "player position", "0"),
                ("tart", "artwork url of t as string", "\"\""),
            ]))
            return {pstate, tid, tname, tartist, talbum, tdur, tpos, tart}
            """
        case .music, .system:
            return """
            set pstate to player state as string
            if pstate is "stopped" then return {pstate}
            \(Self.guardedReads([
                ("tid", "persistent ID of current track as string", "\"\""),
                ("tname", "name of current track as string", "\"\""),
                ("tartist", "artist of current track as string", "\"\""),
                ("talbum", "album of current track as string", "\"\""),
                ("tdur", "duration of current track", "0"),
                ("tpos", "player position", "0"),
            ]))
            if tname is "" then
                try
                    set tname to current stream title as string
                end try
            end if
            return {pstate, tid, tname, tartist, talbum, tdur, tpos, ""}
            """
        }
    }

    func snapshot() throws -> PlayerSnapshot {
        let result = try run(stateScript)
        func string(_ i: Int) -> String { result.atIndex(i)?.stringValue ?? "" }
        func number(_ i: Int) -> Double { result.atIndex(i)?.doubleValue ?? 0 }

        let state = PlayState(rawValue: string(1)) ?? .stopped
        guard state != .stopped, result.numberOfItems >= 8 else {
            return PlayerSnapshot(source: source, state: .stopped, track: nil, position: 0)
        }
        let title = string(3)
        let artist = string(4)
        let album = string(5)
        var id = string(2)
        if id.isEmpty { id = "\(title)|\(artist)|\(album)" }
        let art = string(8)
        let track = Track(
            id: id, title: title, artist: artist, album: album,
            duration: max(0, number(6)), source: source,
            artworkURL: art.isEmpty ? nil : art
        )
        return PlayerSnapshot(source: source, state: state, track: title.isEmpty && artist.isEmpty ? nil : track, position: max(0, number(7)))
    }

    /// Apple Music hands over artwork bytes directly; Spotify gives a URL instead.
    func artworkData() -> Data? {
        guard source == .music else { return nil }
        let body = """
        try
            return raw data of artwork 1 of current track
        end try
        try
            return data of artwork 1 of current track
        end try
        return ""
        """
        guard let result = try? run(body), result.descriptorType != typeUnicodeText else { return nil }
        let data = result.data
        return data.isEmpty ? nil : data
    }

    func send(_ command: String) {
        _ = try? run(command)
    }
}

// MARK: - Now playing model

@Observable
@MainActor
final class NowPlaying {
    private(set) var track: Track?
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var positionDate = Date()
    private(set) var artwork: Artwork = .placeholder
    /// Most recent first, including the current track.
    private(set) var history: [RecentTrack] = []
    private(set) var permissionNeeded: PlayerSource?
    private(set) var activeSource: PlayerSource?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private(set) var players: [PlayerSource: ScriptPlayer] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastPlayingSource: PlayerSource?
    @ObservationIgnored private var artTask: Task<Void, Never>?
    @ObservationIgnored private var artworkAlbumKey: String?
    /// Track whose artwork came straight from the system Now Playing session.
    @ObservationIgnored private var systemArtworkTrackKey: String?
    /// Track whose artwork is a high-resolution cover found in the iTunes catalog.
    @ObservationIgnored private var catalogArtworkTrackKey: String?
    @ObservationIgnored private var sessionHasArtwork = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var playURLAttempts: [String: Date] = [:]
    /// Which artwork has already been written for each history file.
    @ObservationIgnored private var writtenHistoryArt: [String: UUID] = [:]
    @ObservationIgnored private let bridge = SystemNowPlayingBridge()

    init(settings: AppSettings, restore: Bool = true) {
        self.settings = settings
        for source in PlayerSource.scriptable { players[source] = ScriptPlayer(source: source) }
        if restore { restoreState() }
    }

    /// "Any App" reads the system Now Playing session; AppleScript is the fallback.
    private var usesSystemSession: Bool {
        settings.source == .automatic && !bridge.isUnavailable
    }

    // MARK: Derived values

    /// The last five songs before the one on the turntable.
    var recentTracks: [RecentTrack] {
        Array(history.filter { $0.id != track?.key }.prefix(5))
    }

    /// Cover of the song played before this one.
    var previousArtwork: Artwork? { recentTracks.first?.artwork }

    func currentPosition(at date: Date) -> Double {
        guard let track else { return 0 }
        let pos = isPlaying ? position + date.timeIntervalSince(positionDate) : position
        return track.duration > 0 ? min(max(pos, 0), track.duration) : max(pos, 0)
    }

    func progress(at date: Date) -> Double {
        guard let track, track.duration > 0 else { return 0 }
        return clamp01(currentPosition(at: date) / track.duration)
    }

    // MARK: Lifecycle

    func start() {
        settings.onSourceChange = { [weak self] in self?.sourceChanged() }
        for player in players.values {
            player.onPermissionResolved = { [weak self] in self?.refresh() }
        }
        bridge.onUpdate = { [weak self] update in self?.handle(update) }
        bridge.onUnavailable = { [weak self] in self?.refresh() }
        if settings.source == .automatic { bridge.start() }

        let distributed = DistributedNotificationCenter.default()
        for source in PlayerSource.scriptable {
            observers.append(distributed.addObserver(forName: source.notificationName, object: nil, queue: .main) { [weak self] note in
                let state = (note.userInfo?["Player State"] as? String)?.lowercased()
                MainActor.assumeIsolated {
                    if state == "playing" { self?.lastPlayingSource = source }
                    self?.refresh()
                }
            })
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { self?.refresh() } }
                }
            })
        }

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        bridge.stop()
    }

    private func sourceChanged() {
        if settings.source == .automatic {
            bridge.start()
        } else {
            bridge.stop()
        }
        refresh()
    }

    // MARK: System Now Playing

    private func handle(_ update: SystemNowPlayingBridge.Update) {
        guard usesSystemSession else { return }
        if permissionNeeded != nil { permissionNeeded = nil }
        guard update.active, !(update.title.isEmpty && update.artist.isEmpty) else {
            apply(nil)
            return
        }
        let title = Self.cleanTitle(update.title)
        let id = [update.bundleID ?? "", title, update.artist, update.album].joined(separator: "|")
        let track = Track(
            id: id, title: title, artist: update.artist, album: update.album,
            duration: max(0, update.duration), source: .system, appName: update.appName, bundleID: update.bundleID
        )
        sessionHasArtwork = update.hasArtwork
        apply(PlayerSnapshot(source: .system, state: update.playing ? .playing : .paused, track: track, position: max(0, update.elapsed)))
        if let data = update.artwork, let image = NSImage(data: data) {
            useSessionArtwork(image, for: track)
        }
        retryPlayURLIfMissing()
    }

    /// Keeps trying to find a replay link for the current song (the tab may not have
    /// updated yet, or Automation access was granted after it started).
    private func retryPlayURLIfMissing() {
        guard let track, let item = history.first(where: { $0.id == track.key }), item.playURL == nil else { return }
        if let last = playURLAttempts[track.key], Date().timeIntervalSince(last) < 10 { return }
        playURLAttempts[track.key] = Date()
        resolvePlayURL(for: track)
    }

    /// Browsers sometimes publish the tab title ("Song | YouTube Music") instead of the song.
    private static func cleanTitle(_ title: String) -> String {
        var result = title
        for suffix in [" | YouTube Music", " - YouTube Music", " - YouTube", " | YouTube"] where result.hasSuffix(suffix) {
            result.removeLast(suffix.count)
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func useSessionArtwork(_ image: NSImage, for track: Track) {
        // Never trade a sharp catalog cover for the session's thumbnail of the same track.
        guard catalogArtworkTrackKey != track.key else { return }
        systemArtworkTrackKey = track.key
        setArtwork(Artwork(image: image), albumKey: track.albumKey)
    }

    /// Browsers only hand over small thumbnails (YouTube Music: 120px), sometimes late or
    /// not at all. Give the session a moment, then look for a sharp cover in the catalog.
    private func loadSystemArtwork(for track: Track) {
        let key = track.key
        artTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.track?.key == key else { return }
            let haveSessionArt = self.systemArtworkTrackKey == key
                || (self.sessionHasArtwork && !self.artwork.isPlaceholder)
            if haveSessionArt && self.artwork.pixelWidth >= 500 { return }

            let data = await Self.searchITunes(artist: track.artist, album: track.album, title: track.title)
            guard !Task.isCancelled, self.track?.key == key else { return }
            if let data, let image = NSImage(data: data) {
                self.catalogArtworkTrackKey = key
                self.setArtwork(Artwork(image: image), albumKey: track.albumKey)
            } else if !haveSessionArt && !self.sessionHasArtwork {
                self.setArtwork(.placeholder, albumKey: nil)
            }
        }
    }

    // MARK: Polling

    func refresh() {
        if usesSystemSession {
            if permissionNeeded != nil { permissionNeeded = nil }
            return
        }
        var snapshots: [PlayerSnapshot] = []
        var denied: PlayerSource?
        for source in settings.source.sources {
            guard let player = players[source], player.isRunning else { continue }
            do {
                snapshots.append(try player.snapshot())
            } catch ScriptError.notAuthorized {
                denied = source
            } catch {}
        }
        if permissionNeeded != denied { permissionNeeded = denied }

        let playing = snapshots.filter { $0.state == .playing && $0.track != nil }
        let paused = snapshots.filter { $0.state == .paused && $0.track != nil }
        let chosen = playing.first { $0.source == lastPlayingSource }
            ?? playing.first
            ?? paused.first { $0.source == activeSource }
            ?? paused.first
        apply(chosen)
    }

    private func apply(_ chosen: PlayerSnapshot?) {
        let now = Date()
        guard let chosen, let newTrack = chosen.track else {
            // Player quit or stopped: keep the last record on the platter, just stop it.
            if isPlaying {
                position = currentPosition(at: now)
                positionDate = now
                isPlaying = false
            }
            return
        }

        let nowPlaying = chosen.state == .playing
        if nowPlaying { lastPlayingSource = chosen.source }
        if activeSource != chosen.source { activeSource = chosen.source }

        let trackChanged = track?.key != newTrack.key
        let stateChanged = isPlaying != nowPlaying
        let drift = abs(currentPosition(at: now) - chosen.position)
        if trackChanged || stateChanged || drift > 1.25 {
            position = chosen.position
            positionDate = now
        }
        if stateChanged { isPlaying = nowPlaying }

        if trackChanged {
            track = newTrack
            // Consecutive tracks from the same album keep the art already on the desk.
            // (System sessions always re-check: videos from one channel share an "album".)
            if newTrack.source == .system || newTrack.albumKey != artworkAlbumKey || artwork.isPlaceholder {
                loadArtwork(for: newTrack)
            }
            recordInHistory(newTrack)
            persist()
        } else if track != newTrack {
            let artArrived = track?.artworkURL == nil && newTrack.artworkURL != nil
            track = newTrack
            if artArrived && artwork.isPlaceholder { loadArtwork(for: newTrack) }
        }
    }

    // MARK: Transport

    private var controllablePlayer: ScriptPlayer? {
        if let activeSource, let p = players[activeSource], p.isRunning { return p }
        return settings.source.sources.compactMap { players[$0] }.first { $0.isRunning }
    }

    func playPause() { command("playpause", .togglePlayPause) }
    func nextTrack() { command("next track", .nextTrack) }
    func previousTrack() { command("previous track", .previousTrack) }

    private func command(_ verb: String, _ systemCommand: SystemNowPlayingBridge.Command) {
        if usesSystemSession {
            bridge.send(systemCommand)
            return
        }
        guard let player = controllablePlayer else { return }
        player.send(verb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { MainActor.assumeIsolated { self.refresh() } }
    }

    // MARK: Artwork

    private func loadArtwork(for track: Track) {
        artTask?.cancel()
        if track.source == .system {
            loadSystemArtwork(for: track)
            return
        }
        let key = track.key
        let musicData = track.source == .music ? players[.music]?.artworkData() : nil
        artTask = Task { [weak self] in
            var image = musicData.flatMap(NSImage.init(data:))
            if image == nil, let s = track.artworkURL, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                image = await Self.download(url).flatMap(NSImage.init(data:))
            }
            if image == nil {
                image = await Self.searchITunes(artist: track.artist, album: track.album, title: track.title).flatMap(NSImage.init(data:))
            }
            guard !Task.isCancelled, let self, self.track?.key == key else { return }
            if let image {
                self.setArtwork(Artwork(image: image), albumKey: track.albumKey)
            } else if self.artworkAlbumKey != track.albumKey {
                self.setArtwork(.placeholder, albumKey: nil)
            }
        }
    }

    private func setArtwork(_ art: Artwork, albumKey: String?) {
        guard art.id != artwork.id else { return }
        artwork = art
        artworkAlbumKey = albumKey
        if !art.isPlaceholder, let key = track?.key, let index = history.firstIndex(where: { $0.id == key }) {
            history[index].artwork = art
        }
        persist()
    }

    // MARK: History

    private func recordInHistory(_ track: Track) {
        // Something that was "playing" for under five seconds was a skip or a browser
        // metadata flicker between songs (tab titles, half-filled artists): not a record.
        if let first = history.first, first.id != track.key, Date().timeIntervalSince(first.playedAt) < 5,
           first.track.bundleID == track.bundleID {
            history.removeFirst()
        }
        history.removeAll { $0.id == track.key || ($0.track.title == track.title && $0.track.bundleID == track.bundleID) }
        // Same album as what's on the desk: the cover is already right.
        let art = track.albumKey == artworkAlbumKey && !artwork.isPlaceholder ? artwork : nil
        history.insert(RecentTrack(track: track, artwork: art, playURL: directPlayURL(for: track), playedAt: Date()), at: 0)
        if history.count > 6 { history.removeLast(history.count - 6) }
        if history[0].playURL == nil { resolvePlayURL(for: track) }
    }

    /// Players that identify tracks themselves already hand over a replayable ID.
    private func directPlayURL(for track: Track) -> String? {
        switch track.source {
        case .spotify: track.id.hasPrefix("spotify:") ? track.id : nil
        case .music: track.id.isEmpty || track.id.contains("|") ? nil : "music-pid:\(track.id)"
        case .system: nil
        }
    }

    /// Asks the app that's playing for a link back to this exact song: the YouTube tab's
    /// watch URL, or the Spotify / Apple Music track ID.
    private func resolvePlayURL(for track: Track) {
        let key = track.key
        // Give the browser a moment to update the tab's URL for the new song.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard self.track?.key == key, let index = self.history.firstIndex(where: { $0.id == key }),
                      self.history[index].playURL == nil else { return }
                var link: String?
                switch track.bundleID {
                case let id where BrowserPlayback.isBrowser(id):
                    link = BrowserPlayback.mediaTabURL(in: id!, matching: track.title)
                case PlayerSource.spotify.bundleID?:
                    link = (try? self.players[.spotify]?.snapshot())?.track.flatMap { self.directPlayURL(for: $0) }
                case PlayerSource.music.bundleID?:
                    link = (try? self.players[.music]?.snapshot())?.track.flatMap { self.directPlayURL(for: $0) }
                default:
                    break
                }
                // Another song already owns this link: the tab hadn't moved on yet, try again later.
                guard let link, !self.history.contains(where: { $0.id != key && $0.playURL == link }) else { return }
                self.history[index].playURL = link
                self.persist()
            }
        }
    }


    nonisolated private static func download(_ url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Finds a high-resolution cover in the iTunes catalog, for players that give none or
    /// only a thumbnail. Results must match the artist so a YouTube video never gets a
    /// random album's cover.
    nonisolated private static func searchITunes(artist: String, album: String, title: String) async -> Data? {
        func normalized(_ s: String) -> String {
            s.lowercased()
                .replacingOccurrences(of: " - topic", with: "")
                .replacingOccurrences(of: "vevo", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        // Video titles carry noise: "Artist - Song (Official Audio) [4K] | Label".
        var song = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        var artist = artist
        let parts = song.components(separatedBy: CharacterSet(charactersIn: "-–|"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parts.count > 1 {
            if artist.isEmpty { artist = parts[0] }
            let artistKey = normalized(artist)
            song = parts.first { !normalized($0).contains(artistKey) && !artistKey.contains(normalized($0)) } ?? parts[0]
        }

        let wanted = normalized(artist)
        guard !wanted.isEmpty else { return nil }

        var attempts: [(term: String, entity: String)] = []
        if !album.isEmpty { attempts.append(("\(artist) \(album)", "album")) }
        if !song.isEmpty { attempts.append(("\(artist) \(song)", "song")) }

        for attempt in attempts {
            guard var components = URLComponents(string: "https://itunes.apple.com/search") else { continue }
            components.queryItems = [
                URLQueryItem(name: "term", value: attempt.term),
                URLQueryItem(name: "entity", value: attempt.entity),
                URLQueryItem(name: "limit", value: "5"),
            ]
            guard let url = components.url,
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]] else { continue }
            let match = results.first { result in
                let found = normalized(result["artistName"] as? String ?? "")
                return !found.isEmpty && (found.contains(wanted) || wanted.contains(found))
            }
            if let small = match?["artworkUrl100"] as? String,
               let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "1000x1000bb")),
               let image = await download(big) {
                return image
            }
        }
        return nil
    }

    // MARK: Persistence (so the desk isn't empty after a relaunch or when the player quits)

    private struct Saved: Codable {
        var track: Track?
        var position: Double
        var albumKey: String?
    }

    private static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Vinyl", isDirectory: true)
    }

    private func persist() {
        let dir = Self.supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let saved = Saved(track: track, position: currentPosition(at: Date()), albumKey: artworkAlbumKey)
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: dir.appendingPathComponent("state.json"), options: .atomic)
        }
        if !artwork.isPlaceholder, let data = artwork.jpegData() {
            try? data.write(to: dir.appendingPathComponent("current.jpg"), options: .atomic)
        }
        persistHistory(in: dir)
    }

    private func persistHistory(in dir: URL) {
        let artDir = dir.appendingPathComponent("History", isDirectory: true)
        try? FileManager.default.createDirectory(at: artDir, withIntermediateDirectories: true)
        let saved = history.map { SavedRecentTrack(track: $0.track, playURL: $0.playURL, playedAt: $0.playedAt) }
        if let data = try? JSONEncoder().encode(saved) {
            try? data.write(to: dir.appendingPathComponent("history.json"), options: .atomic)
        }
        var keep: Set<String> = []
        for item in history {
            guard let art = item.artwork else { continue }
            let name = item.artworkFileName
            keep.insert(name)
            if writtenHistoryArt[name] != art.id, let data = art.jpegData() {
                try? data.write(to: artDir.appendingPathComponent(name), options: .atomic)
                writtenHistoryArt[name] = art.id
            }
        }
        for file in (try? FileManager.default.contentsOfDirectory(atPath: artDir.path)) ?? [] where !keep.contains(file) {
            try? FileManager.default.removeItem(at: artDir.appendingPathComponent(file))
            writtenHistoryArt[file] = nil
        }
    }

    private func restoreState() {
        let dir = Self.supportDirectory
        if let data = try? Data(contentsOf: dir.appendingPathComponent("state.json")),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            track = saved.track
            position = saved.position
            artworkAlbumKey = saved.albumKey
        }
        if let image = NSImage(contentsOf: dir.appendingPathComponent("current.jpg")) {
            artwork = Artwork(image: image)
        } else {
            artworkAlbumKey = nil
        }
        if let data = try? Data(contentsOf: dir.appendingPathComponent("history.json")),
           let saved = try? JSONDecoder().decode([SavedRecentTrack].self, from: data) {
            let artDir = dir.appendingPathComponent("History", isDirectory: true)
            history = saved.map { entry in
                var item = RecentTrack(track: entry.track, artwork: nil, playURL: entry.playURL, playedAt: entry.playedAt)
                let file = artDir.appendingPathComponent(item.artworkFileName)
                if let image = NSImage(contentsOf: file) {
                    let art = item.track.key == track?.key && !artwork.isPlaceholder ? artwork : Artwork(image: image)
                    item.artwork = art
                    writtenHistoryArt[item.artworkFileName] = art.id
                }
                return item
            }
        }
        // The record left on the platter becomes "previous" once something else plays.
        if let track, !history.contains(where: { $0.id == track.key }) {
            history.insert(RecentTrack(track: track, artwork: artwork.isPlaceholder ? nil : artwork,
                                       playURL: directPlayURL(for: track), playedAt: Date().addingTimeInterval(-60)), at: 0)
        }
    }

    // MARK: Previews / snapshots

    static func preview(settings: AppSettings, art: NSImage?, recent: [NSImage], playing: Bool) -> NowPlaying {
        let model = NowPlaying(settings: settings, restore: false)
        if let art { model.artwork = Artwork(image: art) }
        model.track = Track(id: "preview", title: "Golden Hour", artist: "Saffron Lane", album: "Long Summer", duration: 214, source: .system, appName: "YouTube Music")
        let names = [("Night Swim", "Paper Moons", "Spotify"), ("Velvet Static", "The Low Hums", "YouTube Music"),
                     ("Tangerine", "Oda Rivers", "Apple Music"), ("Slow Lights", "Kinfolk Radio", "Chrome"),
                     ("Afterglow", "Mira Sol", "YouTube Music")]
        model.history = recent.enumerated().map { index, image in
            let name = names[index % names.count]
            return RecentTrack(
                track: Track(id: "recent-\(index)", title: name.0, artist: name.1,
                             album: "", duration: 200, source: .system, appName: name.2),
                artwork: Artwork(image: image), playURL: nil, playedAt: Date().addingTimeInterval(Double(-240 * (index + 1))))
        }
        model.isPlaying = playing
        model.position = 70
        model.positionDate = Date()
        return model
    }
}
