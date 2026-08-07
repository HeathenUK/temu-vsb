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

## The one honest limitation

The protected-mode / DOOM path **cannot be functionally verified in this
environment.** DOOM never reaches gameplay under the QEMU TCG harness (too slow;
documented in `build/harness/doom-spike.md`), and a from-scratch DPMI host is
mode-switch machinery that only proves out on real hardware / a faster
emulator. Therefore each milestone below records **what CAN be checked here**
(it assembles green; real-mode probes; sbdma regression) versus what is
**built-but-unverified-here** and needs hardware. Nothing is claimed working
that wasn't run.

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
   *Checkable here:* assembles; unit-reason the descriptor math. *Unverified
   here:* the actual switch (needs hardware).

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
- [ ] Milestone 2 — PM mode switch.
- [ ] Milestone 3 — int 31h services.
- [ ] Milestone 4 — reflection + PM SB trapping.
