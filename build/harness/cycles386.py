#!/usr/bin/env python3
"""386SX-40 cycle model for VSB's steady-state paths.

QEMU cannot price 386 cycles (icount weighs every instruction as 1), so the
harness pairs its *measured structure* (which path runs, at what interrupt
rate - proven by the behavioural scenarios and the PIT idle probe) with this
*static cycle model* of those paths, derived instruction-by-instruction from
the Intel 80386 Programmer's Reference timing tables plus 386SX realities:

  - VM86 -> ring-0 interrupt via 386 interrupt gate: 119 cycles core, plus
    ~20 for the 9-dword frame + IDT/TSS reads crossing the 16-bit bus.
  - IRETD back to VM86: ~60 core + ~18 bus  -> ~78.
  - mov sreg (protected mode): 19 + ~4 descriptor fetch on the 16-bit bus.
  - OUT to an ISA/board device: ~11 core + bus stall (~24 for the LPT DAC
    on the ISA bus, ~15 for the on-board PIC/PIT).
  - RMW word memory ops: 7 core + ~2 extra bus.
  - 32-bit push/pop: +2 bus each on the SX.

CALIBRATION: the model prices the 1995 binary's playback at 403 cycles/sample,
i.e. 26.9% of a 33 MHz 386SX at 22.05 kHz - matching the author's own
"emulator takes about a quarter of processor's power; 33-MHz 386SX minimum
recommended" (sbemu/ready/vsb.doc), and ~22% at 40 MHz, matching the observed
"about 25%" with command overhead. Treat outputs as good-faith estimates
(+-15%), to be confirmed by the /D duty-cycle flag on real hardware.

Each path below is an auditable (instruction, cycles) list. Edit alongside
any ISR change.
"""
import sys

MHZ = 40.0
ENTRY = ('VM86->PL0 interrupt gate (119 + SX bus)', 139)
EXIT_ = ('IRETD to VM86 (60 + SX bus)', 78)

# ---- steady-state playback body, per build tier (Covox output) --------------
PLAY_BODY = {
    'vintage': [                      # shipped 14/09/95 binary
        ('push ax / push dx', 4),
        ('push ebx (32-bit, SX bus)', 4),
        ('mov ax,@gdData', 2),
        ('mov ds,ax (descriptor load)', 23),
        ('mov ax,@gdFlat', 2),
        ('mov es,ax (patched; descriptor load)', 23),
        ('mov ebx,imm32 (SMC pointer)', 2),
        ('mov al,es:[ebx]', 5),
        ('mov dx,DACport / out dx,al (ISA)', 37),
        ('inc word SamplePointer (RMW+SMC)', 9),
        ('sub SBcounter,1 / jc', 12),
        ('sub DMAcounter,1 / jc', 12),
        ('add Counter,coeff / jc', 12),
        ('mov al,60h / out 20h,al (PIC EOI)', 28),
        ('pop ebx/dx/ax', 14),
    ],
    'current': [                      # idle-gated + flat-SS + ebx-free build
        ('push ax / push dx', 4),
        ('mov al,ss:[disp32] (A0 moffs, addr32; SMC pointer, patch overlay)', 6),
        ('mov dx,DACport / out dx,al (ISA)', 37),
        ('inc word ss:SamplePointer (RMW+SMC)', 9),
        ('sub ss:SBcounter,1 / jc', 12),
        ('sub ss:DMAcounter,1 / jc', 12),
        ('add ss:Counter,coeff / jc', 12),
        ('mov al,60h / out 20h,al (PIC EOI)', 28),
        ('pop dx/ax', 9),
    ],
}
PLAY_BODY['current+E'] = (            # /E: EOI pair replaced by short jmp
    [i for i in PLAY_BODY['current'] if 'EOI' not in i[0]]
    + [('jmp short (EOI patched out by /E)', 8)])

# ---- silent-tick body (ShutUp path) per tier --------------------------------
IDLE_BODY = {
    'vintage': [
        ('push ax/dx/ebx', 8),
        ('mov ax,@gdData / mov ds,ax', 25),
        ('mov ax,@gdFlat', 2),
        ('jmp @@ShutUp (disable patch)', 8),
        ('add Counter,coeff / jc', 12),
        ('mov al,60h / out 20h,al (PIC EOI)', 28),
        ('pop ebx/dx/ax', 14),
    ],
    'current': [
        ('push ax/dx', 4),
        ('jmp @@ShutUp (disable patch overlays the ptr load)', 8),
        ('add ss:Counter,coeff / jc', 12),
        ('idle-gate countdown (cmp, cold)', 5),
        ('mov al,60h / out 20h,al (PIC EOI)', 28),
        ('pop dx/ax', 9),
    ],
}
IDLE_BODY['current+E'] = (
    [i for i in IDLE_BODY['current'] if 'EOI' not in i[0]]
    + [('jmp short (EOI patched out by /E)', 8)])

def path_cycles(body):
    return ENTRY[1] + sum(c for _, c in body) + EXIT_[1]

def pct(rate_hz, cycles):
    return 100.0 * rate_hz * cycles / (MHZ * 1e6)

def silence_rate(tier, sample_rate):
    # vintage keeps the PIT at the sample rate forever; current idles to the
    # game's own rate (18.2 Hz unless the game reprograms it)
    return sample_rate if tier == 'vintage' else 18.2

def report(tier, sample_rate, verbose=False):
    play = path_cycles(PLAY_BODY[tier])
    idle = path_cycles(IDLE_BODY[tier])
    srate = silence_rate(tier, sample_rate)
    lines = []
    lines.append(f'  [{tier}] modeled 386SX-40 cost '
                 f'(play {play} cyc/sample, silent tick {idle} cyc):')
    lines.append(f'    playing @{sample_rate/1000:.2f} kHz : '
                 f'{pct(sample_rate, play):5.1f}% CPU')
    lines.append(f'    playing @22.05 kHz : {pct(22050, play):5.1f}% CPU')
    lines.append(f'    silence            : {pct(srate, idle):5.1f}% CPU '
                 f'({srate:g} int/s)')
    if verbose:
        lines.append('    playback path accounting:')
        lines.append(f'      {ENTRY[0]}: {ENTRY[1]}')
        for name, c in PLAY_BODY[tier]:
            lines.append(f'      {name}: {c}')
        lines.append(f'      {EXIT_[0]}: {EXIT_[1]}')
    return '\n'.join(lines)

if __name__ == '__main__':
    rate = float(sys.argv[1]) if len(sys.argv) > 1 else 10750.0
    for tier in ('vintage', 'current', 'current+E'):
        print(report(tier, rate, verbose='-v' in sys.argv))
    print(f'\n  calibration anchor: vintage playing @22.05 kHz on a 33 MHz '
          f'386SX = {100*22050*path_cycles(PLAY_BODY["vintage"])/33e6:.1f}% '
          f'(author documented "about a quarter of processor\'s power")')
