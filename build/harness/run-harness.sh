#!/bin/sh
# Behavioural harness for the standalone VSB build (PERFORMANCE.md Phase 0).
#
# Boots FreeDOS in QEMU, installs the rebuilt VSB (Covox mode), and plays
# sbemu/sample through the emulated SoundBlaster DSP+DMA using the author's
# own test tool sbemu/sbdma.exe. Every guest OUT to the LPT data port is
# captured via an isa-debugcon device at 0x378; check.py then requires the
# captured stream to reproduce the sample byte-for-byte and the VSB banner
# plus the virtual-IRQ5 diagnostics to appear on the DOS screen.
#
# Usage: build/harness/run-harness.sh   (needs qemu-system-i386, mtools)
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HARN="$ROOT/build/harness"
OUT="$ROOT/build/out/harness"
CACHE="$ROOT/build/toolchain"
FDIMG_SHA="167e6f72697d817fabac9b4fed37356bee712189f68ee892e341f43a847c58c6"

command -v qemu-system-i386 >/dev/null || { echo "need qemu-system-i386"; exit 1; }
command -v mcopy >/dev/null || { echo "need mtools"; exit 1; }
[ -f "$ROOT/build/out/vsb_real.com" ] || "$ROOT/build/build.sh"

mkdir -p "$OUT" "$CACHE"

# FreeDOS boot media (beta9 floppy, cached, sha256-pinned)
if ! echo "$FDIMG_SHA  $CACHE/fdos1440.img" | sha256sum -c - >/dev/null 2>&1; then
    for base in "https://archive.org/download/freedos_20220209" \
                "https://dn720001.ca.archive.org/0/items/freedos_20220209"; do
        curl -sSL --retry 3 -o "$CACHE/fdos1440.img" "$base/fdos1440.img" || continue
        echo "$FDIMG_SHA  $CACHE/fdos1440.img" | sha256sum -c - && break
    done
    echo "$FDIMG_SHA  $CACHE/fdos1440.img" | sha256sum -c -
fi

# Build the harness floppy: FreeDOS kernel+shell from the inner boot image,
# minimal config, BDA-LPT1 poke (debugcon is invisible to the BIOS probe),
# rebuilt VSB, the author's DMA test tool, and the reference sample.
mcopy -n -i "$CACHE/fdos1440.img" ::/FDBOOT.IMG "$OUT/fdboot.img"
mcopy -n -i "$OUT/fdboot.img" ::/KERNEL.SYS "$OUT/kernel.sys"
mcopy -n -i "$OUT/fdboot.img" ::/command.com "$OUT/command.com"
dd if="$OUT/fdboot.img" of="$OUT/bootsect.bin" bs=512 count=1 2>/dev/null
rm -f "$OUT/harness.img"
mformat -i "$OUT/harness.img" -C -f 1440 -B "$OUT/bootsect.bin" -v FREEDOS ::
# SETLPT.COM: mov ax,0040 / mov ds,ax / mov word [0008],0378 / ret
printf '\270\100\000\216\330\307\006\010\000\170\003\303' > "$OUT/setlpt.com"
printf 'FILES=20\r\nBUFFERS=20\r\nSHELL=A:\\COMMAND.COM A:\\ /P\r\n' > "$OUT/fdconfig.sys"
printf '@echo off\r\nSETLPT\r\nVSB /L1\r\nSBDMA\r\n' > "$OUT/autoexec.bat"
mcopy -i "$OUT/harness.img" "$OUT/kernel.sys" ::/KERNEL.SYS
mcopy -i "$OUT/harness.img" "$OUT/command.com" ::/COMMAND.COM
mcopy -i "$OUT/harness.img" "$OUT/fdconfig.sys" ::/FDCONFIG.SYS
mcopy -i "$OUT/harness.img" "$OUT/autoexec.bat" ::/AUTOEXEC.BAT
mcopy -i "$OUT/harness.img" "$OUT/setlpt.com" ::/SETLPT.COM
mcopy -i "$OUT/harness.img" "$ROOT/build/out/vsb_real.com" ::/VSB.COM
mcopy -i "$OUT/harness.img" "$ROOT/sbemu/sbdma.exe" ::/SBDMA.EXE
mcopy -i "$OUT/harness.img" "$ROOT/sbemu/sample" ::/SAMPLE

rm -f "$OUT/lpt.bin"
qemu-system-i386 -machine pc -cpu 486 -m 16 \
    -drive file="$OUT/harness.img",if=floppy,format=raw -boot a \
    -display none -parallel none \
    -chardev file,id=lpt,path="$OUT/lpt.bin" \
    -device isa-debugcon,iobase=0x378,chardev=lpt \
    -monitor unix:"$OUT/mon.sock",server,nowait &
QPID=$!
trap 'kill $QPID 2>/dev/null' EXIT

python3 "$HARN/check.py" "$OUT" "$ROOT/sbemu/sample"
