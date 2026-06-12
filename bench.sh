#!/usr/bin/env bash
# Synthetic benchmark + parity gate for MetalVideoEngine.
#
# The script generates a vertical H.264 test source, ASS captions, and a
# PNG logo, then runs:
#   1. baseline vs baseline, to prove the encoder is deterministic
#   2. baseline vs candidate, to measure speed and pixel parity
#
# Set MVE_BASELINE_BIN=/path/to/old/mve to compare against a release
# binary. Without it, the current release build is used for both sides,
# which still exercises the harness end to end.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG="${FFMPEG_BIN:-ffmpeg}"
FFPROBE="${FFPROBE_BIN:-ffprobe}"
CANDIDATE_BIN="${MVE_CANDIDATE_BIN:-$ROOT/.build/release/mve}"
BASELINE_BIN="${MVE_BASELINE_BIN:-$CANDIDATE_BIN}"

WIDTH="${MVE_BENCH_WIDTH:-1080}"
HEIGHT="${MVE_BENCH_HEIGHT:-1920}"
FPS="${MVE_BENCH_FPS:-30}"
DURATION="${MVE_BENCH_DURATION:-60}"
SOURCE_BITRATE="${MVE_BENCH_SOURCE_BITRATE:-8000000}"
OUTPUT_BITRATE="${MVE_BENCH_OUTPUT_BITRATE:-10000000}"
WORKDIR="${MVE_BENCH_WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/mve-bench.XXXXXX")}"

failures=0

die() {
  echo "FAIL: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_positive_int() {
  local name="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$name must be a positive integer"
}

require_positive_number() {
  local name="$1"
  local value="$2"
  python3 - "$value" <<'PY' || die "$name must be a positive number"
import sys
try:
    ok = float(sys.argv[1]) > 0
except ValueError:
    ok = False
raise SystemExit(0 if ok else 1)
PY
}

require_nonnegative_number() {
  local name="$1"
  local value="$2"
  python3 - "$value" <<'PY' || die "$name must be a nonnegative number"
import sys
try:
    ok = float(sys.argv[1]) >= 0
except ValueError:
    ok = False
raise SystemExit(0 if ok else 1)
PY
}

file_size() {
  if stat -f%z "$1" >/dev/null 2>&1; then
    stat -f%z "$1"
  else
    stat -c%s "$1"
  fi
}

md5_file() {
  if command -v md5 >/dev/null 2>&1; then
    md5 -q "$1"
  else
    md5sum "$1" | awk '{print $1}'
  fi
}

psnr_average() {
  local left="$1"
  local right="$2"
  local label="$3"
  local stats="$WORKDIR/$label-psnr.log"
  local log="$WORKDIR/$label-ffmpeg.log"

  set +e
  "$FFMPEG" -hide_banner -nostats \
    -i "$left" -i "$right" \
    -lavfi "psnr=stats_file=$stats" \
    -f null - >"$WORKDIR/$label-ffmpeg.stdout" 2>"$log"
  local status=$?
  set -e
  if [[ $status -ne 0 ]]; then
    die "ffmpeg PSNR failed for $label; see $log"
  fi
  sed -n 's/.*average:\([^ ]*\).*/\1/p' "$log" | tail -1
}

write_ass() {
  local ass="$1"
  cat >"$ass" <<ASS
[Script Info]
ScriptType: v4.00+
PlayResX: $WIDTH
PlayResY: $HEIGHT

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,72,&H00FFFFFF,&H0000FFFF,&H90000000,&H90000000,-1,0,0,0,100,100,0,0,1,4,2,2,64,64,170,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:00.00,0:00:05.00,Default,,0,0,0,,Synthetic export fixture
Dialogue: 0,0:00:05.00,0:00:12.00,Default,,0,0,0,,Captions hold for seconds
Dialogue: 0,0:00:12.00,0:00:20.00,Default,,0,0,0,,The cache should skip repeated uploads
Dialogue: 0,0:00:20.00,0:00:34.00,Default,,0,0,0,,Overlay and subtitle pixels must stay identical
Dialogue: 0,0:00:34.00,0:00:60.00,Default,,0,0,0,,Benchmark complete
ASS
}

