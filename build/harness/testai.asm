;-----------------------------------------------------------------------------
; TESTAI - harness workload for VSB (see build/harness/check.py)
;
; Exercises the paths the PERFORMANCE.md Phase 1 changes touch:
;   Phase A: four chained single-cycle DMA blocks (stop/start per block)
;   Phase B: auto-init DMA double-buffer, three DSP blocks with the next 14h
;            issued from inside the IRQ handler (the faithful double-buffer
;            pattern; also the only race-free way across the buffer-boundary
;            reload, where VSB briefly resumes output with an expired block
;            counter if the next 14h loses against the next sample tick).
;            The phase ends mid-buffer so the halt is race-free too.
;   Phase C: 2 s of silence, then one more block (re-arm after idle)
; Every block is 512 bytes with a distinct fill (base + (index and 3Fh)) so
; the captured LPT stream proves ordering and reload correctness exactly.
; Prints 'TESTAI DONE <n>' where <n> counts virtual SB IRQs ('8' expected).
;-----------------------------------------------------------------------------
        .MODEL  TINY
        .CODE
        LOCALS  @@
        ORG     100h

Start:  jmp     Init

IRQflag db      0
IRQchar db      '0'
AutoBlk db      0               ; 14h re-issues left for the IRQ handler
BufSeg  dw      0
TimeConst equ   155             ; VSB divisor (255-TC)*120/108 -> ~10.75 kHz

;--------------------------------------------------- IRQ5 (int 0Dh) handler
Int0D:  push    ax
        push    dx
        mov     dx,22Eh
        in      al,dx           ; ack VSB (clears its pending-IRQ latch)
        mov     al,20h
        out     20h,al          ; EOI
        mov     cs:IRQflag,1
        inc     cs:IRQchar
        cmp     cs:AutoBlk,0    ; double-buffer style: next block from the ISR
        je      @@noAuto
        dec     cs:AutoBlk
        mov     dx,22Ch
        mov     al,14h
        out     dx,al
        mov     al,0FFh         ; count-1 = 511
        out     dx,al
        mov     al,1
        out     dx,al
@@noAuto:
        pop     dx
        pop     ax
        iret

;--------------------------------------------- wait for next block-end IRQ
WaitIRQ proc    near
        push    ax
        push    bx
        push    es
        xor     ax,ax
        mov     es,ax
        mov     bx,es:[46Ch]
@@spin: cmp     cs:IRQflag,0
        jne     @@got
        mov     ax,es:[46Ch]
        sub     ax,bx
        cmp     ax,72           ; ~4 s timeout
        jb      @@spin
        mov     dx,offset msgTimeout
        mov     ah,9
        int     21h
        mov     ax,4C01h
        int     21h
@@got:  mov     cs:IRQflag,0
        pop     es
        pop     bx
        pop     ax
        ret
        endp

;----------------------------------------------------- wait CX BIOS ticks
WaitTicks proc  near
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

;------------------- fill 512 bytes at BufSeg:DI with BL + (index and 3Fh)
Fill512 proc    near
        push    ax
        push    cx
        push    di
        push    es
        mov     es,cs:BufSeg
        cld
        xor     cx,cx
@@fill: mov     ax,cx
        and     al,3Fh
        add     al,bl
        stosb
        inc     cx
        cmp     cx,512
        jb      @@fill
        pop     es
        pop     di
        pop     cx
        pop     ax
        ret
        endp

;------------ program DMA ch1: BX=offset in buffer, CX=count-1, DL=mode
ProgDMA proc    near
        push    ax
        push    dx
        mov     al,05h
        out     0Ah,al          ; mask channel 1
        out     0Ch,al          ; reset flip-flop
        mov     al,dl
        out     0Bh,al          ; mode
        mov     ax,cs:BufSeg
        mov     dh,ah
        shr     dh,4            ; page
        shl     ax,4
        add     ax,bx
        jnc     @@nopg
        inc     dh
@@nopg: out     02h,al
        mov     al,ah
        out     02h,al
        mov     al,cl
        out     03h,al
        mov     al,ch
        out     03h,al
        mov     al,dh
        out     83h,al
        mov     al,01h
        out     0Ah,al          ; unmask (VSB latches address+count here)
        pop     dx
        pop     ax
        ret
        endp

