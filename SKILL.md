---
name: loom-feedback
description: >
  Analyze Loom screen recordings (up to 30 minutes) with Gemini 3.1 Pro video
  understanding. Extracts verbatim verbal feedback, correlates to on-screen
  elements and cursor position, flags hallucinated outputs.
  Use when the user says "here's a Loom", "watch this Loom", "Loom feedback", "review
  this video", "I recorded feedback", "here's my screen recording", or pastes a
  loom.com URL.
  Requires: yt-dlp, ffmpeg, and a Gemini API key (GEMINI_API_KEY env var or
  ~/.config/loom-feedback/gemini_api_key).
---

# Loom Feedback Pipeline

Analyzes screen recordings where someone gives verbal UI/UX feedback. Two-layer
grounding so Gemini cannot hallucinate:

1. **Audio-intact download** — Loom's `transcoded-url` endpoint (MP4 with audio),
   not yt-dlp's HLS variant (which silently strips audio).
2. **Gemini 3.1 Pro** transcribes the audio AND analyzes the video in one pass.
   Each feedback `verbal_quote` MUST be a substring of the same response's
   `full_transcript`. Post-hoc grep validation flags any quote whose first six
   words don't appear in the transcript as `suspect_hallucination`.

Whisper was previously used as a separate transcription pass. Removed
2026-04-26 — Gemini's own transcript is sufficient when grep-validated, and
a local Whisper pass added 10–15 min per video on CPU.

## When to Trigger

- User shares a loom.com or loom.io URL
- User says "watch this Loom", "Loom feedback", "I recorded my feedback"
- User references a screen recording with design feedback
- User passes a local `.mp4` / `.MP4` path (iOS RPReplay screen recordings)

## Hard Limits

- **Max video length: 30 minutes** — pipeline rejects longer videos up front
- **Audio track REQUIRED** — pipeline aborts if source has no audio; we never
  hallucinate from silent video
- **Gemini upload uses HTTP/1.1** — HTTP/2 silently dropped large upload bodies
  in testing; the script forces `--http1.1`

## Pipeline Steps

### Step 1: Run the script

```bash
# Remote Loom URL
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh \
  "https://www.loom.com/share/<ID>"

# Local MP4 (iOS screen recording, already has audio)
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh \
  "$HOME/Downloads/RPReplay_Final*.MP4"
```

**Resume cache (added 2026-07-07):** re-running the same URL/file within 24h
reuses the prior analysis instantly (completed runs) or skips the download
(runs that died after download). Pass `--fresh` as a trailing arg to force a
full clean re-run. Cache lives in `/tmp/loom-feedback-<sha>/` and self-purges
after 24 hours.

The script:
1. Downloads the Loom via `transcoded-url` (audio-preserving); falls back to
   `yt-dlp -f bv*+ba`; retries with backoff if Loom is still transcoding
2. Verifies audio track presence and duration (hard-aborts if missing)
3. Uploads video to Gemini File API (resumable, HTTP/1.1)
4. Waits for Gemini file processing (budget scales with duration, 180–900s)
5. Sends video to Gemini with grounding rules — Gemini emits transcript +
   feedback in the same JSON response
6. Extracts a PNG frame at each feedback timestamp
7. Grep-validates every quote against the response transcript →
   `validation.json`

### Step 2: Read outputs

All outputs land in `/tmp/loom-feedback-<sha>/`:

| File | Purpose |
|---|---|
| `feedback.json` | Structured feedback list (Gemini) |
| `transcript.txt` | Flat `[MM:SS] text` transcript (from Gemini response) |
| `validation.json` | `grounded[]` and `suspect_hallucinations[]` IDs |
| `frames/frame_NNN_MMmSSs.png` | Still at each feedback timestamp |
| `video.mp4` | Downloaded source (audio intact) |
| `gemini-raw.json` | Raw Gemini response (debug) |

Every feedback item in `feedback.json` has:

- `id`, `timestamp`, `verbal_quote` (verbatim), `screen`,
- `element_description`, `element_visual_context`,
- `action_needed` (REMOVE | CHANGE_TEXT | CHANGE_COLOR | CHANGE_SIZE |
  CHANGE_SPACING | MOVE | REPLACE | REDESIGN | ADD | FIX_BUG | CLARIFY | OTHER),
