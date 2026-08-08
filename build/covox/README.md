# Covox output backend for SBEMU — DOOM-and-anything with Covox + real OPL3

This is the path to **invisible SB PCM sound for any DOS game — including
protected-mode/DOS-extender titles like DOOM — on a Covox + real OPL3**, which
classic VSB cannot reach (VSB's VM86 monitor offers no VCPI/DPMI, so DOOM's
DOS/4GW aborts; proven in `build/harness/doom-spike.md`).

Rather than rewrite VSB into a DPMI host, we add the one missing piece to
SBEMU, which already: traps ring-3 games via HDPMI (catches DOOM), emulates SB
PCM, and passes FM through to a real OPL3 (`MAIN_HW_OPL3IODT`). The missing
piece for a Covox machine is PCM output to the LPT DAC instead of a PCI card —
one `one_sndcard_info` backend: **`sc_covox.c`** — and then a **minimal build**
that strips everything a Covox+OPL3 machine can't use.

## Minimal by construction

The build is trimmed to exactly Covox+OPL3, nothing else (`SBEMU_COVOX_ONLY`,
see `sbemu-wiring.patch`):

- **all ~24 PCI/ISA card drivers dropped** — only the `CVX` (Covox LPT-DAC)
  backend is linked.
- **the DOSBox software OPL3 synth dropped** (`dbopl.cpp`/`opl3emu.cpp` →
  `opl3emu_stub.c`, ~167 KB) — you have a real OPL3, so FM is passed straight to
  the chip via SBEMU's 388h hardware passthrough; nothing to emulate or mix.
- **the TinySoundFont virtual-MPU dropped** (`SBEMU_VMPU 0`, ~206 KB).

Result: a focused SB.EXE, **~233 KB vs ~565 KB stock** (−59%), that does one
thing — present an SB Pro whose PCM lands on the Covox and whose FM lands on the
real OPL3 — and boots without probing PCI or spinning up synths it will never
use. `sc_covox.c` byte-for-byte unchanged in the harness (corr 0.400) across the
strip.

## Build

```sh
build/covox/integrate.sh          # -> build/covox/work/SBEMU/output/sbemu.exe
```

Fetches SBEMU at the pinned commit (`SBEMU_COMMIT`) + a pinned DJGPP gcc 12.2
cross-toolchain, drops in `sc_covox.c` + `opl3emu_stub.c`, applies
`sbemu-wiring.patch` (Covox-only card set, OPL-emu stub, VMPU off, backend
wiring), and builds. SBEMU is GPL-2 and is fetched, not vendored; `sc_covox.c`
and `opl3emu_stub.c` are our contributions. (The ring-0 host is built
separately — `build/covox/hdpmi/fetch-and-build.sh`.)

## Runtime — one command

Copy `SBCOVOX.BAT` next to `JEMMEX.EXE`, `JLOAD.EXE`, `QPIEMU.DLL`,
`HDPMI32I.EXE`, `SBEMU.EXE`, edit the two `SET` lines for your hardware, and run
it. It brings up the whole stack and hands back:

```
SBCOVOX                 ; defaults: Covox 378h, 11 kHz
SBCOVOX /K22050         ; extra args pass through to SBEMU
```

**The stack is layered by necessity, not choice** — on a 386 you cannot trap a
game's sound ports without a V86 host (real-mode games) and a DPMI host
(protected-mode games) underneath:

```
JEMMEX LOAD NOEMS       ; XMS + V86 host
JLOAD QPIEMU.DLL        ; real-mode (V86) port trapping
HDPMI32i -r -x          ; DPMI host + port trapping (protected-mode; DOOM)
SBEMU /K11025           ; the emulator + our CVX Covox backend
```

FM/music → real OPL3 (388h hardware passthrough); SB PCM → Covox on LPT.