;----------------------------------------- DSP 8-bit DMA block, CX=count-1
Blk14   proc    near
        push    ax
        push    dx
        mov     dx,22Ch
        mov     al,14h
        out     dx,al
        mov     al,cl
        out     dx,al
        mov     al,ch
        out     dx,al
        pop     dx
        pop     ax
        ret
        endp

;-----------------------------------------------------------------------------
Init:   mov     ax,cs           ; paragraph-align the DMA buffer
        mov     dx,offset BufMem+15
        shr     dx,4
        add     ax,dx
        mov     dx,ax           ; keep the 2K window inside one 64K phys page
        and     dx,0FFFh
        cmp     dx,0F80h
        jb      @@bufOK
        add     ax,80h
@@bufOK:mov     cs:BufSeg,ax
        mov     ax,250Dh        ; hook IRQ5 vector
        mov     dx,offset Int0D
        int     21h
        in      al,21h          ; unmask IRQ5
        and     al,11011111b
        out     21h,al
        sti
        mov     dx,226h         ; DSP reset
        mov     al,0
        out     dx,al
        mov     dx,22Ch
        mov     al,0D1h         ; speaker on
        out     dx,al
        mov     al,40h          ; time constant
        out     dx,al
        mov     al,TimeConst
        out     dx,al

; Phase A: four chained single-cycle blocks, alternating content
        mov     bp,4
        mov     bl,40h
@@phaseA:
        xor     di,di
        call    Fill512
        push    bx
        mov     bx,0
        mov     cx,511
        mov     dl,49h          ; single-cycle, read, channel 1
        call    ProgDMA
        mov     cx,511
        call    Blk14
        call    WaitIRQ
        pop     bx
        xor     bl,0C0h         ; 40h <-> 80h
        dec     bp
        jne     @@phaseA

; Phase B: auto-init DMA over a 1024-byte double buffer, three DSP blocks
; (ends mid-buffer; blocks 2 and 3 are issued from the IRQ handler)
        mov     bl,0C0h
        xor     di,di
        call    Fill512
        mov     bl,0
        mov     di,512
        call    Fill512
        mov     bx,0
        mov     cx,1023
        mov     dl,59h          ; auto-init, read, channel 1
        call    ProgDMA
        mov     cs:AutoBlk,2
        mov     cx,511
        call    Blk14
        mov     bp,3
@@phaseB:
        call    WaitIRQ
        dec     bp
        jne     @@phaseB
        mov     dx,22Ch         ; halt DMA
        mov     al,0D0h
        out     dx,al

; Phase C: 2 s of silence, then one more block (re-arm after idle).
; Mid-silence, probe the free-running PIT ch0 count (VSB passes reads
; through): at the sample rate the divisor is 111 so the high byte is
; always 0; idled to the game's rate (divisor 65536) it sweeps 00..FF.
; Prints 'PIT <max-high-byte>'; check.py requires a non-zero value.
        mov     cx,9
        call    WaitTicks
        xor     bh,bh
        mov     bp,8
@@pit:  mov     cx,2
        call    WaitTicks
        in      al,40h          ; low byte (discard)
        in      al,40h          ; high byte
        cmp     al,bh
        jbe     @@pitNext
        mov     bh,al
@@pitNext:
        dec     bp
        jne     @@pit
        mov     al,bh
        shr     al,4
        call    HexNib
        mov     cs:msgPitH,al
        mov     al,bh
        and     al,0Fh
        call    HexNib
        mov     cs:msgPitL,al
        mov     dx,offset msgPit
        mov     ah,9
        int     21h
        mov     cx,9
        call    WaitTicks
        mov     bl,20h
        xor     di,di
        call    Fill512
        mov     bx,0
        mov     cx,511
        mov     dl,49h
        call    ProgDMA
        mov     cx,511
        call    Blk14
        call    WaitIRQ

        mov     al,cs:IRQchar
        mov     cs:msgCount,al
        mov     dx,offset msgDone
        mov     ah,9
        int     21h
        mov     ax,4C00h
        int     21h

HexNib  proc    near
        cmp     al,10
        jb      @@dec
        add     al,7
@@dec:  add     al,'0'
        ret
        endp

msgTimeout db   'TESTAI TIMEOUT$'
msgPit     db   'PIT '
msgPitH    db   '?'
msgPitL    db   '?',13,10,'$'
msgDone    db   'TESTAI DONE '
msgCount   db   '?$'
BufMem     db   4096 dup(?)

        end     Start
