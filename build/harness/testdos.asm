; testdos - probe VSB's built-in DPMI DOS-memory services (Milestone 4d).
;
; Real-mode .COM. Detects the host, switches to protected mode, then from
; ring-3 allocates a DOS memory block (int 31h fn 0100), writes+reads a byte
; through the returned selector (proving base/limit are right), and frees it
; (fn 0101). Each service runs a V86 excursion into DOS int 21h AH=48h/49h
; inside the monitor - the path DOS4GW/DOOM use for real-mode transfer buffers.
;
; Wire format on 0x378:
;   'D','O','S'
;   seg_lo, seg_hi      real-mode segment returned by fn 0100 (nonzero)
;   sel_lo, sel_hi      selector returned by fn 0100 (nonzero, TI/RPL = 7)
;   canary              byte read back through the selector (expect 5A)
;   free_lo, free_hi    0000 if fn 0101 returned CF clear
;   'E','N','D'
; or 'DOSERR'<code_lo><code_hi>'END' if fn 0100 set CF.

                .model  tiny
                .386
                .code
                org     100h
start:
                ; A .COM owns all of conventional memory at load, so int 21h
                ; AH=48h would fail with "insufficient memory" (8). Shrink our
                ; block to 64 KB first (ES = PSP at .COM entry) to free RAM for
                ; the fn 0100 allocation to hand back.
                mov     ah,4Ah
                mov     bx,1000h            ; keep 4096 paragraphs (64 KB)
                int     21h

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
                mov     bx,10h              ; allocate 16 paragraphs (256 bytes)
                mov     ax,0100h
                int     31h
                jc      failed
                mov     [r_seg],ax          ; real-mode segment
                mov     [r_sel],dx          ; selector for the block

                mov     es,dx               ; access the block via its selector
                xor     bx,bx
                mov     byte ptr es:[bx],5Ah   ; write a canary
                mov     al,es:[bx]             ; read it back
                mov     [r_can],al
                push    ds
                pop     es                  ; restore ES before freeing

                mov     dx,[r_sel]          ; free the block (fn 0101)
                mov     ax,0101h
                int     31h
                mov     [r_free],0
                jnc     freed
                mov     [r_free],1
freed:
                ; ---- emit results ----
                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,byte ptr [r_seg]
                out     dx,al
                mov     al,byte ptr [r_seg+1]
                out     dx,al
                mov     al,byte ptr [r_sel]
                out     dx,al
                mov     al,byte ptr [r_sel+1]
                out     dx,al
                mov     al,[r_can]
                out     dx,al
                mov     al,byte ptr [r_free]
                out     dx,al
                mov     al,byte ptr [r_free+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

failed:         mov     [r_seg],ax          ; reuse: stash error code
                mov     dx,378h
                mov     si,offset emsg
                mov     cx,6
                call    emit
                mov     al,byte ptr [r_seg]
                out     dx,al
                mov     al,byte ptr [r_seg+1]
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

sig             db      'DOS'
term            db      'END'
emsg            db      'DOSERR'
entry_off       dw      0
entry_seg       dw      0
r_seg           dw      0
r_sel           dw      0
r_can           db      0
r_free          dw      0
                end     start
