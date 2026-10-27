# Kagu

One record button for your Mac. Kagu records your microphone and everything the Mac plays (Meet, Discord, a video) into one file, then writes a transcript on this Mac with **You** and **Them** kept apart. What you hear does not change.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshot-dark.png">
  <img src="docs/screenshot-light.png" alt="Kagu library with a transcribed recording">
</picture>

## Install

```sh
gh release download -R us/kagu -p Kagu.dmg -D /tmp --clobber && hdiutil attach -nobrowse -quiet /tmp/Kagu.dmg && ditto /Volumes/Kagu/Kagu.app /Applications/Kagu.app && hdiutil detach -quiet /Volumes/Kagu && open /Applications/Kagu.app
```

Needs macOS 15. Kagu is signed but not notarized: the first open asks once (System Settings, Privacy & Security, Open Anyway). Move it to Applications before that first open, so updates can replace it.

Build from source: `./build.sh`. Everything else: [docs/leaflet.md](docs/leaflet.md).

## Updates

Kagu checks for a new version every 6 hours, downloads it in the background and installs it once nothing is recording or transcribing and Kagu is not the app in front; quitting installs it too. Kagu > Check for Updates... checks now. Settings > General > Updates turns automatic installs off.

## Releases

Versions come from Conventional Commits: release-please keeps a release PR open on `main`; merging it tags `vX.Y.Z` and publishes the GitHub Release. Then, on the Mac that holds the signing certificate and the update key (`~/.config/kagu/sparkle_private_key`):

```sh
git checkout vX.Y.Z && scripts/release.sh X.Y.Z
```

It builds and signs Kagu, and uploads `Kagu-X.Y.Z.zip`, `Kagu.dmg` and `appcast.xml` to the release. Installed copies pick it up from `releases/latest/download/appcast.xml`.

## For agents

[skills/kagu/SKILL.md](skills/kagu/SKILL.md) tells a coding agent where recordings and transcripts are and how to make one.
