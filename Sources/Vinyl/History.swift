import AppKit
import CryptoKit

/// A song that was on the turntable, plus what's needed to put it back on.
struct RecentTrack: Identifiable, Equatable {
    var track: Track
    var artwork: Artwork?
    /// How to play it again: a YouTube / YouTube Music link, `spotify:track:…`, or
    /// `music-pid:<persistent ID>` for the Apple Music library.
    var playURL: String?
    var playedAt: Date

    var id: String { track.key }

    static func == (lhs: RecentTrack, rhs: RecentTrack) -> Bool {
        lhs.id == rhs.id && lhs.artwork?.id == rhs.artwork?.id && lhs.playURL == rhs.playURL && lhs.playedAt == rhs.playedAt
    }

    /// Stable file name for the persisted cover.
    var artworkFileName: String {
        let digest = Insecure.SHA1.hash(data: Data(id.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}

/// Persisted form of the history list (artwork lives in separate JPEGs).
struct SavedRecentTrack: Codable {
    var track: Track
    var playURL: String?
    var playedAt: Date
}

// MARK: - Browsers

/// Finds and drives the browser tab a song is playing in, so a past YouTube / YouTube
/// Music track can be put back on in the same tab.
@MainActor
enum BrowserPlayback {
    static let chromium: [String] = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]
    static let safari: [String] = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return chromium.contains(bundleID) || safari.contains(bundleID)
    }

    private static var targets: [String: AppleScriptTarget] = [:]

    private static func target(_ bundleID: String) -> AppleScriptTarget {
        if let existing = targets[bundleID] { return existing }
        let made = AppleScriptTarget(bundleID: bundleID)
        targets[bundleID] = made
        return made
    }

    private static func titleProperty(_ bundleID: String) -> String {
        safari.contains(bundleID) ? "name" : "title"
    }

    /// The watch link of the tab that's playing `title`, e.g. `https://music.youtube.com/watch?v=…`.
    static func mediaTabURL(in bundleID: String, matching title: String) -> String? {
        let target = target(bundleID)
        guard target.isRunning else { return nil }
        let body = """
        set out to ""
        repeat with w in windows
            repeat with t in tabs of w
                set u to ""
                try
                    set u to URL of t as string
                end try
                if u contains "youtube.com/watch" then
                    set n to ""
                    try
                        set n to \(titleProperty(bundleID)) of t as string
                    end try
                    set out to out & u & (character id 9) & n & (character id 10)
                end if
            end repeat
        end repeat
        return out
        """
        let listing: String
        do {
            listing = try target.run(body).stringValue ?? ""
        } catch {
            historyLog.info("Tab lookup in \(bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        let tabs: [(url: String, title: String)] = listing.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let url = parts.first else { return nil }
            return (String(url), parts.count > 1 ? String(parts[1]) : "")
        }

        let wanted = title.lowercased()
        let chosen = tabs.first { !wanted.isEmpty && $0.title.lowercased().contains(wanted) }
            ?? only(tabs.filter { $0.url.contains("music.youtube.com/watch") })
            ?? only(tabs)
        return chosen.flatMap { cleanWatchURL($0.url) }
    }

    private static func only<T>(_ items: [T]) -> T? { items.count == 1 ? items[0] : nil }

    /// Keeps just the video and playlist, dropping timestamps and tracking parameters.
    private static func cleanWatchURL(_ string: String) -> String? {
        guard var components = URLComponents(string: string),
              let video = components.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        var items = [URLQueryItem(name: "v", value: video)]
        if let list = components.queryItems?.first(where: { $0.name == "list" })?.value {
            items.append(URLQueryItem(name: "list", value: list))
        }
        components.queryItems = items
        components.fragment = nil
        return components.url?.absoluteString
    }

    /// Loads `url` in an existing YouTube / YouTube Music tab (so it replaces what's
    /// playing instead of starting a second player), or opens it if there's none.
    static func play(_ url: URL, preferredBrowser: String?) {
        let host = url.host ?? ""
        let match = host.hasPrefix("music.") ? "music.youtube.com" : "www.youtube.com"
        let safeURL = url.absoluteString.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
        let body = """
        repeat with w in windows
            repeat with t in tabs of w
                set u to ""
                try
                    set u to URL of t as string
                end try
                if u contains "\(match)" then
                    set URL of t to "\(safeURL)"
                    return "ok"
                end if
            end repeat
        end repeat
        return "none"
        """
        var browsers = (chromium + safari).filter { target($0).isRunning }
        if let preferredBrowser, let index = browsers.firstIndex(of: preferredBrowser) {
            browsers.swapAt(0, index)
        }
        for browser in browsers {
            if (try? target(browser).run(body).stringValue) == "ok" { return }
        }
        open(url, in: preferredBrowser)
    }

    static func open(_ url: URL, in bundleID: String?) {
        if let bundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Playing a past track

extension NowPlaying {
    func play(_ item: RecentTrack) {
        let track = item.track
        if let link = item.playURL {
            if link.hasPrefix("spotify:"), let spotify = players[.spotify] {
                if (try? spotify.target.run("play track \"\(link)\"")) != nil {
                    refreshSoon()
                    return
                }
                if let url = URL(string: link) { NSWorkspace.shared.open(url) }
                return
            }
            if link.hasPrefix("music-pid:"), let music = players[.music] {
                let pid = link.dropFirst("music-pid:".count)
                if (try? music.target.run("play (first track of library playlist 1 whose persistent ID is \"\(pid)\")")) != nil {
                    refreshSoon()
                    return
                }
            }
            if link.hasPrefix("http"), let url = URL(string: link) {
                BrowserPlayback.play(url, preferredBrowser: track.bundleID)
                return
            }
        }
        searchAndPlay(track)
    }

    /// No direct link (e.g. the tab was closed before Vinyl saw it): search the service it came from.
    private func searchAndPlay(_ track: Track) {
        let query = [track.artist, track.title].filter { !$0.isEmpty }.joined(separator: " ")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let isSpotify = track.source == .spotify || track.bundleID == PlayerSource.spotify.bundleID
        let isMusic = track.source == .music || track.bundleID == PlayerSource.music.bundleID
        if isSpotify, let url = URL(string: "spotify:search:\(encoded)") {
            NSWorkspace.shared.open(url)
        } else if isMusic, let url = URL(string: "https://music.apple.com/search?term=\(encoded)") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "https://music.youtube.com/search?q=\(encoded)") {
            BrowserPlayback.open(url, in: BrowserPlayback.isBrowser(track.bundleID) ? track.bundleID : nil)
        }
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { MainActor.assumeIsolated { self.refresh() } }
    }
}
