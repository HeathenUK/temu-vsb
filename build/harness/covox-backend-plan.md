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

## Stage 2 design — SOLVED (lean HDPMI-client realization)

Pivot (user's call): drop SBEMU's bulk (FM emu/dbopl, MIDI/tsf, PCI drivers) —
FM is real-OPL3 passthrough, so none is needed. Keep only the proven core that
makes DOOM work: HDPMI ring-3 trapping + SB DSP/DMA/virtual-IRQ emulation, plus
our Covox output. This is the "lean HDPMI client" — reusing SBEMU's *working*
trap/DSP core rather than reimplementing it, minus ~90% dead weight.

Interrupt architecture (from reading main.c MAIN_Interrupt/InterruptPM/RM):
- SBEMU = producer/consumer. `MAIN_Interrupt()` (producer) refills card_DMABUFF
  from the game's DMA via DPMI-mapped memory + resample; the card (consumer)
  drains it and reports position via `cardbuf_pos`. Producer is driven by the
  card's IRQ (`DPMI_InstallISR`/`InstallRealModeISR` on `card_irq`, routed by
  `HDPMIPT_InstallIRQRoutedHandler` so it fires in both PM (DOOM) and RM).
- Covox has no hardware IRQ -> our fast PIT ch0 ISR IS the card interrupt.

Performance-critical split (386SX-40):
- Per-sample output = a MINIMAL raw ISR (VSB's ~19-instruction body: read
  card_DMABUFF[pos], OUT to LPT, advance pos, Int8Coeff accumulate). NOT routed
  through SBEMU's DPMI ISR wrapper — that wrapper is fine at ~115 Hz refill but
  ruinous at 16 kHz/sample. This is the single most important perf decision.
- Refill = SBEMU's heavy `MAIN_Interrupt()` producer, called from the raw ISR
  only every K = rate/115 ticks (the PCI refill cadence). Expose MAIN_Interrupt
  (drop `static`) for the backend to call.
