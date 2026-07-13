#!/usr/bin/env bash
set -euo pipefail

# Loom Feedback Pipeline — enterprise-grade, up to 30 minutes
# Downloads a Loom video WITH AUDIO, asks Gemini 3.1 Pro to transcribe +
# analyze in a single pass with strict grounding rules.
#
# Usage: bash loom-feedback.sh <loom-url|local-video-path> [--fresh]
#
# Root-cause lesson from 2026-04-20 incident:
#   yt-dlp's default Loom HLS variant has NO AUDIO. Gemini then hallucinated
#   a plausible-sounding transcript (fake hex codes, wrong file paths,
#   fabricated copy). This pipeline enforces two gates against that:
#   1. transcoded-url MP4 download (audio preserved) + audio-track verification
#      BEFORE calling Gemini
#   2. Gemini emits a full_transcript + feedback items; each feedback
#      verbal_quote is grep-checked against the transcript, and anything
#      unmatched is flagged as suspect_hallucination

LOOM_URL="${1:?Usage: loom-feedback.sh <loom-url|local-video-path> [--fresh]}"
FRESH=0
for _a in "$@"; do [[ "$_a" == "--fresh" ]] && FRESH=1; done
# Key resolution: GEMINI_API_KEY env > GEMINI_KEY env > ~/.config/loom-feedback/gemini_api_key
GEMINI_KEY="${GEMINI_API_KEY:-${GEMINI_KEY:-$(cat ~/.config/loom-feedback/gemini_api_key 2>/dev/null)}}"
MODEL="gemini-3.1-pro-preview"

MAX_VIDEO_MINUTES=30
MIN_VIDEO_BYTES=$((1 * 1024 * 1024))

IS_LOCAL=0
if [[ -f "$LOOM_URL" ]]; then
  IS_LOCAL=1
  LOCAL_SRC="$LOOM_URL"
  URL_HASH=$(shasum "$LOCAL_SRC" | cut -c1-12)
else
  URL_HASH=$(printf '%s' "$LOOM_URL" | shasum | cut -c1-12)
fi
WORK_DIR="/tmp/loom-feedback-${URL_HASH}"
mkdir -p "$WORK_DIR/frames"
printf '%s\n' "$LOOM_URL" > "$WORK_DIR/source_url.txt"

# Auto-cleanup: delete any loom-feedback scratch dirs older than 24 hours.
# These can accumulate to many GB. This keeps /tmp from filling up.
find /tmp -maxdepth 1 -type d -name 'loom-feedback-*' -not -path "$WORK_DIR" -mtime +1 -exec rm -rf {} + 2>/dev/null || true

# Resume cache: a prior successful run of this exact source already produced
# validated output in WORK_DIR. Reuse it instead of re-paying download +
# upload + Gemini analysis (5-15 min per run). Force a re-run with --fresh.
if [[ "$FRESH" -eq 0 ]] && \
   python3 -c "import json,sys; json.load(open('$WORK_DIR/feedback.json')); json.load(open('$WORK_DIR/validation.json'))" 2>/dev/null; then
  FRAME_COUNT=$(ls -1 "$WORK_DIR/frames/"*.png 2>/dev/null | wc -l | tr -d ' ' || true)
  echo "=== CACHE HIT — reusing prior analysis of this source (pass --fresh to re-run) ==="
  echo "  Feedback JSON:   $WORK_DIR/feedback.json"
  echo "  Transcript TXT:  $WORK_DIR/transcript.txt"
  echo "  Validation:      $WORK_DIR/validation.json"
  echo "  Frames ($FRAME_COUNT):     $WORK_DIR/frames/"
  echo "  Video:           $WORK_DIR/video.mp4"
  exit 0
fi

VIDEO_FILE="$WORK_DIR/video.mp4"

if [[ -z "$GEMINI_KEY" ]]; then
  echo "ERROR: No Gemini API key. Set GEMINI_API_KEY or put your key in ~/.config/loom-feedback/gemini_api_key" >&2
  exit 1
fi

echo "=== LOOM FEEDBACK PIPELINE (enterprise, ≤${MAX_VIDEO_MINUTES}min) ==="
if [[ "$IS_LOCAL" -eq 1 ]]; then
  echo "LOCAL FILE: $LOOM_URL"
else
  echo "URL: $LOOM_URL"
fi
echo "Work dir: $WORK_DIR"
echo ""

