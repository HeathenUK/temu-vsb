# DOOM-with-Covox: the concrete build plan (scope fully de-risked)

Goal (user's framing): **one TSR, invisible, any game** — real-mode or
DOS-extended — gets Covox PCM sound with minimal CPU. DOOM is the proof of the
protected-mode (DOS/4GW) case, not the deliverable.

## Why this is now a small, well-bounded task

The user's hardware is **Covox (LPT DAC) + a real OPL3**. That eliminates most
of what a full SB emulator does:

| SB function | Our need | Who does it |
|---|---|---|
| FM / OPL3 music | **passthrough** | real OPL3 chip — SBEMU's `MAIN_HW_OPL3IODT` already forwards ports 388–38B to hardware |
| MPU-401 MIDI | not needed | disable |
| PCI/HDA card mixing | not needed | — |
| **SB PCM (DSP + DMA)** | **must emulate → Covox** | **the one new piece** |
| Ring-3 port trapping (catches DOOM) | required | HDPMI32i — proven to trap DOOM (spike) |

Everything except the PCM→Covox output hop already exists and works in SBEMU
with our exact hardware profile. Confirmed from source:
- `HDPMIPT_Install_IOPortTrap(start,end,iodt,count,iopt)` + `HDPMIPT_*IRQRouted*`
  — the ring-3 trap + IRQ-routing API (hdpmipt.h), host-agnostic (HDPMI/JEMMEX).
- `MAIN_HW_OPL3IODT` — hardware-OPL3 passthrough table (main.c) → your OPL3
  plays music natively; VSB's `/A` idea, already built.
- Output backend = one `one_sndcard_info` struct in `all_sndcard_info[]`.
- Setting `bits_card=8, chan_card=1, freq_card=<rate>` makes SBEMU's mixer emit
  **Covox-ready 8-bit unsigned mono bytes directly** — no conversion in our code.
- SBEMU builds clean here with DJGPP gcc 12.2 (`make` → `output/sbemu.exe`).

## The one hard part, stated precisely

SBEMU is built for cards that **play their DMA buffer autonomously in
hardware**; its timer is a **~115 Hz monitor** (`INT08_DIVISOR_NEW=10375`) that
only refills and advances bookkeeping between hardware-clocked samples. A Covox
has no autonomous playback — the CPU must write the LPT port **once per output
sample (8–22 kHz)**.

Therefore `sc_covox.c` cannot be a passive backend riding the 115 Hz callback.
It must:
1. Own a **fast PIT ch0 ISR at the output sample rate** (reprogram the divisor,
   hook IRQ0 via HDPMI's IRQ routing so it fires correctly in both the RM DOS
   context and the PM DPMI-client (DOOM) context).
2. Per tick: read one byte from the mixed DMA buffer, `OUT` to the Covox LPT
   data port, advance the play pointer — **this is VSB's proven ISR**.
3. Every k ≈ rate/refill samples, do the mix/virtual-SB-advance bookkeeping
   SBEMU normally does at 115 Hz (call into its refill + raise the virtual SB
   IRQ to the game on block completion via `HDPMIPT_*IRQRouted*`).
4. Chain the old int08 at 18.2 Hz so the DOS clock keeps time.
5. Report `card_dma_lastgoodpos` from the play pointer so SBEMU's virtual-DMA
   sees a consistent position.

This inverts SBEMU's "passive card + master monitor timer" into VSB's "master
fast timer that also monitors" — the same architecture we already proved and
optimized (idle gating, `/Q` decimation, `/E` AEOI all directly applicable to
this ISR). It is real driver work with protected-mode-IRQ and reentrancy care,
but it is *our* design on a small, self-owned surface, not a fight with the
mixer.

## Build/test stages (each an LPT-captured green check in the harness)

1. **Backend compiles + registers**: `sc_covox.c` in the tree, selectable as a
   card, format/buffer path via `MDma_*`. Gate: SBEMU builds, `/SCL`-lists CVX.
2. **Output ISR in isolation**: fast PIT ISR drains a test-filled buffer to the
   LPT port at the set rate. Gate: harness debugcon captures a known ramp at the
   expected byte rate.
3. **Real-mode game** (the majority case) under SBEMU+Covox: a trapped SB PCM
   program → Covox. Gate: byte-exact LPT stream (reuse the sbdma/sample rig).
4. **DOOM (PM proof)**: HDPMI32i + SBEMU(hw-OPL3 passthrough)+Covox, DOOM SFX →
   Covox on LPT capture; music → OPL3 (untrapped). Gate: LPT carries DOOM SFX.
5. **CPU pricing**: `cycles386` pass over the combined per-sample path (SBEMU
   mix + our ISR) to state the real-386SX-40 cost honestly.

## Decision settled

This supersedes last turn's three-way fork. The user's OPL3 insight makes the
**SBEMU + Covox-output-backend** route clearly correct: FM is free (hardware
passthrough), ring-3 trapping is done (HDPMI), and the only new code is the
Covox PCM output — VSB's engine re-seated behind SBEMU's mixer. No DPMI-host
rewrite, no FM emulation to carry.
