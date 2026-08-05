#!/bin/sh
# Reproducible build of the standalone VSB binary (sbemu/vsb_real.com) on a
# modern Linux host: TASM 4.1 under headless DOSBox for assembly, then
# build/omf2com.py in place of TLINK /t. See build/README.md.
#
# Usage:  build/fetch-toolchain.sh   (once)
#         build/build.sh            -> build/out/vsb_real.com (+ verify report)
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
OUT="$BUILD/out"
STAGE="$OUT/stage"

command -v dosbox >/dev/null || { echo "dosbox not found (apt-get install dosbox)"; exit 1; }
[ -f "$BUILD/toolchain/TASM.EXE" ] || { echo "run build/fetch-toolchain.sh first"; exit 1; }

rm -rf "$STAGE"
mkdir -p "$STAGE/SRC/SBEMU" "$STAGE/TOOLS"
cp "$BUILD/toolchain/TASM.EXE" "$STAGE/TOOLS/"

# Stage sources: repo worktree is IBM437-encoded (.gitattributes) with LF line
# endings; DOS tools want CRLF. Filenames are upcased for 8.3 friendliness.
python3 - "$ROOT" "$STAGE" <<'EOF'
import pathlib, sys
root, stage = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
def cp(src, dst):
    data = src.read_bytes().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
    dst.write_bytes(data)
for f in root.glob('386*.asm'):
    cp(f, stage/'SRC'/f.name.upper())
for n in ['vsb_real.asm', 's386port.asm', 's386data.asm', 'vsb.asm', 'vsb_qemm.asm']:
    cp(root/'sbemu'/n, stage/'SRC'/'SBEMU'/n.upper())
EOF

# /m3: three optimizer passes -- documented closest match to the 1995 binary.
cat > "$OUT/dosbox.conf" <<EOF
[dosbox]
memsize=16
[dos]
ems=false
[autoexec]
mount c $STAGE
c:
PATH C:\\TOOLS
cd \\SRC\\SBEMU
TASM /m3 VSB_REAL.ASM > TASMOUT.TXT
exit
EOF

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy dosbox -conf "$OUT/dosbox.conf" -noconsole >/dev/null 2>&1 || true
tr -d '\r' < "$STAGE/SRC/SBEMU/TASMOUT.TXT" || { echo "TASM did not run"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMOUT.TXT" || { echo "assembly failed"; exit 1; }

python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/VSB_REAL.OBJ" "$OUT/vsb_real.com" 0x100 add
python3 "$BUILD/verify.py" "$ROOT/sbemu/vsb_real.com" "$OUT/vsb_real.com"