- System clock chained at 18.2 Hz via the Int8Coeff carry (VSB's mechanism).
- Idle gating / /Q integer decimation / /E AEOI all port directly onto this ISR.

Install: card_irq set so SBEMU routes IRQ0; card_start reprograms PIT ch0 to the
output rate and arms the raw ISR; SBEMU's 115 Hz mpxplay timer disabled for this
card (the raw ISR drives everything). getbufpos returns the drained position so
the producer refills exactly the consumed amount.

Remaining work is implementation + the multi-cycle interrupt-level debug this
class of code always needs (PM/RM context, timing, reentrancy), validated at
each harness stage (ramp capture -> real-mode PCM -> DOOM).

## Stage 2 progress + the architectural crux (findings from live debugging)

Implemented and verified in the harness (real-mode sbdma under HDPMI+QPIEMU):
- **Fixed the crash**: a Covox is the first non-PCI card in SBEMU. It segfaulted
  in `pcibios_AssignIRQ(NULL)` because `card_irq` was uninitialised (255). Fix:
  set a valid `card_irq` in `COVOX_card_detect`, `card_pci_dev=0`, and guard
  `pcibios_enable_interrupt` for a NULL device. SBEMU now installs cleanly:
  `SB Pro(1:CVX) emulation at address 220, IRQ 7, DMA 1: enabled`, real+PM.
- **card_setrate / card_start confirmed reached** (debug markers on LPT: E1/E2).

The blocker, now understood at the code level:
1. **SBEMU has NO timer in TSR mode.** The int08 monitor
   (`mpxplay_timer_addfunc(aucards_dma_monitor,...)`) is inside `#ifndef SBEMU`
   (au_cards.c:573), so `cardbuf_int_monitor` is dead code in SBEMU builds.
   SBEMU pumps the mixer **only** from the sound card's hardware IRQ
   (`MAIN_Interrupt` on `card_irq`). A Covox has no hardware IRQ, so nothing
   ever runs. => The backend MUST supply its own interrupt source.
2. **The one usable fast timer is PIT ch0 — which DOOM also owns.** Covox needs
   a sample-rate interrupt (8-22 kHz). Only PIT ch0 (IRQ0) or the RTC (IRQ8,
   ~8 kHz max) can do that. DOOM (via DMX) reprograms **PIT ch0** for its own
   ~140 Hz game timer, and **SBEMU does not trap the PIT** (it traps DMA, SB,
   OPL, MPU, PIC 20h/A0h — not 40h/43h). So reprogramming PIT ch0 for Covox
   output directly contends with the exact game we are targeting.

This is precisely the problem classic VSB does **not** have: VSB owns the
machine (VM86), traps 40h/43h, runs the physical PIT at the sample rate, and
synthesises the game's timer ticks via the `Int8Coeff` accumulator. SBEMU, a
ring-3 client, has no PIT virtualisation.

### Two honest paths (decision needed)
- **A. Port VSB's PIT virtualisation into the client.** Trap 40h/43h via
  HDPMIPT, run the physical PIT at the output rate, drive per-sample Covox
  output from a minimal raw IRQ0 ISR, and reconstruct the game's timer ticks
  with the Int8Coeff mechanism. This is VSB's proven design; it solves DOOM
  contention and gives full-rate audio. Most work, best result.
- **B. Use the RTC (IRQ8) for Covox output.** Leaves PIT ch0 to the game, no
  contention, no PIT virtualisation — but caps output at ~8 kHz (RTC max rate)
  and adds RTC/CMOS handling. Lower quality ceiling, less code.

Path A is the same engine we already built and optimised in VSB; B is a
lower-ceiling shortcut. Current `sc_covox.c` (card_irq=0 borrow of PIT) is a
Stage-2a stepping stone that will be replaced by A or B.

## Stage 2 update: the IRQ0-delivery obstacle (Path A groundwork)

Path A chosen (port VSB's PIT virtualisation into the client). First groundwork
+ diagnostic, tested with real-mode sbdma under HDPMI+QPIEMU:
- Set `card_irq = 0` (borrow the timer) + an `irq_routine` that drains
  card_DMABUFF -> LPT, and reprogrammed physical PIT ch0 in `card_start`.
- Result: `irq_routine` IS reached (confirmed by an LPT debug marker) - so
  SBEMU's PM/RM IRQ routing can call our code - **but only ~2 times in 45 s**,
  not the ~1000/s the reprogrammed PIT should give.

Reading: **IRQ0 is not cleanly available via SBEMU's card-IRQ routing**, almost
certainly because the timer is special in the DPMI-host (HDPMI) environment -
DPMI hosts commonly manage/virtualise IRQ0 themselves. Borrowing it through
`card_irq=0` fights HDPMI, so only stray ticks reach us.

Consequence for Path A: the output timer can't be a passive borrow of IRQ0 via
SBEMU's card machinery. It needs a **proper, HDPMI-coexisting fast timer path**:
either install our own IRQ0 handler ahead of HDPMI in both PM and RM (chaining
HDPMI's/the game's timer), or drive the physical PIT and reclaim IRQ0 at the
DPMI-host level - plus the 40h/43h trap to virtualise the game's timer
(Int8Coeff), which is the DOOM-contention fix. This is genuine DPMI-host-level
interrupt work: VSB's proven engine, but re-hosted under a DPMI host that also
wants the timer. It is a multi-session implementation, not a backend tweak.

Honest status: SBEMU makes DOOM's PCM trappable+mixable (hard part done); the
Covox card builds, installs, and its lifecycle runs; the remaining gap is the
fast output timer, which is hard precisely because Covox needs the one timer
that both the game and the DPMI host contend for - the problem VSB solves in
VM86 but that must be re-solved under HDPMI here.

## Stage 2b: fast-timer mechanism PROVEN; per-sample path must be a raw ISR

Two decisive tested results (real-mode sbdma under HDPMI+QPIEMU, LPT captured):

1. **Fast IRQ0 output WORKS.** Isolation test: `card_start` reprograms PIT ch0
   to a fast rate; `irq_routine` emits an incrementing ramp and returns 0. Result:
   **81,801 bytes, a perfect `00 01 02 03...` ramp.** So a Covox backend CAN
   reprogram the PIT and receive IRQ0 at the fast rate under HDPMI, in both PM
   and RM. The earlier "HDPMI owns IRQ0" reading was WRONG - IRQ0 is fully
   available. (This retires the RTC/Path-B question: full-rate PIT output is
   viable.)

2. **The per-sample path must NOT go through SBEMU's `MAIN_InterruptPM`.**
   Wiring per-sample output via `card_irq=0` routes every PIT tick through
   SBEMU's heavy PM interrupt wrapper (`HDPMIPT_GetInterrupContext` + context
   save). At ~1 kHz that's fine (isolation ramp worked); at the ~16 kHz sample
   rate it runs 16,000x/s and saturates the CPU into a hang (output stops after
   the probe byte). `MAIN_Interrupt` itself is guarded on PLAYING (not a state
   crash) - the killer is the wrapper's per-tick overhead. This confirms the
   design's central perf decision: **per-sample output is a MINIMAL RAW ISR**,
   and the heavy producer (`MAIN_Interrupt`) runs only every K ticks.

### Concrete remaining work (well-defined now)
- Install our OWN raw IRQ0 ISR (`DPMI_InstallISR`+`DPMI_InstallRealModeISR`
  +`HDPMIPT_InstallIRQRoutedHandler`, NOT via `card_irq`/`MAIN_InterruptPM`):
  cheap per-sample `OUT card_DMABUFF[pos]` to the LPT, advance pos, Int8Coeff
  accumulate; every K ticks call the producer and, at the 18.2 Hz carry, chain
  the old timer.
- Producer refill: call `MAIN_Interrupt()` every K ticks from the raw ISR
  (it is normally called from an ISR context, so this is the same posture).
- PIT virtualisation (trap 40h/43h) for DOOM, so the game's timer reprogramming
  doesn't fight ours - VSB's Int8Coeff mechanism reconstructs the game ticks.

The uncertain part (does full-rate PIT/IRQ0 work under HDPMI at all) is now
answered YES. What remains is assembling VSB's known ISR shape in this client -
implementation, not research.

## Stage 2b: output engine PROVEN end-to-end; producer integration is the wall

Extensive tested iteration (real-mode sbdma, HDPMI+QPIEMU, LPT capture):

**WORKS (tested):** Our own raw IRQ0 (PIT) ISR, installed via
`DPMI_InstallISR`+`DPMI_InstallRealModeISR`+`HDPMIPT_InstallIRQRoutedHandler`
(bypassing SBEMU's heavy `MAIN_InterruptPM` wrapper), reprograms PIT ch0 to the
sample rate and fires reliably in both PM and RM - **81,801 bytes of a perfect
`00 01 02 03...` ramp**. So the full-rate Covox output timer under HDPMI is
real and solid. This is the crux of Path A, de-risked.

**THE WALL: getting the game's PCM into the buffer (SBEMU's producer).** SBEMU's
`MAIN_Interrupt()` (map game DMA -> resample -> write card buffer) cannot be
cleanly driven for a Covox:
- Called directly from our raw IRQ0 ISR it hangs/crashes on the first call.
  Bisected with markers: it enters, passes the mixer (self-guarded on NULL
  `card_mixerchans`), reads VDMA, finds `digital==false` (SBEMU has not marked
  the SB stream started), then hangs before returning. Not reentrancy (removing
  `sti` didn't help), not MAIN_PCM overflow (32 KB, ample).
- Moving the producer onto SBEMU's own IRQ path via a second timer (card_irq=8
  RTC at ~128 Hz, our IRQ0 ISR consumer-only) also yields no audio yet - the
  buffer stays empty, so the (working) consumer has nothing to drain.

Net: the **output half is solved and tested**; the **input half** - SBEMU
recognising the trapped SB stream as "started" and its producer filling the
card buffer for our card - is unresolved and is where the remaining work is. It
needs careful study of SBEMU's playback-start / VDMA preconditions for a
non-PCI card (why `SBEMU_HasStarted()` stays false and how a real card's
producer gets valid `digital` state), not more blind timer variants.

Honest status: this is genuinely deep integration with SBEMU's PCM pipeline.
The raw-ISR breakthrough is banked and reusable; the producer side is the open
problem. Current sc_covox.c carries the raw IRQ0 consumer + RTC-producer
scaffold; wiring patch updated.

## Stage 2c/3: producer pipeline SOLVED end-to-end; the wall is now CPU, not correctness

Method upgrade that unblocked everything: build SBEMU with `DEBUG=1` and run it
with `/DBG1`, so its internal `_LOG` trace goes to **COM1** (captured with
`qemu -serial file:com1.log`) — a debug channel completely separate from the
LPT PCM capture (isa-debugcon at 0x378). `build/covox/harness/run-sbdma.sh`
boots FreeDOS → JEMMEX → QPIEMU → HDPMI32i → our SBEMU(CVX) → sbdma, capturing
both. This turned blind timer-poking into precise, traced debugging.

Findings, each verified in that harness:

1. **The divide-by-zero crash is fixed — root cause found.** `MAIN_Interrupt`'s
   first real call faulted with `Divide error`. Traced through the mixer tail
   (`AU_writedata` → `aucards_writedata_nowait` → `MDma_writedata`) to the true
   cause: **`aui->card_DMABUFF` was NULL** — `COVOX_card_setrate` computed the
   ring geometry via `MDma_init_pcmoutbuf` but never *allocated* the buffer (PCI
   cards allocate DMA-capable memory themselves and set `card_DMABUFF`; a
   software Covox ring must do the same). Fix: `MDma_alloc_cardmem(COVOX_DMABUF_
   SIZE)` in `card_setrate`, set `card_dma_dosmem`/`card_DMABUFF`. `card_close`
   frees it. (The `Divide error` label was go32's SIGFPE for the near-NULL
   write, not an actual division.)

2. **Producer → consumer → LPT pipeline now runs end-to-end.** With the buffer
   allocated, `MAIN_Interrupt` completes cleanly and the raw IRQ0 ISR drains the
   ring to the LPT: **325k+ bytes** streamed in a run. Currently silence (`0x00`)
   because no game has started the SB stream (`SBEMU_HasStarted()==false` →
   `muted` branch), which is correct: the path is proven, it just needs a live
   digital stream. `sc_covox.c` now also reconstructs the ~18.2065 Hz BIOS tick
   from the fast PIT (accumulator → `DPMI_CallOldISR` at each boundary) so
   tick-based DOS/game delays don't stall.

3. **SBEMU's real-mode SB trap DOES fire for a real-mode program** — confirmed:
   with the output ISR disabled (diagnostic no-op `arm`, full CPU to the
   foreground), sbdma's DSP-reset write to port 0x226 **was trapped** (COM1:
   `SBTRAP reset port=226`). So the input half is reachable; DOOM's PM trap was
   already proven in doom-spike.md. This retires the "does the trap engage"
   question — it does.

