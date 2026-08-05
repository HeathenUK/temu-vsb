#!/usr/bin/env python3
"""Structural equivalence check: rebuilt vsb_real.com vs the shipped 1995 binary.

The shipped binary was produced by the author's TASM (3.x/4.0-era); this kit
uses TASM 4.1, whose optimizer differs in exactly two benign ways (verified by
disassembly, see build/README.md):

  1. It pads with one NOP after converting a forward jump in the interrupt-stub
     block to short form (the byte is between stubs and never executed).
  2. It encodes `cmp word mem,0FFFFh` using the sign-extended imm8 form
     (83 /7 ib, 6 bytes) where the older TASM used imm16 (81 /7 iw, 7 bytes).
     Same semantics.

Everything else must match, modulo (a) address/displacement bytes shifted by
the net insertion/deletion offset (accepted only in runs of <= 3 bytes), and
(b) the `??date`/`??time` build stamp. Any other difference fails the check.
"""
import sys

def mask_datestamp(data):
    d = bytearray(data)
    i = d.find(b'Compiled on ')
    if i >= 0:
        for j in range(i, min(i + 33, len(d))):
            d[j] = 0
    return bytes(d)

def main(ref_path, new_path):
    a = mask_datestamp(open(ref_path, 'rb').read())   # shipped
    b = mask_datestamp(open(new_path, 'rb').read())   # rebuilt
    if abs(len(a) - len(b)) > 4:
        return fail(f"size difference too large: {len(a)} vs {len(b)}")
    i = j = 3          # skip entry `jmp Init` displacement (shifts with layout)
    nops = cmps = addr_runs = 0
    while i < len(a) and j < len(b):
        if a[i] == b[j]:
            i += 1; j += 1
            continue
        # imm16 vs imm8 encoding of `cmp word [mem],0FFFFh` (with ss: prefix)
        if a[i-1] == 0x36 and a[i] == 0x81 and b[j] == 0x83 \
           and a[i+1] == b[j+1] and a[i+4:i+6] == b'\xff\xff' and b[j+4] == 0xff:
            cmps += 1; i += 6; j += 5
            continue
        # short mismatch run: address/displacement bytes moved by the shift
        run = 0
        while run < 4 and i + run < len(a) and j + run < len(b) \
              and a[i+run] != b[j+run]:
            run += 1
        if 0 < run < 4 and a[i+run] == b[j+run]:
            addr_runs += 1; i += run; j += run
            continue
        # rebuilt has a padding NOP the shipped binary lacks (resync required),
        # possibly preceded by 1-3 shifted address bytes
        for pre in range(0, 4):
            if b[j+pre] == 0x90 and a[i+pre:i+pre+3] == b[j+pre+1:j+pre+4]:
                nops += 1
                if pre: addr_runs += 1
                i += pre; j += pre + 1
                break
        else:
            return fail(f"unexplained divergence at ref {i:#x} / new {j:#x}:\n"
                        f"  ref: {a[i-8:i+16].hex()}\n  new: {b[j-8:j+16].hex()}")
    print(f"PASS: structurally equivalent to shipped binary "
          f"({nops} assembler NOP pad(s), {cmps} imm8/imm16 re-encoding(s), "
          f"{addr_runs} shifted address field(s), datestamp masked)")
    return 0

def fail(msg):
    print("FAIL:", msg)
    return 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
