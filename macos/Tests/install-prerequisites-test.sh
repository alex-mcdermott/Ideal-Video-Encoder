#!/bin/bash
# Ideal Video Encoder for macOS - tests for install-prerequisites.sh
# Copyright (C) 2026 the Ideal Video Encoder contributors
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Runs the script against a fake Homebrew and fake tools in a temporary folder, so nothing on
# this Mac is installed, upgraded or removed. Usage: Tests/install-prerequisites-test.sh

set -u
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/install-prerequisites.sh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ive-prereq-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASS=0 FAIL=0
ALL="libx265 libsvtav1 zscale lut3d lutyuv libvmaf"
NO_ZSCALE="libx265 libsvtav1 lut3d lutyuv libvmaf"

# A fake ffmpeg whose -encoders/-filters listings contain the names in its sibling .components file
make_ffmpeg() { # dir components...
  local dir=$1; shift
  mkdir -p "$dir"
  printf '%s\n' "$@" > "$dir/ffmpeg.components"
  cat > "$dir/ffmpeg" <<'EOF'
#!/bin/bash
echo "Listing:"; echo " ------"
while read -r n; do echo " V..... $n   fake"; done < "$(dirname "$0")/ffmpeg.components"
EOF
  printf '#!/bin/bash\nexit 0\n' > "$dir/ffprobe"
  chmod +x "$dir/ffmpeg" "$dir/ffprobe"
}
make_exiftool() { mkdir -p "$1"; printf '#!/bin/bash\necho 13.0\n' > "$1/exiftool"; chmod +x "$1/exiftool"; }

# A fake brew that records its arguments and "installs" into $PREFIX/bin (helpers live in $ROOT/helpers.sh)
{ declare -f make_ffmpeg; declare -f make_exiftool; } > "$ROOT/helpers.sh"
make_brew() { # prefix [fail]
  local prefix=$1 fail=${2:-}
  mkdir -p "$prefix/bin"
  cat > "$prefix/bin/brew" <<EOF
#!/bin/bash
. "$ROOT/helpers.sh"
echo "\$*" >> "$prefix/brew.log"
case "\$1" in
  --prefix) echo "$prefix" ;;
  list) [ -f "$prefix/core-ffmpeg" ] ;;
  uninstall) rm -f "$prefix/bin/ffmpeg" "$prefix/bin/ffprobe" "$prefix/core-ffmpeg" ;;
  tap) exit 0 ;;
  install)
    [ "$fail" = fail ] && exit 1
    case "\$2" in
      exiftool) make_exiftool "$prefix/bin" ;;
      homebrew-ffmpeg/ffmpeg/ffmpeg) [ "\$3 \$4" = "--with-zimg --with-libvmaf" ] || exit 1
        make_ffmpeg "$prefix/bin" $ALL ;;
    esac ;;
esac
EOF
  chmod +x "$prefix/bin/brew"
  touch "$prefix/brew.log"
}


# run NAME EXPECTED_EXIT [script args] -- runs with env already exported, captures output
run() {
  local name=$1 want=$2; shift 2
  OUT=$("$SCRIPT" "$@" 2>&1); local got=$?
  if [ "$got" = "$want" ]; then PASS=$((PASS + 1)); printf 'ok   %s (exit %s)\n' "$name" "$got"
  else FAIL=$((FAIL + 1)); printf 'FAIL %s: exit %s, wanted %s\n%s\n' "$name" "$got" "$want" "$OUT"; fi
}
expect() { # NAME CONDITION-DESCRIPTION COMMAND...
  local name=$1; shift
  if "$@"; then PASS=$((PASS + 1)); printf 'ok   %s\n' "$name"; else FAIL=$((FAIL + 1)); printf 'FAIL %s\n%s\n' "$name" "$OUT"; fi
}
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

reset() { unset IVE_FFMPEG IVE_FFPROBE IVE_EXIFTOOL IVE_BREW IVE_SEARCH_PATH; T="$ROOT/$1"; mkdir -p "$T/empty"; }

# 1. Homebrew missing: print the official command, install nothing
reset nobrew
export IVE_SEARCH_PATH="$T/empty" IVE_BREW="$T/no-such-brew"
run "no Homebrew -> exit 2" 2
expect "no Homebrew -> shows official install command" contains "$OUT" 'raw.githubusercontent.com/Homebrew/install/HEAD/install.sh'

