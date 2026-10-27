#!/bin/sh
# Makes the update for release v<version> on this Mac (the signing certificate and the update key live here)
# and attaches it to the GitHub release: the app zip and appcast.xml (the feed every installed Kagu reads),
# and Kagu.dmg for a first install.
# KAGU_DOWNLOADS=<url> writes both into dist/ with zip links under that url and uploads nothing (a local test).
set -eu
cd "$(dirname "$0")/.."
V="${1:?usage: scripts/release.sh <version>}"
KEY="${KAGU_UPDATE_KEY:-$HOME/.config/kagu/sparkle_private_key}"
TOOLS=vendor/sparkle/bin
BASE="${KAGU_DOWNLOADS:-https://github.com/us/kagu/releases/download/v$V}"

[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)" = "$V" ] || { echo "Info.plist is not at $V"; exit 1; }
if [ -z "${KAGU_DOWNLOADS:-}" ]; then
    CHANGES=$(git status --porcelain --untracked-files=no)  # its own line, so a failing git stops the script
    [ -z "$CHANGES" ] || { echo "the tree has uncommitted changes"; exit 1; }
    [ "$(git rev-parse HEAD)" = "$(git rev-parse "v$V^{commit}")" ] || { echo "HEAD is not the tag v$V"; exit 1; }
fi
[ -f "$KEY" ] || { echo "no update key at $KEY"; exit 1; }
if [ ! -x "$TOOLS/sign_update" ]; then
    mkdir -p vendor/sparkle
    gh release download 2.10.0 --repo sparkle-project/Sparkle --pattern "Sparkle-2.10.0.tar.xz" --dir vendor/sparkle --clobber
    tar -xf vendor/sparkle/Sparkle-2.10.0.tar.xz -C vendor/sparkle bin
    rm -f vendor/sparkle/Sparkle-2.10.0.tar.xz
fi

scripts/make-dmg.sh  # builds Kagu.app too
ZIP="dist/Kagu-$V.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Kagu.app "$ZIP"
SIGNATURE=$("$TOOLS/sign_update" --ed-key-file "$KEY" "$ZIP")
cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kagu</title>
    <item>
      <title>Kagu $V</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$V</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/us/kagu/releases/tag/v$V</sparkle:releaseNotesLink>
      <enclosure url="$BASE/Kagu-$V.zip" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
if [ -n "${KAGU_DOWNLOADS:-}" ]; then echo "wrote $ZIP and dist/appcast.xml for $BASE"; exit 0; fi
gh release upload "v$V" "$ZIP" dist/Kagu.dmg dist/appcast.xml --repo us/kagu --clobber
echo "released $V: $BASE/Kagu-$V.zip"
