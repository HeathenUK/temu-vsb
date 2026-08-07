#!/bin/sh
# Build SBEMU with the Covox/LPT-DAC output backend (build/covox/sc_covox.c).
#
# SBEMU (GPL-2, crazii/SBEMU) is not vendored here; this fetches it at a pinned
# commit, drops in our backend source, applies the small wiring patch
# (au_cards.h link macro, au_cards.c array entry, makefile source list), and
# builds with a pinned DJGPP gcc cross-toolchain. Output: SBEMU.EXE with card
# "CVX" that outputs emulated SB PCM to a parallel-port DAC. FM/music is left to
# SBEMU's real-OPL3 hardware passthrough (this backend never touches it).
#
# See build/harness/covox-backend-plan.md for the staged design.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/work}"
SBEMU_COMMIT="$(cat "$HERE/SBEMU_COMMIT")"
DJGPP_URL="https://github.com/andrewwutw/build-djgpp/releases/download/v3.4/djgpp-linux64-gcc1220.tar.bz2"

mkdir -p "$WORK"
cd "$WORK"

# DJGPP toolchain (cached)
if [ ! -x "$WORK/djgpp/bin/i586-pc-msdosdjgpp-gcc" ]; then
    curl -sSL --retry 3 -o djgpp.tar.bz2 "$DJGPP_URL"
    tar xjf djgpp.tar.bz2
fi
export PATH="$WORK/djgpp/bin:$PATH"

# SBEMU at the pinned commit
if [ ! -d "$WORK/SBEMU" ]; then
    git clone https://github.com/crazii/SBEMU.git SBEMU
fi
cd SBEMU
git fetch --depth 1 origin "$SBEMU_COMMIT" 2>/dev/null || git fetch origin
git checkout -q "$SBEMU_COMMIT"

# Drop in our backend + apply wiring (idempotent: reset tracked files first)
git checkout -- mpxplay/au_cards/au_cards.h mpxplay/au_cards/au_cards.c makefile 2>/dev/null || true
cp "$HERE/sc_covox.c" mpxplay/au_cards/sc_covox.c
git apply "$HERE/sbemu-wiring.patch"

make VERSION=covox 2>&1 | grep -iE "sc_covox|error|LINK|\.exe" || true
echo "built: $WORK/SBEMU/output/sbemu.exe"
ls -l output/sbemu.exe
