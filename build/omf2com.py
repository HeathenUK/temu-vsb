#!/usr/bin/env python3
"""Minimal OMF (.OBJ) -> DOS .COM converter for single-module TINY-model objects.

Handles the record set TASM emits for VSB: THEADR, COMENT, LNAMES, SEGDEF16,
GRPDEF, LEDATA16, LIDATA16, FIXUPP16, FIXUPP32, MODEND. No EXTDEF/PUBDEF
support (the module must be self-contained). All segments are laid out
concatenated at their OMF order with frame base 0 (COM model); the image is
emitted from ORG (default 0x100) up to the highest *initialized* byte.
"""
import sys, struct

class Omf:
    def __init__(self, data):
        self.d = data
        self.lnames = []
        self.segs = []      # dicts: name, length, base
        self.grps = []
        self.image = bytearray()
        self.init_high = 0  # highest initialized byte + 1
        self.threads = {}   # (kind, num) -> (method, index)
        self.fix_mode = 'replace'  # or 'add'

    def idx(self, rec, i):
        b = rec[i]
        if b & 0x80:
            return ((b & 0x7F) << 8) | rec[i+1], i+2
        return b, i+1

    def ensure(self, size):
        if size > len(self.image):
            self.image.extend(b'\0' * (size - len(self.image)))

    def seg_base(self, si):
        return self.segs[si-1]['base']

    def run(self):
        d, i = self.d, 0
        last_ledata = None  # (seg_index, offset, length) for fixup anchoring
        while i < len(d):
            rt = d[i]
            ln = struct.unpack_from('<H', d, i+1)[0]
            rec = d[i+3:i+3+ln-1]           # exclude checksum byte
            if rt == 0x96:                   # LNAMES
                j = 0
                while j < len(rec):
                    n = rec[j]; self.lnames.append(rec[j+1:j+1+n].decode('cp437')); j += 1+n
            elif rt == 0x98:                 # SEGDEF16
                acbp = rec[0]; j = 1
                if (acbp >> 5) == 0:         # absolute: skip frame+offset
                    j += 3
                length = struct.unpack_from('<H', rec, j)[0]; j += 2
                if acbp & 0x02: length = 0x10000   # Big bit
                nmi, j = self.idx(rec, j)
                base = sum(s['length'] for s in self.segs)  # concatenate
                self.segs.append({'name': self.lnames[nmi-1] if nmi else '?',
                                  'length': length, 'base': base})
            elif rt == 0x9A:                 # GRPDEF
                self.grps.append(rec)
            elif rt == 0xA0:                 # LEDATA16
                si, j = self.idx(rec, 0)
                off = struct.unpack_from('<H', rec, j)[0]; j += 2
                data = rec[j:]
                addr = self.seg_base(si) + off
                self.ensure(addr + len(data))
                self.image[addr:addr+len(data)] = data
                self.init_high = max(self.init_high, addr + len(data))
                last_ledata = (si, off, len(data))
            elif rt == 0xA2:                 # LIDATA16
                si, j = self.idx(rec, 0)
                off = struct.unpack_from('<H', rec, j)[0]; j += 2
                blob, j = self.lidata_block(rec, j)
                while j < len(rec):
                    more, j = self.lidata_block(rec, j)
                    blob += more
                addr = self.seg_base(si) + off
                self.ensure(addr + len(blob))
                self.image[addr:addr+len(blob)] = blob
                self.init_high = max(self.init_high, addr + len(blob))
                last_ledata = (si, off, len(blob))
            elif rt in (0x9C, 0x9D):         # FIXUPP16 / FIXUPP32
                self.fixupp(rec, rt == 0x9D, last_ledata)
            elif rt in (0x80, 0x88, 0x8A):   # THEADR, COMENT, MODEND
                pass
            else:
                sys.exit(f"unsupported OMF record {rt:#x}")
            i += 3 + ln
        return bytes(self.image)

    def lidata_block(self, rec, j):
        rep = struct.unpack_from('<H', rec, j)[0]; j += 2
        cnt = struct.unpack_from('<H', rec, j)[0]; j += 2
        if cnt == 0:
            n = rec[j]; j += 1
            content = bytes(rec[j:j+n]); j += n
        else:
            content = b''
            for _ in range(cnt):
                sub, j = self.lidata_block(rec, j)
                content += sub
        return content * rep, j

    def fixupp(self, rec, is32, last_ledata):
        j = 0
        while j < len(rec):
            first = rec[j]
            if not (first & 0x80):           # THREAD subrecord
                method = (first >> 2) & 7
                num = first & 3
                kind = 'F' if first & 0x40 else 'T'
                index = None
                if (kind == 'F' and method < 4) or (kind == 'T'):
                    index, j2 = self.idx(rec, j+1); j = j2
                else:
                    j += 1
                self.threads[(kind, num)] = (method, index)
                continue
            # FIXUP subrecord
            m_seg_rel = bool(first & 0x40)
            loc = (first >> 2) & 0x0F
            data_off = ((first & 3) << 8) | rec[j+1]
            j += 2
            fixdat = rec[j]; j += 1
            # frame
            if fixdat & 0x80:                # frame thread
                fmethod, findex = self.threads[('F', (fixdat >> 4) & 3)]
            else:
                fmethod = (fixdat >> 4) & 7
                findex = None
                if fmethod < 3:
                    findex, j = self.idx(rec, j)
            # target
            if fixdat & 0x08:                # target thread
                tmethod, tindex = self.threads[('T', fixdat & 3)]
                tmethod = (tmethod & 3) | (0 if not (fixdat & 0x04) else 4)
            else:
                tmethod = fixdat & 0x07
                tindex, j = self.idx(rec, j)
            disp = 0
            if not (fixdat & 0x04):          # P=0: displacement present
                if is32:
                    disp = struct.unpack_from('<I', rec, j)[0]; j += 4
                else:
                    disp = struct.unpack_from('<H', rec, j)[0]; j += 2
            # resolve target address (only seg/group methods supported)
            tm = tmethod & 3
            if tm == 0:   tbase = self.seg_base(tindex)
            elif tm == 1: tbase = 0          # group -> base 0 in COM
            else: sys.exit("EXTDEF target unsupported")
            target = tbase + disp
            si, off, _ = last_ledata
            addr = self.seg_base(si) + off + data_off
            if not m_seg_rel:                # self-relative
                size = {0:1, 1:2, 2:2, 3:4, 4:1, 5:2, 9:4, 11:6, 13:4}[loc]
                target = target - (addr + size)
            self.apply(addr, loc, target)

    def apply(self, addr, loc, value):
        if loc in (1, 5):                    # 16-bit offset
            old = struct.unpack_from('<H', self.image, addr)[0]
            val = (value + (old if self.fix_mode == 'add' else 0)) & 0xFFFF
            struct.pack_into('<H', self.image, addr, val)
        elif loc in (9, 13):                 # 32-bit offset
            old = struct.unpack_from('<I', self.image, addr)[0]
            val = (value + (old if self.fix_mode == 'add' else 0)) & 0xFFFFFFFF
            struct.pack_into('<I', self.image, addr, val)
        elif loc == 0:                       # low byte
            self.image[addr] = value & 0xFF
        elif loc == 4:                       # high byte
            self.image[addr] = (value >> 8) & 0xFF
        elif loc == 2:                       # segment base
            sys.exit("segment-base fixup: not representable in COM")
        else:
            sys.exit(f"unsupported fixup location type {loc}")

if __name__ == '__main__':
    obj, out = sys.argv[1], sys.argv[2]
    org = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x100
    o = Omf(open(obj, 'rb').read())
    if len(sys.argv) > 4: o.fix_mode = sys.argv[4]
    img = o.run()
    seg_report = ', '.join(f"{s['name']}@{s['base']:#x}+{s['length']:#x}" for s in o.segs)
    print(f"segments: {seg_report}; initialized through {o.init_high:#x}")
    open(out, 'wb').write(img[org:o.init_high])
    print(f"wrote {out}: {o.init_high - org} bytes")