# ─────────────────────────────────────────────
# STEP 1: Download WITH AUDIO, verify
# ─────────────────────────────────────────────

extract_session_id() {
  printf '%s' "$1" | sed -E 's|.*/share/([a-f0-9]+).*|\1|' | head -c 32
}

verify_audio_track() {
  local f="$1"
  local audio_codec audio_dur
  audio_codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$f" 2>/dev/null)
  if [[ -z "$audio_codec" ]]; then
    echo "  NO AUDIO TRACK detected"
    return 1
  fi
  audio_dur=$(ffprobe -v error -select_streams a:0 -show_entries stream=duration -of default=nw=1:nk=1 "$f" 2>/dev/null || echo 0)
  audio_dur=${audio_dur%.*}; audio_dur=${audio_dur:-0}
  # Some containers report N/A for stream duration — fall back to format duration
  if ! [[ "$audio_dur" =~ ^[0-9]+$ ]]; then
    audio_dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null || echo 0)
    audio_dur=${audio_dur%.*}
    [[ "$audio_dur" =~ ^[0-9]+$ ]] || audio_dur=0
  fi
  if [[ "$audio_dur" -lt 3 ]]; then
    echo "  audio track too short (${audio_dur}s)"
    return 1
  fi
  echo "  audio: $audio_codec, ${audio_dur}s ✅"
  return 0
}

verify_video() {
  local f="$1"
  [[ -f "$f" ]] || { echo "  file missing"; return 1; }
  local size dur
  size=$(stat -f%z "$f" 2>/dev/null || stat --format=%s "$f" 2>/dev/null || echo 0)
  [[ "$size" -ge "$MIN_VIDEO_BYTES" ]] || { echo "  size ${size}B < 1MB"; return 1; }
  dur=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$f" 2>/dev/null || echo 0)
  dur=${dur%.*}; dur=${dur:-0}
  [[ "$dur" -gt 0 ]] || { echo "  duration 0"; return 1; }
  local dur_min=$((dur / 60))
  if [[ "$dur_min" -gt "$MAX_VIDEO_MINUTES" ]]; then
    echo "  video too long: ${dur_min}min > ${MAX_VIDEO_MINUTES}min cap"
    return 2
  fi
  echo "  video: $((size/1048576))MB ${dur}s"
  verify_audio_track "$f"
}

attempt_transcoded_mp4() {
  echo "  [strategy: transcoded-url MP4 — audio preserved]"
  local sid api_body mp4_url http_code
  sid=$(extract_session_id "$LOOM_URL")
  [[ -n "$sid" ]] || { echo "  could not parse session id"; return 1; }
  api_body=$(curl -sf -X POST \
    "https://www.loom.com/api/campaigns/sessions/${sid}/transcoded-url" \
    -H "Content-Type: application/json" -d '{}' 2>/dev/null) || {
      echo "  transcoded-url API failed (session may still be transcoding)"
      return 1
    }
  mp4_url=$(printf '%s' "$api_body" | python3 -c "import sys,json;print(json.load(sys.stdin).get('url',''))" 2>/dev/null)
  [[ -n "$mp4_url" ]] || { echo "  transcoded-url returned empty URL"; return 1; }
  rm -f "$VIDEO_FILE"
  # -w writes the status code to stdout; keep stderr separate so it can't pollute the value
  http_code=$(curl -sS -o "$VIDEO_FILE" -w "%{http_code}" "$mp4_url" 2>/dev/null || echo 000)
  if [[ "$http_code" != "200" ]]; then
    echo "  transcoded MP4 download HTTP $http_code"
    rm -f "$VIDEO_FILE"
    return 1
  fi
  verify_video "$VIDEO_FILE"
}

attempt_ytdlp_with_audio() {
  echo "  [strategy: yt-dlp bv*+ba]"
  rm -f "$VIDEO_FILE" "$VIDEO_FILE.part"
  yt-dlp --no-warnings \
    -f "bv*+ba/b" \
    --merge-output-format mp4 \
    -o "$VIDEO_FILE" \
    "$LOOM_URL" 2>&1 | tail -3 || true
  verify_video "$VIDEO_FILE"
}

echo "[1/4] Downloading Loom WITH AUDIO..."
DOWNLOAD_OK=0
DOWNLOAD_RESULT=1

