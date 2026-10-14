#!/bin/bash
# Ideal Video Encoder for macOS - prerequisite setup
# https://github.com/alex-mcdermott/Ideal-Video-Encoder
# Copyright (C) 2026 the Ideal Video Encoder contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Installs what the app needs with Homebrew: ffmpeg (with libx265, libsvtav1, lut3d, lutyuv, libvmaf) and
# exiftool. Homebrew's standard ffmpeg has all of these. zscale is optional: the app uses it when present (as
# the Windows version does) and FFmpeg's built-in scale filter otherwise. Idempotent: tools that are present
# and complete are left alone. Never installs Homebrew itself.
#
# Usage: install-prerequisites.sh [--check-only]
# Exit codes: 0 everything required is present; 1 something is still missing;
#             2 Homebrew is missing; 3 an ffmpeg not managed by Homebrew lacks components.
#
# Environment (for the app and for tests):
#   IVE_FFMPEG, IVE_FFPROBE, IVE_EXIFTOOL  explicit tool paths (the app's overrides)
#   IVE_SEARCH_PATH                        folders to search instead of /opt/homebrew/bin:/usr/local/bin:$PATH
#   IVE_BREW                               brew executable to use

set -u

CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 64 ;;
  esac
done

REQUIRED_ENCODERS="libx265 libsvtav1"
REQUIRED_FILTERS="lut3d lutyuv libvmaf"
TAP="homebrew-ffmpeg/ffmpeg"
TAP_FORMULA="homebrew-ffmpeg/ffmpeg/ffmpeg"
TAP_OPTIONS="--with-zimg --with-libvmaf"
SEARCH_PATH="${IVE_SEARCH_PATH:-/opt/homebrew/bin:/usr/local/bin:${PATH:-}}"

say()  { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }

# find_tool NAME OVERRIDE -> prints the path, or nothing
find_tool() {
  local name=$1 override=$2 dir
  if [ -n "$override" ]; then
    [ -x "$override" ] && printf '%s\n' "$override"
    return
  fi
  local IFS=:
  for dir in $SEARCH_PATH; do
    [ -n "$dir" ] && [ -x "$dir/$name" ] && { printf '%s\n' "$dir/$name"; return; }
  done
}

find_brew() {
  if [ -n "${IVE_BREW:-}" ]; then [ -x "$IVE_BREW" ] && printf '%s\n' "$IVE_BREW"; return; fi
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do [ -x "$b" ] && { printf '%s\n' "$b"; return; }; done
  command -v brew 2>/dev/null
}

