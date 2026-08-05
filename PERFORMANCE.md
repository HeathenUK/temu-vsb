# VSB Performance: Analysis and Staged Optimization Plan

**Scope:** VSB 2.02, **standalone (pure DOS) build** (`sbemu/vsb_real.asm` + shared
`386p*.asm` monitor), output to a **Covox LPT DAC**, target machine **386SX @ 40 MHz**.
The QEMM build and the PC-speaker output path are documented but deferred (see §8).
TEMU is out of scope, but it links the same `386p*.asm` library, so shared-file changes
must keep TEMU assembling and behaving identically.

**Status:** **Phase 1 complete** — idle gating (F1: the PIT returns to the game's
own rate after 2 game-ticks of DMA inactivity, with deferred `40h`, phase carry,
and re-arm on every start path) and the zero-DS-load ISR (F2 cheap tier) are
implemented and green on both behavioural harness scenarios, including a
positive PIT-idle probe. Expected effect on the 386SX/40: ~0% CPU during
silence (was ~7–15%), pending confirmation on real hardware. Phase 0 records:
(1) Build: the repo sources (after restoring four files damaged by a 2017
re-import) assemble clean under TASM 4.1/DOSBox and produce a binary
structurally equivalent to the shipped 1995 `vsb_real.com`, gated by
`build/build.sh` + `build/verify.py`. (2) Behaviour: `build/harness/run-harness.sh`
boots FreeDOS in QEMU, installs the rebuilt VSB, plays `sbemu/sample` through the
emulated DSP/DMA via the author's `sbdma.exe`, and PASSes with the captured Covox
LPT stream reproducing the sample byte-for-byte (26100/26100) and the virtual
IRQ5 firing. Phase 1 changes are next, gated by that harness.
Each phase lands as separate, independently revertible commits on this branch.

---

## 1. Executive summary

VSB's cost is architectural, not incidental. It is a tiny ring-0 hypervisor: DOS and the
game run in VM86 while VSB traps SoundBlaster/DMA/PIT/PIC port I/O and plays the game's
"DMA" buffer one byte per timer interrupt to the DAC. A Covox has no FIFO, no DMA, and no
sample clock, so **one hardware interrupt per output sample is mandatory**, and the
VM86→ring-0→VM86 transition (~200+ CPU-fixed cycles on a 386) dominates everything.

Three findings drive the plan:

1. **The sample-rate timer keeps running during silence** (the PIT is never restored when
   playback ends). This burns an estimated 7–15% CPU doing nothing, most of the time, in
   most games. Fixing it is safe, needs no quality trade-off, and the machinery
   (`SetTimerFreq`, the `Int8Coeff` fractional-tick accumulator) already exists.
2. **Active playback has ~100–150 removable cycles per sample** (segment reloads,
   duplicate counter bookkeeping, per-tick EOI) on top of the irreducible transition cost.
3. **Everything below ~5.5–7% CPU per 11 kHz of output rate is unreachable** while the
   design stays a transparent hypervisor. Going lower requires opt-in quality trade-offs
   (output-rate cap) or a different product (driver-level shims).

Expected end state on the target machine: **~0% CPU while silent** (today: ~7–15%),
**~8–10% during 11 kHz playback** (today: ~11–13%), and an opt-in `/Q` cap that holds
22 kHz-hungry games to the same budget.

---

## 2. How the standalone build works (orientation)

| Piece | File | Role |
|---|---|---|
| Entry, ISR, DSP/DMA state, patches | `sbemu/vsb_real.asm` | `IRQ0handler`, `EnableDMA`/`EnableSB` patch switches, `SetTimerFreq`, install |
| Port trap dispatch (the "DSP") | `sbemu/s386port.asm` | Included into the #GP decoder; jump tables for ports 220h–22Fh, DMA 0–Fh, 40h/43h, 20h/21h, 83h, 388h/389h |
| PM monitor library (shared with TEMU) | `386pdef.asm`, `386pdata.asm`, `386plib.asm`, `386pint.asm`, `386pdt.asm`, `386preal.asm`, `386rdata.asm` | GDT/IDT/TSS, VM86 switch, #GP instruction decoder, hardware-interrupt reflection, debug dump |

Mechanics worth keeping in mind:

