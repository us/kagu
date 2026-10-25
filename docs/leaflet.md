# Kagu

Kagu. Rhynochetos jubatus. Sings in pairs.

Package leaflet: information for the user. Read all of it before the first recording.

## 1. What Kagu is and what it is used for

Kagu is a small Mac app with one record button. It records your microphone and every sound the Mac plays (Google Meet, Discord, a video in the browser) into one audio file, and makes a transcript on this Mac with **You** and **Them** kept apart. What you hear does not change: no driver, no extra device in your sound settings, no change to your output device or volume.

## 2. Before you record

- Kagu needs macOS 15 or newer.
- The first recording asks twice: Microphone, then System Audio Recording. Allow both. If the Mac audio stays silent while something plays, allow Kagu in System Settings, Privacy & Security, Screen & System Audio Recording.
- Kagu records everyone the Mac can hear. Laws about recording a call differ by place. Tell the people on the call before you record.

## 3. How to record

1. `./build.sh`, then open `Kagu.app`.
2. Press the red button (or New Recording, ⌘N). A live row at the top of the list shows the time and the level; press the button again (or Stop Recording, ⌘.) to stop. ⌘N never stops a recording. Pause is ⇧⌘P: nothing is written while paused, the mic stays open. While recording, a small dark Recording window shows the time, a moving waveform, Pause, Stop (⌘.) and a button back to the library.
3. Saving takes about 80 s per recorded hour on an M4 Pro. For a long recording the live row says how long saving should take on this Mac (the median of its last five saves) and says so if it is still saving past that.
4. The new recording is selected. Without a transcript it has one Transcribe button; the first time it downloads the speech model once. A transcript has Copy (speaker, time, text); click a time to play from there. Space plays and pauses (also Playback, ⌥Space). Export... saves the transcript as Markdown or text, or a copy of the audio.
5. File, Transcribe Audio File (⇧⌘T) makes a transcript of any audio file, next to it.

The menu bar item (on by default, Settings, General) has New Recording, Stop Recording, Show App, Transcribe Audio File, Settings and Quit, and at the foot what is on file: "On file: 43 entries, 61 h 24 min." While recording it reads "On the record 00:41:12." With it on, closing the windows keeps Kagu running.

## 4. Possible side effects

- With speakers, the echo of the other side on your mic drops about 20 dB once learned. The first ~5 s of a call keep more echo while it learns. Loud, distorted speakers, Bluetooth or AirPlay speakers (over 150 ms delay) and system audio that contains your own voice are not cancelled well. Headphones avoid all of it.
- FaceTime and other apps that use Apple's voice processing mute the mic for every other app while they run. Kagu warns "No sound from the mic". Meet in Chrome and Discord do not do this.
- If an app plays for a minute and Kagu hears nothing of it, it warns "No sound from the Mac yet": the System Audio Recording permission is missing.
- Everything the Mac plays is recorded, notification sounds included.
- With AirPods: if no call is using the AirPods mic, Kagu uses the built-in mic, so your headphones stay in high quality. If a call uses the AirPods mic, Kagu uses it too and stops (saving the file) when the call releases it. A sample rate change mid recording also stops and saves.
- When something goes wrong, the notice says what happened and, under it, where it was written down: "Condition report: line 1204 of Recorder.log." (`~/Library/Logs/Recorder.log`).

## 5. How to store your recordings

- **Folders.** The window has three columns, like Notes: folders and tags, the recordings in the chosen one, the recording. A folder is a real subfolder of `~/Music/Recordings` (the folder button at the top makes one). Drag a recording onto a folder, or right click, Move to. A move takes every part of the recording with it and keeps its accession number. Right click a folder to rename or delete it; deleting puts its recordings back in Recordings, and a folder that still holds other files is kept. New recordings land in Recordings.
- **Tags.** Tags are Finder tags: the plus under the title adds one, right click removes it. They show in Finder and Spotlight. Every tag in the library is a chip under the search field, with its count; click one to see only those recordings, click it again for all. A row lists all its tags.
- **Accession numbers.** Every recording is entered in a register as `<year>.<n>`, for example `2026.43`, oldest first. The number is written on the file itself (an extended attribute), so it stays through a rename. It is never given twice: a deleted recording leaves its number unused and counts as withdrawn. Search finds a recording by its number. The Details tab lists the number and the parts.
- **Search** (top of the list) finds titles, tags, accession numbers and words inside transcripts. The title on the right is editable and renames every file of the recording. A recording that still has its default name is shown as "Oct 21 at 5:07 PM".
- **Deleting.** Delete (or Move to Trash in the right-click menu and the ... menu) moves a recording to the Trash with its transcript and tracks.

