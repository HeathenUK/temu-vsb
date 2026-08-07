#!/bin/sh
# Reproducible build of the COVOXR0 HDPMI32i host:
#   1. clone crazii/HX at the pinned commit (HX_COMMIT)
#   2. apply hx-covoxr0.patch (the ring-0 Covox fast path)
#   3. build JWasm + JWlink natively (both build with plain gcc)
#   4. assemble/link via build-hdpmi.sh -> $WORK/hdpmi-build/HDPMI32i.EXE
# Usage: fetch-and-build.sh [workdir]   (default: build/covox/work/hdpmi)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-$HERE/../work/hdpmi}"
COMMIT="$(cat "$HERE/HX_COMMIT")"
mkdir -p "$WORK"
cd "$WORK"

if [ ! -d HX ]; then
    git clone https://github.com/crazii/HX.git HX
fi
cd HX
git fetch origin "$COMMIT" 2>/dev/null || git fetch origin
git checkout -q "$COMMIT"
git checkout -q -- . && git clean -qfd Src/HDPMI 2>/dev/null || true
git apply "$HERE/hx-covoxr0.patch"
cd ..

if [ ! -x JWasm/build/GccUnixR/jwasm ]; then
    [ -d JWasm ] || git clone --depth 5 https://github.com/Baron-von-Riedesel/JWasm.git JWasm
    (cd JWasm && make -f GccUnix.mak)
fi
if [ ! -x JWlink/build/jwlinkLR/jwlink ]; then
    [ -d JWlink ] || git clone --depth 5 https://github.com/Baron-von-Riedesel/JWlink.git JWlink
    (cd JWlink && make -f GccUnix.mak)
fi

sh "$HERE/build-hdpmi.sh" "$WORK/HX" \
    "$WORK/JWasm/build/GccUnixR/jwasm" \
    "$WORK/JWlink/build/jwlinkLR/jwlink" \
    "$WORK/hdpmi-build"