- DOS+game run in VM86 with **IOPL=3** (`386pdef.asm:14`, pushed at `386preal.asm:275`),
  so `INT n`/`CLI`/`STI`/`PUSHF` run natively and **only ports set in the TSS I/O permission
  bitmap trap** (`IOportMap`, `386pdata.asm:39`, configured at `vsb_real.asm:343`). This is
  already the cheap-trap configuration.
- A trapped `IN`/`OUT` raises #GP → `Int13h` (`386pint.asm:203`) fetches the opcode via a
  flat selector and dispatches into `s386port.asm`. Untrapped I/O runs at native speed.
- IRQ0 is taken **directly** by `IRQ0handler` via IDT gate 20h (`vsb_real.asm:340`); all
  other IRQs reflect to the VM86 vectors through `HWint`/`IRQset` (`386pint.asm:596`).
- `SetTimerFreq` (`vsb_real.asm:152`) programs PIT ch0 to the sample divisor and computes
  `Int8Coeff = 65536 * physical_divisor / game_divisor` (0.16 fixed point). The ISR
  accumulates it into `Counter`; carry = one virtual game tick, chained to the game's
  INT 8 (`@@DoOld`, `vsb_real.asm:61`). The game's own PIT programming is virtualized via
  the 40h/43h traps (`s386port.asm:68–84`), tracked in `IRQ0freq`.
- Steady-state playback (`IRQ0handler`, `vsb_real.asm:26–59`): load DS, patched
  `mov es,ax` (flat), fetch byte at `SamplePointer` (an immediate operand modified in
  place each tick), OUT to the Covox port (`CovoxPatch`/`DACport`, `vsb_real.asm:244`),
  increment pointer, decrement `SBcounter` **and** `DMAcounter`, accumulate `Counter`,
  specific EOI, `IRETD`.
- Block end (`LastSBbyte`, `vsb_real.asm:99`) raises the virtual SB IRQ (default IRQ5 →
  VM86 int 0Dh) — deferred via `DoAnIRQ` if the game still has it masked at the virtual
  PIC (`PICmask`), retried once per virtual game tick.

The code is deliberate throughout: ICR-read emulation for IRQ-polling detection schemes,
the undocumented `E2` DSP handshake, 1-byte test-transfer special case, `MinTimerFreq`
clamps. Assume fences are load-bearing until traced (§4 records the audit).

## 3. Where the cycles go (estimates — Phase 0 measures for real)

Assumptions: 40 MHz 386SX, 16-bit bus (every dword transfer = 2 bus cycles), ISA I/O
≈ 0.7–1.5 µs effective per OUT, Intel best-case core timings. To be replaced with
measured numbers from the Phase 0 harness; treat as ±30%.

| Cost, per sample interrupt | ~cycles |
|---|---|
| VM86 → ring-0 interrupt entry (gate, TSS stack switch, 9 dwords pushed) | ~120–170 |
| `IRETD` back to VM86 (9 dwords popped) | ~60–110 |
| DS + ES protected-mode segment loads in handler | ~36 |
| Fetch, SMC pointer increment, 3× read-modify-write counters, branches | ~50 |
| OUT to Covox DAC + OUT 20h specific EOI (2 ISA-class I/O cycles) | ~60–110 |

Totals: **active ≈ 350–450 cycles/sample**; the idle `@@ShutUp` path still pays entry +
`Counter` accumulate + EOI + exit ≈ **250–300 cycles/tick**. At 11.025 kHz that is ~11%
CPU active and **~7.5% idle**; at 22.05 kHz, roughly double. This matches the author's
own "about a quarter of processor's power" (vsb.doc §2) and the observed 25%.

**The floor:** entry + exit + one DAC OUT ≈ 220–280 cycles/sample is fixed by the CPU and
the DAC's lack of a FIFO — **~5.5–7% per 11 kHz of output rate**. Every optimization
below either attacks the removable ~150 cycles, removes interrupts that shouldn't happen
(idle), or reduces the number of samples (opt-in cap). Port traps are second-order for
Covox playback: they occur at block boundaries, not per sample, except for games that
busy-poll port 03h/the ICR (measured in Phase 0) and direct-DAC (`10h`) games, which pay
two traps per sample by design.

---

## 4. Findings and fence audit

Each finding records the *why-it's-there* conclusion, because the original design is
careful and the constraint set (386DX/40 development machine, no profiler, no emulators,
reboot-per-test iteration, resident-KB marketing, shareware distribution to unknown
hardware) made most of these choices rational in 1993–95.