FFMPEG= FFPROBE= EXIFTOOL= MISSING_COMPONENTS=
check() {
  FFMPEG=$(find_tool ffmpeg "${IVE_FFMPEG:-}")
  FFPROBE=$(find_tool ffprobe "${IVE_FFPROBE:-}")
  EXIFTOOL=$(find_tool exiftool "${IVE_EXIFTOOL:-}")
  MISSING_COMPONENTS= HAS_ZSCALE=
  if [ -n "$FFMPEG" ]; then
    local enc fil n
    # Names are the second column after the "------" separator line
    enc=$("$FFMPEG" -hide_banner -encoders 2>/dev/null | awk 'p{print $2} /^ *------/{p=1}')
    fil=$("$FFMPEG" -hide_banner -filters 2>/dev/null | awk 'p{print $2} /^ *------/{p=1}')
    for n in $REQUIRED_ENCODERS; do printf '%s\n' "$enc" | grep -qx "$n" || MISSING_COMPONENTS="$MISSING_COMPONENTS $n"; done
    for n in $REQUIRED_FILTERS;  do printf '%s\n' "$fil" | grep -qx "$n" || MISSING_COMPONENTS="$MISSING_COMPONENTS $n"; done
    MISSING_COMPONENTS=${MISSING_COMPONENTS# }
    printf '%s\n' "$fil" | grep -qx zscale && HAS_ZSCALE=1
  fi
}

report() {
  say "ffmpeg:   ${FFMPEG:-MISSING}"
  say "ffprobe:  ${FFPROBE:-MISSING}"
  say "exiftool: ${EXIFTOOL:-MISSING}"
  if [ -n "$FFMPEG" ]; then
    if [ -n "$MISSING_COMPONENTS" ]; then say "ffmpeg components missing: $MISSING_COMPONENTS"
    else say "ffmpeg components: all present ($REQUIRED_ENCODERS $REQUIRED_FILTERS)"; fi
    if [ -n "$HAS_ZSCALE" ]; then say "zscale:   present (full-range clips are converted as on Windows)"
    else say "zscale:   not present (optional; full-range clips use FFmpeg's built-in scale filter)"; fi
  fi
}

complete() { [ -n "$FFMPEG" ] && [ -n "$FFPROBE" ] && [ -n "$EXIFTOOL" ] && [ -z "$MISSING_COMPONENTS" ]; }

step "Checking tools"
check
report
if complete; then say ""; say "Everything Ideal Video Encoder needs is installed."; exit 0; fi
if [ "$CHECK_ONLY" = 1 ]; then say ""; say "Some prerequisites are missing. Run without --check-only to install them."; exit 1; fi

BREW=$(find_brew)
if [ -z "$BREW" ]; then
  say ""
  say "Homebrew is not installed. This script does not install it for you."
  say "Install Homebrew with the official command from https://brew.sh :"
  say ""
  say '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  say ""
  say "Then run this script again."
  exit 2
fi
say "Homebrew: $BREW"
# NO_AUTOREMOVE: replacing ffmpeg must not uninstall and reinstall the libraries it uses
export HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_AUTOREMOVE=1 NONINTERACTIVE=1

if [ -z "$EXIFTOOL" ]; then
  step "Installing exiftool"
  "$BREW" install exiftool || say "brew install exiftool failed."
fi

# ffmpeg: Homebrew's standard bottle has everything required. Only if an ffmpeg Homebrew manages lacks a
# required component is it replaced with the homebrew-ffmpeg tap build, which compiles from source.
brew_owns_ffmpeg() {
  [ -z "$FFMPEG" ] && return 0
  local prefix; prefix=$("$BREW" --prefix 2>/dev/null)
  case "$FFMPEG" in "$prefix"/*) return 0 ;; esac
  return 1
}

if [ -z "$FFMPEG" ] || [ -z "$FFPROBE" ]; then
  step "Installing ffmpeg"
  "$BREW" install ffmpeg || say "brew install ffmpeg failed."
  check
fi

if [ -n "$FFMPEG" ] && [ -n "$MISSING_COMPONENTS" ]; then
  if ! brew_owns_ffmpeg; then
    say ""
    say "The ffmpeg at $FFMPEG is not managed by Homebrew and lacks: ${MISSING_COMPONENTS:-ffprobe}."
    say "Leaving it alone. Either remove it from PATH and run this script again, or point the app's"
    say "tool settings at a complete ffmpeg."
    exit 3
  fi
  step "Installing ffmpeg with all components"
  say "This ffmpeg lacks: $MISSING_COMPONENTS."
  say "Installing the $TAP tap build ($TAP_OPTIONS). It compiles from source; this can take 10-30 minutes."
  if "$BREW" list --formula ffmpeg >/dev/null 2>&1; then
    # Other formulae may depend on ffmpeg; the tap build provides the same libraries
    "$BREW" uninstall --ignore-dependencies ffmpeg || say "Could not uninstall Homebrew's ffmpeg."
  fi
  "$BREW" tap "$TAP" || say "brew tap $TAP failed."
  # shellcheck disable=SC2086
  "$BREW" install "$TAP_FORMULA" $TAP_OPTIONS || say "brew install $TAP_FORMULA failed."
fi

step "Checking again"
check
report
if complete; then say ""; say "Everything Ideal Video Encoder needs is installed."; exit 0; fi
say ""
say "Some prerequisites are still missing (see above)."
exit 1
