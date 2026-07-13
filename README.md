# loom-feedback

**Turn a screen recording of spoken UI feedback into a verified, structured action list your coding agent can execute.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Claude Code Skill](https://img.shields.io/badge/Claude%20Code-Skill-d97757)](https://claude.com/claude-code)
[![Gemini 3.1 Pro](https://img.shields.io/badge/Gemini%203.1%20Pro-Video%20Understanding-4285F4)](https://ai.google.dev)
[![Shell](https://img.shields.io/badge/bash-3.2+-brightgreen)](scripts/loom-feedback.sh)

A [Claude Code](https://claude.com/claude-code) skill for the most common design-review loop there is: someone records a Loom walking through your app ("make this button orange, remove that card, this spacing is off"), and you need every one of those requests captured, grounded to the exact on-screen element, and mapped to source code — without the video model inventing feedback that was never said.

Paste a Loom URL into Claude Code and say "watch this Loom." You get back a structured feedback table with verbatim quotes, timestamps, severity, extracted screenshots, and a hallucination report — then Claude applies the changes to your codebase.

---

## Why this exists

Video models hallucinate, and screen-recording feedback is a worst case: long silent stretches, vague pronouns ("move *this* up"), and UI text the model is tempted to "improve" into requirements nobody stated. The failure that motivated this pipeline: a downloader silently produced a **video with no audio track**, and the model responded by fabricating an entire plausible transcript — invented hex codes, fake file paths, copy changes nobody asked for.

This pipeline is built so that failure class cannot reach your codebase:

| Defense layer | What it prevents |
|---|---|
| **Audio-intact download** via Loom's `transcoded-url` MP4 endpoint (yt-dlp HLS fallback) | The silent-video hallucination case at its source |
| **Hard audio gate** — `ffprobe` verifies an audio track exists before any model call | Analysis of muted or corrupt recordings |
| **Single-response grounding** — Gemini emits the full transcript *and* the feedback items in one JSON response; every `verbal_quote` must be a substring of that transcript | Cross-call drift between transcription and analysis |
| **Post-hoc grep validation** — each quote's first six words are matched against the normalized transcript; misses are flagged `suspect_hallucination` | Paraphrased or invented feedback reaching the apply step |
| **Prompt-level bans** — no inferred hex values, pixel amounts, or file paths; silent navigation segments produce no items | "Helpful" fabrication inside otherwise-valid items |

Anything flagged suspect is surfaced to the user and never auto-applied.

## Pipeline

```
Loom URL or local .mp4
        │
        ▼
[1] Download with audio  ──  transcoded-url MP4 → yt-dlp bv*+ba fallback
        │                    3 attempts, backoff for in-progress transcodes
        ▼
[2] Verify               ──  size, duration ≤ 30 min, audio track present (hard gate)
        │
        ▼
[3] Gemini File API      ──  resumable upload (HTTP/1.1 forced), poll to ACTIVE
        │
        ▼
[4] One-pass analysis    ──  Gemini 3.1 Pro: verbatim transcript + feedback items
        │                    in a single JSON response, temperature 0.1
        ▼
[5] Ground + extract     ──  grep-validate every quote against the transcript,
        │                    pull a PNG frame at each feedback timestamp
        ▼
feedback.json · transcript.txt · validation.json · frames/*.png
```

Operational details baked in from production use:

- **Resume cache** — re-running the same URL/file within 24 h reuses the completed analysis instantly, or skips the download if a prior run died mid-pipeline. `--fresh` forces a clean run. Scratch dirs self-purge after 24 h.
- **HTTP/1.1 forced on upload** — HTTP/2 silently dropped 70 MB+ request bodies in testing; uploads looked successful and weren't.
- **Adaptive processing budget** — the wait for Gemini file processing scales with video duration (420–900 s), with retry/backoff on transient 5xx overload errors.
- **File cleanup** — the uploaded video is deleted from the Gemini File API after analysis.

## Output

Everything lands in `/tmp/loom-feedback-<hash>/`:

| File | Contents |
|---|---|
| `feedback.json` | Structured feedback items + video-level metadata |
| `transcript.txt` | Flat `[MM:SS] text` verbatim transcript |
| `validation.json` | `grounded[]` IDs vs `suspect_hallucinations[]` with quotes |
| `frames/frame_NNN_MMmSSs.png` | Still frame at each feedback timestamp |
| `gemini-raw.json` | Raw model response, for debugging |

Each feedback item:

```json
{
  "id": 3,
  "timestamp": "1:42",
  "verbal_quote": "this quick scan button should be way more orange",
  "screen": "Home tab",
  "element_description": "Primary 'Quick Scan' CTA button",
  "element_visual_context": "Teal rounded button centered below the header card",
  "action_needed": "CHANGE_COLOR",
  "details": "Increase orange saturation of the Quick Scan button",
  "severity": "MEDIUM",
  "confidence": "HIGH",
  "suggested_file_hint": null
}
```

Action taxonomy: `REMOVE · CHANGE_TEXT · CHANGE_COLOR · CHANGE_SIZE · CHANGE_SPACING · MOVE · REPLACE · REDESIGN · ADD · FIX_BUG · CLARIFY · OTHER`

Video-level fields include auto-detected `platform` (iOS / Android / web / desktop), `screens_reviewed`, `transcript_coverage_pct`, and `issues_detected_silently` — defects visible in the video that the speaker never mentioned.

## Requirements

| Dependency | Purpose |
|---|---|
| macOS or Linux, `bash`, `python3` | Runtime (stdlib only, no pip installs) |
| [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) | Fallback downloader |
| [`ffmpeg`](https://ffmpeg.org/) / `ffprobe` | Audio verification + frame extraction |
| [Gemini API key](https://aistudio.google.com/apikey) | Video understanding (Gemini 3.1 Pro) |

## Install

```bash
git clone https://github.com/testedmedia/loom-feedback.git ~/.claude/skills/loom-feedback
```

Provide the Gemini key either way:

```bash
export GEMINI_API_KEY="..."                       # env var, or:
mkdir -p ~/.config/loom-feedback
echo "..." > ~/.config/loom-feedback/gemini_api_key
chmod 600 ~/.config/loom-feedback/gemini_api_key
```

## Usage

**Inside Claude Code** — paste a Loom URL and say "watch this Loom" or "here's my feedback." The skill triggers automatically, runs the pipeline, checks `validation.json`, presents the grounded items as a table, and asks before applying changes.

**Standalone:**

```bash
# Remote Loom
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "https://www.loom.com/share/<ID>"

# Local screen recording (iOS RPReplay, QuickTime, OBS…)
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "$HOME/Downloads/RPReplay_Final.MP4"

# Bypass the 24h resume cache
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "<url>" --fresh
```

## Limits

- **30-minute cap.** Longer videos are rejected up front — split with `ffmpeg -i in.mp4 -c copy -t 1800 part1.mp4` and run per part.
- **Audio is mandatory.** Silent recordings abort by design; the pipeline never analyzes video-only input.
- **~2 GB file cap** (Gemini File API).

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| All download attempts fail | Loom still transcoding, or private link | Wait ~5 min; confirm the share URL is public |
| `NO AUDIO TRACK detected` | Recording captured without mic/system audio | Re-record with audio, or pass a local file that has it |
| Upload succeeds but analysis fails | Transient Gemini 5xx overload | Script retries 4× with backoff automatically; re-run if exhausted |
| Items in `suspect_hallucinations[]` | Quote not found in transcript | Review against `transcript.txt` manually; never auto-apply |
| Processing timeout | Corrupt or unusual encoding | Re-run once; re-encode with `ffmpeg -i in.mp4 -c:v libx264 -c:a aac out.mp4` |

## Recording tips for best grounding

1. Name the screen before the detail: *"On the home tab, the Quick Scan button…"*
2. Hover the cursor directly on the element you're talking about.
3. Use concrete action words: "remove", "change to X", "make bigger", "add 8px spacing".
4. Pause 1–2 seconds on each element.
5. Local screen recordings (iOS RPReplay, QuickTime) skip Loom transcoding entirely — audio is always intact.

## License

[MIT](LICENSE) © Tested Media
