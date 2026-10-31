---
name: kagu
description: Find, read and search Kagu recordings and transcripts on this Mac (meetings, calls, voice notes recorded with the Kagu app), or make a transcript of an audio file with Kagu. Use when the user asks what was said in a meeting or call, wants a summary, action items or a quote from a recording, or wants an audio file transcribed locally.
---

# Kagu

Kagu is a Mac app that records the microphone and everything the Mac plays into one file, then writes a transcript on the Mac with **You** (the mic) and **Them** (the Mac's sound) kept apart. Everything it makes is plain files; read them directly.

## Where things are

- Library: `~/Music/Recordings`. Each subfolder is a folder in Kagu's sidebar (for example `~/Music/Recordings/Clients`).
- A recording: `<title>.m4a`. Its transcript sits next to it: `<title>.md`, or `<title>.transcript.md` when a different `<title>.md` was already there. A recording that still has Kagu's default name (`Recording <date> <time>`) may be given a short title from its summary once the summary is made, so the file name can change after the first look.
- Hidden files you can ignore: `.<title>.tracks.m4a` (the two sides kept apart for a later transcript), `.Recording ....caf` (a recording still being written or waiting to be recovered; never move or delete it).
- The app's log: `~/Library/Logs/Recorder.log`.

## Transcript format

```markdown
# Standup with Fran

Whisper large-v3 turbo, language auto, transcribed Oct 26, 2026 at 9:16 PM

**Them** `00:00:03`

So we ship it on Friday.

**You** `00:00:05`

Yes, Friday works.
```

The first line is the title (the file name), then how and when it was transcribed, then one block per turn: speaker, start time (hours:minutes:seconds from the start of the recording), text.

The speakers are **You** (the mic) and **Them** (the Mac's sound); a transcript of an imported file may have one speaker, **Speaker**. The owner can rename a speaker other than You in Kagu for that recording (for example **Fran**); then every block of that speaker carries the name the owner gave it. Older transcripts may say **Me** for You.

A transcript of a recording Kagu made, or one the owner asked a summary for, has a block between the header line and the first turn, and may have a note at the very end:

```markdown
## Summary

You and the other side agreed to ship on Friday.

## Decisions

- Ship on Friday

## Action items

- You: send the contract to Fran

Made on this Mac from the transcript; it can be wrong.
```

- The summary, decisions and action items are made on the Mac by a small on-device model. They are machine-made and can be wrong or incomplete: treat them as a guide to where to look, not as a record. Decisions and Action items are left out when there are none; a transcript may have no summary at all.
- A quote must come from the speaker lines (`**You** ...`, `**Them** ...`), never from the summary. Quote with the speaker and the time stamp of the turn.
- At the very end, after a line with `---`, a note such as "Struck from the record: 41 fillers ..." says what the cleaning removed from the transcript.

## Common tasks

- Latest recordings: `ls -t ~/Music/Recordings/**/*.m4a | head` (zsh), or `find ~/Music/Recordings -name '*.m4a' -not -name '.*' -print0 | xargs -0 ls -t | head`.
- Search what was said: `grep -ril "pricing" ~/Music/Recordings --include='*.md'`, then read the matching transcript around the hit.
- Recordings with a tag (tags are Finder tags): `mdfind -onlyin ~/Music/Recordings "kMDItemUserTags == 'Work'"`.
- Length of a recording: `afinfo "<file>.m4a" | grep duration`.
- Transcribe an audio file on this Mac (writes `<file>.md` next to it, then quits; the speech model must already be downloaded in Kagu): `/Applications/Kagu.app/Contents/MacOS/Recorder --transcribe-file "/path/to/audio.m4a"`.

## Rules

- Recordings are private conversations. Do not upload a recording or transcript anywhere, or paste it into another service, unless the user asks for that file to go there.
- Do not rename, move or delete files in the library behind Kagu's back while it runs; ask the user to do it in Kagu (right click on a recording: Rename, Move to, Tags).
- When quoting, give the speaker and the time stamp so the user can play from there in Kagu.
