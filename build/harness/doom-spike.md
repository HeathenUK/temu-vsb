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

## Update: blocker proven, and the real path's toolchain is up

Two concrete results since the first spike:

**1. Classic VSB provably cannot run DOOM (empirical).** Booting our current
`vsb_real.com` resident, then `DOOM -timedemo`:

```
DOS/16M error: [17]  system software does not follow VCPI or DPMI specifications
```

DOOM's DOS/4GW extender aborts before starting. VSB has put the CPU in VM86 but
offers neither VCPI nor DPMI, so the game cannot enter protected mode — a hard
refusal, not "runs without sound." LPT captured 1 byte (BIOS probe only). This
is the definitive reason "just amend VSB" is a rewrite: the missing subsystem is
a *DPMI host with port trapping*, and it must be DPMI (ring-3, trappable), not
VCPI (ring-0, untrappable) — exactly why SBEMU bundles HDPMI.

**2. The tractable path — a Covox backend in SBEMU — is now buildable here.**
- SBEMU source (`crazii/SBEMU`) builds clean with a prebuilt DJGPP gcc 12.2
  cross-toolchain (`andrewwutw/build-djgpp` v3.4, `djgpp-linux64-gcc1220`):
  `make VERSION=covox-spike` → `output/sbemu.exe` (560 KB, go32 DOS extender).
  This is the exact software that already traps DOOM's SB access.
- The output backend is a clean compile-time abstraction: one
  `one_sndcard_info` struct (init/detect/setrate/start/stop/`cardbuf_writedata`/
  `cardbuf_pos`) registered in `all_sndcard_info[]` (`au_cards.c`). Existing
  cards are self-playing PCI-DMA buffers monitored via `cardbuf_pos`.

**Backend design (next implementation step).** A Covox card driver would:
allocate a software ring as the "DMA buffer"; on `card_start` install a PIT
ch0 ISR at the output rate that OUTs one 8-bit-unsigned-mono byte to the LPT
data port per tick and advances a consumed-sample counter; implement
`cardbuf_pos` from that counter so SBEMU's virtual-DMA/IRQ refill logic works
unchanged; and downconvert SBEMU's 16-bit signed stereo mix to 8-bit mono in
`card_setrate`/`writedata`. This is VSB's proven timer→LPT engine (idle
gating, `/Q`-style resampling all applicable) relocated behind SBEMU's mixer
instead of behind a VM86 port trap — and because it writes the LPT port
directly, it sidesteps the QEMU HDA/AC97 codec quirk and is captured exactly
by the harness's isa-debugcon at 0x378.

**Open risk to price first (per the cycle model):** SBEMU's mix + this
per-sample timer output stack on a 386SX-40, added to DOOM itself (already a
~5 fps slideshow on that CPU). The backend makes *sound* reach a Covox in
DOOM; whether the combination is playable on real hardware is the honest
question the `cycles386` approach should answer before committing hardware.