# Partial resume: video already downloaded and verified (e.g. a prior run died
# after download). Skip straight to upload unless --fresh.
if [[ "$FRESH" -eq 0 && -f "$VIDEO_FILE" ]]; then
  echo "  found cached download, verifying..."
  if verify_video "$VIDEO_FILE"; then
    echo "  cached download reused — skipping download"
    DOWNLOAD_OK=1
    DOWNLOAD_RESULT=0
  fi
fi

if [[ "$DOWNLOAD_OK" -eq 1 ]]; then
  : # already have a verified video
elif [[ "$IS_LOCAL" -eq 1 ]]; then
  cp "$LOCAL_SRC" "$VIDEO_FILE"
  verify_video "$VIDEO_FILE" && DOWNLOAD_RESULT=0 || DOWNLOAD_RESULT=$?
  if [[ "$DOWNLOAD_RESULT" -eq 0 ]]; then DOWNLOAD_OK=1; fi
else
  for attempt in 1 2 3; do
    echo "Attempt $attempt/3:"
    attempt_transcoded_mp4 && DOWNLOAD_RESULT=0 || DOWNLOAD_RESULT=$?
    if [[ "$DOWNLOAD_RESULT" -eq 0 ]]; then DOWNLOAD_OK=1; break; fi
    if [[ "$DOWNLOAD_RESULT" -eq 2 ]]; then break; fi
    attempt_ytdlp_with_audio && DOWNLOAD_RESULT=0 || DOWNLOAD_RESULT=$?
    if [[ "$DOWNLOAD_RESULT" -eq 0 ]]; then DOWNLOAD_OK=1; break; fi
    if [[ "$DOWNLOAD_RESULT" -eq 2 ]]; then break; fi
    if [[ $attempt -lt 3 ]]; then
      WAIT=$((attempt * 60))
      echo "  both strategies failed. Sleeping ${WAIT}s (Loom may still be transcoding)..."
      sleep "$WAIT"
    fi
  done
fi

if [[ "$DOWNLOAD_RESULT" -eq 2 ]]; then
  DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$VIDEO_FILE" | cut -d. -f1)
  echo ""
  echo "ERROR: video is $((DUR/60))min, exceeds ${MAX_VIDEO_MINUTES}min cap."
  echo "Split and re-run per part:"
  echo "  ffmpeg -i \"$VIDEO_FILE\" -c copy -t 1800 part1.mp4"
  exit 1
fi

if [[ "$DOWNLOAD_OK" -ne 1 ]]; then
  echo ""
  echo "ERROR: could not get an audio-bearing video."
  echo ""
  echo "Common causes:"
  echo "  - Loom still transcoding (retry in 5 min)"
  echo "  - Share URL private or session deleted"
  echo "  - Recording had audio disabled at capture time"
  echo ""
  echo "If you have a local iOS screen recording, pass it directly:"
  echo "  bash $0 \"\$HOME/Downloads/RPReplay_Final*.MP4\""
  exit 1
fi

FILE_SIZE=$(stat -f%z "$VIDEO_FILE" 2>/dev/null || stat --format=%s "$VIDEO_FILE")
DURATION=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$VIDEO_FILE" | cut -d. -f1)
DUR_MIN=$((DURATION/60)); DUR_SEC=$((DURATION%60))
echo "Downloaded: $((FILE_SIZE/1048576))MB, ${DUR_MIN}m${DUR_SEC}s, audio verified"
echo ""

# ─────────────────────────────────────────────
# STEP 2: Upload + wait for Gemini
# ─────────────────────────────────────────────
echo "[2/4] Uploading to Gemini File API..."

DISPLAY_NAME="loom-feedback-$(date +%Y%m%d-%H%M%S)"
UPLOAD_INIT_HEADERS=$(mktemp)
curl -s -X POST \
  "https://generativelanguage.googleapis.com/upload/v1beta/files?key=${GEMINI_KEY}" \
  -D "$UPLOAD_INIT_HEADERS" \
  -H "X-Goog-Upload-Protocol: resumable" \
  -H "X-Goog-Upload-Command: start" \
  -H "X-Goog-Upload-Header-Content-Length: ${FILE_SIZE}" \
  -H "X-Goog-Upload-Header-Content-Type: video/mp4" \
  -H "Content-Type: application/json" \
  -d "{\"file\": {\"display_name\": \"${DISPLAY_NAME}\"}}" \
  -o /dev/null 2>&1
