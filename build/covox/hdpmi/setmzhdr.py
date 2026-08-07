#!/usr/bin/env python3
"""SetMZHdr.exe replacement (HX Src/SHRMZHDR/SETMZHDR.ASM, faithfully):
1. if e_sp == 0: e_sp = 0x200; e_minalloc = ceil(e_sp/16)
2. shrink the load image to the 16-bit part only: pages = (e_ss + e_cparhdr)
   paragraphs -> e_cp = ceil(paras/32), e_cblp = (paras%32)*16
"""
import struct, sys

path = sys.argv[1]
with open(path, 'r+b') as f:
    hdr = bytearray(f.read(0x20))
    (magic, cblp, cp, crlc, cparhdr, minalloc, maxalloc, ss, sp) = \
        struct.unpack_from('<9H', hdr, 0)
    assert magic == 0x5A4D, 'not MZ'
    if sp == 0:
        sp = 0x200
        struct.pack_into('<H', hdr, 16, sp)
        struct.pack_into('<H', hdr, 10, (sp >> 4) + (1 if sp & 0xF else 0))
        print('setmzhdr: SP set to 200h')
    if ss == 0:
        sys.exit('setmzhdr: field SS in header is ZERO.')
    paras = ss + cparhdr
    cp = paras >> 5
    rem = paras & 0x1F
    if rem:
        cp += 1
    struct.pack_into('<H', hdr, 4, cp)
    struct.pack_into('<H', hdr, 2, rem << 4)
    f.seek(0)
    f.write(hdr)
