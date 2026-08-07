#!/usr/bin/env python3
"""386SX-40 cost model for the SBEMU+Covox path (companion to
build/harness/cycles386.py, which prices classic VSB).

Why a separate model: VSB is the ring-0 VM86 monitor itself, so an IRQ0
vectors straight to its handler (one 386 interrupt gate, ~139 cyc). The
Covox-under-SBEMU backend is a *ring-3 DPMI client*: every IRQ0 is reflected
by HDPMI through its routed-IRQ dispatcher and the DPMI ISR wrapper before our
C handler runs, and SBEMU's producer does real per-sample mixing/resampling
that VSB never does. Those two costs are what this model prices, and they are
exactly why the QEMU harness starved the foreground at 22 kHz.

Two structural unknowns dominate and can't be read off a timing table with
confidence, so they are explicit parameters with LOW/MID/HIGH bands:

  R  = HDPMI ring-3 interrupt-reflection overhead per IRQ0 (excl. our body)
  P  = SBEMU producer (MAIN_Interrupt) mixing cost, amortized per output sample

Everything else is an auditable (instruction, cycles) list using the same
80386 SX timing basis as cycles386.py (16-bit bus, descriptor loads ~23,
ISA OUT ~37, PIC EOI ~28, IRETD ~78). Treat outputs as good-faith estimates
with wide bars (the bands below span roughly +-40%); the point is the *shape*
and the crossovers, not three significant figures.

Cross-check the model against reality with the /D-style duty probe on real
hardware; do NOT trust QEMU for absolute cycles (TCG over-weights V86/PM mode
switches, so its 22 kHz starvation is pessimistic vs real silicon).
"""
import sys

MHZ = 40.0
CPU = MHZ * 1e6

# ---- R: HDPMI ring-3 interrupt reflection, per IRQ0 (auditable bands) --------
# Replaces VSB's single native VM86->ring0 gate. HDPMI takes the gate itself,
# runs its routed-IRQ dispatch, then enters our handler via the DPMI ISR
# wrapper (flat-selector loads + locked-stack switch), and unwinds on return.
REFLECT = {
    'low':  [('IDT gate V86->ring0 (HDPMI owns it)', 139),
             ('HDPMI routed-IRQ dispatch (lean)', 40),
             ('DPMI ISR wrapper prologue (1-2 seg loads, stack)', 80),
             ('DPMI wrapper epilogue + IRETD', 90)],
    'mid':  [('IDT gate V86->ring0 (HDPMI owns it)', 139),
             ('HDPMI routed-IRQ dispatch + lock check', 60),
             ('DPMI ISR wrapper prologue (2-3 seg loads @~23, stack)', 110),
             ('DPMI wrapper epilogue + IRETD', 120)],
    'high': [('IDT gate V86->ring0 (HDPMI owns it)', 139),
             ('HDPMI routed-IRQ dispatch + route decision', 90),
             ('DPMI ISR wrapper prologue (3 seg loads + RM-frame touch)', 170),
             ('DPMI wrapper epilogue + IRETD', 160)],
}

# ---- Consumer ISR body, per sample tick (our sc_covox.c, gcc -O2) ------------
# Reads a 16-bit stereo frame, downmixes L+R, biases to unsigned, OUTs to LPT,
# advances, reconstructs the 18.2 Hz tick (usual branch not-taken), EOIs.
CONSUMER_BODY = [
    ('ptr loads + (playpos!=lastput) check', 14),
    ('read stereo frame 2x mov16 + downmix (add,sar,sar)', 18),
    ('bias unsigned + OUT dx,al to LPT (ISA)', 37),
    ('playpos+=4 + wrap cmp/branch', 10),
    ('bios_acc+=imm, cmp, branch (usual: not boundary)', 12),
    ('PIC EOI (mov al,60h / out 20h,al)', 28),
    ('producer gate (++tick, cmp, branch)', 8),
    ('gcc ISR frame prologue/epilogue (not hand-tuned)', 25),
]

# ---- P: producer (MAIN_Interrupt) mixing, amortized per OUTPUT sample --------
# SBEMU maps the game DMA, resamples to the card rate, converts bits/channels,
# applies the volume/OPL mix, and MDma-copies into the ring. Per output sample.
PRODUCER = {
    'low':  [('resample (mixer_speed_lq linear)', 12),
             ('DPMI_LMemcpy game DMA (per-sample share)', 6),
             ('cv_bits/cv_channels (8->16, 1->2ch)', 8),
             ('volume mix loop (2 vals, mul/shift)', 20),
             ('MDma_writedata copy (per-sample share)', 6),
             ('MAIN_Interrupt per-call fixed / REFILL_HZ share', 5)],
    'mid':  [('resample (mixer_speed_lq linear)', 18),
             ('DPMI_LMemcpy game DMA (per-sample share)', 8),
             ('cv_bits/cv_channels (8->16, 1->2ch)', 12),
             ('volume mix loop (2 vals, mul/shift)', 30),
             ('MDma_writedata copy (per-sample share)', 8),
             ('MAIN_Interrupt per-call fixed / REFILL_HZ share', 9)],
    'high': [('resample (mixer_speed_lq linear)', 28),
             ('DPMI_LMemcpy game DMA (per-sample share)', 14),
             ('cv_bits/cv_channels (8->16, 1->2ch)', 18),
             ('volume mix loop + OPL blend (2 vals)', 50),
             ('MDma_writedata copy (per-sample share)', 10),
             ('MAIN_Interrupt per-call fixed / REFILL_HZ share', 20)],
}

