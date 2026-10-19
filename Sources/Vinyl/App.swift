import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            MainActor.assumeIsolated { IconRenderer.render(to: URL(fileURLWithPath: args[i + 1])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--gif") {
            MainActor.assumeIsolated { GIFRenderer.run(Array(args[(i + 1)...])) }
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot") {
            MainActor.assumeIsolated { Snapshotter.run(Array(args[(i + 1)...])) }
            exit(0)
        }
        VinylApp.main()
    }
}

@MainActor
final class AppState {
    static let shared = AppState()

    let settings = AppSettings()
    let nowPlaying: NowPlaying
    let desktop: DesktopController

    private init() {
        nowPlaying = NowPlaying(settings: settings)
        desktop = DesktopController(nowPlaying: nowPlaying, settings: settings)
    }

    func start() {
        nowPlaying.start()
        desktop.start()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.nowPlaying.stop() }
    }
}

struct VinylApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(nowPlaying: AppState.shared.nowPlaying, settings: AppState.shared.settings)
        } label: {
            MenuBarLabel(nowPlaying: AppState.shared.nowPlaying)
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    let nowPlaying: NowPlaying

    var body: some View {
        Image(systemName: nowPlaying.isPlaying ? "record.circle.fill" : "record.circle")
    }
}