- `details`, `severity`, `confidence`, `suggested_file_hint`

Top-level fields also include `platform` (auto-detected mobile/web/desktop),
`screens_reviewed`, `transcript_coverage`, and `issues_detected_silently`
(bugs Gemini saw that the speaker didn't mention).

### Step 3: Trust check (MANDATORY)

Before acting on any feedback, read `validation.json`:

- `grounded[]` — IDs whose `verbal_quote` first 6 words appear verbatim in
  the Gemini transcript. These are safe to act on.
- `suspect_hallucinations[]` — IDs whose quote could not be found. Treat as
  fabricated. Do not apply changes based on these.

If `suspect_hallucinations` is non-empty, surface the list to the user and ask
whether to drop or manually review them.

### Step 4: Map to source code

For each grounded feedback item:

1. Locate the project repo the video is reviewing
2. Cross-check `suggested_file_hint` against the real repo (`ls`/`Glob`).
   Gemini can still guess a wrong path — verify before opening.
3. Use `screen` + `element_description` + the extracted PNG frame to locate
   the exact component/JSX element.
4. Apply the change specified in `action_needed` + `details`.

### Step 5: Present to user

```
| # | Timestamp | Screen | Element | Action | Details | Confidence | File |
|---|-----------|--------|---------|--------|---------|------------|------|
| 1 | 0:15 | Home | Quick Scan button | CHANGE_COLOR | "make it more orange" | HIGH | app/(tabs)/index.tsx:42 |
```

Ask: "N grounded items, M suspect. Apply all grounded, review suspect, or
review each individually?"

### Step 6: Apply changes

- Simple changes (REMOVE / CHANGE_TEXT / CHANGE_COLOR / CHANGE_SPACING):
  apply directly with Edit; show before/after.
- Complex changes (REDESIGN / MOVE / ADD): propose implementation first; confirm
  before applying.

## Error Handling

| Issue | Detection | Fix |
|-------|-----------|-----|
| yt-dlp can't download | All 3 attempts fail verification | Check URL is public; wait 5 min if fresh (Loom still transcoding) |
| Downloaded video has no audio | `verify_audio_track()` hard-aborts | Re-record with audio enabled, OR use local RPReplay file |
| Video > 30 min | `verify_video` returns 2 | Split with `ffmpeg -i in.mp4 -c copy -t 1800 part1.mp4` and re-run per part |
| Gemini upload empty body | response is 0 bytes despite exit 0 | HTTP/2 silently drops body; script forces `--http1.1` |
| Gemini upload fails | No `file_uri` in response | Check API key; check file size (Gemini File API cap ~2GB) |
| Processing timeout | Budget (180–900s, scaled) exceeded | Retry once; if repeated, video may be corrupt |
| Suspect hallucinations in validation | `suspect_hallucinations[]` non-empty | Drop those items or manually verify against `transcript.txt` |

## Design choices (why this skill looks the way it does)

- **Audio-intact first** — earlier version relied on yt-dlp HLS downloads
  which silently dropped audio. Gemini then fabricated plausible-sounding
  transcripts (invented hex codes, wrong file paths, non-existent copy).
  Transcoded-url fixes this at the source.
- **Single-pass Gemini transcription** — Gemini does both transcription and
  analysis in one call. Removed the standalone Whisper step on 2026-04-26
  because it added 10–15 min per video on CPU and the grep-validation
  layer already catches drift.
- **HTTP/1.1 for upload** — HTTP/2 silently dropped 73MB+ bodies in
  curl runs. Forced `--http1.1` on the Gemini File API resumable upload.
- **Post-hoc grep validation** — trust but verify: every quote is matched
  against Gemini's emitted transcript, and anything that doesn't appear is
  flagged as suspect.
- **30-min cap** — Gemini File API and the token budget comfortably handle
  this; beyond that, analysis quality degrades and the user should split.

## Filming Tips (share with user if they ask)

- Speak clearly; noise hurts grounding confidence
- Hover cursor directly ON the element before speaking about it
- Say specific action words: "remove", "change to X", "make bigger", "add N px spacing"
- Pause 1–2 seconds on each element
- Name the screen before diving into detail: "On the home tab, the Quick Scan button…"
- iOS RPReplay recordings are preferred over Loom when possible — audio is
  always intact and no transcoding delay
