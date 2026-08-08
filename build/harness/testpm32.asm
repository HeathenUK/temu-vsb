; testpm32 - execute genuine 32-bit protected-mode code under VSB's DPMI host
; (the last synthetic gap before a real 32-bit extender / DOOM).
;
; Real-mode .COM. Detects the host, switches to PM (16-bit CS), then does what a
; 32-bit extender does: allocates an extended-memory block (fn 0501), copies a
; small 32-bit routine into it, builds a USE32 code selector over that block
; (base != the switch-time code base), and far-jumps to it. The 32-bit routine
; does a trapped SB DSP-status read (in al,dx -> #GP -> the PM-fault decoder,
; which must resolve the base from the FAULTING CS, not a cached value) and an
; int 31h (get version) from 32-bit code, then far-jumps back to 16-bit to emit.
;
; Wire format on 0x378:
;   'P','3','2'
;   verAL, verAH        int 31h version from 32-bit code (expect 5A 00)
;   dspstat             0x22A read from 32-bit code (expect AA)
;   'E','N','D'
; or 'P32ERR'<code_lo><code_hi>'END' if a service set CF.

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
                jc      nohost

                ; ---- protected mode (16-bit) ----
                mov     word ptr [ret16+4],cs   ; return selector = our 16-bit CS

                mov     bx,0                ; allocate one 4K page (BX:CX bytes)
                mov     cx,1000h
                mov     ax,0501h
                int     31h
                jc      failed
                mov     [blk_hi],bx         ; block linear base BX:CX
                mov     [blk_lo],cx

                mov     cx,2                ; two descriptors: code32 + data
                xor     ax,ax
                int     31h
                jc      failed
                mov     [sel32],ax
                add     ax,8
                mov     [seld],ax

                ; data selector over the block (to copy the stub in)
                mov     bx,[seld]
                mov     cx,[blk_hi]
                mov     dx,[blk_lo]
                mov     ax,0007h            ; set base
                int     31h
                jc      failed
                mov     bx,[seld]
                xor     cx,cx
                mov     dx,0FFFFh
                mov     ax,0008h            ; set limit 64K-1
                int     31h
                jc      failed
                mov     bx,[seld]
                mov     cl,0F2h
                xor     ch,ch
                mov     ax,0009h            ; ring-3 data
                int     31h
                jc      failed

                ; copy the 32-bit stub into the block
                push    ds
                pop     es                  ; (restored below via the selector load)
                mov     es,[seld]
                xor     di,di
                mov     si,offset code32
                mov     cx,code32end-code32
                cld
                rep     movsb
                push    ds
                pop     es

                ; code32 selector over the block: 32-bit, ring-3, readable
                mov     bx,[sel32]
                mov     cx,[blk_hi]
                mov     dx,[blk_lo]
                mov     ax,0007h            ; set base = block
                int     31h
                jc      failed
                mov     bx,[sel32]
                xor     cx,cx
                mov     dx,0FFFFh
                mov     ax,0008h            ; set limit 64K-1
                int     31h
                jc      failed
                mov     bx,[sel32]
                mov     cl,0FAh             ; present, DPL3, code, readable
                mov     ch,40h              ; D-bit set -> 32-bit segment
                mov     ax,0009h
                int     31h
                jc      failed

                mov     ax,[sel32]          ; patch the far-jump target selector
                mov     word ptr [jmp32+4],ax

                ; DSP reset so 0x22A returns AA, then preload DX for the 32-bit IN
                mov     dx,226h
                mov     al,1
                out     dx,al
                xor     al,al
                out     dx,al
                mov     dx,22Ah

                ; ---- 32-bit far jump to the copied stub (offset 0 in the block) ---
                db      66h,0FFh,2Eh        ; jmp fword [jmp32] (66 -> m16:32)
                dw      offset jmp32

; ===================== 32-bit routine (hand-encoded) =======================
; Runs with CS = sel32 (base = the block, NOT the switch-time base) and D=1.
; DS is still the client 16-bit data selector, so absolute [moffs] references
; resolve into THIS .COM's data. Position-independent w.r.t. CS.
code32:
                db      0ECh                ; in    al,dx        (SB status; #GP -> M4c)
                db      0A2h                ; mov   [dspstat],al  (moffs32, DS-rel)
                dd      offset dspstat
                db      66h,0B8h,00h,04h    ; mov   ax,0400h      (66 = opsize 16)
                db      0CDh,31h            ; int   31h           (get version)
                db      66h,0A3h            ; mov   [r_ver],ax    (moffs32, DS-rel)
                dd      offset r_ver
                db      0FFh,2Dh            ; jmp   fword [ret16]  (disp32, m16:32)
                dd      offset ret16
code32end:
; ===========================================================================

; ---- back in 16-bit protected mode ----
cont16:
                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,byte ptr [r_ver]
                out     dx,al
                mov     al,byte ptr [r_ver+1]
                out     dx,al
                mov     al,[dspstat]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

failed:         mov     [r_ver],ax
                mov     dx,378h
                mov     si,offset emsg
                mov     cx,6
                call    emit
                mov     al,byte ptr [r_ver]
                out     dx,al
                mov     al,byte ptr [r_ver+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
                jmp     hang

nohost:         mov     ax,4C01h
                int     21h

emit            proc    near
emit1:          mov     al,[si]
                out     dx,al
                inc     si
                loop    emit1
                ret
emit            endp

sig             db      'P32'
term            db      'END'
emsg            db      'P32ERR'
entry_off       dw      0
entry_seg       dw      0
blk_lo          dw      0
blk_hi          dw      0
sel32           dw      0
seld            dw      0
jmp32           dd      0                   ; 32-bit far ptr: offset 0 in the block
                dw      0                   ;   selector (patched = sel32)
ret16           dd      offset cont16       ; 32-bit far ptr back to 16-bit code
                dw      0                   ;   selector (patched = our CS)
r_ver           dw      0
dspstat         db      0
                end     start
