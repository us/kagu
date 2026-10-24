#!/bin/sh
# Builds Kagu.app and packs it into dist/Kagu.dmg with an Applications link, signed like the app.
set -eu
cd "$(dirname "$0")/.."
IDENTITY="${IDENTITY:-Apple Development: Recep Saritekin (5TTV65YL4S)}"
./build.sh
STAGE=.build/dmg
rm -rf "${STAGE:?}" && mkdir -p "$STAGE" dist
ditto Kagu.app "$STAGE/Kagu.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Kagu -srcfolder "$STAGE" -ov -format UDZO dist/Kagu.dmg >/dev/null
codesign --force --sign "$IDENTITY" dist/Kagu.dmg
echo "built $(pwd)/dist/Kagu.dmg"
