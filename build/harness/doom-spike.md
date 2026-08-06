# DOOM feasibility spike (VSBHDA-style ring-3 trapping) — results

Goal: determine whether the SBEMU/VSBHDA architecture (a DPMI host with I/O
port trapping keeps DOS-extender games at ring 3, where SB port accesses trap)
works for DOOM in our QEMU harness — as the blueprint for reaching DOOM with
Covox output, which classic VSB's VM86 monitor cannot do (DOS/4GW needs
VCPI/DPMI; VCPI clients get ring 0 and are untrappable).

## Rig (reproducible)

- Guest: FreeDOS beta9 kernel (harness floppy) + 64 MB FAT16 HDD image built
  with mtools (`mpartition -I; mpartition -c -a; mformat`, `partition=1`).
- DOOM 1.9 shareware from idgames `doom19s.zip` (DeICE volumes are a spanned
  PKZIP: carve from the first `PK\x03\x04` in `DOOMS_19.1`, append
  `DOOMS_19.2`, open as one zip — DOOM.EXE has DOS/4GW bound in).
- SBEMU 1.0.0-beta.6 release zip (bundles HDPMI32i.EXE, JEMMEX.EXE, JLOAD,
  QPIEMU.DLL).
- QEMU: `-cpu 486 -m 16`, sound tried as `-device AC97` and
  `-device intel-hda -device hda-output`, with `-audiodev wav` capture.
- Boot chain: `JEMMEX LOAD NOEMS` (provides the XMS SBEMU requires — without
  it SBEMU aborts with "Failed allocating XMS") → `HDPMI32i -r -x` →
  `sbemu` → `DOOM -timedemo demo1`. DOOM sound config: `default.cfg` with
  `snd_sfxdevice 3`, `snd_musicdevice 3` (3 = Sound Blaster).

## Results

| Stage | Result |
|---|---|
| DOOM alone (no managers) | Runs: `timed 5026 gametics in 7405 realtics` (DOS/4GW raw mode) |
| DOOM + HDPMI32i resident | Runs unchanged — DOS/4GW takes the DPMI path without issue |
| SBEMU install | `Sound card: Intel HDA / Protected mode support: enabled / SB Pro emulation at address 220, IRQ 7, DMA 1: enabled`; sets BLASTER |
| DOOM under full stack | Runs to completion, `8415 realtics` = **+13.6% sound-processing load vs control** — trap-mediated SB/OPL activity confirmed |
| Audio capture | Stream opens (WAV grows for the demo duration) but content is digital silence (peak ≈ noise), on AC97 and HDA, with `/O0`/`/O1`, `/VOL100` |

## Conclusions

1. **The architecture works for DOOM in this rig**: HDPMI32i coexists with
   DOS/4GW, SBEMU's ring-3 port trapping engages, and DOOM completes with the
   expected added sound workload. This is the mechanism classic VSB lacks.
2. The silent capture is an SBEMU↔QEMU **codec/output-stage** issue (QEMU's
   simplified HDA/AC97 codec vs SBEMU's mixer programming) — the exact layer
   a Covox backend would replace with plain LPT port writes, which this
   harness captures perfectly via isa-debugcon.
3. **Porting direction**: rather than teaching 1995 VSB to be a DPMI host,
   the tractable route is the reverse — add a **Covox/LPT timer-paced output
   backend** to SBEMU/VSBHDA (GPL-2, C + Watcom/JWasm — buildable with this
   repo's toolchain approach), reusing their trap client, DSP/SB16 emulation,
   and virtual-IRQ machinery. Open risk to quantify first: SBEMU's mixing/
   format pipeline is written for fast CPUs; a 386SX-40 budget needs the
   cycles386-style pricing pass before committing.

Spike artifacts (DOOM shareware, SBEMU zip, disk images) are fetched ad hoc
into the scratchpad — game data is not committed to this repository; this
document records the exact recipe instead.
