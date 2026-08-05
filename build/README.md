# Reproducible build for VSB (Phase 0 of PERFORMANCE.md)

This directory reconstructs the 1995 build environment for the standalone
(pure-DOS) VSB binary and proves the repository sources produce the shipped
`sbemu/vsb_real.com`. **No build system existed in the repository or in the
original distribution** — the toolchain and process below were reverse-derived
from the sources and binaries.

## Quick start

```sh
apt-get install dosbox        # any SDL DOSBox; runs headless
build/fetch-toolchain.sh      # downloads TASM 4.1 from archive.org (pinned sha256)
build/build.sh                # -> build/out/vsb_real.com, then verify.py gate
```

## What the original build chain was

Derived from the sources (TASM-only directives: `SMART`, `LOCALS @@`,
`NOWARN ALN`, `%Include` expansion, `??date`/`??time`) and `sbemu/mvsb.pas`:

| Step | Tool (1995) | This kit |
|---|---|---|
| `vsb_real.asm` → `.OBJ` | Borland TASM (3.x/4.0-era), multi-pass | TASM 4.1 `/m3` under headless DOSBox |
| `.OBJ` → `.COM` | `TLINK /t` | `build/omf2com.py` (deterministic OMF→COM) |
| `vsb.asm` stub + both COMs → combined `vsb.com` | stub + `mvsb.pas` (Turbo Pascal) appender | not yet reproduced (stub assembles; merger is trivial, pending) |

TLINK is bypassed deliberately: the module is fully self-contained (no
EXTDEF/PUBDEF), so COM generation is a mechanical image dump plus base-0
fixups — `omf2com.py` does it natively on Linux and removes a second
hard-to-source period binary. (The TLINK 5.0 floating around the same
archive item dies with "Out of memory" on this object's FIXUPP32 records.)

## Fidelity status: near-byte-identical, fully explained

`verify.py` enforces this. Against the shipped `vsb_real.com`
(sha256 `442df827eb562afbc065d6cf263fdb926cf5556865c15a17c4809e4da5fcb8d1`),
the rebuild differs **only** by:

1. **One assembler padding NOP** at the interrupt-stub block (image `0x25A7`):
   TASM 4.1 pads after converting a forward `jmp IntDump` to short form; the
   author's older TASM emitted the tighter sequence. The byte sits between
   stubs and is never executed.
2. **Two instruction encodings** in `EnableDMA`: `cmp ss:SBcounter/DMAcounter,
   0FFFFh` — author's TASM used `81 /7 imm16` (7 bytes), TASM 4.1 uses the
   equivalent sign-extended `83 /7 imm8` (6 bytes).
3. **Address/displacement bytes** shifted by the net ±1 layout drift those
   cause (verified to occur only in ≤3-byte runs).
4. **The `??date`/`??time` build stamp** — the shipped binary reads
   `Compiled on 14/09/95 at 15:45:26`, confirming the datestamp line must be
   active (it had been commented out in this repo; see below).

A byte-identical rebuild would need the author's exact TASM version
(3.1/3.2/4.0 all predate the two 4.1 optimizer behaviours); TASM 4.1 was the
best cleanly sourceable build. Functional equivalence is complete.

`/m3` (three optimizer passes) is pinned because it matches the author's
short/near jump convergence exactly; `/m2` leaves 3 jumps long (+10 bytes) and
`/m4+` converges one further (−1 byte plus the NOP artifact moving).

## Source archaeology (important)

The sources at this repository's HEAD **did not assemble**. Commit `dec4656`
("Set text file working tree encodings in .gitattributes", 2017) rewrote the
tree with more than encoding changes; buried in the renormalization were
curation edits that were never re-assembled:

- `@@1`/`@@2…` local labels renamed to `LocalOne`/`LocalTwo…` in
  `sbemu/vsb_real.asm` and `sbemu/s386port.asm`. Under TASM's `LOCALS @@`
  the renamed colon-labels become scope-breaking global labels, so
  `jmp @@CommandOK` in `s386port.asm` fails to resolve (5 errors).
  The parallel `vsb_qemm.asm` kept the original `@@` names throughout.
- `include ..\file` flipped to `../file` (harmless to TASM, but not original).
- `SMART` commented out in `vsb.asm`; a `lea` expression hoisted to an `equ`.
- The `??date`/`??time` line commented out in `s386data.asm` — although the
  shipped binary proves it was active in the author's build.

These look like artifacts of a modernization/porting attempt (probably toward
a MASM-syntax assembler) that was committed without a round-trip test. The
initial commit `10a900a` contains the authentic sources: they assemble with
**zero errors and zero warnings**, and this branch restores those four files
to that state (encoding conventions preserved via `.gitattributes`).

## Toolchain provenance

- `TASM.EXE` 4.1 (sha256-pinned in `fetch-toolchain.sh`) from archive.org item
  `tasm_20221214_194938_113157`. Borland abandonware; fetched on demand, not
  committed.
- DOSBox runs it headless (`SDL_VIDEODRIVER=dummy`), driven by a generated
  conf `[autoexec]`; assembler output is captured to a file and checked.

## Behavioural harness (`harness/run-harness.sh`)

Boots FreeDOS (beta9 kernel, sha256-pinned archive.org image) in
`qemu-system-i386`, installs the rebuilt VSB in Covox mode, and drives it with
the author's own test tool `sbemu/sbdma.exe`, which programs the emulated DSP
(reset, `D1`, `40h` TC=155 ≈ 9.9 kHz, `14h`) and real DMA-ch1 registers to
play `sbemu/sample`. Every guest `OUT` to the LPT data port is captured via an
`isa-debugcon` device at 0x378 (a 12-byte `SETLPT.COM` pokes the BIOS data
area so VSB finds the port, since debugcon is invisible to the BIOS probe).

`harness/check.py` gates on: the VSB banner on the DOS text screen (read via
the QEMU monitor), SBDMA's virtual-IRQ5 diagnostics (proves the emulated
SB interrupt fired), and the captured LPT stream reproducing `sample`
**byte-for-byte** (26100/26100; one leading 0xAA is SeaBIOS's POST-time LPT
probe). Current status: **PASS** — VSB's ring-0 VM86 hypervisor runs correctly
under QEMU TCG, end to end.

This is the regression gate for the Phase 1+ changes in PERFORMANCE.md:
run it against the unmodified build (green baseline), then after each change.

## Known limitations / next steps

- Capture is content-exact but not timestamped; pacing/CPU-duty measurement
  (trace-based or pipe-timestamped) is a planned harness extension, and final
  duty-cycle numbers come from real hardware via the planned `/D` flag anyway.
- `vsb_qemm.asm` assembles clean, but `omf2com.py` needs multi-segment
  group-frame fixup handling before its image is trustworthy (the standalone
  build's single-segment case is exact). QEMM build is out of scope for the
  performance work.
- The combined `vsb.com` merger (`mvsb.pas`) is not yet reproduced.
- Harness variations to add with Phase 1: auto-init mode, `D0`/`D4` pause/
  resume, masked-IRQ deferral, direct-DAC (`10h`), and `E2` sequences.
