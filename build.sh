#!/bin/zsh
# Builds Vinyl.app.
#   ./build.sh             native build            -> build/Vinyl.app
#   ./build.sh install     native build, then copy to /Applications and launch
#   ./build.sh universal   Apple Silicon + Intel   -> build/Vinyl.app (used for releases)
set -euo pipefail
cd "${0:A:h}"
MODE="${1:-}"

if [[ "$MODE" == "universal" ]]; then
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  mkdir -p build
  lipo -create .build/arm64-apple-macosx/release/Vinyl .build/x86_64-apple-macosx/release/Vinyl -output build/Vinyl-bin
  TOOL=.build/arm64-apple-macosx/release/Vinyl
  [[ "$(uname -m)" == "x86_64" ]] && TOOL=.build/x86_64-apple-macosx/release/Vinyl
else
  swift build -c release
  mkdir -p build
  cp .build/release/Vinyl build/Vinyl-bin
  TOOL=.build/release/Vinyl
fi

APP=build/Vinyl.app
rm -rf "$APP" build/AppIcon.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
mv build/Vinyl-bin "$APP/Contents/MacOS/Vinyl"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Now Playing helper: loaded into /usr/bin/perl, see Helper/NowPlayingAdapter.m.
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 \
  -framework Foundation -framework AppKit \
  Helper/NowPlayingAdapter.m -o "$APP/Contents/Frameworks/libVinylNowPlaying.dylib"
cp Helper/run-adapter.pl "$APP/Contents/Resources/run-adapter.pl"
codesign --force --sign - "$APP/Contents/Frameworks/libVinylNowPlaying.dylib"

"$TOOL" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $PWD/$APP"

if [[ "$MODE" == "install" ]]; then
  pkill -x Vinyl 2>/dev/null && sleep 1 || true
  rm -rf /Applications/Vinyl.app
  cp -R "$APP" /Applications/Vinyl.app
  open /Applications/Vinyl.app
  echo "Installed to /Applications/Vinyl.app"
fi
