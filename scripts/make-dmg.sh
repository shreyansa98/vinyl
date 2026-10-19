#!/bin/zsh
# Packages a universal Vinyl.app into a drag-to-install disk image.
#   scripts/make-dmg.sh   -> build/Vinyl-<version>-beta.dmg
set -euo pipefail
cd "${0:A:h}/.."

./build.sh universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
STAGE=build/dmg
DMG="build/Vinyl-${VERSION}-beta.dmg"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R build/Vinyl.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
REPO_URL=$(git config --get remote.origin.url 2>/dev/null | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##')
cat > "$STAGE/Read Me First.txt" <<TXT
Vinyl (beta)

1. Drag Vinyl into the Applications folder.
2. Open Vinyl from Applications. It lives in the menu bar (look for the record icon).

macOS says Vinyl "cannot be opened" or "Apple could not verify" it?
This beta isn't notarized by Apple yet. To open it anyway:
  • Open System Settings › Privacy & Security, scroll down, and click "Open Anyway" next to Vinyl.
  • Or, in Terminal: xattr -dr com.apple.quarantine /Applications/Vinyl.app

Vinyl is open source: ${REPO_URL:-on GitHub}
TXT

hdiutil create -volname "Vinyl ${VERSION} Beta" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
shasum -a 256 "$DMG"
echo "Built $PWD/$DMG"
