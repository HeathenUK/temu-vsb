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
for n in ['vsb_real.asm', 's386port.asm', 's386data.asm', 's386dpmi.asm', 'vsb.asm', 'vsb_qemm.asm']:
    cp(root/'sbemu'/n, stage/'SRC'/'SBEMU'/n.upper())
cp(root/'build'/'harness'/'testai.asm', stage/'SRC'/'SBEMU'/'TESTAI.ASM')
cp(root/'build'/'harness'/'testperf.asm', stage/'SRC'/'SBEMU'/'TESTPERF.ASM')
cp(root/'build'/'harness'/'testdpmi.asm', stage/'SRC'/'SBEMU'/'TESTDPMI.ASM')
cp(root/'build'/'harness'/'testpm.asm', stage/'SRC'/'SBEMU'/'TESTPM.ASM')
cp(root/'build'/'harness'/'testint31.asm', stage/'SRC'/'SBEMU'/'TESTI31.ASM')
EOF

# /m3: three optimizer passes -- documented closest match to the 1995 binary.
# The DPMI build uses /m1 instead: at /m3 TASM's jump-shrink optimization can
# leave a phantom byte in the OBJ after a short-jumped forward branch (LEDATA
# gets `EB xx 00 <next>` while the listing shows `EB xx <next>`), which our
# omf2com placer can't reconcile against TASM's own label offsets -- the near
# call at the resident/transient boundary then lands one byte early on an iret
# and VSB crashes on load. /m1 does not emit that phantom (verified: 0 vs 1
# occurrences), costs only a few near-vs-short jump bytes (no runtime cost on a
# 386), and is what lifted the ~18 KB "resident ceiling". The shipping
# vsb_real.com stays /m3 so it remains byte-identical to the verified baseline.
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
TASM /m1 /dVSB_DPMI VSB_REAL.ASM VSB_DPMI.OBJ > TASMDPMI.TXT
TASM /m3 TESTAI.ASM > TASMTAI.TXT
TASM /m3 TESTPERF.ASM > TASMTPF.TXT
TASM /m3 TESTDPMI.ASM > TASMTDP.TXT
TASM /m3 TESTPM.ASM > TASMTPM.TXT
TASM /m3 TESTI31.ASM > TASMI31.TXT
TASM /m3 /dTC22 TESTAI,TESTA22 > TASMT22.TXT
TASM /m3 /dTC22 TESTPERF,TESTPF22 > TASMP22.TXT
exit
EOF

SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy dosbox -conf "$OUT/dosbox.conf" -noconsole >/dev/null 2>&1 || true
tr -d '\r' < "$STAGE/SRC/SBEMU/TASMOUT.TXT" || { echo "TASM did not run"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMOUT.TXT" || { echo "assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMDPMI.TXT" || { echo "vsb_dpmi assembly failed"; exit 1; }

grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMTAI.TXT" || { echo "testai assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMTPF.TXT" || { echo "testperf assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMT22.TXT" || { echo "testa22 assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMP22.TXT" || { echo "testpf22 assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMTDP.TXT" || { echo "testdpmi assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMTPM.TXT" || { echo "testpm assembly failed"; exit 1; }
grep -q "Error messages:    None" "$STAGE/SRC/SBEMU/TASMI31.TXT" || { echo "testint31 assembly failed"; exit 1; }
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/VSB_REAL.OBJ" "$OUT/vsb_real.com" 0x100 add
# vsb_dpmi.com: WIP built-in DPMI host build (VSB_DPMI). Not the shipping
# product yet - see build/harness/vsb-dpmi-host-plan.md.
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/VSB_DPMI.OBJ" "$OUT/vsb_dpmi.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTAI.OBJ" "$OUT/testai.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTPERF.OBJ" "$OUT/testperf.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTA22.OBJ" "$OUT/testa22.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTDPMI.OBJ" "$OUT/testdpmi.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTPM.OBJ" "$OUT/testpm.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTI31.OBJ" "$OUT/testint31.com" 0x100 add
python3 "$BUILD/omf2com.py" "$STAGE/SRC/SBEMU/TESTPF22.OBJ" "$OUT/testpf22.com" 0x100 add
# The byte-level gate reproduces the 1995 binary from pristine sources; once
# the Phase 1+ performance changes land, divergence is intended and the
# behavioural harness (build/harness/) is the gate. VSB_VERIFY=strict keeps
# the old hard failure for baseline-reproduction runs.
if python3 "$BUILD/verify.py" "$ROOT/sbemu/vsb_real.com" "$OUT/vsb_real.com"; then
    :
elif [ "$VSB_VERIFY" = "strict" ]; then
    exit 1
else
    echo "note: binary diverges from the 1995 baseline (expected with Phase 1+"
    echo "      changes applied); run build/harness/run-harness.sh to validate."
fi
