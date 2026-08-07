#!/usr/bin/env python3
"""Harness checker: waits for VSB playback inside the QEMU guest, then gates on
(1) the VSB banner + SBDMA's virtual-IRQ diagnostics on the DOS text screen and
(2) the captured LPT byte stream reproducing sbemu/sample exactly.

The capture may carry a small number of leading non-sample bytes (SeaBIOS
probes the port with 0xAA during POST); the sample must appear as one exact
contiguous run at a small offset.
"""
import hashlib, re, socket, sys, time, pathlib

SHIPPED_1995_SHA = '442df827eb562afbc065d6cf263fdb926cf5556865c15a17c4809e4da5fcb8d1'

def monitor_cmd(sock_path, cmd, settle=1.0):
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock_path)
    s.settimeout(2)
    out = b''
    try:
        s.recv(65536)                       # banner
    except socket.timeout:
        pass
    s.send((cmd + '\n').encode())
    time.sleep(settle)
    try:
        while True:
            r = s.recv(65536)
            if not r:
                break
            out += r
    except socket.timeout:
        pass
    s.close()
    return out.decode('utf-8', 'replace')

def read_screen(sock_path):
    txt = monitor_cmd(sock_path, 'xp /4000bx 0xb8000')
    chars = []
    for m in re.finditer(r'[0-9a-f]+:((?:\s0x[0-9a-f]{2})+)', txt):
        row = [int(x, 16) for x in re.findall(r'0x([0-9a-f]{2})', m.group(1))]
        chars += row[0::2]
    screen = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in chars)
    return [screen[i:i+80].rstrip() for i in range(0, len(screen), 80)]

def block(base):
    return bytes((base + (i & 0x3F)) & 0xFF for i in range(512))

