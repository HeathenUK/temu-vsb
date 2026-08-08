; testvec - probe VSB DPMI int 31h vector services (M4d): fn 0200/0201 (real-
; mode int vector) and fn 0204/0205 (protected-mode int vector). Switches to PM,
; sets each vector, reads it back, and reports the round-tripped values.
;
; Wire format on 0x378:
;   'V','E','C'
;   rm_off_lo,hi  rm_seg_lo,hi     (fn 0201->0200: expect 5678, 1234)
;   pm_sel_lo,hi  pm_off_0..3      (fn 0205->0204: expect 00F0, AABBCCDD)
;   'E','N','D'

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [eoff],di
                mov     [eseg],es
                xor     ax,ax
                call    dword ptr [eoff]
                jc      nohost

                ; ---- protected mode ----
                mov     bx,00B0h            ; RM vector 0B0h
                mov     cx,1234h            ; segment
                mov     dx,5678h            ; offset
                mov     ax,0201h            ; set real-mode int vector
                int     31h
                mov     bx,00B0h
                mov     ax,0200h            ; get real-mode int vector
                int     31h
                mov     [rmseg],cx
                mov     [rmoff],dx

                mov     bx,00B1h            ; PM vector 0B1h
                mov     cx,00F0h            ; selector
                mov     edx,0AABBCCDDh      ; offset
                mov     ax,0205h            ; set PM int vector
                int     31h
                mov     bx,00B1h
                mov     ax,0204h            ; get PM int vector
                int     31h
                mov     [pmsel],cx
                mov     [pmoff],edx

                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     ax,[rmoff]
                call    outw
                mov     ax,[rmseg]
                call    outw
                mov     ax,[pmsel]
                call    outw
                mov     eax,[pmoff]
                call    outd
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

nohost:         mov     ax,4C01h
                int     21h

emit            proc    near
emit1:          mov     al,[si]
                out     dx,al
                inc     si
                loop    emit1
                ret
emit            endp
outw            proc    near            ; AX -> two bytes, DX=378h
                out     dx,al
                mov     al,ah
                out     dx,al
                ret
outw            endp
outd            proc    near            ; EAX -> four bytes, DX=378h
                out     dx,al
                shr     eax,8
                out     dx,al
                shr     eax,8
                out     dx,al
                shr     eax,8
                out     dx,al
                ret
outd            endp

sig             db      'VEC'
term            db      'END'
eoff            dw      0
eseg            dw      0
rmseg           dw      0
rmoff           dw      0
pmsel           dw      0
pmoff           dd      0
                end     start