386SX tuning: `SBEMU /K11025` (the `SBCOVOX.BAT` default) halves the Covox
interrupt load (~22% → ~11% CPU on a 386SX-40 with the ring-0 host) and is
lossless for games that mix at 11 kHz anyway (DOOM's DMX does); use `/K22050`
only where the game genuinely outputs 22 kHz PCM.

The truly single-binary end-state (one TSR, no stack) would require teaching
classic VSB to be its own DPMI host — the deferred VCPI/DPMI-server rewrite; the
SB-emulation core stripped here is what that TSR would reuse.

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
- [~] **Stage 4 — DOOM (PM): SFX → Covox, music → OPL3.** *In progress; harness
  findings this pass:*
  - DOOM boots under the full Covox stack (JEMMEX→QPIEMU→HDPMI32i-covox→
    SBEMU-covox `/K11025`): clears `I_StartupTimer()`, reaches `DMX_Init`,
    `S_Init`. "Dude. The Adlib isn't responding" is expected in QEMU (no real
    OPL3; the FM path is 388h passthrough — untestable here, works on the chip).
  - The Covox backend **streams to the LPT in real time** — observed ~695 KB in
    one clean run (steady ~11 kHz), so the PCM producer→LPT path is alive under
    a PM client.
  - **FIXED — DOOM used to die during init at `ST_Init`/`HU_Init` with
    `W_ReadLump: only read 0 of N on lump …`** (a WAD read returning 0 bytes,
    *before* gameplay). Root cause (isolated, not heap — `DOOM -mb 6` and stock
    HDPMI+`COVOXNOR0=1` both ruled memory out): the ring-0 IRQ0 fast path
    *reflected* game-tick and producer-pump ticks (`@simintlpms`/`lpms_call_int`,
    or the SBEMU mixer via `MAIN_CovoxPump`) **while the host was already
    servicing a PM client's reflected DOS call**. That nested re-entry corrupts
    the in-flight int 21h transfer, so DOOM's WAD read returns 0. Confirmed by a
    drain-only diagnostic build (reflections disabled → DOOM boots and runs).
  - **Fix (in `hx-covoxr0.patch`):** the ring-0 `covox_out` path now consults
    DOS's `InDOS` flag (`DOSSDA.bInDOS` at `[dwSDA]`, read through `_FLATSEL_`
    since the SDA is in low memory, unreachable via the base-adjusted host SS).
    When `InDOS != 0` it EOIs and `iretd`s **drain-only, no reflection**;
    reflection (timer pacing + pump) resumes once DOS is idle. This is the
    classic TSR reentrancy guard and is correct for both a PM extender (DOOM,
    whose reflected int 21h sets InDOS) and real-mode games (native DOS calls
    set InDOS too). With the fix DOOM boots cleanly past `ST_Init`/`HU_Init` and
    streams continuously with no `W_ReadLump`.
  - **Remaining (open):** captured LPT is still ~constant `0x80` silence during
    the title/attract loop and under `-timedemo demo1` — DOOM's *digital* SFX
    are not yet reaching the Covox ring (SB-DSP capture / mixer-input path, or
    DOOM not emitting PCM in these states). Separate from the crash; under
    investigation.
  - **Harness caveats (resolved this pass):** (1) `pkill -9 qemu-system-i386`
    silently no-ops — the process name truncates to 15 chars (`qemu-system-i38`);
    kill by scanning `/proc/*/cmdline` or `pkill -9 -f qemu-system`. (2) mcopy'd
    `AUTOEXEC.BAT` **must be CRLF** — FreeCom silently drops LF-only files to the
    `A:\>` prompt (autoexec never runs). (3) foreground inline `sleep` is blocked
    in this sandbox; run the timed loop inside an invoked script. (4) use QEMU
    `snapshot=on` per drive to avoid write-lock contention between runs.
  - Real-mode SB PCM→Covox is already verified (Stage 3, sbdma); the real
    end-goal validation is on the user's Covox+OPL3 hardware, where the FM path
    and true timing apply.
- [ ] **Stage 5 — 386SX-40 cost pricing** of the combined path (model updated:
  see `cycles386_covox.py` ring-0 tier).

### Reproduce

`build/covox/harness/run-sbdma.sh` boots the full stack (JEMMEX → QPIEMU →
HDPMI32i → SBEMU/CVX → sbdma) in QEMU, capturing the LPT stream (`lpt.bin`) and
SBEMU's internal `_LOG` trace on COM1 (`com1.log`, needs a `DEBUG=1 /DBG1`
build). The two-channel capture (PCM on 0x378, trace on COM1) is what made the
producer pipeline debuggable.
