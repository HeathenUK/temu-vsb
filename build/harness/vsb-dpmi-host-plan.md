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

4. **Reflection + PM SB trapping**, in probe-verified sub-steps:
   - **4a — V86 excursion / simulate-real-mode-int (int 31h fn 0300).** DONE.
     From the PM host, drop to V86, run `IVT[BL]` with a resident real-mode
     stack whose iret returns to a `HLT` sentinel that traps back to ring 0,
     copy the result registers back to the client's RMCS, resume the client.
     *Probe (`testrm`):* fn 0300 → real-mode `int 21h/AH=30h` returned DOS
     version **7.10** (FreeDOS) — real-mode DOS ran and registers round-tripped.
   - **4b — HW interrupt delivery to the PM client.** A HW IRQ arriving while
     the client runs in PM currently faults VSB's still-V86-only reflection;
     deliver it to the client's PM handler (or reflect to real mode).
   - **4c — PM SB/DMA/OPL port trapping.** Run the client at IOPL<3 so its SB
     port I/O trips the TSS I/O bitmap → #GP; extend the #GP handler to decode
     a PM-client fault (CS is a selector, not seg<<4) and route into
     `s386port.asm` so DOOM's PCM lands on Covox and its FM on the real OPL3.
   - **4d — the int 31h services DOS4GW needs on top of 4a:** alloc/free DOS
     memory (0100/0101, via fn-0300-style excursions to int 21h AH=48h/49h),
     get/set real-mode & PM interrupt vectors (0200/0201/0204/0205), allocate
     real-mode callback (0303/0304).

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
  LDT free pool is 251 descriptors (256 slots), ample for DOS4GW/DOOM.
- [x] **Toolchain fix (was the "~18 KB resident ceiling")** — the ceiling was
  never about size: TASM `/m3`'s jump-shrink optimization emits a phantom `00`
  byte in the OBJ after a short-jumped forward branch, which `omf2com` can't
  reconcile against TASM's label offsets, so a near call at the resident
  boundary landed one byte early on an `iret` and VSB crashed on load. Root-
  caused by diffing `omf2com`'s image against the TASM `.LST` (divergence began
  at exactly the phantom byte). Fix: build the DPMI target with `/m1` (no
  phantom — verified 0 vs 1 occurrence), which also lets the resident grow
  freely; the shipping `vsb_real.com` stays `/m3` and byte-identical. All three
  probes pass at an 18787-byte, 256-LDT build.
- [x] **Milestone 4a** — V86 excursion / simulate-real-mode-int (`int 31h fn
  0300`). **Verified in QEMU** (`run-harness.sh rm`): `testrm.com` runs real-mode
  `int 21h/AH=30h` from PM and reads back DOS version **7.10** through the RMCS —
  real-mode DOS ran and registers round-tripped. (`s386dpmi.asm` `d31_simint`/
  `RmExGo`/`RmExDone`; `DoHalt` hook matches the `RmExSentinel` HLT.)
- [x] **Milestone 4d (vectors)** — `int 31h fn 0200/0201` (real-mode int vector,
  IVT) and `0204/0205` (PM int vector, host table). **Verified** (`run-harness.sh
  vec`): `testvec.com` round-trips a real-mode (`0B0h -> 1234:5678`) and a PM
  (`0B1h -> 00F0:AABBCCDD`) vector.
- [x] **Milestone 4c** — PM SB/DMA/OPL port trapping. **Verified in QEMU**
  (`run-harness.sh sb`): the client runs at IOPL 0, so its SB-port I/O trips
  the TSS bitmap → `#GP`; a new `Int13h` branch decodes the PM-client fault via
  `CliCodeBase` and reuses `PortHandler`. `testsb.com` does a full DSP reset +
  status read from PM and reads back **0xAA** (DSP ready) — the SB emulation
  reached from protected mode, the path DOOM's PCM takes to the Covox. CLI/STI
  are emulated as no-ops in the branch.
- [x] **Milestone 4b** — HW interrupt delivery to the PM client. **Verified**
  (same `sb` run, reset path): the DSP reset reprograms the PIT, so a timer
  IRQ0 fires while the client is in PM; `IRQset` now branches on `EFLAGS.VM=0`
  to `PmDeliver`, which delivers to the client's `PmVecTable` handler or drops
  the int — absorbing the IRQ instead of fault-storming. Covox audio path
  unaffected (sample still reproduces 26100/26100 on the DPMI build).
- [ ] **Milestone 4d (DOS mem)** — `int 31h fn 0100/0101` via fn-0300-style
  excursions to `int 21h AH=48h/49h`; real-mode callbacks (`0303/0304`).
