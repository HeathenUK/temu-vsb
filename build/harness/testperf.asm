;-----------------------------------------------------------------------------
; TESTPERF - guest-side CPU-availability probe for VSB (build/harness).
;
; Counts iterations of a fixed busy-loop across an 18-BIOS-tick (~1 s)
; window in three states and prints each as 'P<n> <hex32>':
;   P1: after VSB install, before any DSP activity
;   P2: during 8-bit DMA playback (~10.75 kHz, ~5.3 s block)
;   P3: after the DSP is halted (the idle state Phase 1 gates)
; More iterations = more CPU left for the application. Run under QEMU
; -icount for deterministic, build-comparable numbers. Not a 386SX cycle
; model - it measures structure (interrupt rates), not real cycle costs.
;-----------------------------------------------------------------------------
        .MODEL  TINY
        .CODE
        LOCALS  @@
        ORG     100h

Start:  jmp     Init

IFDEF TC22
TimeConst equ   205             ; divisor 55 -> ~21.7 kHz (the /Q test rate)
ELSE
TimeConst equ   155             ; ~10.75 kHz
ENDIF
PlayLen   equ   0DFFFh          ; 57344 samples, ~5.3 s

Int0D:  push    ax
        push    dx
        mov     dx,22Eh
        in      al,dx           ; ack VSB
        mov     al,20h
        out     20h,al          ; EOI
        pop     dx
        pop     ax
        iret

HexNib  proc    near
        cmp     al,10
        jb      @@dec
        add     al,7
@@dec:  add     al,'0'
        ret
        endp

Hex4    proc    near            ; AX -> 4 hex chars at cs:[bx], bx advances
        push    cx
        mov     cx,4
@@dig:  rol     ax,4
        push    ax
        and     al,0Fh
        call    HexNib
        mov     cs:[bx],al
        inc     bx
        pop     ax
        loop    @@dig
        pop     cx
        ret
        endp

WaitTicks proc  near            ; wait CX BIOS ticks
        push    ax
        push    bx
        push    es
        xor     ax,ax
        mov     es,ax
        mov     bx,es:[46Ch]
@@tick: mov     ax,es:[46Ch]
        sub     ax,bx
        cmp     ax,cx
        jb      @@tick
        pop     es
        pop     bx
        pop     ax
        ret
        endp

Measure proc    near            ; busy-loop iterations over 18 ticks -> DI:SI
        push    ax
        push    bx
        push    cx
        push    es
        xor     ax,ax
        mov     es,ax
        xor     si,si
        xor     di,di
        mov     bx,es:[46Ch]
@@edge: mov     ax,es:[46Ch]    ; align to a tick boundary
        cmp     ax,bx
        je      @@edge
        mov     bx,ax
@@unit: mov     cx,100
@@spin: loop    @@spin
        add     si,1
        adc     di,0
        mov     ax,es:[46Ch]
        sub     ax,bx
        cmp     ax,18
        jb      @@unit
        pop     es
        pop     cx
        pop     bx
        pop     ax
        ret
        endp

Report  proc    near            ; DL = state digit, DI:SI = value
        mov     cs:msgN,dl
        mov     ax,di
        mov     bx,offset msgVal
        call    Hex4
        mov     ax,si
        call    Hex4
        mov     dx,offset msgP
        mov     ah,9
        int     21h
        ret
        endp

ProgDMA proc    near            ; DMA ch1: seg 1000h ofs 0, CX=count-1, DL=mode
        push    ax
        mov     al,05h
        out     0Ah,al
        out     0Ch,al
        mov     al,dl
        out     0Bh,al
        xor     al,al           ; linear 10000h: addr 0, page 1
        out     02h,al
        out     02h,al
        mov     al,cl
        out     03h,al
        mov     al,ch
        out     03h,al
        mov     al,1
        out     83h,al
        mov     al,01h
        out     0Ah,al
        pop     ax
        ret
        endp

;-----------------------------------------------------------------------------
Init:   mov     ax,250Dh        ; hook IRQ5 vector
        mov     dx,offset Int0D
        int     21h
        in      al,21h          ; unmask IRQ5
        and     al,11011111b
        out     21h,al
        sti

        call    Measure         ; P1: post-install
        mov     dl,'1'
        call    Report

        mov     dx,226h         ; DSP reset, speaker on, time constant
        mov     al,0
        out     dx,al
        mov     dx,22Ch
        mov     al,0D1h
        out     dx,al
        mov     al,40h
        out     dx,al
        mov     al,TimeConst
        out     dx,al
        mov     cx,PlayLen
        mov     dl,49h
        call    ProgDMA
        mov     dx,22Ch         ; start the long block
        mov     al,14h
        out     dx,al
        mov     ax,PlayLen
        out     dx,al
        mov     al,ah
        out     dx,al

        mov     cx,2
        call    WaitTicks
        call    Measure         ; P2: during playback
        mov     dl,'2'
        call    Report

        mov     dx,22Ch         ; halt DSP, let idle hysteresis fire
        mov     al,0D0h
        out     dx,al
        mov     cx,5
        call    WaitTicks
        call    Measure         ; P3: post-playback silence
        mov     dl,'3'
        call    Report

        mov     ax,4C00h
        int     21h

msgP    db      13,10,'P'
msgN    db      '?',' '
msgVal  db      '????????',13,10,'$'

        end     Start
