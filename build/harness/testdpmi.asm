;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;∩┐╜   testdpmi - probe VSB's built-in DPMI detection responder (Milestone 1)  ∩┐╜
;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;
; Real-mode .COM. Issues int 2Fh AX=1687h (DPMI installation check) and writes
; the outcome to the LPT data port 0x378, where the QEMU harness captures it.
; No DPMI mode switch is attempted - this verifies only the handshake, which is
; the part that CAN be checked in emulation.
;
; Wire format on 0x378 (so check.py can locate & decode it):
;   'D','P','M','I','?'         signature
;   CF        (00 = present, 01 = not present / carry set)
;   AL, AH                      (present => 00 00)
;   BL                          (bit0 => 32-bit programs supported)
;   CL                          (processor type; 03 = 386)
;   DL, DH                      (DPMI version minor, major; 5A 00 = 0.90)
;   DI_lo, DI_hi, ES_lo, ES_hi  (mode-switch entry point seg:off)
;   'E','N','D'                 terminator

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,0DEADh          ; sentinels so "untouched" is visible
                xchg    ax,bx
                mov     ax,0DEADh
                xchg    ax,cx
                mov     ax,0DEADh
                xchg    ax,dx
                push    0
                pop     es                 ; ES=0000, DI=0000 before the call
                xor     di,di
                mov     ax,1687h
                int     2Fh

                mov     [r_ax],ax          ; DS=CS for a .COM
                mov     [r_bx],bx
                mov     [r_cx],cx
                mov     [r_dx],dx
                mov     [r_di],di
                mov     [r_es],es
                pushf
                pop     ax
                mov     [r_fl],ax

                ; ---- emit signature ----
                mov     dx,378h
                mov     si,offset sig
                mov     cx,5
emitsig:        lodsb
                out     dx,al
                loop    emitsig

                ; ---- CF (bit0 of saved flags) ----
                mov     ax,[r_fl]
                and     al,1
                out     dx,al

                mov     ax,[r_ax]
                out     dx,al              ; AL
                mov     al,ah
                out     dx,al              ; AH
                mov     ax,[r_bx]
                out     dx,al              ; BL
                mov     ax,[r_cx]
                out     dx,al              ; CL
                mov     ax,[r_dx]
                out     dx,al              ; DL
                mov     al,ah
                out     dx,al              ; DH
                mov     ax,[r_di]
                out     dx,al              ; DI lo
                mov     al,ah
                out     dx,al              ; DI hi
                mov     ax,[r_es]
                out     dx,al              ; ES lo
                mov     al,ah
                out     dx,al              ; ES hi

                mov     si,offset term
                mov     cx,3
emitend:        lodsb
                out     dx,al
                loop    emitend

                mov     ax,4C00h
                int     21h

sig             db      'DPMI?'
term            db      'END'
r_ax            dw      0
r_bx            dw      0
r_cx            dw      0
r_dx            dw      0
r_di            dw      0
r_es            dw      0
r_fl            dw      0
                end     start
