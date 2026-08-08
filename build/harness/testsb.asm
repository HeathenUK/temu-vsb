; testsb - probe VSB's PM Sound Blaster port trapping (M4c). Switches to PM,
; then (at ring-3, IOPL 0) does an SB DSP reset and reads the DSP data port.
; Those port accesses hit the TSS I/O bitmap -> #GP -> VSB's PortHandler
; emulation. A returned 0xAA (DSP ready) proves the SB emulation was reached
; from protected mode - the path that lands DOOM's PCM on the Covox.
;
; Wire format on 0x378:  'S','B'  <dsp-status>  'E','N','D'   (expect AA)

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [eoff],di           ; ES:DI = mode-switch entry
                mov     [eoff+2],es
                xor     ax,ax
                call    dword ptr [eoff]
                jc      nohost

                ; ---- protected mode, IOPL 0: SB port I/O traps ----
                ; Full DSP reset then status read. The reset reprograms the PIT,
                ; so a timer IRQ0 fires while we're in PM - M4b must absorb it
                ; (deliver-or-drop) rather than fault-storm.
                mov     dx,226h             ; DSP reset port
                mov     al,1
                out     dx,al               ; -> #GP -> PortHandler (reset)
                xor     al,al
                out     dx,al
                mov     dx,22Ah             ; DSP read-data port
                in      al,dx               ; -> #GP -> PortHandler -> 0xAA
                mov     [dspstat],al

                mov     dx,378h
                mov     si,offset sig
                mov     cx,2
                call    emit
                mov     al,[dspstat]
                out     dx,al
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

sig             db      'SB'
term            db      'END'
eoff            dw      0
                dw      0
dspstat         db      0
                end     start
