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

386SX tuning: `SBEMU /K11025` halves the Covox interrupt load (~22% → ~11%
CPU on a 386SX-40 with the ring-0 host) and is lossless for games that mix
at 11 kHz anyway (DOOM's DMX does); use `/K22050` only where the game
genuinely outputs 22 kHz PCM.

## 386SX @ 40 MHz performance

The output ISR is VSB's proven lean engine (idle gating, `/Q` integer
decimation, `/E` AEOI all apply). 8-bit unsigned mono card format means SBEMU's
mixer emits Covox-ready bytes with **zero per-sample conversion** in the
backend. The combined per-sample cost (SBEMU mix + this ISR) gets a
`cycles386`-style pass at Stage 5.

## Status (staged; see build/harness/covox-backend-plan.md for full trace)

- [x] **Stage 1 — compiles, registers, selectable.** SBEMU builds with CVX
  linked; autodetect prints `Covox LPT-DAC at port 378h`. Env `COVOX=<hexport>`.
- [x] **Stage 2 — fast PIT ISR** draining the ring to the LPT at the set rate:
  proven with an 81,801-byte `00 01 02…` ramp, and the producer pipeline now
  streams **325k+ bytes** end-to-end (silence until a game starts the stream).
- [x] **Producer fixed.** `MAIN_Interrupt` used to fault (`Divide error`); root
  cause was `card_DMABUFF` never being *allocated* by the backend. Fixed in
  `COVOX_card_setrate` (`MDma_alloc_cardmem`). BIOS 18.2 Hz tick reconstructed
  from the fast PIT so DOS/game tick-delays don't stall.
- [x] **SB trap engages for real-mode clients** — sbdma's DSP reset is trapped
  (verified via the COM1 `_LOG` channel). DOOM's PM trap was proven earlier.
- [x] **Stage 3 — real-mode SB PCM program → Covox: WORKING at ≤~8 kHz.**
  `SBEMU /K8000` + sbdma: SBEMU traps the SB, `digital==true` (`sample rate:
  9900 8000`), and the Covox backend plays it. Verified against the source:
  smooth waveform centred on 0x80, lag-1 autocorr 0.55, windowed
  cross-correlation peak 0.89 — recognisably the sample. Two fidelity fixes
  landed here: unsigned sign-bias, and a 16-bit-stereo→8-bit-mono downmix in the
  consumer (SBEMU's mixer is 16-bit stereo and copies raw). ~6% underruns remain
  (mild jitter) under the interrupt-reflection cost.
- [x] **Idle-gating + full-rate output.** `sc_covox.c` is an active/idle state
  machine: PIT ch0 stays at 18.2 Hz in silence (~0% CPU) and spins up to the
  sample rate only while the SB is playing. This closed the silence burn (sbdma
  run: ~470 KB of silence output → ~21.7 KB) AND unlocked higher rates — because
  the game now initialises un-starved, **16 kHz and 22 kHz both play** (peak corr
  0.64/0.63) at the same ~6% underrun as 8 kHz. "Not limited to 8 kHz": met.
- [x] **386SX-40 pricing** — `cycles386_covox.py`. ~13% @8kHz … ~37% @22kHz
  (mid band), ~1.6–2× VSB, the excess almost all HDPMI reflection.
- [ ] **~6% underrun** (rate-independent): larger ring / higher refill / cheaper
  producer.
- [x] **PIT virtualisation (trap 40h/43h)** — capture the game's timer divisor,
  deliver its int8 via the accumulator, keep the physical PIT ours. Our own PIT
  writes go through SBEMU's `UntrappedIO_OUT/IN` to avoid re-entering the trap.
  Real-mode verified (sbdma 0.907, unaffected).
- [x] **Split PM/RM ISR** (`COVOX_timer_isr_pm` / `_rm`): each chains its OWN
  handle with the matching call (`DPMI_CallOldISR`/`WithContext` for PM,
  `DPMI_CallRealModeOldISR` for RM), mirroring SBEMU's separate
  `MAIN_InterruptPM`/`RM`. **Fixes DOOM's DOS/4GW `exception 06`** — DOOM now
  boots clean to full init (`R_Init`…`I_StartupTimer()`). sbdma unchanged (0.872).
- [x] **Ring-0 fast path in the host (`hdpmi/`) — the "super narrow driver".**
  We now build HDPMI32i from source natively (jwasm+jwlink, `hdpmi/fetch-and-build.sh`,
  crazii/HX pinned + `hx-covoxr0.patch`) with a hand-written IRQ0 fast path in
  the IDT stub (`intr08`): one sample ring→LPT per tick entirely at ring 0 — no
  LPMS switch, no ring-3 reflection. Registration via vendor fn 0Fh (int 2F/168A),
  shared state in a client-owned control block (CVCB). Modeled: **666→~400
  cyc/sample** for PM clients (36.7%→22% CPU @22 kHz on a 386SX-40), within ~15%
  of classic VSB. Baseline host rebuild verified byte-equivalent in-harness
  before patching; sbdma regression at parity (corr 0.400-0.448 vs 0.441
  control). `COVOXNOR0=1` falls back to the all-ring-3 path.
- [x] **DOOM `I_StartupTimer()` hang FIXED** — root cause was that DOOM's timer
  ISR lives in *its* DPMI client's vector table (per-client state in HDPMI),
  unreachable from our resident client's context by any ring-3 chain. The ring-0
  path solves it structurally: game-due ticks reflect with `cvSkipRoute`, which
  makes `lpms_call_int` deliver to the **current client's own int8** (DOOM's
  handler), bypassing the routed handler. DOOM now boots past `I_StartupTimer`
  into DMX sound init and streams to the LPT.
- [x] **DOOM DSP detection + auto-init stream WORKING.** The "detection loop"
  had two layers, both fixed: (1) what looked like reset spam was DMX polling
  22Eh for its SB-IRQ ack (`DSP RS` = Read Status, not reset) — its `F2`
  (IRQ-request) probe fires while the stream is idle, and in ring-0 mode
  nothing serviced the trigger because producer wakes only run while active;
  the `SBEMU_StartCallback` hook now also fires on `F2`, so the timer spins up
  and the first pump services the trigger (COM1 trace: `trig=1 -> 0`, then DMX
  proceeds through mixer setup, `48 FF 00` block size, `90` auto-init
  high-speed — the real DOOM SFX stream — with per-block virtual IRQs
  delivered at the pump rate). (2) `MAIN_Interrupt`'s PLAYING gate was
  confirmed satisfied (`info=0x11` at pump time) once the F2 window existed.
- [ ] **Stage 4 — DOOM (PM)**: SFX → Covox, music → OPL3.
- [ ] **Stage 5 — 386SX-40 cost pricing** of the combined path (model updated:
  see `cycles386_covox.py` ring-0 tier).

### Reproduce

`build/covox/harness/run-sbdma.sh` boots the full stack (JEMMEX → QPIEMU →
HDPMI32i → SBEMU/CVX → sbdma) in QEMU, capturing the LPT stream (`lpt.bin`) and
SBEMU's internal `_LOG` trace on COM1 (`com1.log`, needs a `DEBUG=1 /DBG1`
build). The two-channel capture (PCM on 0x378, trace on COM1) is what made the
producer pipeline debuggable.
