import socket, time, re, sys
SP='/tmp/claude-0/-home-user-temu-vsb/0ec422c7-c498-5af9-855f-809e9da3780b/scratchpad'
def screen():
    s = socket.socket(socket.AF_UNIX); s.connect(SP+'/doom/mon.sock'); s.settimeout(2)
    def cmd(c):
        s.send((c+'\n').encode()); time.sleep(0.8); out=b''
        try:
            while True:
                r=s.recv(65536)
                if not r: break
                out+=r
        except socket.timeout: pass
        return out.decode('utf-8','replace')
    cmd('')
    txt = cmd('xp /4000bx 0xb8000')
    s.close()
    chars=[]
    for m in re.finditer(r'[0-9a-f]+:((?:\s0x[0-9a-f]{2})+)', txt):
        row=[int(x,16) for x in re.findall(r'0x([0-9a-f]{2})', m.group(1))]
        chars+=row[0::2]
    scr=''.join(chr(c) if 32<=c<127 else ' ' for c in chars)
    return [scr[i:i+80].rstrip() for i in range(0,min(len(scr),4000),80)]
marker = sys.argv[1] if len(sys.argv)>1 else 'STAGEA_DONE'
deadline = time.time()+float(sys.argv[2] if len(sys.argv)>2 else 300)
last=[]
while time.time()<deadline:
    try: last=[l for l in screen() if l]
    except Exception: last=[]
    joined=' '.join(last)
    if marker in joined or 'DOS/4G' in joined and 'error' in joined.lower():
        break
    time.sleep(10)
for l in last: print('|',l)