# 2. Nothing installed: exiftool from Homebrew, ffmpeg from the tap with the right options
reset fresh
make_brew "$T/brew"
export IVE_SEARCH_PATH="$T/brew/bin" IVE_BREW="$T/brew/bin/brew"
run "fresh -> installs and exits 0" 0
expect "fresh -> brew install exiftool" grep -qx "install exiftool" "$T/brew/brew.log"
expect "fresh -> tap + install with options" grep -qx "install homebrew-ffmpeg/ffmpeg/ffmpeg --with-zimg --with-libvmaf" "$T/brew/brew.log"
expect "fresh -> nothing uninstalled" bash -c "! grep -q uninstall '$T/brew/brew.log'"

# 3. Homebrew core ffmpeg without zscale: replace with the tap build, leave exiftool alone
reset core
make_brew "$T/brew"; make_ffmpeg "$T/brew/bin" $NO_ZSCALE; touch "$T/brew/core-ffmpeg"; make_exiftool "$T/brew/bin"
export IVE_SEARCH_PATH="$T/brew/bin" IVE_BREW="$T/brew/bin/brew"
run "core ffmpeg lacks zscale -> exit 0" 0
expect "core -> explains what is missing" contains "$OUT" "Homebrew's standard ffmpeg lacks: zscale"
expect "core -> uninstall --ignore-dependencies" grep -qx "uninstall --ignore-dependencies ffmpeg" "$T/brew/brew.log"
expect "core -> exiftool not reinstalled" bash -c "! grep -q 'install exiftool' '$T/brew/brew.log'"

# 4. Everything present: no brew calls at all (idempotent)
reset complete
make_brew "$T/brew"; make_ffmpeg "$T/brew/bin" $ALL; make_exiftool "$T/brew/bin"
export IVE_SEARCH_PATH="$T/brew/bin" IVE_BREW="$T/brew/bin/brew"
run "complete -> exit 0" 0
run "complete, --check-only -> exit 0" 0 --check-only
expect "complete -> brew never called" test ! -s "$T/brew/brew.log"

# 5. --check-only with things missing: report, change nothing
reset checkonly
make_brew "$T/brew"; make_ffmpeg "$T/brew/bin" $NO_ZSCALE
export IVE_SEARCH_PATH="$T/brew/bin" IVE_BREW="$T/brew/bin/brew"
run "--check-only, missing -> exit 1" 1 --check-only
expect "--check-only -> lists missing exiftool and zscale" bash -c "printf '%s' \"\$0\" | grep -q 'exiftool: MISSING' && printf '%s' \"\$0\" | grep -q 'components missing: zscale'" "$OUT"
expect "--check-only -> brew never called" test ! -s "$T/brew/brew.log"

# 6. An ffmpeg outside Homebrew that lacks components is left alone
reset foreign
make_brew "$T/brew"; make_ffmpeg "$T/other" $NO_ZSCALE; make_exiftool "$T/other"
export IVE_SEARCH_PATH="$T/other" IVE_BREW="$T/brew/bin/brew"
run "non-Homebrew ffmpeg -> exit 3" 3
expect "non-Homebrew ffmpeg -> not touched" bash -c "! grep -qE 'uninstall|install' '$T/brew/brew.log'"

# 7. The app's explicit tool paths are honoured (hidden from the search path)
reset overrides
make_brew "$T/brew"; make_ffmpeg "$T/custom" $ALL; make_exiftool "$T/custom"
export IVE_SEARCH_PATH="$T/empty" IVE_BREW="$T/brew/bin/brew" IVE_FFMPEG="$T/custom/ffmpeg" IVE_FFPROBE="$T/custom/ffprobe" IVE_EXIFTOOL="$T/custom/exiftool"
run "explicit tool paths -> exit 0" 0

# 8. A failing brew install: exit 1, not 0
reset failing
make_brew "$T/brew" fail
export IVE_SEARCH_PATH="$T/brew/bin" IVE_BREW="$T/brew/bin/brew"
run "brew install fails -> exit 1" 1

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