write_job_spec() {
  local output="$1"
  local spec="$2"
  local frame_at="${3:-}"
  local frame_out="${4:-}"

  python3 - "$SOURCE" "$output" "$ASS_FILE" "$LOGO_FILE" \
    "$WIDTH" "$HEIGHT" "$OUTPUT_BITRATE" "$frame_at" "$frame_out" >"$spec" <<'PY'
import json
import sys

source, output, ass_path, logo_path = sys.argv[1:5]
width, height, bitrate = sys.argv[5:8]
frame_at, frame_out = sys.argv[8:10]

spec = {
    "input": source,
    "output": output,
    "preset": f"{width}x{height}",
    "bitrate": int(bitrate),
    "quality": "delivery",
    "codec": "h264",
    "grade": {"brightness": 0.02, "contrast": 1.05, "saturation": 1.10},
    "bypass": {"zoom": 1.01, "noise": 2, "grain": 2},
    "subtitles": {"assPath": ass_path},
    "overlays": [
        {
            "imagePath": logo_path,
            "anchor": 3,
            "offsetX": -20,
            "offsetY": -20,
            "widthFraction": 0.16,
            "opacity": 0.88,
        }
    ],
    "texts": [
        {
            "text": "@mve",
            "anchor": 9,
            "offsetX": -18,
            "offsetY": 32,
            "fontSize": 58,
            "colorHex": "FFFFFF",
            "shadow": True,
            "bgColorHex": "000000",
            "bgOpacity": 0.45,
            "bgRadius": 14,
        }
    ],
}
if frame_at:
    spec["frame"] = {"atSeconds": float(frame_at), "outPath": frame_out}

json.dump(spec, sys.stdout, indent=2)
sys.stdout.write("\n")
PY
}

RUN_STATUS=0
RUN_REAL=""
RUN_DONE=""

run_job() {
  local label="$1"
  local bin="$2"
  local spec="$3"
  local log="$WORKDIR/$label.log"

  set +e
  /usr/bin/time -p "$bin" job "$spec" >"$WORKDIR/$label.stdout" 2>"$log"
  RUN_STATUS=$?
  set -e

  RUN_REAL="$(sed -n 's/^real //p' "$log" | tail -1)"
  RUN_DONE="$(grep -E '^\[done\]' "$log" | tail -1 || true)"
  [[ -n "$RUN_REAL" ]] || RUN_REAL="n/a"
  if [[ $RUN_STATUS -ne 0 && -z "$RUN_DONE" ]]; then
    die "$label exited $RUN_STATUS before [done]; see $log"
  fi
}

run_frame_probe() {
  local label="$1"
  local bin="$2"
  local at="$3"
  local png="$4"
  local spec="$WORKDIR/$label-frame-$at.json"
  local log="$WORKDIR/$label-frame-$at.log"

  write_job_spec "$WORKDIR/$label-frame-unused.mp4" "$spec" "$at" "$png"
  set +e
  "$bin" frame "$spec" >"$WORKDIR/$label-frame-$at.stdout" 2>"$log"
  local status=$?
  set -e
  if [[ $status -ne 0 || ! -s "$png" ]]; then
    die "$label frame probe at ${at}s failed; see $log"
  fi
}

need "$FFMPEG"
need "$FFPROBE"
need python3