UPLOAD_URL=$(grep -i "x-goog-upload-url:" "$UPLOAD_INIT_HEADERS" | sed 's/x-goog-upload-url: //i' | tr -d '\r\n')
rm -f "$UPLOAD_INIT_HEADERS"
[[ -n "$UPLOAD_URL" ]] || { echo "ERROR: could not init Gemini upload" >&2; exit 1; }

UPLOAD_RESPONSE=$(curl --http1.1 -s --max-time 600 --retry 2 -X POST "$UPLOAD_URL" \
  -H "Content-Length: ${FILE_SIZE}" \
  -H "X-Goog-Upload-Offset: 0" \
  -H "X-Goog-Upload-Command: upload, finalize" \
  --data-binary "@${VIDEO_FILE}")
FILE_URI=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin)['file']['uri'])" 2>/dev/null)
FILE_NAME=$(echo "$UPLOAD_RESPONSE" | python3 -c "import sys,json;print(json.load(sys.stdin)['file']['name'])" 2>/dev/null)
[[ -n "$FILE_URI" ]] || { echo "ERROR: Gemini upload failed: $UPLOAD_RESPONSE" >&2; exit 1; }
echo "Uploaded: $FILE_URI"

# Budget scales with video length: 20s per video-minute, floor 420s, ceiling 900s
# (Floor raised 180→420 on 2026-07-02: an 8-min video timed out at 180s — Gemini
# processing latency doesn't track video length tightly enough for a low floor.)
MAX_WAIT=$((DURATION * 20 / 60))
[[ "$MAX_WAIT" -lt 420 ]] && MAX_WAIT=420
[[ "$MAX_WAIT" -gt 900 ]] && MAX_WAIT=900
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
  STATUS=$(curl -s "https://generativelanguage.googleapis.com/v1beta/${FILE_NAME}?key=${GEMINI_KEY}" \
    | python3 -c "import sys,json;print(json.load(sys.stdin).get('state','UNKNOWN'))" 2>/dev/null)
  if [[ "$STATUS" == "ACTIVE" ]]; then
    echo "File ACTIVE (${WAITED}s)."
    break
  elif [[ "$STATUS" == "FAILED" ]]; then
    echo "ERROR: Gemini failed to process video" >&2; exit 1
  fi
  sleep 5; WAITED=$((WAITED + 5))
done
[[ $WAITED -lt $MAX_WAIT ]] || { echo "ERROR: processing timed out after ${MAX_WAIT}s" >&2; exit 1; }
echo ""

# ─────────────────────────────────────────────
# STEP 3: Gemini analysis — transcript + feedback in one pass
# ─────────────────────────────────────────────
echo "[3/4] Analyzing with Gemini 3.1 Pro..."

PROMPT_FILE="$WORK_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<'PROMPT_END'
You are a senior product-design reviewer analyzing a screen recording of someone giving UI/UX feedback on software they own.

The video has AUDIO. Your task has two parts:

PART A — TRANSCRIBE the full audio verbatim with [MM:SS] timestamps per spoken segment. This transcript is the ground truth for Part B.

PART B — EXTRACT every distinct piece of feedback the speaker gave. Only transcribe what you actually hear. Do NOT infer or paraphrase.

HARD RULES — violating these produces broken outputs:
- Every feedback `verbal_quote` MUST be an exact substring of `full_transcript`. Do not paraphrase.
- Every feedback `timestamp` MUST fall within a transcript segment ±5s.
- If the speaker says something vague like "this looks weird", capture it verbatim — do not guess what they meant.
- NEVER invent hex colors, pixel values, spacing amounts, or file paths the speaker did not state.
- If the speaker is silent (only navigating) during a stretch, skip it — do NOT manufacture feedback for silent segments.
- Auto-detect platform from the video (mobile iOS / mobile Android / web / desktop). Do NOT default to web.

