# Covox output backend for SBEMU — DOOM-and-anything with Covox + real OPL3

This is the path to **invisible SB PCM sound for any DOS game — including
protected-mode/DOS-extender titles like DOOM — on a Covox + real OPL3**, which
classic VSB cannot reach (VSB's VM86 monitor offers no VCPI/DPMI, so DOOM's
DOS/4GW aborts; proven in `build/harness/doom-spike.md`).

Rather than rewrite VSB into a DPMI host, we add the one missing piece to
SBEMU, which already: traps ring-3 games via HDPMI (catches DOOM), emulates SB
PCM, and passes FM through to a real OPL3 (`MAIN_HW_OPL3IODT`). The missing
piece for a Covox machine is PCM output to the LPT DAC instead of a PCI card —
one `one_sndcard_info` backend: **`sc_covox.c`**.

## Build

```sh
build/covox/integrate.sh          # -> build/covox/work/SBEMU/output/sbemu.exe
```

Fetches SBEMU at the pinned commit (`SBEMU_COMMIT`) + a pinned DJGPP gcc 12.2
cross-toolchain, drops in `sc_covox.c`, applies `sbemu-wiring.patch` (link
macro, card-array entry, makefile source), and builds. SBEMU is GPL-2 and is
fetched, not vendored; `sc_covox.c` is our contribution.

## Runtime (target config)

```
JEMMEX LOAD NOEMS        (or QPIEMU)   ; XMS + a port-trapping host
HDPMI32i -r -x                          ; DPMI host with port trapping (ring-3)
SBEMU /SC<n>                            ; select the CVX card (see /SCL)
```

FM/music → real OPL3 (untrapped passthrough); SB PCM → Covox on LPT.

## 386SX @ 40 MHz performance

The output ISR is VSB's proven lean engine (idle gating, `/Q` integer
decimation, `/E` AEOI all apply). 8-bit unsigned mono card format means SBEMU's
mixer emits Covox-ready bytes with **zero per-sample conversion** in the
backend. The combined per-sample cost (SBEMU mix + this ISR) gets a
`cycles386`-style pass at Stage 5.

## Status (staged; see build/harness/covox-backend-plan.md)

- [x] **Stage 1 — compiles, registers, selectable.** SBEMU builds with CVX
  linked; `/SCL` autodetect prints `Covox LPT-DAC at port 378h (8-bit mono
  PCM)`. Format/buffer path via `MDma_*`; env override `COVOX=<hexport>`.
- [ ] **Stage 2 — fast PIT ISR** draining the ring to the LPT port at the set
  rate (harness debugcon captures a known ramp). Replaces the Stage-1
  position-advance stub in `COVOX_int_monitor`.
- [ ] **Stage 3 — real-mode SB PCM program → Covox**, byte-exact LPT capture.
- [ ] **Stage 4 — DOOM (PM)**: SFX → Covox on LPT, music → OPL3.
- [ ] **Stage 5 — 386SX-40 cost pricing** of the combined path.

`sc_covox.c` header documents the Stage-1 vs Stage-2 boundary in code.