require_positive_int "MVE_BENCH_WIDTH" "$WIDTH"
require_positive_int "MVE_BENCH_HEIGHT" "$HEIGHT"
require_positive_int "MVE_BENCH_FPS" "$FPS"
require_positive_int "MVE_BENCH_SOURCE_BITRATE" "$SOURCE_BITRATE"
require_positive_int "MVE_BENCH_OUTPUT_BITRATE" "$OUTPUT_BITRATE"
require_positive_number "MVE_BENCH_DURATION" "$DURATION"
(( WIDTH % 2 == 0 )) || die "MVE_BENCH_WIDTH must be even for H.264"
(( HEIGHT % 2 == 0 )) || die "MVE_BENCH_HEIGHT must be even for H.264"

DEFAULT_PROBES="$(python3 -c "d=float('$DURATION'); print(f'{min(3.0, max(0.1, d * 0.25)):.3f} {min(31.2, max(0.2, d * 0.75)):.3f}')")"
PROBES="${MVE_BENCH_PROBES:-$DEFAULT_PROBES}"
for probe in $PROBES; do
  require_nonnegative_number "MVE_BENCH_PROBES item" "$probe"
done

mkdir -p "$WORKDIR"

if [[ ! -x "$CANDIDATE_BIN" && "$CANDIDATE_BIN" == "$ROOT/.build/release/mve" ]]; then
  echo "candidate binary missing; building release mve"
  CLANG_MODULE_CACHE_PATH="$ROOT/.build/clang-module-cache" swift build -c release
fi

[[ -x "$CANDIDATE_BIN" ]] || die "candidate binary is not executable: $CANDIDATE_BIN"
[[ -x "$BASELINE_BIN" ]] || die "baseline binary is not executable: $BASELINE_BIN"

SOURCE="$WORKDIR/source.mp4"
ASS_FILE="$WORKDIR/captions.ass"
LOGO_FILE="$WORKDIR/logo.png"

echo "=== fixture ==="
echo "workdir:   $WORKDIR"
echo "source:    ${WIDTH}x${HEIGHT}@${FPS} for ${DURATION}s"
echo "baseline:  $BASELINE_BIN"
echo "candidate: $CANDIDATE_BIN"
echo

set +e
"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
  -pix_fmt yuv420p -c:v h264_videotoolbox -allow_sw 1 -b:v "$SOURCE_BITRATE" \
  -movflags +faststart "$SOURCE" >"$WORKDIR/source-videotoolbox.stdout" 2>"$WORKDIR/source-videotoolbox.log"
source_status=$?
set -e
if [[ $source_status -ne 0 ]]; then
  echo "fixture VideoToolbox encode failed; retrying with libx264 (see $WORKDIR/source-videotoolbox.log)" >&2
  set +e
  "$FFMPEG" -y -hide_banner -loglevel error \
    -f lavfi -i "testsrc2=size=${WIDTH}x${HEIGHT}:rate=${FPS}:duration=${DURATION}" \
    -pix_fmt yuv420p -c:v libx264 -preset veryfast -b:v "$SOURCE_BITRATE" \
    -movflags +faststart "$SOURCE" >"$WORKDIR/source-libx264.stdout" 2>"$WORKDIR/source-libx264.log"
  retry_status=$?
  set -e
  [[ $retry_status -eq 0 ]] || die "fixture libx264 retry failed; see $WORKDIR/source-libx264.log"
fi

"$FFMPEG" -y -hide_banner -loglevel error \
  -f lavfi -i "color=c=black@0.0:s=320x120:d=1,format=rgba" \
  -vf "drawbox=x=0:y=0:w=320:h=120:color=white@0.82:t=fill,drawbox=x=14:y=14:w=292:h=92:color=0x225EA8@1:t=fill" \
  -frames:v 1 "$LOGO_FILE"

write_ass "$ASS_FILE"

echo "=== source probe ==="
"$FFPROBE" -v error \
  -show_entries stream=codec_name,width,height,r_frame_rate,duration \
  -show_entries format=duration \
  -of default=noprint_wrappers=1 "$SOURCE"
echo