4. **The remaining wall is CPU, specifically HDPMI interrupt-reflection cost at
   sample rate.** With the real output ISR armed (PIT ch0 at 22 kHz), sbdma is
   *starved to a standstill* — 0 SB traps, because every one of the 22 050
   IRQ0/s is delivered through HDPMI's PM/RM interrupt-reflection path (our ISR
   is a ring-3 DPMI ISR, not a ring-0 monitor like VSB). That per-interrupt
   mode-switch overhead, ×22 000/s, consumes essentially all emulated CPU. This
   is the same ceiling flagged in Stage 2b, now pinned as the concrete blocker:
   VSB pays ~0 per-interrupt overhead (it *is* the ring-0 VM86 monitor); a
   ring-3 HDPMI client cannot, so full-rate per-sample output under HDPMI is
   fundamentally more expensive than under VSB.

### What this means (calibrated)

- **Proven this session:** the Covox backend builds/installs/selects; the full
  SBEMU producer→ring→LPT pipeline works (divide-error eliminated); the SB trap
  engages for real-mode clients; BIOS-tick reconstruction is in place.
- **Not yet working:** a real game's PCM actually reaching the Covox *while the
  game keeps running*, because the sample-rate IRQ0 under HDPMI reflection
  starves the foreground. This is an architectural cost, not a bug to squash.