Per feedback item:
- id:                    1-indexed integer
- timestamp:             MM:SS matching the transcript
- verbal_quote:          verbatim substring of full_transcript
- screen:                Name of the screen/page (e.g. "Home tab", "Report detail", "Walkthrough setup")
- element_description:   UI element the speaker referenced
- element_visual_context: What you SEE around that element (colors, layout, nearby text) — pure observation
- action_needed:         REMOVE | CHANGE_TEXT | CHANGE_COLOR | CHANGE_SIZE | CHANGE_SPACING | MOVE | REPLACE | REDESIGN | ADD | FIX_BUG | CLARIFY | OTHER
- details:               Specifics spoken. If vague, state "speaker did not specify — needs follow-up"
- severity:              CRITICAL | HIGH | MEDIUM | LOW
- confidence:            HIGH | MEDIUM | LOW (how unambiguous the request is)
- suggested_file_hint:   Only if you can confidently guess a path from visible UI text. Otherwise null. NEVER fabricate.

Top-level fields:
- platform:                  "mobile_ios" | "mobile_android" | "web" | "desktop" | "mixed"
- app_or_site_name:          if visible
- full_transcript:           single string with "[MM:SS] text\n[MM:SS] text\n..." format
- overall_theme:             one-paragraph summary
- screens_reviewed:          ordered list of screens the speaker visited
- transcript_coverage_pct:   integer 0–100, fraction of transcript segments that led to actionable feedback
- issues_detected_silently:  bugs you SEE in the video that the speaker did NOT mention
   Each: { timestamp, screen, issue, severity }

Return ONLY valid JSON matching this schema:
{
  "platform": "...",
  "app_or_site_name": "...",
  "full_transcript": "[00:00] ...\n[00:03] ...",
  "overall_theme": "...",
  "screens_reviewed": ["..."],
  "transcript_coverage_pct": N,
  "total_feedback_items": N,
  "feedback": [ ... ],
  "issues_detected_silently": [ ... ]
}
PROMPT_END

