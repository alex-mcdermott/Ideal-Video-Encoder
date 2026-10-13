#!/bin/bash
# Ideal Video Encoder for macOS - end-to-end UI checks through the accessibility API
# Copyright (C) 2026 the Ideal Video Encoder contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Drives the built Debug app with Tests/UI/axdo (needs Accessibility permission for the terminal/editor running
# it, and Screen Recording for the screenshots). Everything happens in a temporary folder with synthetic clips
# and a separate settings file; nothing outside it is read or written.
# Usage: Tests/UI/e2e.sh [--with-mouse] [app path]
#   --with-mouse  also test drag and drop and the Add Clips panel (moves the pointer and types keystrokes)
set -u
cd "$(dirname "$0")/../.."
MOUSE=0; [ "${1:-}" = --with-mouse ] && { MOUSE=1; shift; }
APP=${1:-"$PWD/build/dd/Build/Products/Debug/Ideal Video Encoder.app"}
BIN="$APP/Contents/MacOS/Ideal Video Encoder"
mkdir -p build/tools
[ build/tools/axdo -nt Tests/UI/axdo.swift ] || swiftc -O Tests/UI/axdo.swift -o build/tools/axdo
[ build/tools/dragdrop -nt Tests/UI/dragdrop.swift ] || swiftc -O Tests/UI/dragdrop.swift -o build/tools/dragdrop
W=$(mktemp -d "${TMPDIR:-/tmp}/ive-e2e.XXXXXX")
W=$(printf '%s' "$W" | tr -s /)   # $TMPDIR ends in "/"; the app shows normalised paths
SHOTS="$W/screenshots"; mkdir -p "$SHOTS" "$W/clips/Card A" "$W/clips/Card B" "$W/out"
SETTINGS="$W/settings.json"
PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

clip() { ffmpeg -v error -y -f lavfi -i "$1=s=$2:r=30" -t "$3" -c:v libx265 -preset ultrafast -x265-params log-level=error \
  -pix_fmt yuv422p10le -color_range tv -colorspace bt709 -color_primaries bt709 -color_trc bt709 -tag:v hvc1 "$4"; }
clip testsrc2 1280x720 2 "$W/clips/Card A/A001.MOV"
clip mandelbrot 1280x720 2 "$W/clips/Card A/A002.MOV"
clip testsrc2 1920x1080 30 "$W/clips/Card B/B001_long.MOV"

PID=
launch() {
  pkill -f "$BIN" 2>/dev/null; sleep 1
  open -n -a "$APP" --env IVE_SETTINGS_PATH="$SETTINGS" "$@" --args -DismissedSetupProblems "FFmpeg lacks zscale"
  for _ in $(seq 1 50); do PID=$(pgrep -f "$BIN" | head -1); [ -n "$PID" ] && build/tools/axdo "$PID" exists Start && break; sleep 0.2; done
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $PID) to true" >/dev/null
  sleep 0.5
}
ax() { build/tools/axdo "$PID" "$@"; }
shot() { local id; id=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
if let w = l.first(where: { ($0[kCGWindowOwnerPID as String] as? Int) == Int(CommandLine.arguments[1]) && ($0[kCGWindowName as String] as? String ?? "").hasPrefix("Ideal") }) { print(w[kCGWindowNumber as String]!) }' "$PID" 2>/dev/null)
  [ -n "$id" ] && screencapture -o -l "$id" "$SHOTS/$1.png"; }
status() { ax get Status; }
waitfor() { for _ in $(seq 1 "${2:-300}"); do [ "$(status)" = "$1" ] && return 0; sleep 0.5; done; return 1; }

echo "== launch with two clips (Finder 'Open With' path)"
launch "$W/clips/Card A/A001.MOV" "$W/clips/Card A/A002.MOV"
check "two clips queued" test "$(ax dump | grep -c 'MOV, Queued')" = 2
shot 01-launch

echo "== 'Saves to' follows the output settings"
S1=$(ax get "Saves to")
check "next to source: <clip folder>/From FFmpeg/A001.MOV" test "$S1" = "$W/clips/Card A/From FFmpeg/A001.MOV"
ax press "Custom folder"; sleep 0.3; ax set "Output folder" "$W/out"; ax set Subfolder "graded/day 1"; sleep 0.4
check "custom folder + nested subfolder" test "$(ax get 'Saves to')" = "$W/out/graded/day 1/A001.MOV"
ax press Codec; sleep 0.3; ax menu "AV1 (SVT-AV1)"; sleep 0.4
check "AV1 switches the extension to .MP4" test "$(ax get 'Saves to')" = "$W/out/graded/day 1/A001.MP4"
ax set Subfolder "bad:name"; sleep 0.4
check "invalid subfolder is flagged" ax exists "Problem: Subfolder 'bad:name' is not a valid folder name."
ax set Subfolder ""; sleep 1
check "empty subfolder saves directly in the folder" test "$(ax get 'Saves to')" = "$W/out/A001.MP4"