def main(outdir, sample_path, scenario='sample', vsb_bin=None, vsb_args=''):
    out = pathlib.Path(outdir)
    if scenario.startswith('perf'):
        # measurement mode: wait for P3 marker on the guest screen, then report
        deadline = time.time() + 420
        lines = []
        while time.time() < deadline:
            try:
                lines = [l for l in read_screen(str(out / 'mon.sock')) if l]
            except OSError:
                lines = []
            if any('P3 ' in l for l in lines) or any('TIMEOUT' in l for l in lines):
                break
            time.sleep(10)
        print('--- guest screen ---')
        for l in lines:
            print('|', l)
        vals = {}
        for l in lines:
            m = re.search(r'\bP([123]) ([0-9A-F]{8})\b', l)
            if m:
                vals[int(m.group(1))] = int(m.group(2), 16)
        if len(vals) != 3:
            print('FAIL: expected P1/P2/P3 measurements, got', vals)
            return 1
        print(f'P1 post-install : {vals[1]:>10} loop units')
        print(f'P2 playing      : {vals[2]:>10} loop units '
              f'({100*vals[2]/vals[1]:.1f}% of P1)')
        print(f'P3 silence      : {vals[3]:>10} loop units '
              f'({100*vals[3]/vals[1]:.1f}% of P1)')
        # companion 386SX-40 cycle model: the measurement above proves the
        # structure (states and interrupt rates); cycles386 prices it
        try:
            import cycles386
            tier = 'current'
            if vsb_bin and hashlib.sha256(
                    open(vsb_bin, 'rb').read()).hexdigest() == SHIPPED_1995_SHA:
                tier = 'vintage'
            elif '/E' in (vsb_args or '').upper():
                tier = 'current+E'
            print('--- modeled 386SX-40 impact (cycles386.py; calibrated '
                  'against the author\'s documented 25%-of-33MHz figure) ---')
            rate = 21694.0 if '22' in scenario else 10750.0
            if '/Q' in (vsb_args or '').upper() and rate > 11000:
                rate /= 2          # /Q integer decimation, k=2 at this rate
                print(f'  (/Q active: physical interrupt rate {rate:.0f}/s)')
            print(cycles386.report(tier, rate))
            if tier != 'vintage':
                print('  vs the 1995 binary:')
                print(cycles386.report('vintage', rate))
        except Exception as e:
            print('note: 386SX model unavailable:', e)
        print('PASS: perf measurement complete')
        return 0
    if scenario == 'pm':
        # testpm.com switches to protected mode and writes 'PMOK'<cs-sel>'END'
        # (or 'PMNOEND' if declined) to the LPT port.
        lpt = out / 'lpt.bin'
        deadline = time.time() + 180
        cap = b''
        while time.time() < deadline:
            cap = lpt.read_bytes() if lpt.exists() else b''
            if b'END' in cap and (b'PMOK' in cap or b'PMNO' in cap):
                break
            time.sleep(3)
        lines = [l for l in read_screen(str(out / 'mon.sock')) if l]
        print('--- guest screen ---')
        for l in lines:
            print('|', l)
        if b'PMNO' in cap:
            print(f'FAIL: mode switch declined (host returned CF=set): '
                  f'{cap[:32].hex()}')
            return 1
        i = cap.find(b'PMOK')
        if i < 0:
            print(f'FAIL: no PM marker captured - switch did not reach PM code '
                  f'({len(cap)} bytes: {cap[:32].hex()})')
            return 1
        cs = cap[i + 4] | (cap[i + 5] << 8)
        print(f'PM marker captured: client CS selector = {cs:04X}')
        ok = (cs & 4) != 0 and (cs & 3) == 3     # TI=LDT, RPL=3
        print(f'  {"ok  " if ok else "FAIL"} CS is an LDT ring-3 selector '
              f'(TI={ (cs>>2)&1 }, RPL={cs&3})')
        print('PASS: V86->PM mode switch green (pm)' if ok else 'FAIL')
        return 0 if ok else 1
    if scenario == 'dpmi':
        # testdpmi.com emits the int 2Fh/1687h outcome to the LPT port, framed
        # by 'DPMI?' ... 'END'. Decode and gate on the advertised host fields.
        lpt = out / 'lpt.bin'
        deadline = time.time() + 180
        cap = b''
        while time.time() < deadline:
            cap = lpt.read_bytes() if lpt.exists() else b''
            if b'DPMI?' in cap and b'END' in cap[cap.find(b'DPMI?'):]:
                break
            time.sleep(3)
        lines = [l for l in read_screen(str(out / 'mon.sock')) if l]
        print('--- guest screen ---')
        for l in lines:
            print('|', l)
        ok = True
        if not any('Installed' in l and 'VSB' in l for l in lines):
            print('FAIL: VSB banner not found on guest screen')
            ok = False
        s = cap.find(b'DPMI?')
        e = cap.find(b'END', s + 5) if s >= 0 else -1
        if s < 0 or e < 0:
            print(f'FAIL: DPMI probe frame not captured on LPT '
                  f'({len(cap)} bytes: {cap[:32].hex()})')
            return 1
        body = cap[s + 5:e]                 # 11 payload bytes
        if len(body) != 11:
            print(f'FAIL: DPMI frame is {len(body)} bytes, expected 11 '
                  f'({body.hex()})')
            return 1
        cf, al, ah, bl, cl, dl, dh = body[0:7]
        di = body[7] | (body[8] << 8)
        es = body[9] | (body[10] << 8)
        print(f'DPMI 1687h -> CF={cf} AX={ah:02X}{al:02X} BL={bl:02X} '
              f'CL={cl:02X} DX={dh:02X}{dl:02X} entry={es:04X}:{di:04X}')
        checks = [
            (cf == 0, 'CF clear (DPMI present)'),
            (al == 0 and ah == 0, 'AX=0 (installed)'),
            (bl & 1, 'BL bit0 (32-bit programs supported)'),
            (cl == 3, 'CL=3 (80386)'),
            (dl == 0x5A and dh == 0, 'DX=005A (version 0.90)'),
            (es != 0 or di != 0, 'mode-switch entry non-null'),
        ]
        for good, desc in checks:
            print(f'  {"ok  " if good else "FAIL"} {desc}')
            ok = ok and bool(good)
        print('PASS: DPMI detection responder green (dpmi)' if ok else 'FAIL')
        return 0 if ok else 1
    if scenario.startswith('chain'):
        # must match testai.asm: A: 40,80,40,80; B: C0,00,C0; C: 20.
        # chain22 runs at ~21.7 kHz and REQUIRES /Q: the stream is every
        # 2nd source byte (integer decimation, k=2)
        dec = 2 if scenario == 'chain22' else 1
        ref = b''.join(block(b)[::dec] for b in
                       (0x40, 0x80, 0x40, 0x80, 0xC0, 0x00, 0xC0, 0x20))
        done_marker = 'TESTAI DONE 8'
    else:
        ref = open(sample_path, 'rb').read()
        done_marker = None
    lpt = out / 'lpt.bin'
    # wait for the guest: capture file reaches sample size and stops growing
    deadline = time.time() + 300
    last = -1
    while time.time() < deadline:
        size = lpt.stat().st_size if lpt.exists() else 0
        if size >= len(ref) and size == last:
            break
        last = size
        time.sleep(5)
    cap = lpt.read_bytes() if lpt.exists() else b''

    lines = [l for l in read_screen(str(out / 'mon.sock')) if l]
    print('--- guest screen ---')
    for l in lines:
        print('|', l)

    ok = True
    if not any('Installed' in l and 'VSB' in l for l in lines):
        print('FAIL: VSB banner not found on guest screen')
        ok = False
    if done_marker:
        if not any(done_marker in l for l in lines):
            print(f'FAIL: "{done_marker}" not found on guest screen')
            ok = False
        pit = next((m.group(1) for l in lines
                    for m in [re.search(r'\bPIT ([0-9A-F]{2})\b', l)] if m), None)
        if pit is None:
            print('FAIL: PIT idle probe output not found')
            ok = False
        elif int(pit, 16) == 0:
            print('FAIL: PIT still at sample rate during silence '
                  '(idle gating not engaged)')
            ok = False
        else:
            print(f'PIT idle probe: high byte {pit} (timer idled to game rate)')
        if not any('ADDR OK' in l for l in lines):
            print('FAIL: DMA current-address read-back wrong (ADDR OK missing)')
            ok = False
    elif not any(re.search(r'\d+ / \d+ / \d+', l) for l in lines):
        print('FAIL: SBDMA virtual-IRQ diagnostics not found (IRQ5 never fired?)')
        ok = False

    idx = cap.find(ref)
    if idx < 0:
        print(f'FAIL: sample not reproduced in LPT capture '
              f'({len(cap)} bytes captured, {len(ref)} expected)')
        ok = False
    elif idx > 8:
        print(f'FAIL: sample found but after {idx} junk bytes')
        ok = False
    else:
        extra = len(cap) - idx - len(ref)
        print(f'LPT stream: sample reproduced exactly '
              f'({len(ref)}/{len(ref)} bytes at offset {idx}, '
              f'{extra} trailing byte(s))')
        if extra > 8:
            print(f'FAIL: {extra} unexpected trailing bytes')
            ok = False

    print(f'PASS: VSB behavioural harness green ({scenario})' if ok else 'FAIL')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2],
                  sys.argv[3] if len(sys.argv) > 3 else 'sample',
                  sys.argv[4] if len(sys.argv) > 4 else None,
                  sys.argv[5] if len(sys.argv) > 5 else ''))
