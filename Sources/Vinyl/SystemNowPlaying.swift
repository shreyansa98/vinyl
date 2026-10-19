import AppKit

/// Reads the system-wide Now Playing session (the one shown in Control Center), so any
/// app that publishes media info works: YouTube Music or YouTube in Chrome/Safari/Arc,
/// Spotify, Apple Music, Tidal, podcasts, VLC…
///
/// macOS 15.4+ only answers MediaRemote queries from Apple-signed processes, so the
/// bundled helper library runs inside /usr/bin/perl and streams JSON lines back.
@MainActor
final class SystemNowPlayingBridge {
    struct Update {
        var active: Bool
        var playing: Bool
        var title: String
        var artist: String
        var album: String
        var duration: Double
        var elapsed: Double
        var bundleID: String?
        var appName: String?
        var artwork: Data?
        var hasArtwork: Bool
    }

    enum Command: Int {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    var onUpdate: ((Update) -> Void)?
    /// Called when the helper stops working for good, so callers can fall back.
    var onUnavailable: (() -> Void)?

    /// True once the helper has delivered a valid message.
    private(set) var isHealthy = false
    private(set) var isUnavailable = false

    private var process: Process?
    private var stdinPipe: Pipe?
    private var buffer = Data()
    private var failures = 0

    private var libraryURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("libVinylNowPlaying.dylib")
    }

    private var scriptURL: URL? {
        Bundle.main.url(forResource: "run-adapter", withExtension: "pl")
    }

    private var helperFilesExist: Bool {
        guard let libraryURL, let scriptURL else { return false }
        return FileManager.default.fileExists(atPath: libraryURL.path) && FileManager.default.fileExists(atPath: scriptURL.path)
    }

    func start() {
        guard process == nil, !isUnavailable else { return }
        guard helperFilesExist, let libraryURL, let scriptURL else {
            markUnavailable()
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, libraryURL.path, "vinyl_stream"]
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didTerminate() } }
        }

        do {
            try process.run()
            self.process = process
            self.stdinPipe = input
        } catch {
            didTerminate()
        }
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    func send(_ command: Command) {
        guard helperFilesExist, let libraryURL, let scriptURL else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [scriptURL.path, libraryURL.path, "vinyl_send"]
        process.environment = ["VINYL_COMMAND": String(command.rawValue)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private func didTerminate() {
        process = nil
        stdinPipe = nil
        buffer.removeAll()
        isHealthy = false
        failures += 1
        guard failures < 6 else {
            markUnavailable()
            return
        }
        let delay = Double(failures) * 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.start() } }
    }

    private func markUnavailable() {
        isHealthy = false
        isUnavailable = true
        onUnavailable?()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if json["error"] != nil {
                stop()
                markUnavailable()
                return
            }
            isHealthy = true
            failures = 0
            onUpdate?(Self.parse(json))
        }
    }

    private static func parse(_ json: [String: Any]) -> Update {
        func string(_ key: String) -> String { (json[key] as? String) ?? "" }
        func number(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
        return Update(
            active: (json["active"] as? NSNumber)?.boolValue ?? false,
            playing: (json["playing"] as? NSNumber)?.boolValue ?? false,
            title: string("title"),
            artist: string("artist"),
            album: string("album"),
            duration: number("duration"),
            elapsed: number("elapsed"),
            bundleID: json["bundleID"] as? String,
            appName: json["appName"] as? String,
            artwork: (json["artwork"] as? String).flatMap { Data(base64Encoded: $0) },
            hasArtwork: (json["hasArtwork"] as? NSNumber)?.boolValue ?? false
        )
    }
}