### F1. PIT never restored when playback stops — **fix (Phase 1)**
- **Evidence:** `LastSBbyte` (`vsb_real.asm:99`), DSP halt `D0` (`s386port.asm:221`), and
  reset (`Out226`, `s386port.asm:153`) all disable DMA via patches but never call
  `SetTimerFreq`; the sample-rate divisor programmed by command `40h`
  (`s386port.asm:292`) persists through silence.
- **Impact:** ~7.5% CPU at 11 kHz, ~15% at 22 kHz, during *silence* — for most games,
  most of the time. Also leaves the physical PIT free-running at sample rate where reads
  pass through the trap to the real counter (`DirectRead`, `s386port.asm:530`), so games
  polling PIT ch0 while idle read garbage; restoring the divisor fixes that too.
- **Fence audit:** the naive fix has real pitfalls, which plausibly deterred a rewrite:
  (a) double-buffered playback crosses idle/active 20–40×/s — switching rates at every
  block boundary without carrying the fractional `Counter` phase jitters or drops virtual
  game ticks (audible wobble in games running music off a reprogrammed INT 8);
  (b) every resume path (`14h`, `D4`, auto-init) must re-arm or you ship a silence bug.
  On the author's 386DX/40 the idle burn was halved and invisible without a profiler.
- **Required mitigations:** hysteresis (drop to the game divisor only after ~2 virtual
  game ticks ≈ 110 ms with DMA inactive — also eliminates reprogram churn between
  double-buffered blocks); carry `Counter` phase across switches; re-arm in *all* start
  paths (`LocalTwo2C_14b`, `LocalTwo2C_D4` via `EnableDMA(1)` callers); leave the `DoAnIRQ`
  masked-IRQ retry functional (it already lives on the surviving `@@DoOld` path).
  Defer the physical PIT switch on `40h` until DMA actually starts (also keeps
  direct-DAC games from raising the timer needlessly).

### F2. Per-sample segment loads — **fix cheap tier (Phase 1), skip radical tier**
- **Evidence:** `IRQ0handler` loads DS every tick (`vsb_real.asm:30–31`) and, while
  playing, ES via the `PatchData2` patch (`vsb_real.asm:241`). ~18–19 cycles each in PM.
