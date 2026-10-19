import Foundation
import Observation
import ServiceManagement

enum SceneKind: String, CaseIterable, Identifiable, Codable {
    case listeningRoom, afterHours, turntable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .listeningRoom: "Listening Room"
        case .afterHours: "After Hours"
        case .turntable: "Turntable"
        }
    }
}

enum SourcePreference: String, CaseIterable, Identifiable {
    case automatic, spotify, music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: "Any App"
        case .spotify: "Spotify"
        case .music: "Apple Music"
        }
    }

    var sources: [PlayerSource] {
        switch self {
        case .automatic: [.spotify, .music]
        case .spotify: [.spotify]
        case .music: [.music]
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onSourceChange: (() -> Void)?

    var scene: SceneKind {
        didSet { defaults.set(scene.rawValue, forKey: "scene") }
    }

    var wallpaperEnabled: Bool {
        didSet { defaults.set(wallpaperEnabled, forKey: "wallpaperEnabled") }
    }

    var hideWhenPaused: Bool {
        didSet { defaults.set(hideWhenPaused, forKey: "hideWhenPaused") }
    }

    var source: SourcePreference {
        didSet {
            defaults.set(source.rawValue, forKey: "source")
            onSourceChange?()
        }
    }

    private(set) var launchAtLogin: Bool
    private(set) var loginItemNote: String?

    init() {
        scene = SceneKind(rawValue: defaults.string(forKey: "scene") ?? "") ?? .listeningRoom
        wallpaperEnabled = defaults.object(forKey: "wallpaperEnabled") as? Bool ?? true
        hideWhenPaused = defaults.object(forKey: "hideWhenPaused") as? Bool ?? false
        source = SourcePreference(rawValue: defaults.string(forKey: "source") ?? "") ?? .automatic
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemNote = nil
        } catch {
            loginItemNote = "Couldn’t update login items: \(error.localizedDescription)"
        }
        refreshLoginItemStatus()
    }

    func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            loginItemNote = "Approve Vinyl in System Settings › General › Login Items."
        }
    }
}