# ---- Ring-0 fast path (COVOXR0 HDPMI32i, build/covox/hdpmi/) ----------------
# The patched host drains one sample per tick entirely at ring 0: no LPMS
# switch, no reflection, no DPMI wrapper. Per-sample cost = one inner-ring
# interrupt gate + the hand-written drain + IRETD. The ring-3 backend only
# runs at ~REFILL_HZ for producer refills (amortized below), and game ticks
# reflect to the game's own ISR (its cost is the game's, not ours).
R0_FAST = [
    ('IDT gate ring3->ring0 (PM client, 99 + SX bus)', 119),
    ('cb check + 3 push + cb load', 16),
    ('active check + playpos/writepos/lastout loads', 26),
    ('ring byte fetch (flat ss) + L+R downmix + bias', 21),
    ('lastout store + playpos advance/wrap/store', 21),
    ('mov+load port + OUT dx,al to LPT (ISA)', 45),
    ('tickcount inc + chain/pump accumulators (2x RMW)', 26),
    ('PIC EOI (mov al,60h / out 20h,al)', 28),
    ('3 pop + IRETD to ring 3', 94),
]

def s(lst):
    return sum(c for _, c in lst)

def per_sample(band):
    return s(REFLECT[band]) + s(CONSUMER_BODY) + s(PRODUCER[band])

def per_sample_r0(band, rate, refill_hz=120):
    # fast ticks + the amortized ring-3 producer wake (a full reflection +
    # producer work, refill_hz times a second)
    wake = s(REFLECT[band]) + s(PRODUCER[band]) + 200  # 200: pump body + EOI
    return s(R0_FAST) + wake * refill_hz / rate

def silence_per_tick(band):
    # No active stream: the producer's muted path is cheap, but the consumer +
    # reflection still fire every PIT tick because the backend does NOT idle
    # the PIT during silence (VSB's idle-gating is not ported). So silence
    # costs reflection + consumer body at the FULL output rate.
    return s(REFLECT[band]) + s(CONSUMER_BODY)

def pct(rate, cyc):
    return 100.0 * rate * cyc / CPU

RATES = [8000, 11025, 16000, 22050]

def main():
    print("SBEMU+Covox on a 386SX-40 (40 MHz) - modeled per-sample cost\n")
    print("  Per-output-sample cost = HDPMI reflection R + consumer body + producer P")
    hdr = "  band   R    body   P    total   " + "  ".join(f"{r/1000:>5.1f}kHz" for r in RATES)
    print(hdr); print("  " + "-"*(len(hdr)-2))
    for band in ('low', 'mid', 'high'):
        tot = per_sample(band)
        cells = "  ".join(f"{pct(r,tot):6.1f}%" for r in RATES)
        print(f"  {band:<5}{s(REFLECT[band]):>4}{s(CONSUMER_BODY):>6}"
              f"{s(PRODUCER[band]):>5}{tot:>7}    {cells}")
    print("\n  Ring-0 fast path (COVOXR0 host, PM client like DOOM; per-sample")
    print("  drain at ring 0, producer wakes amortized at 120 Hz):")
    hdr2 = "  band   fast   " + "  ".join(f"{r/1000:>5.1f}kHz" for r in RATES)
    print(hdr2)
    for band in ('low', 'mid', 'high'):
        cells = "  ".join(f"{pct(r, per_sample_r0(band, r)):6.1f}%" for r in RATES)
        print(f"  {band:<5}{s(R0_FAST):>6}   {cells}")

    print("\n  For reference, classic VSB (cycles386.py, 'current' tier):")
    print("    ~346 cyc/sample, ~9.3% @10.75kHz, ~19.1% @22.05kHz - and ~0% in")
    print("    silence (idle-gated to 18.2 Hz).")

    print("\n  Silence cost: ~0%. The backend idle-gates like VSB (the PIT")
    print("  returns to the game's own rate between streams); in ring-0 mode")
    print("  idle ticks additionally bypass the backend entirely (the host")
    print("  hands them 1:1 to the current client). The table below is what")
    print("  silence WOULD cost without idle-gating, kept for the record:")
    for band in ('low', 'mid', 'high'):
        st = silence_per_tick(band)
        cells = "  ".join(f"{pct(r,st):6.1f}%" for r in RATES)
        print(f"    {band:<5} {st:>4} cyc/tick   {cells}")

    print("\n  Crossovers (MID band, playing):")
    tot = per_sample('mid')
    for budget in (25, 50, 100):
        rate = budget/100.0 * CPU / tot
        print(f"    reaches {budget:3d}% CPU at ~{rate/1000:.1f} kHz")

    print("\n  Reading it:")
    print("   - The path is ~1.6-2x VSB's per-sample cost; the extra is almost")
    print("     entirely HDPMI's ring-3 reflection (R), the cost VSB's ring-0")
    print("     design pays ~0 for. Producer mixing (P) is secondary.")
    print("   - MID band: ~8 kHz is cheap (~13%), ~16 kHz ~27% (~VSB's budget),")
    print("     ~22 kHz ~37% - heavy but plausible on real silicon, NOT the")
    print("     100% QEMU showed (TCG over-weights the V86/PM switches in R).")
    print("   - Two levers, in priority order:")
    print("       1. Idle-gate the PIT in silence (port VSB's mechanism) - kills")
    print("          the continuous silence burn shown above.")
    print("       2. Cut R for the real-mode path with a raw-IVT hook (bypass")
    print("          HDPMI reflection when the game is in real mode), keeping the")
    print("          PM route only for DOS-extender games. That moves R toward")
    print("          VSB's native ~217 and makes higher rates affordable.")

if __name__ == '__main__':
    main()