REQUEST_PAYLOAD=$(FILE_URI="$FILE_URI" PROMPT_FILE="$PROMPT_FILE" python3 -c "
import json, os
with open(os.environ['PROMPT_FILE']) as f:
    prompt = f.read()
payload = {
    'contents': [{
        'parts': [
            {'file_data': {'mime_type': 'video/mp4', 'file_uri': os.environ['FILE_URI']}},
            {'text': prompt}
        ]
    }],
    'generationConfig': {
        'temperature': 0.1,
        'maxOutputTokens': 32768,
        'responseMimeType': 'application/json'
    }
}
print(json.dumps(payload))
")

RESPONSE_FILE="$WORK_DIR/gemini-raw.json"
# Retry on 500/503 with exponential backoff — Gemini 3 Pro has transient overload errors
for ATTEMPT in 1 2 3 4; do
  curl -s -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${GEMINI_KEY}" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_PAYLOAD" \
    --max-time 900 \
    -o "$RESPONSE_FILE" 2>&1
  HTTP_STATUS=$(python3 -c "
import sys,json
try:
    with open('$RESPONSE_FILE') as f: d=json.load(f)
    if 'error' in d: print(d['error'].get('code', 0))
    elif 'candidates' in d: print(200)
    else: print(0)
except Exception: print(0)
" 2>/dev/null)
  if [[ "$HTTP_STATUS" == "200" ]]; then
    echo "  Gemini OK on attempt $ATTEMPT"
    break
  fi
  if [[ $ATTEMPT -lt 4 ]]; then
    BACKOFF=$((ATTEMPT * 15))
    echo "  Gemini returned $HTTP_STATUS on attempt $ATTEMPT; retrying in ${BACKOFF}s..."
    sleep "$BACKOFF"
  fi
done

if [[ "$HTTP_STATUS" != "200" ]]; then
  echo "ERROR: Gemini analysis failed after 4 attempts (last status: $HTTP_STATUS). See $RESPONSE_FILE" >&2
  head -c 2000 "$RESPONSE_FILE" >&2
  exit 1
fi

if ! python3 - "$RESPONSE_FILE" "$WORK_DIR/feedback.json" "$WORK_DIR/transcript.txt" <<'PY'
import json, sys
raw_path, fb_path, transcript_path = sys.argv[1:4]
with open(raw_path) as f:
    data = json.load(f)
text = data['candidates'][0]['content']['parts'][0]['text']
parsed = json.loads(text)
with open(fb_path, "w") as f:
    json.dump(parsed, f, indent=2)
with open(transcript_path, "w") as f:
    f.write(parsed.get("full_transcript", "") + "\n")
print(f"  platform: {parsed.get('platform','?')}")
print(f"  app/site: {parsed.get('app_or_site_name','?')}")
print(f"  feedback items: {parsed.get('total_feedback_items',0)}")
print(f"  silent issues: {len(parsed.get('issues_detected_silently',[]))}")
print(f"  transcript len: {len(parsed.get('full_transcript',''))} chars")
PY
then
  echo "ERROR: Gemini returned an unparseable response. See $RESPONSE_FILE" >&2
  head -c 2000 "$RESPONSE_FILE" >&2
  exit 1
fi
echo ""

# ─────────────────────────────────────────────
# STEP 4: Frame extraction + transcript grounding validation
# ─────────────────────────────────────────────
echo "[4/4] Extracting frames + validating grounding..."

python3 - "$WORK_DIR/feedback.json" "$VIDEO_FILE" "$WORK_DIR/frames" "$WORK_DIR/transcript.txt" "$WORK_DIR/validation.json" <<'PY'
import json, subprocess, sys, os, re
fb_path, video, frames_dir, transcript_path, validation_path = sys.argv[1:6]
with open(fb_path) as f:
    data = json.load(f)
with open(transcript_path) as f:
    raw_transcript = f.read()
def normalize(s):
    return re.sub(r'[^a-z0-9 ]+', ' ', s.lower())
def collapse(s):
    return re.sub(r'\s+', ' ', s).strip()
transcript_n = collapse(normalize(raw_transcript))

validation = {"grounded": [], "suspect_hallucinations": []}

for item in data.get('feedback', []):
    ts = item.get('timestamp', '0:00')
    item_id = item.get('id', 0)
    quote = item.get('verbal_quote', '') or ""
    parts = ts.split(':')
    if len(parts) == 2:
        seconds = int(parts[0]) * 60 + int(parts[1])
    elif len(parts) == 3:
        seconds = int(parts[0]) * 3600 + int(parts[1]) * 60 + int(parts[2])
    else:
        seconds = 0
    fname = f"frame_{item_id:03d}_{ts.replace(':', 'm')}s.png"
    output = os.path.join(frames_dir, fname)
    try:
        subprocess.run(['ffmpeg', '-y', '-ss', str(seconds), '-i', video,
                        '-frames:v', '1', '-q:v', '2', output],
                       capture_output=True, timeout=30)
        if os.path.exists(output):
            print(f'  Frame {item_id} @ {ts} -> {fname}')
    except Exception as e:
        print(f'  Frame {item_id}: FAILED ({e})')
    tokens = re.findall(r'\w+', quote.lower())
    probe = ' '.join(tokens[:6]) if len(tokens) >= 6 else ' '.join(tokens)
    # r-loomfix: use transcript_n (normalized) — bare `transcript` was a
    # NameError that crashed the whole step-4 block after frame 1.
    if probe and probe in transcript_n:
        validation["grounded"].append(item_id)
    elif quote.strip():
        validation["suspect_hallucinations"].append({
            "id": item_id, "timestamp": ts, "quote": quote[:160]
        })

with open(validation_path, "w") as f:
    json.dump(validation, f, indent=2)
print("")
print(f"Grounding: {len(validation['grounded'])} verbatim hits, {len(validation['suspect_hallucinations'])} suspect")
if validation["suspect_hallucinations"]:
    print("Suspect items (review before acting):")
    for s in validation["suspect_hallucinations"]:
        print(f"  #{s['id']} @ {s['timestamp']}: {s['quote'][:80]}")
PY

# `|| true`: empty glob makes ls exit 2, which set -euo pipefail would turn
# into a hard crash right before the completion banner (0-feedback-item runs).
FRAME_COUNT=$(ls -1 "$WORK_DIR/frames/"*.png 2>/dev/null | wc -l | tr -d ' ' || true)
echo ""
echo "=== PIPELINE COMPLETE ==="
echo "  Feedback JSON:   $WORK_DIR/feedback.json"
echo "  Transcript TXT:  $WORK_DIR/transcript.txt"
echo "  Validation:      $WORK_DIR/validation.json"
echo "  Frames ($FRAME_COUNT):     $WORK_DIR/frames/"
echo "  Video:           $VIDEO_FILE"
echo ""

if [[ -n "${FILE_NAME:-}" ]]; then
  curl -s -X DELETE \
    "https://generativelanguage.googleapis.com/v1beta/${FILE_NAME}?key=${GEMINI_KEY}" \
    > /dev/null 2>&1
  echo "Cleaned up Gemini file upload."
fi
