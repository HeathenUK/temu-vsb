# One binary, hand-crafted asm: teaching VSB to be its own DPMI host

**Goal (the user's, verbatim):** one hand-crafted-assembly resident that
transparently presents Covox + real OPL3 as a Sound Blaster to *any* DOS
program — real-mode **and** protected-mode/DOS-extender titles like DOOM — on a
386SX, with minimum CPU impact. No stack of loaders. One thing.

## The decision (why VSB, not a rewrite)

There are three hand-written-asm bodies of code in play. Only one of them is
already the whole product minus a single capability:

| base | what it already is (hand asm) | what it lacks |
|------|-------------------------------|---------------|
| **VSB** (`sbemu/vsb_real.asm` + `386p*.asm` + `s386port.asm`) | a self-contained ring-0 **V86 monitor** with its own GDT/IDT/TSS, that **traps SB/DMA/PIT/OPL ports** via the TSS I/O bitmap → #GP → emulates, and **outputs PCM to Covox** + passes FM to a **real OPL3** (`/A`). One `.com`, ~15 KB, no dependencies. **Verified** (sbdma corr up to 0.9). | a **DPMI host**, so DOS-extender clients (DOOM/DOS4GW) can run under it. That's the *only* reason DOOM aborts today. |
| **HDPMI** (`build/covox/hdpmi/`) | a complete hand-asm **DPMI host** (~30 asm files) that already runs DOOM. | any **SB emulation** (that lives in SBEMU's C) and a self-contained **V86 monitor** (it leans on JEMM/QPIEMU). Not one binary. |
| **SBEMU** (`build/covox/`) | full **SB emulation**, but in **C** (DJGPP). | it is a 32-bit **DPMI *client*** — it cannot be a standalone TSR; it needs a DPMI host resident under it. Not hand asm, not one binary. |

Re-implementing SBEMU's SB core (VSB already has one) or re-implementing HDPMI
(already hand asm, already builds here) would be throwing working code away. The
**one genuinely missing hand-asm piece** for a single do-everything binary is a
**DPMI server folded into VSB**. VSB is the only base that is already
self-contained (its own V86 monitor + SB emulation + Covox/OPL3 output) — adding
a DPMI host to it yields *one* `.com` that needs nothing else loaded.

So: **extend VSB into its own DPMI host.** This is the deferred "VCPI/DPMI-server
rewrite" the covox README names as the true single-binary end-state.

## What can and can't be verified here (the honest scope)

The host's **mechanics are testable here with targeted probes** — the same
technique that verified milestone 1. A probe is a tiny purpose-built program
that exercises one host feature and reports the outcome over the LPT port
(captured by QEMU). `testdpmi.com` did this for the handshake; milestone 2 gets
a probe that performs the mode switch and writes a marker *from protected mode*;
milestone 3 a probe that calls each `int 31h` service and reports results; etc.
These run in well under a second and pinpoint the exact failure — a strictly
better test than a whole game.

The **one** thing that genuinely can't run here is a full commercial extender
game (**DOOM**) all the way to audible in-game sound: DOOM is too large for the
QEMU TCG interpreter to drive to gameplay in harness time
(`build/harness/doom-spike.md`), and it lights up the entire host surface at
once, so a single gap hangs it with no diagnostic. That final acceptance run
needs real hardware or a faster emulator. Everything *underneath* it — every
host mechanism DOOM relies on — is probe-verifiable here, and each milestone
below is gated on its own probe. Nothing is claimed working that wasn't run.

To keep the **shipping product safe while the host is built**, all DPMI code is
behind the `VSB_DPMI` conditional-assembly flag. The default `vsb_real.com` stays
byte-for-byte the proven real-mode product; `vsb_dpmi.com` is the
work-in-progress host target. A half-built host must never advertise itself and
then fault a real game — so until the mode switch actually works, the detection
responder is only in the flagged build, and its mode-switch entry returns
CF=set (clean "can't") rather than crashing the client.

## Milestones (ordered; each builds on the last)

1. **DPMI detection responder — `int 2Fh AX=1687h`.** A resident, chained
   real-mode int 2Fh handler (reached in V86 via the monitor's `DoIntNN`
   reflection, so AX is trivially readable). Answers: DPMI installed, 32-bit
   supported, CPU 386, version 0.90, host-data paras, and `ES:DI` = mode-switch
   entry. Mode-switch entry is a WIP stub (CF=set).
   *Checkable here:* assembles green; a real-mode probe (`testdpmi`) reads back
   the advertised fields; `vsb_real.com` unchanged.

2. **V86 → ring-3 PM mode switch.** On the client's far-call to the entry:
   build an LDT (client CS/DS/PSP/env selectors over its real-mode memory),
   and transition it from V86 into ring-3 protected mode at the return address
   with a PM stack. VSB's `SwitchToPM`/`SwitchToVM86`/TSS primitives are the
   reusable substrate, but running a *client* at ring-3 PM is new machinery.
   *Probe (`testpm`):* far-call the entry, then from the resulting PM context
   write a marker byte to the LPT port and read back a client selector — the
   capture proves the switch executed real PM code. Fast, deterministic, here.

3. **`int 31h` services.** Descriptor alloc/free/set-base/limit/access; alloc/
   free DOS memory; get/set real-mode & PM interrupt vectors; allocate
   real-mode callback; simulate real-mode int / far-call / iret. The subset
   DOS4GW/DOOM actually calls.

4. **Reflection + PM SB trapping.** Reflect the PM client's int 21h/int 10h/…
   down to real-mode DOS (V86 round-trip, register-frame copy); deliver HW IRQs
   to the client's PM handlers; and trap the client's SB/DMA/OPL port I/O *in
   protected mode*, routing it into the existing `s386port.asm` emulation so
   DOOM's PCM lands on Covox and its FM on the real OPL3.

At milestone 4, `vsb_dpmi.com` is the single hand-asm binary that does
everything; `VSB_DPMI` becomes the default and the loader stack
(`SBCOVOX.BAT`, JEMM/QPIEMU/HDPMI/SBEMU) is retired for it.

## Status

- [x] Architecture decided and recorded (this doc).
- [x] **Milestone 1** — detection responder (`sbemu/s386dpmi.asm`, behind
  `VSB_DPMI`). **Verified in QEMU** (`run-harness.sh dpmi`): a guest program's
  `int 2Fh AX=1687h` is reflected by VSB's V86 monitor into the handler, which
  answers `CF=0, AX=0000, BL=01 (32-bit), CL=03 (386), DX=005A (v0.90),
  entry=<cs>:<off>` — read back byte-exact off the LPT port by `testdpmi.com`.
  Default `vsb_real.com` proven byte-identical (only the assembly-clock seconds
  in the help text differ), so the shipping product is untouched. The
  mode-switch entry is still the honest WIP stub (CF=set) until milestone 2.
- [x] **Milestone 2** — V86→ring-3 PM mode switch (`s386dpmi.asm`
  `DpmiDoSwitch`, `DoHalt` hook in `386pint.asm`, `gdLDT` in `386pdt.asm`).
  **Verified in QEMU** (`run-harness.sh pm`): `testpm.com` far-calls the entry
  and, from the resulting context, writes `PMOK` + its CS to the LPT port — the
  capture decodes `CS = 000F` = `selCode` (LDT, ring-3), proving real ring-3 PM
  code executed after the switch. The entry HLTs → traps to the monitor → the
  `DoHalt` hook recognises our resident CS:IP → `DpmiDoSwitch` builds a 4-entry
  LDT (code/data/stack/PSP over the client's real-mode segments), `LLDT`s it,
  and `iretd`s to ring 3 with EFLAGS VM=0, IOPL=3.
  Known follow-ups (not blockers for M2): (a) `ECX/EDX/ESI/EDI` aren't preserved
  across the switch yet (Int13h doesn't save them; the probe doesn't need them —
  DOS4GW sets them up post-switch); (b) a HW IRQ arriving while the client runs
  in PM faults VSB's still-V86-only interrupt reflection — that's exactly
  milestone 4's job (deliver HW ints to the PM client).
- [x] **Milestone 3** — `int 31h` services (`s386dpmi.asm` `Dpmi31h` + a DPL-3
  gate on vector 31h routed in `386preal.asm`). **Verified in QEMU**
  (`run-harness.sh int31`): `testint31.com` switches to PM and calls the
  services, reporting over the LPT port — `version=0.90`, `alloc-sel=002F` (an
  LDT ring-3 selector), and it **read a 0xA5 canary through the allocated
  selector**, so allocate (0000) + set-base (0007) + set-limit (0008) genuinely
  map memory. Also implemented: get-base (0006), set-access (0009), free (0001);
  unsupported functions return CF + 8001h. The client reaches `int 31h` because
  vector 31h's IDT gate is re-pointed to `Dpmi31h` with DPL=3 (mirroring how
  `InitializeIDT` already re-points `#GP` to `Int13h`).
  **Known limitation:** the LDT free pool is capped at 64 descriptors, because a
  larger one pushes the resident past a ~18 KB ceiling that currently breaks
  install (task #13 — a latent VSB layout bug where V86 execution lands in the
  banner data; must be fixed before M4 and before raising the pool for DOOM).
- [ ] Milestone 3b — DOS memory (0100/0101), get/set real-mode & PM interrupt
  vectors (0200/0201/0204/0205), simulate-real-mode-interrupt (0300).
- [ ] Milestone 4 — reflection + PM SB trapping.