BASE_A_OUT="$WORKDIR/baseline-a.mp4"
BASE_B_OUT="$WORKDIR/baseline-b.mp4"
CAND_OUT="$WORKDIR/candidate.mp4"
BASE_A_SPEC="$WORKDIR/baseline-a.json"
BASE_B_SPEC="$WORKDIR/baseline-b.json"
CAND_SPEC="$WORKDIR/candidate.json"

write_job_spec "$BASE_A_OUT" "$BASE_A_SPEC"
write_job_spec "$BASE_B_OUT" "$BASE_B_SPEC"
write_job_spec "$CAND_OUT" "$CAND_SPEC"

echo "=== renders ==="
run_job "baseline-a" "$BASELINE_BIN" "$BASE_A_SPEC"
BASE_A_STATUS=$RUN_STATUS
BASE_A_REAL=$RUN_REAL
BASE_A_DONE=$RUN_DONE

run_job "baseline-b" "$BASELINE_BIN" "$BASE_B_SPEC"
BASE_B_STATUS=$RUN_STATUS
BASE_B_REAL=$RUN_REAL
BASE_B_DONE=$RUN_DONE

run_job "candidate" "$CANDIDATE_BIN" "$CAND_SPEC"
CAND_STATUS=$RUN_STATUS
CAND_REAL=$RUN_REAL
CAND_DONE=$RUN_DONE

printf "%-12s %-8s %-8s %-12s %s\n" "run" "wall" "exit" "bytes" "done"
printf "%-12s %-8s %-8s %-12s %s\n" "baseline-a" "$BASE_A_REAL" "$BASE_A_STATUS" "$(file_size "$BASE_A_OUT")" "$BASE_A_DONE"
printf "%-12s %-8s %-8s %-12s %s\n" "baseline-b" "$BASE_B_REAL" "$BASE_B_STATUS" "$(file_size "$BASE_B_OUT")" "$BASE_B_DONE"
printf "%-12s %-8s %-8s %-12s %s\n" "candidate" "$CAND_REAL" "$CAND_STATUS" "$(file_size "$CAND_OUT")" "$CAND_DONE"
echo

if [[ $CAND_STATUS -ne 0 ]]; then
  echo "FAIL: candidate exited $CAND_STATUS despite producing [done]"
  failures=$((failures + 1))
fi

echo "=== parity ==="
SELF_PSNR="$(psnr_average "$BASE_A_OUT" "$BASE_B_OUT" "baseline-self")"
echo "baseline vs baseline PSNR average: $SELF_PSNR"
if [[ "$SELF_PSNR" != "inf" ]]; then
  echo "FAIL: baseline encoder is nondeterministic; not trusting candidate PSNR"
  failures=$((failures + 1))
fi

CAND_PSNR="$(psnr_average "$BASE_A_OUT" "$CAND_OUT" "candidate")"
echo "baseline vs candidate PSNR average: $CAND_PSNR"
if [[ "$SELF_PSNR" == "inf" && "$CAND_PSNR" != "inf" ]]; then
  echo "FAIL: candidate output is not bit-identical to baseline"
  failures=$((failures + 1))
fi

for at in $PROBES; do
  base_png="$WORKDIR/frame-baseline-$at.png"
  cand_png="$WORKDIR/frame-candidate-$at.png"
  run_frame_probe "baseline" "$BASELINE_BIN" "$at" "$base_png"
  run_frame_probe "candidate" "$CANDIDATE_BIN" "$at" "$cand_png"
  base_md5="$(md5_file "$base_png")"
  cand_md5="$(md5_file "$cand_png")"
  if [[ "$base_md5" == "$cand_md5" ]]; then
    echo "frame ${at}s MD5: PASS $base_md5"
  else
    echo "frame ${at}s MD5: FAIL baseline=$base_md5 candidate=$cand_md5"
    failures=$((failures + 1))
  fi
done
echo

if [[ $failures -eq 0 ]]; then
  echo "PASS: benchmark parity gate succeeded"
else
  echo "FAIL: benchmark parity gate found $failures issue(s)"
  exit 1
fi
