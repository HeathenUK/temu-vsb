#!/usr/bin/env python3
"""Harness checker: waits for VSB playback inside the QEMU guest, then gates on
(1) the VSB banner + SBDMA's virtual-IRQ diagnostics on the DOS text screen and
(2) the captured LPT byte stream reproducing sbemu/sample exactly.

The capture may carry a small number of leading non-sample bytes (SeaBIOS
probes the port with 0xAA during POST); the sample must appear as one exact
contiguous run at a small offset.
"""
import re, socket, sys, time, pathlib

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

def main(outdir, sample_path):
    out = pathlib.Path(outdir)
    ref = open(sample_path, 'rb').read()
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
    if not any(re.search(r'\d+ / \d+ / \d+', l) for l in lines):
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

    print('PASS: VSB behavioural harness green' if ok else 'FAIL')
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main(sys.argv[1], sys.argv[2]))
