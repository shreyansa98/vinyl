# Contributing to Vinyl

Thanks for helping make Vinyl better. Bug fixes, new scenes, performance work, docs, translations: it's all welcome. 💿

## Ground rules

- **Fork the repo and open a pull request.** Nobody pushes to `main` directly; every change goes through review.
- **One idea per PR.** Small, focused PRs get reviewed and merged much faster.
- **Be kind.** This project follows the [Code of Conduct](CODE_OF_CONDUCT.md).
- **Bigger changes:** open an issue or discussion first, so we can agree on the approach before you spend a weekend on it.

## Setup (about 2 minutes)

Requirements: macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is optional.

```sh
git clone https://github.com/<you>/<your-fork>.git
cd <your-fork>
swift build                 # compile
./build.sh install          # build Vinyl.app, install to /Applications and launch it
```

Running from a terminal build? Note that the system-wide Now Playing helper only works from the bundled `.app` (`./build.sh`), not from `swift run`.

## Project layout

| Path | What lives there |
|---|---|
| `Sources/Vinyl/App.swift` | Entry point, menu bar app, command-line tools (`--snapshot`, `--gif`, `--render-icon`) |
| `Sources/Vinyl/Scenes.swift` | Scene composition and lighting. **Start here for a new scene.** |
| `Sources/Vinyl/Objects.swift` | Desk objects: wood, lamp, frame, album stand, record pile |
| `Sources/Vinyl/Turntable.swift` | Turntable geometry and projection, spinning record, tonearm motion |
| `Sources/Vinyl/NowPlaying.swift` | Player detection, progress, artwork pipeline, history |
| `Sources/Vinyl/SystemNowPlaying.swift`, `Helper/` | Bridge to the system Now Playing session (via `/usr/bin/perl`) |
| `Sources/Vinyl/History.swift`, `Recents.swift` | Recently played, replay, clickable record pile |
| `Sources/Vinyl/Desktop.swift` | Desktop-level windows, one per display |
| `Sources/Vinyl/MenuView.swift` | Menu bar window |
| `scripts/` | Demo cover generator, DMG packaging |

Scenes are laid out on a **1440×900 design stage** (`StageLayout`) that's scaled to fit each display, with walls and desk extending to fill the rest. Position things in stage coordinates and they'll land in the same place on every screen.

## Showing visual changes

Vinyl can render every scene to PNG without touching your desktop. Please attach before/after renders to any PR that changes how things look:

```sh
swift build
swift scripts/make-demo-covers.swift /tmp/covers
.build/debug/Vinyl --snapshot /tmp/vinyl-snaps /tmp/covers/golden-hour.jpg 1440 900 \
  /tmp/covers/night-swim.jpg /tmp/covers/velvet-static.jpg /tmp/covers/tangerine.jpg
open /tmp/vinyl-snaps
```

Use the demo covers (or your own artwork) in screenshots, never real album art: covers are copyrighted.

## Performance matters

Vinyl runs all day behind everything else. Before submitting:

- Check Activity Monitor: **~0% CPU when paused**, and single-digit % while playing.
- Anything that redraws every frame should be tiny. Static things belong in views that SwiftUI won't re-render (see `DeckBody`, `WoodGrain`, which are `Equatable`).
- Be careful re-assigning `@Observable` properties inside view updates; it can create render loops (see the comments in `DeckMotion`).

## Code style

- Match the surrounding code: SwiftUI, `@Observable`, small focused views.
- Comment the *why*, not the *what*.
- No new third-party dependencies without discussion. Vinyl is intentionally dependency-free.

## PR checklist

- [ ] `swift build` passes (CI checks this too)
- [ ] Tested in the real app with `./build.sh install`
- [ ] Before/after renders attached for visual changes
- [ ] No real album art, personal data or secrets in the diff
- [ ] README updated if behaviour or permissions changed

## Ideas to pick up

See the [Roadmap](README.md#roadmap) and issues labelled **good first issue** and **help wanted**. A new scene is a great first big contribution: copy `RoomScene`, rearrange the desk, change the light.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
