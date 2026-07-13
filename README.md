# loom-feedback

A [Claude Code](https://claude.com/claude-code) skill that turns a Loom (or any screen recording) of someone talking through UI/UX feedback into a structured, hallucination-checked action list — then helps Claude apply the changes to your codebase.

Built on Gemini 3.1 Pro video understanding. Handles videos up to 30 minutes.

## What it does

1. **Downloads the video with audio intact.** Loom's default HLS variant (what yt-dlp grabs) silently strips audio, which makes any video model fabricate a plausible-sounding transcript. This pipeline uses Loom's `transcoded-url` MP4 endpoint first and hard-aborts if the file has no audio track.
2. **One-pass transcription + analysis.** Gemini transcribes the audio verbatim and extracts every distinct piece of feedback in the same response, with strict grounding rules (no invented hex codes, pixel values, or file paths).
3. **Anti-hallucination validation.** Every extracted `verbal_quote` is grep-checked against the transcript from the same response. Anything that doesn't match is flagged as `suspect_hallucination` and should not be acted on.
4. **Frame extraction.** A PNG still is pulled at each feedback timestamp so Claude (or you) can see exactly what was on screen.
5. **Structured output.** Each item has a timestamp, verbatim quote, screen name, element description, action type (`CHANGE_COLOR`, `REMOVE`, `FIX_BUG`, …), severity, and confidence.

## Requirements

- macOS or Linux, `bash`, `python3`
- [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) and [`ffmpeg`](https://ffmpeg.org/) on PATH
- A [Gemini API key](https://aistudio.google.com/apikey)

## Install

```bash
git clone https://github.com/testedmedia/loom-feedback.git ~/.claude/skills/loom-feedback
```

Provide your Gemini key either way:

```bash
export GEMINI_API_KEY="..."          # env var, or:
mkdir -p ~/.config/loom-feedback
echo "..." > ~/.config/loom-feedback/gemini_api_key
chmod 600 ~/.config/loom-feedback/gemini_api_key
```

## Use

In Claude Code, just paste a Loom URL and say "watch this Loom" / "here's my feedback". Claude picks up the skill automatically.

Or run the pipeline directly:

```bash
# Remote Loom
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "https://www.loom.com/share/<ID>"

# Local screen recording (iOS RPReplay etc.)
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "$HOME/Downloads/RPReplay_Final.MP4"

# Force a clean re-run (bypass the 24h resume cache)
bash ~/.claude/skills/loom-feedback/scripts/loom-feedback.sh "<url>" --fresh
```

Outputs land in `/tmp/loom-feedback-<hash>/`:

| File | Purpose |
|---|---|
| `feedback.json` | Structured feedback list |
| `transcript.txt` | `[MM:SS] text` transcript |
| `validation.json` | `grounded[]` vs `suspect_hallucinations[]` |
| `frames/*.png` | Still frame at each feedback timestamp |

## Recording tips (better grounding)

- Hover the cursor directly on the element before speaking about it
- Use specific action words: "remove", "change to X", "make bigger"
- Name the screen first: "On the home tab, the Quick Scan button…"
- Pause 1–2 seconds on each element

See [SKILL.md](SKILL.md) for the full pipeline documentation and design rationale.

## License

MIT
