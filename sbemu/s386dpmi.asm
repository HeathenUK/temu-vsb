;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;∩┐╜           Virtual Sound Blaster - built-in DPMI host (WIP)             ∩┐╜∩┐╜
;∩┐╜                  Milestone 1: detection responder                     ∩┐╜∩┐╜
;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;
; Guarded by VSB_DPMI (TASM /dVSB_DPMI). Absent from the shipping vsb_real.com.
;
; This is the first brick of teaching VSB to be its own DPMI host so that
; DOS-extender games (DOOM/DOS4GW) run under it and get their SB ports trapped
; onto Covox + real OPL3 - the single-binary end state (see
; build/harness/vsb-dpmi-host-plan.md).
;
; A DOS extender detects a DPMI host with `int 2Fh, AX=1687h`. Under VSB the
; game runs in V86; its int 2Fh #GP-faults and the monitor's DoIntNN reflects
; it to the real-mode IVT - so a handler we place in IVT[2Fh] runs in the V86
; task where AX is a plain 16-bit register. That is the natural, correct place
; for the DPMI handshake (real hosts hook 2Fh the same way).
;
; These routines live in the RESIDENT region (before LastByte) so int 27h keeps
; them. The IVT install lives in the transient Init code.
;
; They run in the V86 task as an ordinary real-mode far ISR: the stack frame is
; IP(2), CS(2), FLAGS(2); return with IRET; DS is the caller's, so our own
; storage is reached with cs: overrides.

;--- saved previous int 2Fh vector (for chaining non-1687h calls) ------------
OldInt2F        dd      0

;--- DPMI mode-switch entry point --------------------------------------------
; The client far-CALLs this (AX=0 -> 16-bit client, AX=1 -> 32-bit) to switch
; itself into protected mode; it returns via RETF with CF clear on success.
;
; MILESTONE 1: the switch is not built yet, so we honestly decline - CF set,
; client stays in real/V86 mode and (per DPMI) treats the host as unavailable.
; This keeps a half-built host from crashing a real game. Milestone 2 replaces
; this body with the V86->ring-3 PM transition.
DpmiSwitch      proc    far
                stc                     ; WIP: mode switch not implemented
                retf
DpmiSwitch      endp

;--- int 2Fh handler ---------------------------------------------------------
Dpmi2F          proc    far
                cmp     ax,1687h        ; DPMI installation check?
                je      @@Detect
                ; not ours - chain to whoever had 2Fh before us, frame intact
                jmp     dword ptr cs:OldInt2F

@@Detect:       ; AX=0000  -> DPMI is installed
                ; BX bit0  -> 32-bit programs supported
                ; CL       -> processor type (3 = 80386)
                ; DX       -> DPMI version (DH.major DL.minor) = 0.90 -> 005Ah
                ; SI       -> paragraphs of DOS memory the host needs (0 for now)
                ; ES:DI    -> real-mode mode-switch entry point
                ; CF clear -> present
                push    bp
                mov     bp,sp           ; frame: [bp]=old bp,+2 IP,+4 CS,+6 FLAGS
                and     word ptr [bp+6],0FFFEh  ; clear CF in the flags IRET pops
                pop     bp
                xor     ax,ax
                mov     bx,1
                mov     cl,3
                mov     dx,005Ah
                xor     si,si
                push    cs
                pop     es
                mov     di,offset DpmiSwitch
                iret
Dpmi2F          endp
