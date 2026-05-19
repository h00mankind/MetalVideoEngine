#!/usr/bin/env bash
# Head-to-head: research/recap-metal vs. the production ffmpeg path
# (videotoolbox decode + cpu scale/pad + videotoolbox encode).
#
# Both engines do: decode H.264 → scale + letterbox to 1080×1920 → encode
# H.264 @ 10 Mbps. Video only, no audio, no subtitles, no overlays. This
# isolates the GPU-pipeline win from features the production path has
# that this prototype doesn't.

set -euo pipefail
IN="${1:?usage: bench.sh <input.mp4>}"

ROOT="$(cd "$(dirname "$0")" && pwd)"
METAL="$ROOT/.build/release/recap-metal"
FFMPEG="${FFMPEG_BIN:-ffmpeg}"

OUT_METAL=/tmp/bench-metal.mp4
OUT_FFMPEG=/tmp/bench-ffmpeg.mp4
rm -f "$OUT_METAL" "$OUT_FFMPEG"

if [ ! -x "$METAL" ]; then
  echo "build first:  cd research && swift build -c release"
  exit 1
fi

echo "=== source ==="
"${FFPROBE_BIN:-ffprobe}" -v error -show_entries stream=width,height,r_frame_rate,duration \
  -of default=noprint_wrappers=1 "$IN"
echo

echo "=== recap-metal (Metal end-to-end) ==="
T0=$(date +%s.%N)
"$METAL" render --in "$IN" --out "$OUT_METAL" --preset 1080p 2>&1 | tail -1
T1=$(date +%s.%N)
METAL_T=$(echo "$T1 - $T0" | bc -l)
echo "wall: ${METAL_T}s   out: $(stat -f%z "$OUT_METAL") bytes"
echo

echo "=== ffmpeg + videotoolbox (production path equivalent) ==="
T0=$(date +%s.%N)
"$FFMPEG" -y -hide_banner -loglevel error \
  -hwaccel videotoolbox -hwaccel_output_format nv12 \
  -i "$IN" \
  -filter_complex "[0:v]scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1[vout]" \
  -map "[vout]" -an \
  -c:v h264_videotoolbox -b:v 10M -realtime 1 -prio_speed 1 \
  -pix_fmt yuv420p -movflags +faststart \
  "$OUT_FFMPEG"
T1=$(date +%s.%N)
FFMPEG_T=$(echo "$T1 - $T0" | bc -l)
echo "wall: ${FFMPEG_T}s   out: $(stat -f%z "$OUT_FFMPEG") bytes"
echo

echo "=== speedup ==="
python3 -c "m=$METAL_T; f=$FFMPEG_T; print(f'recap-metal is {f/m:.2f}x faster than the ffmpeg path' if m<f else f'ffmpeg path is {m/f:.2f}x faster than recap-metal')"
