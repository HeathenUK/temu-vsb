;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;∩┐╜   testpm - probe VSB's built-in DPMI mode switch (Milestone 2)            ∩┐╜
;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;
; Real-mode .COM. Detects the host (int 2Fh/1687h), then far-calls the
; mode-switch entry to enter protected mode. From the resulting PM context it
; writes a marker + a captured selector to the LPT port 0x378, which the QEMU
; harness captures - proof that real ring-3 PM code executed after the switch.
;
; Wire format on 0x378:
;   'P','M','O','K'   switch succeeded, PM code ran
;   CS_lo, CS_hi      the client CS *selector* (low bits set => a PM selector,
;                     not a real-mode segment)
;   'E','N','D'
; or, if the switch was declined (CF set):
;   'P','M','N','O','E','N','D'
;
; After emitting, the probe spins (int 21h exit needs reflection = milestone 4);
; the harness reads the marker and stops QEMU.

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h            ; DPMI installation check
                int     2Fh
                or      ax,ax
                jnz     nohost              ; AX!=0 -> no host
                test    bl,1                ; 32-bit supported?
                ; (we switch 16-bit regardless; bl checked only for report)
                mov     [entry_off],di      ; ES:DI = mode-switch entry
                mov     [entry_seg],es

                xor     ax,ax               ; AX=0 -> 16-bit switch
                ; far call [entry_seg:entry_off]
                call    dword ptr [entry_off]
                jc      declined            ; CF set -> host declined

                ; ---- we are now in protected mode (ring 3) ----
                mov     dx,378h
                mov     al,'P'
                out     dx,al
                mov     al,'M'
                out     dx,al
                mov     al,'O'
                out     dx,al
                mov     al,'K'
                out     dx,al
                mov     ax,cs               ; our CS is now a selector
                out     dx,al               ; CS lo
                mov     al,ah
                out     dx,al               ; CS hi
                mov     al,'E'
                out     dx,al
                mov     al,'N'
                out     dx,al
                mov     al,'D'
                out     dx,al
hang:           jmp     hang

declined:       mov     dx,378h
                mov     si,offset msg_no
                mov     cx,7
emitno:         mov     al,[si]
                out     dx,al
                inc     si
                loop    emitno
                jmp     hang

nohost:         mov     ax,4C01h            ; still real mode here - clean exit
                int     21h

entry_off       dw      0
entry_seg       dw      0
msg_no          db      'PMNOEND'
                end     start
