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

5. **Extended-memory (linear) services — `int 31h fn 0500/0501/0502`.** A 32-bit
   extender's heap. No paging: the pool is physical extended RAM (>1 MB),
   identity-mapped through `@gdFlat`, bump-allocated top-down. A20 is opened and
   the pool sized (`int 15h AH=88h`) at Init. This is the piece — beyond the
   plan's original milestone-4 scope — that lets DOS4GW allocate its
   protected-mode memory; without it a 32-bit extender can't start.

At milestone 5, `vsb_dpmi.com` is the single hand-asm binary that does
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
- [x] **Milestone 4d (DOS mem)** — `int 31h fn 0100/0101` (allocate/free DOS
  memory). **Verified in QEMU** (`run-harness.sh dos`): `d31_dosalloc`/
  `d31_dosfree` reuse the 4a excursion (`RmExGo`/`RmExDone`, `ExMode != 0`) with
  a private RMCS to run `int 21h AH=48h/49h` in real mode, then `RmExDoneDos`
  stages `AX`/`DX`/`CF` for the PM client. fn 0100 also mints an LDT selector
  (`AllocSel`, base = realseg<<4, 64 KB data) so the client gets `AX=realseg`,
  `DX=selector`; fn 0101 frees both the DOS block and its selector. `testdos.com`
  (which first shrinks its own block via `AH=4Ah`, since a `.COM` owns all of
  conventional RAM) allocated seg **4590** / sel **002F**, wrote+read **0x5A**
  through the selector, and freed it with CF clear. The error path is exercised
  too: without the shrink, `AH=48h` returns DOS error **8** and the excursion
  round-trips `AX=8`+CF faithfully to PM.
- [x] **Milestone 5 (extended memory)** — `int 31h fn 0500/0501/0502` (get free
  memory info / allocate / free linear memory blocks). **Verified in QEMU**
  (`run-harness.sh mem`): `InstallDPMI` opens A20 (port 92h) and sizes the pool
  from `int 15h AH=88h`; `d31_memalloc` bump-allocates physical extended RAM
  top-down (`HiMemTop`/`HiMemBot`, identity-mapped through `@gdFlat`, no paging).
  `testmem.com` allocated a 64 KB block at linear **0x00FD0000** (real RAM above
  1 MB), mapped a descriptor over it, and — critically — wrote a byte through a
  second descriptor based at the block's **bit-20 alias** (`base XOR 0x100000`)
  and re-read the block: the canary **survived** (0x5A), proving A20 is truly
  open and the block is genuine extended memory, not a 1 MB wrap. This is the
  heap path a 32-bit DOS extender (DOS4GW/DOOM) takes. Free is a LIFO/leak no-op
  for now (fine for a single run). Covox audio path unaffected (DPMI build still
  reproduces the sample exactly).
- [x] **Milestone 6 (32-bit client)** — execute genuine 32-bit protected-mode
  code under the host, and harden the PM-fault decoder for it. **Verified in
  QEMU** (`run-harness.sh pm32`): `testpm32.com` does what an extender does —
  allocates an extended-memory block (fn 0501), copies a 32-bit routine into it,
  builds a **USE32** code selector over that block (D-bit set, base != the
  switch-time base), and far-jumps to it. From that 32-bit code it calls int 31h
  (version **0.90**) and does a trapped SB read (0x22A -> **0xAA**). The fix:
  the M4c PM-fault decoder (`386pint.asm`) now resolves the faulting
  instruction's linear base from the **actual faulting CS** (looked up in the
  client LDT) instead of a cached `CliCodeBase` — required because a 32-bit
  extender runs code from its own block, whose CS base differs from the 16-bit
  stub's. Had it stayed cached, the SB read would have decoded the wrong bytes
  and failed; `0xAA` proves the DOOM PCM path works from 32-bit code. (16-bit
  `sb` and the Covox `sample` still green — no regression.)