- **The tractable directions** (next session): (a) cut per-interrupt cost —
  hook IRQ0 at the raw IVT level for the real-mode case to bypass HDPMI's
  reflection, keeping the PM route only for PM games; (b) lower the output rate
  (8–11 kHz) to cut interrupt frequency — a real quality/CPU trade the user
  wanted to avoid but which may be the only viable point on a 386SX under a DPMI
  host; (c) reconsider whether the DOOM (PM) case, which needs the PM reflection
  path regardless, is affordable at all on a 386SX-40 — the honest cycle
  question the whole exercise exists to answer.

The output engine and the producer pipeline are banked and reusable. The open
problem is now precisely characterised: **per-interrupt overhead of a ring-3
timer under a DPMI host at PCM sample rates**, which is exactly the cost VSB's
ring-0 design avoids and a Covox-under-SBEMU design must pay.

## Stage 3 REACHED: real-mode SB PCM plays through the Covox — verified audio

Lowering the output rate to **8 kHz** (`SBEMU /K8000`) drops the IRQ0 frequency
below the reflection-starvation threshold, and the full path comes alive:
`sample rate: 9900 8000` in the trace = SBEMU trapped sbdma's SB programming,
recognised the stream (`digital==true`), resampled 9900→8000, and the Covox
backend drained it to the LPT. **The captured LPT stream is the sample.**

Two real fidelity bugs found and fixed getting there (both visible only once
audio actually flowed):
1. **Signedness.** SBEMU's mixer is signed; a Covox DAC is unsigned. Silence
   came out `0x00` instead of `0x80`. Fixed with a sign-bias on output.
2. **Format.** SBEMU's mixer buffer is **16-bit signed stereo** and
   `MDma_writedata` copies it *raw* (SBEMU only ever targeted 16-bit-stereo PCI
   cards — it does no down-conversion). Reading it as 8-bit mono played
   interleaved byte-halves (lag-1 autocorr ≈ 0, lag-2 ≈ 0.5 — the stereo
   signature). Fixed: the consumer now reads a 16-bit stereo frame, averages
   L+R, takes the high byte, biases to unsigned — a few adds/shifts per sample.
   `card_setrate` reports `bits_card=16, chan_card=2` so SBEMU's DMA accounting
   stays native; the 16→8 mono downmix lives entirely in the output ISR.

Verification (build/covox/harness/run-sbdma.sh, LPT capture analysed):
- Output waveform is smooth and centred on `0x80`; amplitude distribution
  matches the source (mean ~125 vs 124, full 0–255 range).
- Lag-1 autocorrelation **0.55** (real audio; noise ≈ 0).
- Drift-tolerant windowed cross-correlation against the source sample peaks at
  **0.89**; recognisably the same waveform.
- ~6% of samples are dropped (active length 19,890 vs ~21,090 expected) — mild
  **underruns**: the producer occasionally can't refill in time under the
  reflection cost. Audible as slight timing jitter, not garbling. Refinements:
  larger ring (already 32 KB), higher `COVOX_REFILL_HZ`, or a cheaper producer.

### Where this lands

- **Real-mode games at ≤~8 kHz under SBEMU+Covox: working and verified** — the
  original objective (invisible SB PCM to a Covox for a trapped SB program) is
  met for the real-mode case. This is genuinely new: classic VSB can't host a
  DPMI game at all; this can, and now emits correct Covox audio.
- **Higher rates / DOOM (PM)** remain gated by the ring-3 interrupt-reflection
  cost (22 kHz starved the foreground in QEMU). The honest next question is the
  `cycles386` price of the per-interrupt path on a real 386SX-40 — that decides
  whether pushing the rate up, or the PM/DOOM case, is worth the interrupt-cost
  reduction work (raw-IVT hook for the RM path; PM route only where required).

## Stage 5: 386SX-40 pricing pass — `build/covox/cycles386_covox.py`

