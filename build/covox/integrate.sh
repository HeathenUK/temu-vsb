#!/bin/sh
# Build the MINIMAL Covox+OPL3 SBEMU (build/covox/sc_covox.c + the wiring patch).
#
# SBEMU (GPL-2, crazii/SBEMU) is not vendored here; this fetches it at a pinned
# commit, drops in our backend + OPL3-emu stub, applies the wiring/strip patch,
# and builds with a pinned DJGPP gcc cross-toolchain. Output: SBEMU.EXE with
# card "CVX" that outputs emulated SB PCM to a parallel-port DAC.
#
# "Minimal, no bells and whistles irrelevant to Covox+OPL3": the patch trims the
# build to just the LPT-DAC backend (SBEMU_COVOX_ONLY) and drops everything a
# Covox+real-OPL3 machine can't use - all ~24 PCI/ISA card drivers, the DOSBox
# software OPL3 synth (dbopl.cpp/opl3emu.cpp -> opl3emu_stub.c; FM goes straight
# to the real OPL3 via SBEMU's 388h hardware passthrough), and the TinySoundFont
# virtual-MPU (SBEMU_VMPU 0). Release binary: ~233 KB vs ~565 KB stock.
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

# Drop in our sources + apply wiring/strip (idempotent: reset tracked files first)
git checkout -- mpxplay/au_cards/au_cards.h mpxplay/au_cards/au_cards.c makefile \
                main.c sbemu/sbemu.c sbemu/sbemu.h sbemu/sbemucfg.h 2>/dev/null || true
cp "$HERE/sc_covox.c"      mpxplay/au_cards/sc_covox.c
cp "$HERE/opl3emu_stub.c"  sbemu/opl3emu_stub.c
git apply "$HERE/sbemu-wiring.patch"

make VERSION=covox 2>&1 | grep -iE "sc_covox|error|LINK|\.exe" || true
echo "built: $WORK/SBEMU/output/sbemu.exe"
ls -l output/sbemu.exe