echo "== each codec keeps its own CRF"
ax set "Quality (CRF)" 33; sleep 0.3
ax press Codec; sleep 0.3; ax menu "HEVC (x265)"; sleep 0.3; H=$(ax get "Quality (CRF)")
ax set "Quality (CRF)" 19; sleep 0.3
ax press Codec; sleep 0.3; ax menu "AV1 (SVT-AV1)"; sleep 0.3; A=$(ax get "Quality (CRF)")
ax press Codec; sleep 0.3; ax menu "HEVC (x265)"; sleep 0.3; H2=$(ax get "Quality (CRF)")
check "HEVC default 21 after AV1 was set to 33 (got $H)" test "$H" = 21
check "AV1 kept 33 (got $A)" test "$A" = 33
check "HEVC kept 19 (got $H2)" test "$H2" = 19
shot 02-output-and-crf

echo "== settings survive quitting and relaunching"
sleep 1; ax key 12 cmd; sleep 2
check "app quit with Cmd-Q" bash -c "! pgrep -f '$BIN' >/dev/null"
launch
check "codec, CRF and folder restored" bash -c "[ \"\$(build/tools/axdo $PID get Codec)\" = 'HEVC (x265)' ] && [ \"\$(build/tools/axdo $PID get 'Quality (CRF)')\" = 19 ] && [ \"\$(build/tools/axdo $PID get 'Output folder')\" = '$W/out' ]"
check "settings file uses the Windows keys" python3 -c "import json,sys; d=json.load(open('$SETTINGS')); sys.exit(0 if d['CrfHevc']=='19' and d['CrfAv1']=='33' and d['OutputMode']=='custom' and d['Subfolder']=='' else 1)"

echo "== Remove and Clear really empty the queue"
launch "$W/clips/Card A/A001.MOV" "$W/clips/Card A/A002.MOV" "$W/clips/Card B/B001_long.MOV"
ax select-row 1; ax key 51; sleep 0.4   # Delete key
check "Delete removed A002" bash -c "! build/tools/axdo $PID dump | grep -q 'A002.MOV, '"
ax set "Trim end" 0.5; ax select-row 0; ax press Start
waitfor Finished 120 || true
check "next Start encodes only the remaining clips" bash -c "[ -f '$W/out/A001.MOV' ] && [ -f '$W/out/B001_long.MOV' ] && [ ! -e '$W/out/A002.MOV' ]"
ax press Clear; sleep 0.4
check "Clear emptied the queue" bash -c "! build/tools/axdo $PID dump | grep -q 'MOV, '"
rm -f "$W/out/"*.MOV
ax press Start; sleep 1
check "Start with an empty queue warns and encodes nothing" bash -c "build/tools/axdo $PID exists 'Add some clips first.' && [ -z \"\$(ls '$W/out')\" ]"
ax key 36; sleep 0.3
ax set "Trim end" ""

echo "== schedule, then Start now"
launch "$W/clips/Card A/A001.MOV"
ax press "Start, When to start"; sleep 0.3; ax menu "Later at"; sleep 0.3; ax set "Start time" "4:00"; sleep 0.3
ax press Start; sleep 1
check "scheduled (status shows 'Scheduled for')" bash -c "build/tools/axdo $PID get Status | grep -q '^Scheduled for '"
check "countdown shown" bash -c "build/tools/axdo $PID get Time | grep -qE '^Starts in [0-9]+:[0-9]{2}:[0-9]{2}$'"
ax press "Start now"; sleep 1.5
check "Start now starts immediately" bash -c "build/tools/axdo $PID get Status | grep -qE '^(1 of 1|Converting)'"
waitfor Finished 120; shot 03-start-now
ax press "Start, When to start"; sleep 0.3; ax menu "Now"; sleep 0.3

echo "== cancel mid-encode"
launch "$W/clips/Card B/B001_long.MOV"
ax set "Quality (CRF)" 18; ax press Start
for _ in $(seq 1 100); do ax dump | grep -q 'Encoding [1-9]' && break; sleep 0.2; done
PART="$W/out/B001_long.MOV"
check "partial output exists while encoding" test -f "$PART"
check "ffmpeg running" bash -c "pgrep -f -- '$PART' >/dev/null" || ps -Aww -o pid,args | grep '[f]fmpeg' | cut -c1-200
shot 04-encoding
ax key 47 cmd; sleep 2   # Cmd-.
check "ffmpeg gone after Cancel (pgrep)" bash -c "! pgrep -f -- '$PART' >/dev/null"
check "partial output deleted" test ! -e "$PART"
check "clip marked Cancelled" ax exists "B001_long.MOV, Cancelled"
check "summary says cancelled" bash -c "[ \"\$(build/tools/axdo $PID get Status)\" = Finished ] && build/tools/axdo $PID get Time | grep -q 'cancelled'"
check "log says the partial output was removed" bash -c "build/tools/axdo $PID press Log && sleep 0.5 && build/tools/axdo $PID dump | grep -q 'B001_long.MOV: cancelled, partial output removed.'"
ax press "Queue (1)"

