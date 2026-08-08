; testmem - probe VSB's DPMI extended-memory (linear) services (Milestone 5).
;
; Real-mode .COM. Detects the host, switches to PM, then from ring-3 allocates a
; linear memory block (int 31h fn 0501) - which must come from physical RAM
; above 1 MB - builds a descriptor over it (fn 0000/0007/0008/0009), and writes
; a canary through it. To prove the block is REAL extended memory (and A20 is
; open, not wrapping at 1 MB), it also writes a different byte through a second
; descriptor based at the block's bit-20 alias (base XOR 0x100000) and re-reads
; the block: if A20 is open the two are distinct (canary survives); if A20 were
; masked the alias write would clobber the block. This is the heap path a 32-bit
; DOS extender (DOS4GW/DOOM) takes.
;
; Wire format on 0x378:
;   'M','E','M'
;   lin0,lin1,lin2,lin3   linear base of the block (little-endian; expect >=1MB)
;   canary                block[0] re-read after the alias write (expect 5A)
;   'E','N','D'
; or 'MEMERR'<code_lo><code_hi>'END' if a service set CF.

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h            ; detect DPMI host
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [entry_off],di
                mov     [entry_seg],es

                xor     ax,ax               ; 16-bit switch
                call    dword ptr [entry_off]
                jc      nohost              ; declined -> bail (still real mode)

                ; ---- protected mode from here ----
                mov     bx,1                ; allocate 64 KB (BX:CX = size bytes)
                xor     cx,cx
                mov     ax,0501h
                int     31h
                jc      failed
                mov     [lin_hi],bx         ; linear base BX:CX
                mov     [lin_lo],cx

                mov     cx,2                ; allocate 2 descriptors
                xor     ax,ax
                int     31h
                jc      failed
                mov     [sel1],ax
                add     ax,8
                mov     [sel2],ax

                ; sel1 -> base = linear block
                mov     bx,[sel1]
                mov     cx,[lin_hi]
                mov     dx,[lin_lo]
                mov     ax,0007h
                int     31h
                jc      failed
                call    setlim1             ; limit 64K-1, access data r/w

                ; sel2 -> base = block XOR 0x100000 (the bit-20 alias)
                mov     bx,[sel2]
                mov     cx,[lin_hi]
                xor     cx,10h              ; toggle bit 20 (0x100000 >> 16)
                mov     dx,[lin_lo]
                mov     ax,0007h
                int     31h
                jc      failed
                mov     bx,[sel2]
                call    setlim              ; limit/access on BX

                ; write canary to the block, then to the alias, then re-read block
                mov     es,[sel1]
                xor     bx,bx
                mov     byte ptr es:[bx],5Ah    ; block[0] = 5A
                mov     es,[sel2]
                mov     byte ptr es:[bx],0A5h   ; alias[0] = A5 (clobbers block if A20 off)
                mov     es,[sel1]
                mov     al,es:[bx]              ; re-read block[0]
                mov     [r_can],al
                push    ds
                pop     es

                ; ---- emit results ----
                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,byte ptr [lin_lo]
                out     dx,al
                mov     al,byte ptr [lin_lo+1]
                out     dx,al
                mov     al,byte ptr [lin_hi]
                out     dx,al
                mov     al,byte ptr [lin_hi+1]
                out     dx,al
                mov     al,[r_can]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

; setlim1: apply limit+access to sel1; setlim: apply to selector already in BX
setlim1         proc    near
                mov     bx,[sel1]
setlim:         xor     cx,cx
                mov     dx,0FFFFh           ; limit 64K-1 (byte granular)
                mov     ax,0008h
                int     31h
                jc      slfail
                mov     cl,0F2h             ; ring-3 data, present, writable
                xor     ch,ch
                mov     ax,0009h
                int     31h
                jc      slfail
                ret
slfail:         jmp     failed              ; abandons return addr; failed -> hang
setlim1         endp

failed:         mov     [lin_lo],ax         ; reuse: stash error code
                mov     dx,378h
                mov     si,offset emsg
                mov     cx,6
                call    emit
                mov     al,byte ptr [lin_lo]
                out     dx,al
                mov     al,byte ptr [lin_lo+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
                jmp     hang

nohost:         mov     ax,4C01h
                int     21h

; emit CX bytes from DS:SI to port DX
emit            proc    near
emit1:          mov     al,[si]
                out     dx,al
                inc     si
                loop    emit1
                ret
emit            endp

sig             db      'MEM'
term            db      'END'
emsg            db      'MEMERR'
entry_off       dw      0
entry_seg       dw      0
lin_lo          dw      0
lin_hi          dw      0
sel1            dw      0
sel2            dw      0
r_can           db      0
                end     start