A companion cost model to `build/harness/cycles386.py` (which prices classic
VSB), built on the same 80386 SX timing basis, with the two structural unknowns
as explicit LOW/MID/HIGH bands: **R** = HDPMI ring-3 interrupt-reflection per
IRQ0, **P** = SBEMU producer mixing per output sample. Modeled 386SX-40 result
(MID band, playing):

| rate | SBEMU+Covox | classic VSB | note |
|---|---|---|---|
| 8 kHz  | ~13% | ~7% | the verified-working point |
| 11 kHz | ~18% | ~10% | |
| 16 kHz | ~27% | ~14% | ≈ VSB's documented budget |
| 22 kHz | ~37% | ~20% | heavy but plausible on real silicon |

Findings:
1. **The path is ~1.6–2× VSB's per-sample cost, and the extra is almost all R**
   — HDPMI's ring-3 reflection, the cost VSB's ring-0 VM86 design pays ~0 for.
   Producer mixing (P) is the smaller term.
2. **QEMU's 22 kHz starvation is pessimistic.** TCG over-weights V86/PM mode
   switches (which dominate R), so real silicon should be far cheaper than the
   emulator implies — the model puts 22 kHz at ~37%, not 100%. Confirm with a
   duty probe on real hardware before trusting either number.
3. **Biggest surprise — the silence burn.** The backend does not idle the PIT
   when nothing is playing, so silence costs the *full-rate* reflection+consumer
   continuously (~12–32% depending on rate/band) where classic VSB idles to
   ~0%. On paper this is the single largest waste.

Two levers, and an honest note on each:
- **Idle-gating** (kill the silence burn) is the biggest paper win, BUT doing it
  generally re-opens PIT virtualisation: to idle the PIT in silence and restore
  it when a game that *also* uses the PIT starts sound, the backend must trap
  40h/43h (SBEMU doesn't) and reconstruct the game's rate — VSB's Int8Coeff
  mechanism. Cheap for PIT-agnostic programs (sbdma), substantial in general.
- **Raw-IVT hook for the real-mode path** cuts R toward VSB's native ~217 by
  bypassing HDPMI's reflection when the game is in real mode (PM route kept only
  for DOS-extender games like DOOM). This is the lever that makes higher rates
  affordable; also substantial (DPMI-host-level interrupt work).

