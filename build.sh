#!/bin/sh
# Builds and signs Kagu.app next to this script.
set -eu
cd "$(dirname "$0")"
IDENTITY="${IDENTITY:-Apple Development: Recep Saritekin (5TTV65YL4S)}"

[ -x vendor/whisper-cli ] || ./scripts/build-whisper.sh
swift build -c release
APP=Kagu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp .build/release/Recorder "$APP/Contents/MacOS/Recorder"
# KaguWatch, the launch agent that opens Kagu when a call starts (SMAppService finds the plist by name).
cp .build/release/KaguWatch "$APP/Contents/MacOS/KaguWatch"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cp Resources/LaunchAgents/local.recorder.watch.plist "$APP/Contents/Library/LaunchAgents/"
# Sparkle, the updater: ditto keeps the framework's symlinks. Not sandboxed, so its XPC services are not needed.
ditto "$(swift build -c release --show-bin-path)/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$APP/Contents/Frameworks/Sparkle.framework/XPCServices"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Recorder"
cp vendor/whisper-cli "$APP/Contents/MacOS/whisper-cli"
cp vendor/ggml-silero-v5.1.2.bin vendor/LICENSE-whisper.cpp "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
# The app icon: light, dark and tinted appearances from Resources/AppIcon.icon (scripts/make-icon.py makes it).
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
    --app-icon AppIcon --output-partial-info-plist .build/icon-partial.plist >/dev/null
# Nested code is signed first, inside out: signing the app does not sign it.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/whisper-cli"
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/KaguWatch"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign "$IDENTITY" -o runtime "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$IDENTITY" -o runtime "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$IDENTITY" -o runtime "$SPARKLE"
codesign --force --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "built $(pwd)/$APP"