## 6. Contents of the pack

Each recording is up to three files in `~/Music/Recordings`, numbered as parts of its entry:

```
~/Music/Recordings/
  Recording 2026-10-21 17.07.14.m4a          2026.43.1  the recording, stereo AAC
  Recording 2026-10-21 17.07.14.md           2026.43.2  its transcript
  .Recording 2026-10-21 17.07.14.tracks.m4a  2026.43.3  your mic and the Mac audio apart (hidden, about 45 MB an hour)
```

Elsewhere on this Mac: the speech models in `~/Library/Application Support/Recorder/Models`, the log in `~/Library/Logs/Recorder.log`, the tracks of an interrupted transcript in `~/Library/Caches/Recorder`. No recording or transcript is sent anywhere; the only download is the speech model, when you ask for it.

The app icon comes from the three logos in `design/logo/` (light, dark, monochrome): `uv run --with numpy --with pillow python scripts/make-icon.py` writes `Resources/AppIcon.icon`, which `build.sh` compiles with `actool` into the light, dark and tinted icon appearances.

## How it works

A private aggregate device holds the default mic (the clock) and a global Core Audio process tap (unmuted). Both arrive in one callback on one clock, so they stay in sync. While recording it writes a 3 channel CAF (mic, system left, system right) that survives a crash; at stop the speaker echo is removed from the mic (SpeexDSP echo canceller, the system audio is the reference), then the mic is mixed into both channels of a stereo AAC `.m4a`, scaled so it never clips. With headphones there is no echo path; that is detected and the mic is saved exactly as recorded. Saving takes about 80 s per recorded hour. A CAF left by a crash is converted the next time the app opens.

## Levels and interrupted transcripts

- When a recording is saved, a mic that is much quieter than the Mac audio is brought up to its level (at most 6 times, never turned down; with nobody else talking it goes to a normal speech level). A very low input volume in System Settings, Sound, Input is still worth raising, because boosting later also boosts the room noise. The log line `convert: ... mic gain` shows what was done.
- If the app is quit while it transcribes, the two tracks stay in `~/Library/Caches/Recorder`. The next normal launch transcribes them again and writes `Recording <date time>.md`. Every new recording also keeps a small hidden file next to it (`.<name>.tracks.m4a`, about 45 MB an hour) with your mic and the Mac audio apart, so a transcript made later still separates You and Them. Recordings made before that, and other audio files, have one "Speaker", because a mixed file cannot be split.

## Transcription

Optional. The Transcribe button works once a model is downloaded: in Settings, Transcription, pick a model and press Download (Large v3 is 3.1 GB and best, the turbo model is 574 MB and about twice as fast; both are checked against a SHA-256). New recordings are transcribed by themselves only when "Transcribe new recordings automatically" is on (off by default). Nothing is uploaded: a bundled copy of whisper.cpp (MIT) runs on this Mac, one job at a time, at low priority.

- With that switch on, after each recording the app writes `Recording <date time>.md` next to the `.m4a`. The mic and the Mac audio are transcribed as two separate tracks, so lines are labelled **You** and **Them** without any guessing. Several remote people all show as "Them".
- File, Transcribe Audio File... (⇧⌘T) turns any audio file into `<name>.transcript.md` (one "Speaker", since a mixed file cannot be split). An existing transcript is never replaced; the new one gets " 2" in its name.
- Language: "Detect automatically" or one of the listed languages. Turkish is better with the Large v3 model.
- Large v3 needs about 5 GB of memory while it runs; a 4 minute slice took 26 s on an M4 Pro. English fillers (um, uh) and repeated phrases are removed, and a "You" line of four or more words that only repeats what "Them" said at the same moment (speaker bleed from the speakers) is dropped. What was removed is counted at the foot of the transcript, under a rule: "Struck from the record: 41 fillers and 2 lines repeated from Them."

Build: `./build.sh` also builds the engine on first use (`scripts/build-whisper.sh`, needs cmake) into `vendor/`.

Test aids: `--library <folder>` (use another folder, for screenshots), `--pause <a> <b>` with `--record`, `--import`, `--details`, `--selftest`, `--play <m4a>`, `--select <file name>`, `--search <text>`, `--tag <file name> <tag>`, `--settings`, `--appearance light|dark`, `--model <file>`, `--download largeV3|turbo`, `--transcribe-raw <Recording x.raw.caf>`, `--transcribe-file <audio>`.