- [x] **Milestone 7 (round out the service set)** — the remaining `int 31h`
  functions a real extender (DOS4GW) calls on top of the verified core:
  **fn 000A** create alias descriptor (**verified**, `run-harness.sh alias`:
  aliased a code selector as data — canary 0x5A read through it, byte written
  through it seen via DS, alias sel 0037); **fn 0202/0203** PM exception vectors
  (routed to the PM vector table); **fn 0600/0601** lock/unlock linear region
  (no-op success — there is no paging to lock against); **fn 0900/0901/0902**
  virtual interrupt state (a tracked `VirtIF` flag for consistent save/restore;
  actual delivery is gated by the monitor's own IF). These close the
  unsupported-function gaps a real extender would hit; the alias service is the
  cleanly-verifiable one and is green.
- [ ] **Real-mode callbacks** (`int 31h fn 0303/0304`). Not yet needed by the
  DOOM/DOS4GW path verified so far; deferred until a title demands it.
- [~] **Final integration — real DOOM under `vsb_dpmi.com` (IN PROGRESS).**
  DOOM shareware boots in the QEMU harness with `VSB` (the DPMI build) as the
  *only* resident — no JEMMEX/HDPMI/SBEMU stack (`scratchpad/doom/run2.sh`).
  Result so far:
  - **Big win:** DOOM's extender no longer aborts with `DOS/16M error: system
    software does not follow VCPI or DPMI specifications` (what classic
    `vsb_real.com` produces). It detects the built-in host, takes the mode
    switch, and executes protected-mode code.
  - **Current blocker:** DOOM's extender is **DOS/4G (Rational Systems
    DOS/16M)**, not DOS/4GW (Tenberry). It `#GP`s in its C-runtime startup at
    `selCode:0x13D8` on `les bx,[di+20]`, loading a raw real-mode paragraph
    (`0xa115`) as a selector. Ground-truth memory inspection
    (`scratchpad/doom/mon_inspect.py`) confirmed the LDT is built correctly
    (selCode/selData base `0x3a900`, etc.) and the instruction bytes are real.
    DOS/16M assumes a specific selector↔segment tiling from its native
    VCPI/raw mode and only tolerates DPMI hosts that replicate its quirks — the
    exact class of behaviour HDPMI accumulated years of special-casing for.
  - **Added while chasing it (committed):** `int 31h fn 0002` (segment→
    descriptor), `0003`, `000B`/`000C` (get/set descriptor), and full GP-register
    preservation across the mode switch. All correct host improvements; none
    resolves the DOS/16M-specific tiling assumption.
  - **ROOT CAUSE FOUND (via HDPMI source, `Src/HDPMI/HDPMI.ASM`).** The problem
    is not a DOS/16M mystery — it's a missing core DPMI mechanism in our host:
    **protected-mode software-interrupt reflection.** Our IDT (`InitializeIDT`,
    `386preal.asm`) gives *every* vector except int 31h a DPL-0 gate. When
    DOS/16M does `int 21h` in PM (e.g. `AH=52h` get-list-of-lists, right before
    the fault) it `#GP`s (gate DPL 0 < CPL 3); our `#GP` path decodes `CD 21`
    and routes it to `DoIntNN` — which is **V86-only**: it reads `[ebp+10h]` as
    a real-mode SS *segment*, builds a real-mode iret frame, and `iretd`s back
    with VM=1. For a PM client that mangles the call and corrupts DOS/16M's
    state, so it later loads garbage (`0xa115`) as a selector. **Our host never
    actually reflects a PM-client software interrupt to real-mode DOS.**
  - **The fix (well-defined, uses machinery we already have):**
    1. **PM software-int reflection.** When the PM-fault decoder hits `CD NN`
       (`DoIntNN` with EFLAGS.VM=0), run `IVT[NN]` in a V86 excursion with the
       client's registers and return the results to the PM client — exactly the
       `RmExGo`/`RmExDone` excursion built for fn 0300, but register-based
       instead of RMCS-based (add an `ExMode`). Key simplifier: our client
       selectors have base = segment<<4, so set real-mode `DS`/`ES` =
       (selector base)>>4 and `DS:DX`/`ES:BX` pointers map straight back.
    2. **DOS integration on the initial switch, mirroring HDPMI's
       `_initclient_pm` (`HDPMI.ASM:4939`):** allocate proper CS/DS/SS selectors
       (its `getrmdesc`, `I31SEL.ASM:754` — same idea as our new fn 0002), then
       **convert the PSP's environment field `PSP:[2Ch]` from a real-mode
       segment to a selector and write it back into the PSP**, get a PSP
       selector, and set up the DTA selector. DOS/16M reads these expecting
       selectors; we currently leave raw segments there.
    3. Return `SI = host-data paragraphs` from int 2Fh/1687h (HDPMI returns
       `?RMSTKSIZE/16`), not `SI=0`, and use the client-provided `ES` block as
       the reflection stack (HDPMI's model) — or keep our resident RM stack.
  - **Deep-dive finding (memory inspection, `scratchpad/doom/mon_dbg2.py`):**
    The `#GP` is `les bx,[di+20]` loading selector **`0xa115`**, which is a
    *pre-built native selector baked into DOS/16M's own image* — it lives in a
    table at code offset `~[0972]`, gets copied to a runtime table at `[1560+]`,
    and is loaded directly. Crucially, at the fault DOS/16M has made **zero
    int 31h calls** (our LDT free pool is untouched except the env selector our
    switch adds). So DOS/16M reaches this on a **native-selector code path** it
    takes *before* doing any DPMI descriptor allocation. HDPMI's `getrmdesc`
    (`I31SEL.ASM:754`) uses only standard int 31h fn 0000/0007/0008/0009 — no
    selector tiling — so under HDPMI DOS/16M does **not** take this path. The
    divergence is therefore in DOS/16M's *early branch selection*, driven by
    some detection/switch-time difference (int 2Fh/1687h fields, fn 0400
    version, the `-AUTO`-build condition DOS/16M's strings mention, or the host
    stack/ES convention) — not a missing descriptor service. Both correct fixes
    added this session (PM int reflection, PSP env→selector) verified present
    (env selector `0x2F` base `0x48270` in the LDT) but are reached *after* this
    fault, so they don't affect it.
  - **What cracking it would take:** a *differential* trace — run this exact
    DOOM under the working HDPMI stack, capture DOS/16M's selector tables /
    call sequence at the equivalent point, and diff against our host to find the
    one detection-time report that flips DOS/16M's branch. That's a substantial
    reverse-engineering effort (or DOS/16M source, which isn't public). Blind
    guessing at the trigger is not tractable.
  - **Reference in hand:** full HX/HDPMI source is in
    `scratchpad/hx/HX-master/Src/HDPMI/` (user-provided `HXmaster.zip`). Key
    files: `HDPMI.ASM` (`_initclient_pm`, `int2f1687`), `I31SEL.ASM`
    (`getrmdesc`), `INT21API.ASM`, `I31INT.ASM`. This is a substantial but
    now-mapped implementation effort (essentially the host's DOS-integration
    layer). The synthetic probes and the audio path are unaffected and stay
    green throughout.
- [ ] Audible Covox output — hardware-only for the *hearing* test, but note the
  harness *does* capture LPT bytes exactly, so a running DOOM's Covox stream
  would be visible in `lpt.bin` here (it just never reaches sound yet).

## Assumptions & known limitations (for the real-extender run)

The host is complete for the DOS4GW/DOOM service set and every mechanism is
probe-verified, but a few deliberate simplifications are worth knowing before
the first real-extender boot:

- **RMCS / buffer pointers are 16-bit offsets.** `fn 0300` (simulate real int)
  and `fn 0500` (get memory info) read the client's `ES:DI` as a 16-bit `DI`,
  not `EDI`. This is correct for DOS4GW, whose real-mode call structure and
  transfer buffer live in a DOS-memory block (a real-mode segment, small
  offset). A 32-bit client that placed its RMCS at an `EDI` offset >64 KB in a
  large data segment would need the calling-CS `D`-bit consulted to widen the
  offset — straightforward to add if a title needs it, but unverifiable here
  without that title, so left as-is rather than adding untested complexity.
- **`fn 0900-0902` virtual interrupt state is a tracked flag, not enforced.**
  Get/disable/enable return a consistent previous state for save/restore, but
  actual interrupt delivery is gated by the monitor's real IF, not the virtual
  flag. Adequate for extender startup; revisit if a client depends on precise
  virtual-IF masking.
- **`fn 0502` free / `fn 0101`-selector free are LIFO/leak.** The extended-mem
  pool is a top-down bump allocator; a non-LIFO free leaks until exit. Fine for
  a single game run.
- **No paging / `fn 0800` physical mapping.** The client is identity-mapped, so
  a descriptor's base *is* the physical address — VGA at `0xA0000`, etc., are
  reached by `fn 0007` set-base directly. `fn 0800` (map physical→linear) is a
  no-op-equivalent (linear = physical) and can be added as an identity return
  if an extender calls it explicitly.
