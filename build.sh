#!/bin/sh
# Builds and signs Kagu.app next to this script.
set -eu
cd "$(dirname "$0")"
IDENTITY="${IDENTITY:-Apple Development: Recep Saritekin (5TTV65YL4S)}"

[ -x vendor/whisper-cli ] || ./scripts/build-whisper.sh
swift build -c release
APP=Kagu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Recorder "$APP/Contents/MacOS/Recorder"
cp vendor/whisper-cli "$APP/Contents/MacOS/whisper-cli"
cp vendor/ggml-silero-v5.1.2.bin vendor/LICENSE-whisper.cpp "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# The app icon: light, dark and tinted appearances from Resources/AppIcon.icon (scripts/make-icon.py makes it).
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist .build/icon-partial.plist >/dev/null
# The helper is signed first: signing the app does not sign nested executables.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/whisper-cli"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "built $(pwd)/$APP"
