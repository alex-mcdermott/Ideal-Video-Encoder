#!/bin/bash
# Ideal Video Encoder for macOS - independent check of an analysis suggestion
# Copyright (C) 2026 the Ideal Video Encoder contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Re-encodes a window of the source at the suggested CRF and cap with plain ffmpeg commands (no app code) and
# scores it with the standalone vmaf tool (libvmaf's CLI), which pairs frames by their position in raw files:
# no timestamps involved, so this doesn't share the app's (or ffmpeg's) frame-pairing logic.
# Usage: verify-suggestion.sh <source> <start s> <length s> <hevc|av1> <crf> <cap Mbps, 0 = none>
set -eu
SRC=$1 START=$2 LEN=$3 CODEC=$4 CRF=$5 CAP=$6
T=$(mktemp -d "${TMPDIR:-/tmp}/ive-verify.XXXXXX"); trap 'rm -rf "$T"' EXIT
W=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of csv=p=0 "$SRC")
H=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of csv=p=0 "$SRC")
# Reference: the window as raw 10-bit 4:2:0 frames (BT.709, as the encoder converts it)
ffmpeg -v error -nostdin -y -ss "$START" -t "$LEN" -i "$SRC" -an -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p10le" -f rawvideo "$T/ref.yuv"
VBV=(); [ "$CAP" != 0 ] && VBV=(-maxrate "${CAP}M" -bufsize "$((CAP * 2))M")
if [ "$CODEC" = av1 ]; then
  P=4; { [ "$W" -gt 4096 ] || [ "$H" -gt 2304 ]; } && P=5
  ENC=(-c:v libsvtav1 -preset $P -crf "$CRF" ${VBV[@]+"${VBV[@]}"} -svtav1-params tune=0)
else
  ENC=(-c:v libx265 -preset slow -crf "$CRF" ${VBV[@]+"${VBV[@]}"} -x265-params "aq-mode=3:aq-strength=1.2:psy-rd=2:psy-rdoq=1:qg-size=16:sao=1:rect=1:amp=1:log-level=error")
fi
ffmpeg -v error -nostdin -y -f rawvideo -pix_fmt yuv420p10le -s "${W}x${H}" -r 30 -i "$T/ref.yuv" "${ENC[@]}" -pix_fmt yuv420p10le "$T/enc.mp4" 2>&1 | grep -v '^Svt\[info\]' || true
ffmpeg -v error -nostdin -y -i "$T/enc.mp4" -f rawvideo -pix_fmt yuv420p10le "$T/dist.yuv"
REF_N=$(( $(stat -f %z "$T/ref.yuv") / (W * H * 3) )); DIST_N=$(( $(stat -f %z "$T/dist.yuv") / (W * H * 3) ))
[ "$REF_N" = "$DIST_N" ] || { echo "frame count mismatch: ref $REF_N, encoded $DIST_N"; exit 1; }
vmaf -r "$T/ref.yuv" -d "$T/dist.yuv" -w "$W" -h "$H" -p 420 -b 10 --threads 8 --json -o "$T/v.json" -q >/dev/null
SIZE=$(stat -f %z "$T/enc.mp4")
python3 - "$T/v.json" "$SIZE" "$LEN" <<'EOF'
import json, sys
f = json.load(open(sys.argv[1]))["frames"]
v = sorted(x["metrics"]["vmaf"] for x in f)
print(f"frames {len(v)}  VMAF {sum(v)/len(v):.2f}  worst 1% {v[int(len(v)*0.01)]:.2f}  bitrate {int(sys.argv[2])*8/float(sys.argv[3])/1e6:.1f} Mbps")
EOF