- **Fence audit:** half the codebase already avoids this — `s386port.asm` uses `ss:`
  overrides throughout because #GP entry has no DS. The ring-0 SS is `@gdData` loaded
  from the TSS on every VM86 interrupt, so `IRQ0handler`'s data references can be
  `ss:`-prefixed (segment-override prefix is free on a 386) and the DS load dropped.
  Plain idiom/habit; a true micro-gap. The ES flat load must stay (DMA-buffer fetch).
  The *radical* tier (single flat 4 GB segment, zero loads, linear-relocated data — the
  QEMM build's `[ebx]` scheme) has a blast radius covering the debug dump, `Back2DOS`,
  and stack layout: not worth it for ~18 more cycles; **rejected**.

### F3. Duplicate per-sample counter bookkeeping — **fix (Phase 2)**
- **Evidence:** three RMW word ops + branches per sample: `SBcounter`, `DMAcounter`
  (`vsb_real.asm:45–48`), `Counter` (`vsb_real.asm:50`).
- **Fence audit:** both counters are architecturally required (DSP block length ≠ DMA
  length is the normal double-buffer pattern) — but per-sample, only the *nearest* expiry
  matters. Precompute `n = min(SBcounter, DMAcounter, ticks-to-game-tick)` at every
  reprogram point, decrement one counter in the ISR, settle the others from elapsed count
  on expiry. ~30 lines replacing 6, and the settle logic must preserve the `0FFFFh`
  "unprogrammed" sentinels (`EnableDMA`, `vsb_real.asm:128–133`), auto-init reload
  (`LastDMAByte`), `E2`'s pointer writes, and ports 02h/03h read-back. Correctly refused
  in 1993 (reboot-per-test debugging); flips to worthwhile with an emulator harness.
  Saves ~15 cycles + 2 branches per sample (branches also flush the 386 prefetch queue).

### F4. Specific EOI every tick / AEOI — **opt-in flag only (Phase 3)**
- **Evidence:** `mov al,60h / out 20h,al` per interrupt (`vsb_real.asm:54–55`); one
  ISA-class I/O cycle ≈ 1–2% CPU at playback rates.
- **Fence audit:** genuine trade-off, author's caution correct. Master-PIC auto-EOI
  changes system-wide semantics: ISRs that `STI` early lose PIC-priority re-entry
  protection (serial mouse drivers are the classic casualty), and clone-PIC AEOI quirks
  existed. Ship as `/E`, default off, soak-tested per machine. Keep the slave PIC normal.

### F5. Output rate = game rate — **opt-in `/Q#` cap (Phase 3)**
- **Evidence:** `LocalTwo2C_40` (`s386port.asm:292`) programs the PIT to whatever the game
  asks (clamped only at ~24 kHz by `MinIRQfreq`/`MinTimerFreq`).
- **Fence audit:** deliberate design, not a gap. "One interrupt = one source byte" is the
  keystone invariant — carry-chained expiries, the SMC pointer, DMA read-back, and `E2`
  all rest on it. A 16.16 phase-accumulator cap (output at ≤ N kHz, advance source
  position by `step`) breaks all of it at once: counters must advance by variable
  amounts, block-end IRQs can overshoot by a sample (auto-init loop clicks), read-back
  needs separate accounting, and nearest-neighbor decimation aliases. Implement as a
  strictly opt-in mode with its own specialized ISR; default remains 1:1.
- **Payoff:** caps worst-case CPU regardless of game (22.05→11.025 kHz ≈ halves active
  ISR load); the right knob for a 386SX.

### F6. PC-speaker pulse-width clipping — **deferred (Covox target)**
- **Evidence:** `shr al,1` → 0–127 pulse widths vs. an 11 kHz PIT divisor of ~108
  (`PatchIRQ`, `vsb_real.asm:242`); loud samples saturate. Fix is a rate-dependent
  256-byte scaling LUT, same per-sample cost. The author labeled `/S` "highly not
  recommended... implemented only because it was very simple" — acknowledged neglect.
  Documented here; implement only if speaker output becomes relevant.

### F7. Trap-path costs — **measure first (Phase 0), optimize only if hot**
- Block-boundary traps are noise. Two cases can be hot: games busy-polling port 03h /
  the ICR during playback, and direct-DAC (`10h`) games (two #GP traps per sample). The
  Phase 0 harness counts traps per second per port; only optimize (fast-path re-entry
  for repeated same-port `OUT`s, tighter dispatch) if a game you actually run shows up.

### F8. QEMM build — **out of scope** (standalone is the daily driver). The known
  improvements there (direct IDT hook for #GP, bypassing the QPI callback — the author's
  own documented "major rewrite I don't have time for") are recorded in §8.

Also noted for forward-compatibility, no action: the per-sample self-modifying pointer
(`SamplePointer` as a `mov ebx,imm32` operand) is optimal on a cacheless 386 and hostile
on 486+; any future 486 path should use a data variable instead.

---

## 5. Staged plan

### Phase 0 — Reproducible build + measurement harness *(prerequisite for everything)*
1. Toolchain: assemble `vsb_real.com` from source (TASM-era syntax: TASM under DOSBox or
   JWasm compatibility — whichever achieves fidelity). **Goal: byte-identical rebuild** of
   the shipped `sbemu/vsb_real.com`; fallback is functional equivalence in the harness.
2. Harness: QEMU full-system DOS image booting VSB; instrument/trace `OUT`s to the LPT
   port with timestamps → automated verification of sample stream content and pacing.
   Reuse the author's own tools (`sbemu/sbdma.exe`, `sbemu/mvsb.exe`, the raw `sample`
   file) plus scripted DSP command sequences (reset/detect, `40h`+`14h` single-cycle,
   auto-init pattern, `D0`/`D4`, `E1`/`E2`, masked-IRQ deferral).
3. Diagnostics: `/D` build flag adding border-color duty-cycle flashes (the `Flash` macro
   already exists in the QEMM source) + a trap-rate counter, for before/after evidence on
   the real 386SX.
4. Baseline: record idle/active duty cycle and trap rates for the games that matter.

**Acceptance:** rebuild verified; harness runs the DSP sequence suite green against the
unmodified binary; baseline numbers recorded (replacing the §3 estimates).

### Phase 1 — Safe corrections (default-on, no behavior change intended)
1. **Idle gating (F1)** with all §4-F1 mitigations: hysteresis, phase carry, deferred
   `40h`, complete resume-path audit.
2. **`ss:`-override cleanup (F2 cheap tier)** in `IRQ0handler`: drop the DS load.
3. Confined to `sbemu/` files where possible; any `386p*.asm` touch must leave TEMU
   assembling byte-identically.

**Acceptance:** harness shows PIT restored to the game divisor within hysteresis after
block end and re-armed on every start path; virtual-tick (DOS clock) drift over a
simulated 10-minute run ≤ baseline; full DSP suite green; idle duty cycle reduced >90%.

### Phase 2 — ISR slimming (default-on after regression proof)
1. **Merged min-counter (F3)** with sentinel/auto-init/`E2`/read-back semantics preserved.
2. 16-bit pointer forms / shorter encodings in the hot path (prefetch-bound on the SX bus).

**Acceptance:** DSP suite green including auto-init loop-point exactness (no ±1-sample
drift across 1000 reloads in the harness); measured active-path cycles reduced.

### Phase 3 — Opt-in flags (default off; the author's caution was correct)
1. **`/Q#` output-rate cap (F5)** as a separate specialized ISR path.
2. **`/E` auto-EOI (F4)**, master PIC only.

**Acceptance:** with flags off, binary behavior identical to Phase 2; `/Q` verified for
pacing/loop exactness at 22→11 kHz; `/E` soak-tested on target hardware (long session
with mouse/keyboard/disk activity).

### Ordering rationale
Value/risk sorted: Phase 1 is most of the real-world win at least risk; Phase 2 is
bounded micro-optimization behind a regression suite; Phase 3 changes behavior and so
ships dark. The floor (§3) says stop optimizing the transparent path after Phase 2 —
further gains come only from `/Q` or from non-goals (§8).

---

## 6. Expected outcomes (to be re-baselined after Phase 0)

| State | Today | After P1 | After P2 | After P3 (`/Q11`) |
|---|---|---|---|---|
| Silence (game idle, 11 kHz set) | ~7.5% | **~0%** | ~0% | ~0% |
| Silence (22 kHz set) | ~15% | **~0%** | ~0% | ~0% |
| Playback @ 11.025 kHz | ~11–13% | ~10–12% | **~8–10%** | ~8–10% |
| Playback @ 22.05 kHz | ~22–26% | ~21–25% | ~17–20% | **~9–11%** |

Direct-DAC (`10h`) games are governed by trap cost, not the ISR; F7 measurement decides
whether they get attention.

## 7. Risk register

| Risk | Phase | Mitigation |
|---|---|---|
| Missed re-arm path → silence bug | P1 | Enumerated start paths + harness DSP suite |
| Virtual-tick jitter/drift at rate switches | P1 | Phase carry + hysteresis + drift test |
| Merged-counter settle breaks sentinels/auto-init | P2 | Preserved-semantics tests, 1000-reload exactness check |
| `/Q` overshoot at block ends (loop clicks) | P3 | Overshoot settle at expiry; opt-in only |
| AEOI re-entrancy in third-party ISRs | P3 | Opt-in only; slave PIC untouched; soak test |
| Toolchain drift vs. shipped binary | P0 | Byte-compare gate before any code change |
| Shared `386p*.asm` regression into TEMU | all | TEMU byte-identical assembly check in CI script |

## 8. Explicitly out of scope / deferred

- **QEMM build work** (direct #GP IDT hook replacing the QPI callback; per-trap cost is
  several × the standalone build's): revisit only if the daily-driver setup changes.
- **PC-speaker LUT (F6):** documented defect, Covox user — implement on demand.
- **Driver-level paravirtualization** (CT-VOICE/DIGPAK/AIL shims; real-mode ~60-cycle
  interrupt entry; would reach DOS-extender games): a different product, not an
  optimization of VSB; noted as the only route below the §3 floor.
- **HLL rewrite:** no gain available; the hot path is already near-minimal assembly and
  the cost is ring-transition physics.

## 9. Provenance

Produced from a full source review of this repository (standalone chain: `vsb_real.asm`,
`s386port.asm`, `386p*.asm`; QEMM build read for comparison; `ready/vsb.doc` consulted —
its "quarter of processor's power" matches the reported ~25% on the target machine).
Findings F1/F5 and parts of F2/F3 were independently confirmed by a second review of the
same sources; the fence audit (§4) additionally credits the original author's published
rationale in `ready/vsb.doc` (QEMM rewrite acknowledged as unaffordable; `/S` speaker
mode acknowledged as minimal-effort). Cycle figures are estimates pending Phase 0
measurement and are labeled as such.
