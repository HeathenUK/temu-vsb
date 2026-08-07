#!/bin/sh
# SBEMU+Covox real-mode producer test: sbdma plays sbemu/sample through the
# emulated SB DSP+DMA under HDPMI; SBEMU's Covox backend outputs PCM to LPT.
# LPT (0x378) captured to lpt.bin; SBEMU internal _LOG trace on COM1 -> com1.log.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
rm -f lpt.bin com1.log
timeout 90 qemu-system-i386 -machine pc -cpu 486 -m 16 \
    -drive file=boot.img,if=floppy,format=raw \
    -drive file=hdd.img,format=raw \
    -boot a -display none -parallel none \
    -chardev file,id=lpt,path=lpt.bin \
    -device isa-debugcon,iobase=0x378,chardev=lpt \
    -serial file:com1.log \
    -monitor unix:mon.sock,server,nowait || true
echo "=== lpt.bin size ==="; wc -c < lpt.bin
echo "=== com1.log (last 60 lines) ==="; tail -60 com1.log 2>/dev/null
