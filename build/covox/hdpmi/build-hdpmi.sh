#!/bin/sh
# Native-Linux build of HDPMI32i.EXE (crazii/HX fork) — replicates
# Src/HDPMI/HDPMI32I.MAK with:
#   - JWasm  (Baron-von-Riedesel/JWasm,  make -f GccUnix.mak) instead of jwasm.exe
#   - JWlink (Baron-von-Riedesel/JWlink, make -f GccUnix.mak) instead of jwlink.exe
#   - setmzhdr.py (below) instead of SetMZHdr.exe (Src/SHRMZHDR/SETMZHDR.ASM:
#     set e_sp=200h if zero, e_minalloc from it, and shrink e_cp/e_cblp so DOS
#     loads only the 16-bit part — the 32-bit segments are pulled up by INIT).
# The librarian step (jwlib) is skipped: all objects are passed to jwlink
# directly in modules.inc order, hdpmi.obj first, same as the .mak's link set.
#
# Usage: build-hdpmi.sh <HX-src dir> <jwasm> <jwlink> <outdir>
set -e
HX="$1"; JWASM="$2"; JWLINK="$3"; OUT="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

# Stage sources on the case-sensitive host FS: the DOS-era sources `include`
# lowercase names while the files are uppercase. Alias every source/include
# to lowercase in a flat staging dir (includes resolve from the source dir).
SRC="$OUT/stage"
rm -rf "$SRC"; mkdir -p "$SRC"
for f in "$HX/Src/HDPMI"/*.ASM "$HX/Src/HDPMI"/*.INC "$HX/Include"/*.*; do
    b="$(basename "$f")"
    cp "$f" "$SRC/$b"
    lc="$(printf %s "$b" | tr 'A-Z' 'a-z')"
    [ "$lc" != "$b" ] && ln -sf "$b" "$SRC/$lc"
done

# AOPT from HDPMI32I.MAK (-Zi/-Fl dropped; -q quiet)
AOPT="-q -c -Cp -Sg -D?32BIT=1 -D?PMIOPL=0 -D?VIODIROUT=1 -D?COVOXR0=1 -I$SRC"

printf 'format DOS\nname %s\noption quiet, map=%s, stack=0\n' \
    "$OUT/HDPMI32i.EXE" "$OUT/HDPMI32i.MAP" > "$OUT/link.lnk"
for m in HDPMI A20GATE CLIENTS EXCEPT HEAP HELPERS I2FHDPMI I31DEB I31DOS \
         I31FPU I31INT I31MEM I31SEL I31SWT INIT INT13API INT21API INT2FAPI \
         INT2XAPI INT31API INT33API INT41API INTXXAPI MOVEHIGH PAGEMGR \
         PUTCHR PUTCHRR SWITCH VXD; do
    "$JWASM" $AOPT -Fo"$OUT/$m.OBJ" "$SRC/$m.ASM"
    printf 'file %s\n' "$OUT/$m.OBJ" >> "$OUT/link.lnk"
done

"$JWLINK" @"$OUT/link.lnk"

python3 "$HERE/setmzhdr.py" "$OUT/HDPMI32i.EXE"
ls -l "$OUT/HDPMI32i.EXE"