echo "== quitting during a run asks first"
ax press Start
for _ in $(seq 1 100); do ax dump | grep -q 'Encoding [1-9]' && break; sleep 0.2; done
ax key 12 cmd; sleep 1
check "quit asks for confirmation" ax exists "A conversion or analysis is running."
shot 05-quit-confirm
ax press "Keep Running"; sleep 1
check "Keep Running keeps encoding" bash -c "pgrep -f -- '$PART' >/dev/null"
ax key 12 cmd; sleep 1; ax press "Stop and Quit"; sleep 3
check "Stop and Quit quits" bash -c "! pgrep -f '$BIN' >/dev/null"
check "... and leaves no ffmpeg or partial file" bash -c "! pgrep -f -- '$PART' >/dev/null && [ ! -e '$PART' ]"

echo "== accessibility: every interactive element in every tab has a name"
launch "$W/clips/Card A/A001.MOV"
for tab in "Queue (1)" Analysis Log; do
  ax press "$tab"; sleep 0.5
  # System-provided parts (window buttons, scroll-bar arrows and pages) are named by macOS itself
  UNNAMED=$(ax dump | grep -E '^\s*(AXButton|AXCheckBox|AXRadioButton|AXPopUpButton|AXTextField|AXSlider|AXMenuButton)[/ ]|^\s*(AXButton|AXCheckBox|AXRadioButton|AXPopUpButton|AXTextField|AXSlider|AXMenuButton)$' \
    | grep -vE 'desc="|title="' | grep -vE '/(AXCloseButton|AXMinimizeButton|AXFullScreenButton|AXZoomButton|AXIncrementArrow|AXDecrementArrow|AXIncrementPage|AXDecrementPage)' || true)
  check "tab '$tab': no unnamed controls" test -z "$UNNAMED"
  [ -n "$UNNAMED" ] && echo "$UNNAMED"
  check "tab '$tab': its contents are in the accessibility tree" bash -c "build/tools/axdo $PID dump | grep -q 'AXTabGroup' && [ \$(build/tools/axdo $PID dump | wc -l) -gt 60 ]"
done
ax press "Queue (1)"

if [ "$MOUSE" = 1 ]; then
  echo "== drag and drop (files, a folder, duplicates) and the Add Clips panel"
  mkdir -p "$W/dnd/sub"; cp "$W/clips/Card A/A001.MOV" "$W/dnd/D001.MOV"; cp "$W/clips/Card A/A002.MOV" "$W/dnd/D002.mp4"
  cp "$W/clips/Card A/A001.MOV" "$W/dnd/sub/NESTED.MOV"; echo text > "$W/dnd/notes.txt"
  launch
  B=$(swift -e 'import CoreGraphics
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in l where (w[kCGWindowOwnerPID as String] as? Int) == Int(CommandLine.arguments[1]) && (w[kCGWindowName as String] as? String ?? "").hasPrefix("Ideal") {
  let b = w[kCGWindowBounds as String] as! [String: Double]; print(Int(b["X"]!), Int(b["Y"]!), Int(b["Width"]!), Int(b["Height"]!)) }' "$PID" 2>/dev/null)
  read -r X Y WW HH <<< "$B"; TX=$((X + WW * 30 / 100)); TY=$((Y + HH * 75 / 100))
  build/tools/dragdrop $TX $TY "$W/clips/Card A/A001.MOV" "$W/clips/Card A/A002.MOV" >/dev/null; sleep 1.5
  check "dropping two files adds both" test "$(ax dump | grep -c 'MOV, Queued')" = 2
  build/tools/dragdrop $TX $TY "$W/dnd" >/dev/null; sleep 1.5
  check "dropping a folder adds its top-level .MOV/.mp4 only" bash -c "build/tools/axdo $PID exists 'D001.MOV, Queued' && build/tools/axdo $PID exists 'D002.mp4, Queued' && ! build/tools/axdo $PID dump | grep -q NESTED"
  build/tools/dragdrop $TX $TY "$W/clips/Card A/A001.MOV" "$W/dnd/notes.txt" >/dev/null; sleep 1.5
  check "duplicates and other files are ignored" test "$(ax dump | grep -cE '\.(MOV|mp4), Queued')" = 4
  ax press "Add Clips…" 2>/dev/null; sleep 2
  osascript -e 'tell application "System Events" to key code 5 using {command down, shift down}'; sleep 1.2
  osascript -e "tell application \"System Events\" to keystroke \"$W/clips/Card B/B001_long.MOV\""; sleep 1
  osascript -e 'tell application "System Events" to key code 36'; sleep 1.2; osascript -e 'tell application "System Events" to key code 36'; sleep 2
  check "Add Clips panel adds the chosen file" ax exists "B001_long.MOV, Queued"
fi

pkill -f "$BIN"
printf '\n%s passed, %s failed. Screenshots: %s\n' "$PASS" "$FAIL" "$SHOTS"
[ "$FAIL" = 0 ]