Net: the pricing pass confirms **≤~16 kHz real-mode Covox audio is affordable on
a 386SX-40** (≤~VSB's own budget), the verified 8 kHz result sits comfortably
inside that, and pushing toward 22 kHz or DOOM is gated by two well-characterised
(but non-trivial) interrupt-cost levers rather than anything unknown.

## Stage 6: idle-gating implemented — silence burn gone AND 22 kHz unlocked

Acted on the pricing pass's #1 finding. `sc_covox.c` is now an active/idle state
machine (increment 1, correct for PIT-agnostic programs):

- **Idle** (no stream): PIT ch0 left at the BIOS 18.2 Hz. The ISR just passes the
  tick to the BIOS/game int8 and polls `SBEMU_HasStarted()`. No consumer, no
  producer — ~0% CPU in silence.
- **Active** (SB playing): on the idle tick that sees the stream start, spin PIT
  ch0 up to the sample rate, resync `playpos` to the producer frontier, and run
  the full consumer + producer. Drop back to idle `~250 ms` after the stream
  ends (hysteresis, drains the tail first).

Verified in the harness (real-mode sbdma), two wins:
1. **Silence burn eliminated.** Total LPT output for the sbdma run fell from
   ~470 KB (continuous full-rate silence) to **~21.7 KB** — essentially just the
   playback burst. Audio unchanged: peak windowed correlation **0.907** (best
   yet), lag-1 autocorr 0.55. This is the model's #1 waste, closed.
2. **22 kHz now works.** Because sbdma now *initialises* with the PIT idled
   instead of fighting a full-rate ISR, the earlier 22 kHz starvation is gone:
   **16 kHz and 22 kHz both play recognisable audio** (peak corr 0.64 / 0.63) at
   the *same ~6 % underrun as 8 kHz*. The "not limited to 8 kHz" goal is met —
   the achievable rate was being throttled by init-time starvation, not the
   steady-state cost.

Remaining, in order:
- **~6 % underrun**, rate-independent (so it's buffer/refill cadence, not
  starvation): mild timing jitter. Refine via a larger ring / higher
  `COVOX_REFILL_HZ` / cheaper producer.
- **Increment 2 — full PIT virtualisation** (trap 40h/43h): needed for games
  that reprogram the timer (DOOM's ~140 Hz DMX tick) so idle/active PIT changes
  don't skew the game's clock. sbdma and PIT-agnostic games don't need it; DOOM
  does. This is the shared prerequisite with the DOOM (PM) case.

## Stage 7: PIT virtualisation + PM-safe timer chaining (toward DOOM)

Two mechanisms landed, each with a subtle wall found and solved:

1. **Trap 40h/43h (PIT ch0).** Capture the game's divisor, deliver its int8 at
   that rate from our fast tick via the accumulator (`covox_game_step`), never
   let its divisor reach hardware. **Wall:** because we trap those ports, our OWN
   `covox_set_pit` writes (and passthroughs) re-enter the trap — confirmed as an
   infinite loop, and a mis-captured own-write once set a bogus 2 kHz game rate.
   **Fix:** route all our 0x40/0x43 access through SBEMU's `UntrappedIO_OUT/IN`
   (host untrapped-IO, works PM+RM — the path its own passthrough handlers use).
   Trap only 0x40 and 0x43 (PM needs two single-port installs; trapping the
   0x40-0x43 *range* would catch 0x41 DRAM-refresh and hang). Verified: sbdma
   unchanged (0.907); trap installs and is harmless for PIT-agnostic programs.

2. **PM-safe int8 chaining.** Our IRQ0 fires while the CPU may run V86 code
   (real-mode game) or PM code (DOS/4GW game). **Wall:** a bare
   `DPMI_CallOldISR` to the real-mode int8 from a PM context faults — DOOM died
   with `JemmEx: exception 06` during DOS/4GW init. **Fix:** `covox_chain_int8()`
   gets the interrupt context (`HDPMIPT_GetInterrupContext`) and, per SBEMU's own
   `MAIN_InterruptPM`, uses the bare call only when `EFLAGS & CPU_VMFLAG`
   (interrupted V86) and `DPMI_CallOldISRWithContext(&h, &ctx.regs)` otherwise
   (interrupted PM). **Verified (diagnostic):** with the bad bare call removed,
   DOOM boots *past* the DOS/4GW crash all the way to `I_StartupMouse …
   I_StartupTimer()` — the mode-safe variant is the real fix, and mirrors SBEMU.

**Correction/refinement (verified with the harness back up):** the mode-safe
single-function chainer was *not enough* — DOOM still faulted, because the crash
context is V86 (EFLAGS VM=1), so it took the bare-call branch, and a single ISR
function chaining the *PM* handle from the *RM* path is the actual bug. SBEMU
avoids this with two separate functions (`MAIN_InterruptPM`/`MAIN_InterruptRM`),
each chaining its own handle with the matching call
(`DPMI_CallOldISR`/`WithContext` for PM, `DPMI_CallRealModeOldISR` for RM).

**Fix (Stage 8): split the Covox ISR into PM and RM entry points**
(`COVOX_timer_isr_pm` / `_rm`), sharing one body but each passing the correct
chainer. Result, verified:
- **DOOM no longer crashes.** It boots clean through `R_Init` (WAD load),
  `P_Init`, `I_Init`, and every `I_Startup*` subsystem to `I_StartupTimer()` —
  far past the old DOS/4GW `exception 06`.
- **sbdma unchanged** on the split build (lag-1 0.872 @16 kHz) — the RM path now
  uses `DPMI_CallRealModeOldISR` and is identical in behaviour.

**Remaining DOOM blocker (precisely characterised):** DOOM boots but then hangs
in its main loop — 220 s with no gametics and no SFX. Cause: DOOM installs its
own int8 handler *after* we armed, and (because we took the int8 vector via
`DPMI_InstallISR`) DOOM's saved "old" handler is *our* wrapper. Our ISR chains
the handler we saved at arm time (the pre-DOOM BIOS int8), so **DOOM's own timer
handler never receives our reconstructed ticks** → its game clock never advances.
Calling DOOM's current handler instead would recurse (it chains back to us).
The fix is to re-seat the hook so DOOM chains to the BIOS, not to us: take IRQ0
via HDPMI routing only (leave the int8 IVT vector as BIOS so DOOM's "old" is
BIOS), and call the game's current int8 at the divided rate. That's genuine
DPMI-host interrupt-chaining work — the honest last mile for DOOM.

(Harness note: mid-session the QEMU runner got flaky — background launches
intermittently exit 1, and long foreground runs are killed. Reliable pattern
now: launch qemu via a backgrounded tool call with `-monitor none` or a unix
monitor socket, then poll `lpt.bin`/screen from short foreground cells; re-verify
in a fresh session with `build/covox/harness/run-sbdma.sh` and a DOOM
`-timedemo`.)

## Stage 9: DOOM traced further — the hang is timer SETUP, not tick delivery

With the split ISR, DOOM boots and (via `/DBG1` + a COM1 trace) we can see what
it does:
- **DOOM reprograms PIT ch0 to 140 Hz** (`PITAPPLY div=8522 rate=140`) — our
  40h/43h trap captures it correctly. So timer virtualisation is engaging.
- **DOOM then hangs at `I_StartupTimer()`** — no SFX ever (`SBEMU_HasStarted`
  never true, LPT stays at the 1-byte BIOS probe), for 220-280 s.

Attempted fix (reverted): deliver each reconstructed tick to DOOM's *current*
int8 (read live via `DPMI_GetISR`, with a reentrancy guard so DOOM's chain-back
into our wrapper falls through to the BIOS). It did **not** change the outcome —
DOOM still hangs at `I_StartupTimer()`. Crucially, the hang is present in BOTH
the plain split-ISR build and the tick-delivery build, which means **the blocker
is DOOM's timer *setup/calibration*, not the steady-state tick hand-off.** The
speculative tick-delivery code (plus a per-tick `DPMI_GetISR`/INT 31h in the ISR,
which is itself risky) was reverted to keep HEAD at the verified split-ISR state.

**Leading hypothesis (unconfirmed):** DMX's `I_StartupTimer` calibrates by
reading the PIT counter (latch ch0 via 43h, read 40h). Our trap passes counter
reads straight to the *hardware* counter, which is running at the 16 kHz output
rate — so DOOM reads a counter cycling ~880× too fast and its calibration
never converges (or divides by a bad delta). The fix would be **PIT counter-read
virtualisation**: synthesise a ch0 count consistent with the *game's* programmed
divisor and elapsed time on latch/read, instead of passing hardware through.
That plus correct tick delivery is the remaining DOOM work — genuinely a fresh-
session task, and it wants a stable harness (this session's QEMU runner became
unreliable for the ~2-3 min DOOM runs).

**Where DOOM stands, precisely:** boots clean to full init; timer trap engages
(140 Hz captured); hangs in `I_StartupTimer`. Real-mode Covox audio (the shipped
deliverable for real-mode games at ≤22 kHz) is unaffected and verified
(sbdma 0.872).

## Stage 10: DOOM timer path fully diagnosed — it's HDPMI IRQ-routing internals

Instrumented the ISR (PM/RM call counts + live int8 vector) during a DOOM run.
Findings over 15 000 ticks:
- **DOOM reprograms PIT ch0 to 140 Hz** (`div=8522`) — our trap captures it.
- **DOOM never hooks the int8 vector we can see** — the PM int8 vector stays
  `177:20` and the RM vector `30d5:73c` for the entire run. So "call the current
  int8" can never reach DOOM's timer handler; it isn't there.
- **Every physical IRQ0 fires BOTH our PM and RM wrappers** (`pm==rm` always) —
  HDPMI delivers each interrupt through both handler chains (per the routing
  comment in main.c). Our body double-executes; SBEMU guards this with
  `MAIN_InINT`/`irq_routine`, we don't. (Harmless for real-mode sbdma, which only
  exercises the RM path, but real for a PM game.)

Conclusion: **DOOM's IRQ0 handler is registered inside HDPMI's IRQ-routing chain
(via DPMI), not on the IDT/IVT int8 vector.** When we took over IRQ0 with
`HDPMIPT_InstallIRQRoutedHandler`, we displaced that chain, so DOOM's timer never
ticks → its game clock never advances → hang in `I_StartupTimer`.

Two fixes tried, both wrong:
1. Call the live int8 vector (`DPMI_GetISR`+reentrancy guard) — no effect
   (DOOM isn't on that vector).
2. Call the saved OLD ROUTED handle (`covox_oldroute`) via `DPMI_CallOldISR` —
   **crashes** (`exception 06` at a garbage `9090:90BE`): the routed handle's
   `cs:offset` is NOT a plain callable far pointer; HDPMI invokes the chain via
   its own dispatch, for which there is **no exposed API** (`hdpmipt.h` offers
   Install/Get/Enable/Disable/Lock routing — nothing to *invoke* the old chain).

**So the DOOM finish line needs HDPMI-internals work**, one of:
- add an "invoke previous routed handler" primitive to the HDPMI fork and call it
  at the divided rate (plus dedupe the PM/RM double-fire, à la `MAIN_InINT`); or
- don't displace IRQ0 routing at all — drive Covox output from a *different*
  timer (RTC/IRQ8, ≤~8 kHz) and leave PIT/IRQ0 entirely to the game (the Path-B
  tradeoff, but it sidesteps the whole routing conflict for PM games).

This is beyond the exposed SBEMU/HDPMI interface and needs a stable harness (this
session's QEMU runner became unreliable for multi-minute DOOM runs). HEAD stays
at the verified split-ISR: **DOOM boots to full init; real-mode Covox audio
(≤22 kHz) is done and verified.** DOOM SFX-through-Covox remains open, now with a
complete root-cause map rather than a guess.

### Remaining for DOOM after this
- Counter reads (0x40 in) are passed straight through (live hardware counter at
  our rate); if DOOM's timing needs a virtual latch/counter, add it.
- Price the combined DOOM+Covox path on a real 386SX (DOOM alone is a slideshow
  there; `cycles386_covox.py` covers the sound half).

## Stage 11: ring-0 fast path in the host — HDPMI-internals work DONE

The Stage-10 conclusion ("needs HDPMI-internals work") is now implemented — and
it turned out to solve BOTH open problems (per-sample cost and DOOM's routing
conflict) with one mechanism, because we now build HDPMI32i from source:

- **Toolchain** (`build/covox/hdpmi/`): crazii/HX pinned (`HX_COMMIT`) +
  `hx-covoxr0.patch`; JWasm and JWlink both build native-Linux from source
  (`make -f GccUnix.mak`); `setmzhdr.py` replaces SetMZHdr.exe (header shrink
  so DOS loads only the 16-bit part). Baseline gate: the UNPATCHED rebuild is
  behaviorally identical to the shipped binary in the sbdma harness (same
  byte count, same correlation, same offset).
- **The fast path** (`?COVOXR0`, `intr08`): one ring-0 drain per PIT tick —
  ring byte -> L+R downmix -> LPT OUT -> EOI -> IRETD, no LPMS switch, no
  ring-3 reflection. Per-tick outcome decided by two accumulators in a
  client-owned control block (CVCB, registered via new vendor fn 0Fh):
  *game ticks* reflect with `cvSkipRoute` so `lpms_call_int` bypasses the
  routed handler and delivers to the CURRENT client's own int8 — this is the
  clean fix for Stage 10 (DOOM's timer ISR lives in ITS DPMI client's vector
  table, unreachable from the backend's client context by ANY ring-3 chain);
  *producer wakes* (~120 Hz) reflect normally to the routed handler (the
  backend refills the ring); idle ticks pass 1:1 to the client.
- **Backend wiring** (`sc_covox.c`): registers the CVCB when the host has fn
  0Fh (COVOXNOR0=1 forces the all-ring-3 fallback); PM stream start moves into
  the DSP trap via a 2-line SBEMU core hook (`SBEMU_StartCallback` — the spot
  crazii left a commented-out `SBEMU_StartCB()` at); RM-window ticks drain
  from the shared CVCB so PM/RM consumers stay coherent.
- **Modeled effect** (`cycles386_covox.py`, ring-0 tier): 666 -> ~396
  cyc/sample mid-band for PM clients — 36.7% -> ~22% CPU @22 kHz on a
  386SX-40, within ~15% of classic VSB itself; the R-band uncertainty
  collapses because reflections now happen at 120 Hz, not per sample.

### Debug war stories (recorded so nobody repeats them)
- Chaining "the live int8 vector" from ring 3 cannot work for extender games
  (per-client vector tables), and calling DPMI services (`DPMI_GetISR`) from
  ISR context corrupts the host — the floppy driver was the canary.
- A hand-written `pushl %esi` before reading an `"m"` operand in inline asm
  breaks gcc's ESP-relative operand addressing at -O2: the vendor call passed
  garbage in ESI, the host stored 0x177 as the CVCB pointer, and the "fast
  path" spent its life read-modify-writing host data at SS:0x177 and OUTing
  to a junk port every tick. Diagnosed by `pmemsave` + disassembling the live
  code out of guest RAM + reading `covoxr0_cb` via the link map. Fix: the
  `"S"` constraint (gcc loads ESI itself).

## Stage 12: DOOM DSP detection + auto-init stream fixed

With COM1 `_LOG` tracing finally wired (`SBEMU /DBG1` + `-serial file:`), the
"detection loop" decomposed into observable facts instead of theories:

- The endless `DSP RS` lines are **Read Status polls (22Eh)** — DMX's SB-IRQ
  ack — not resets. DMX's detection sends `E1` (version) then **`F2` (IRQ
  request)**: a real SB raises its IRQ immediately; DMX busy-waits
  (SBEMU_DELAY_FOR_IRQ) and checks its handler flag.
- SBEMU services that trigger at the top of `MAIN_Interrupt` — which in
  ring-0 mode only runs on producer wakes, and producer wakes only run while
  the stream is ACTIVE. `F2` arrives while idle -> the trigger was never
  serviced inside the wait window.
- Fix: the `SBEMU_StartCallback` core hook now fires on `SBEMU_TriggerIRQ`
  too, so `F2` spins up the timer machinery exactly like a stream start; the
  first pump (~8 ms) services the trigger. Trace confirms `PUMP info=11
  trig=1` then `trig=0`, no CALLINT starvation, and DMX proceeding to its
  real configuration: SB Pro stereo mixer writes, `40` tc=211 (11 kHz
  stereo), `48 FF 00` (block 256), `90` auto-init high-speed DMA - the
  actual DOOM SFX stream - with `MAIN_Interrupt` consuming game DMA and
  delivering per-block virtual IRQs (`samples:... 256 <pos>` traces).
- Debug-build console logging throttles the guest badly (VGA writes per log
  in interrupt context); judge behavior with the release build and the LPT
  capture, keep /DBG1 for forensics only.

## Stage 13 (open): V86-window tick cost - the next narrow-driver target

With detection fixed, DOOM advances through its full init and its 140 Hz
timer + 35 Hz game tics verifiably run (RAM-counter diffing: +140/s and
+35/s equivalents in DOOM's zone during D_DoomLoop). The remaining drag:
while the CPU sits in a V86 window (DOS file I/O - level loading), every
PIT tick takes JEMM IVT -> SBEMU's RM wrapper -> full RM->PM DPMI switch ->
C body -> back, at the output rate. At 22 kHz that is ~500+ cycles per tick
of pure mode-switching on a 386SX (~30-45% CPU during any DOS call), and
under QEMU TCG it slows level loads to a crawl. `/K11025` halves it and is
lossless for DMX (mixes at 11 kHz); the real fix is the same trick as ring 0:
a pure real-mode drain stub in conventional memory (VSB-style: out sample,
EOI, iret; chain to the PM machinery only at pump/game rate). Requires the
CVCB+ring to move below 1 MB (conventional DOS memory) so the stub can
reach them - MDma's XMS allocation puts them high today.
