;∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜═┐
;∩┐╜∩┐╜∩┐╜∩┐╜            Sound Blaster emulator for Covox & PC-Squeaker           █▓∩┐╜∩┐╜
;∩┐╜∩┐╜∩┐╜∩┐╜             for Covox Speech Thing|PC Squeaker & 386 CPU            █▓∩┐╜∩┐╜
;∩┐╜∩┐╜∩┐╜∩┐╜          Version 2.02 (C)opyright 1993 by FRIENDS software          █▓∩┐╜∩┐╜
;∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜∩┐╜

                .SALL
                .MODEL  TINY
                .386P
                .CODE
                SMART
                ORG     100h

PortHandler     equ     <s386port.asm>
MinIRQfreq      equ     20h
MinTimerFreq    equ     030h            ; Ignore request to faster frequences
IdleDelay       equ     2               ; Game ticks of silence before the PIT
                                        ; is returned to the game's own rate
QminDiv         equ     108             ; /Q: minimum PIT divisor (~11 kHz cap)

Start:          jmp     Init

                include ..\386pdef.asm  ; Definitions first
                include ..\386pdata.asm ; Then data segment
                include ..\386plib.asm  ; PM library
                include ..\386pint.asm  ; ISR's
                include ..\386pdt.asm   ; Descriptor tables

; All data references use ss: overrides - the VM86 interrupt loads SS:ESP
; from the TSS (SS0 = @gdData), so no per-sample DS descriptor load is
; needed. Segment-override prefixes cost no extra cycles on a 386.
IRQ0handler     proc    near
                push    ax
                push    dx
; EnablePatch overlays the first two bytes of the pointer load: disabled =
; short jmp to the ShutUp path (PatchData1, precomputed), enabled = the
; instruction's own first bytes (captured into PatchData2 at install).
; The disp32 IS the current linear sample address (SS has a 4Gb limit set in
; SetupRoutines); it is SMC-advanced each tick, so no register is needed -
; the direct load drops the push/mov/pop ebx trio the ebx form required.
EnablePatch     label   word
                db      36h,67h,0A0h    ; mov al,ss:[dword disp] - SS override +
                dd      12345678h       ; addr32 prefix + A0 moffs (7 bytes); the
SamplePointer   equ     dword ptr $-4   ; overlay header is the 36h 67h prefixes

PatchHere:      shr     al,1
                out     42h,al

                add     word ptr ss:SamplePointer,1
IncDecPatch     equ     byte ptr $-4    ; modrm: /0 add (inc) or /5 sub (dec)
StepPatchP      equ     byte ptr $-1    ; step k (source samples per tick, /Q)
                sub     ss:SBcounter,1
StepPatch1      equ     byte ptr $-1
                jc      LastSBbyte
@@DecDMA:       sub     ss:DMAcounter,1
StepPatch2      equ     byte ptr $-1
                jc      LastDMAbyte

ShutUp0         label   near
@@ShutUp:       add     ss:Counter,1234h
Int8Coeff       equ     word ptr $-2
                jc      @@DoOld

@@IRET          label   near
EOIpatch1       label   word
                mov     al,60h          ; specific EOI for IRQ0; /E patches
                out     20h,al          ; this to a short jmp (PIC auto-EOI)
                pop     dx
                pop     ax
                iretd

@@DoOld:        cmp     ss:IdleTicks,0  ; hysteresis armed by EnableDMA(0)
                je      @@NoIdle
                dec     ss:IdleTicks
                jne     @@NoIdle
                call    SetIdleFreq     ; silence: stop sample-rate IRQs
@@NoIdle:       cmp     ss:Speaker,0
                je      @@NoRestore
                in      al,61h
                or      al,3
                out     61h,al
                mov     al,90h
                out     43h,al
@@NoRestore:    test    ss:PICmask,10000000b
IRQpatch5       equ     byte ptr $-1
                jne     @@IRQ7_masked
                cmp     ss:DoAnIRQ,1
                je      LastSBbyte
@@IRQ7_masked:  test    ss:PICmask,00000001b
                jne     @@IRET
                mov     ss:DoAnIRQ,0
                pop     dx
                ;mov     al,60h
                ;out     20h,al
                ;mov     ss:FlagsMask,1111111011111111b
                mov     ax,8                    ; Do old 8th interrupt
                jmp     IRQset

LastDMAByte:    push    offset @@ShutUp
@@LastDMA:      mov     al,0
                cmp     ss:AutoInit,al
                jne     @@Reload
                mov     ss:DMAcounter,0FFFFh    ; canonical post-expiry value
                jmp     @@TurnOff
@@Reload:       mov     ax,word ptr ss:DMAch1count
                mov     ss:DMAcounter,ax
                mov     ax,word ptr ss:DMAch1ad
                sub     ax,word ptr ss:LinearBase
                mov     word ptr ss:SamplePointer,ax
                movzx   ax,byte ptr ss:DMAch1page
                sbb     ax,word ptr ss:LinearBase+2
                mov     word ptr ss:SamplePointer+2,ax
                mov     al,1
@@TurnOff:      jmp     EnableDMA

LastSBbyte:     mov     ss:DoAnIRQ,1
                mov     ss:SBcounter,0FFFFh     ; canonical post-expiry value
                mov     al,0
                call    EnableDMA
                test    ss:PICmask,10000000b
IRQpatch6       equ     byte ptr $-1
                jne     @@DecDMA
                sub     ss:DMAcounter,1
StepPatch3      equ     byte ptr $-1
                jnc     @@SkipDMA
                call    near ptr @@LastDMA
@@SkipDMA:      mov     ss:DoAnIRQ,0
                pop     dx
EOIpatch2       label   word
                mov     al,60h
                out     20h,al
                mov     ss:Port020,8007h
IRQpatch1       equ     word ptr $-2
                mov     ax,0Fh                  ; Generate an IRQ
IRQpatch3       equ     byte ptr $-2
                jmp     IRQset
IRQ0handler     endp

; 1 - enable; 0 - disable DMA
EnableDMA       proc    near
                push    bx
                mov     bx,word ptr ss:PatchData1
                or      al,al
                je      @@Off
                cmp     ss:SBcounter,0FFFFh
                jne     @@1
                inc     ss:SBcounter
@@1:            cmp     ss:DMAcounter,0FFFFh
                jne     @@2
                inc     ss:DMAcounter
@@2:            mov     bx,word ptr ss:PatchData2
                mov     ss:IdleTicks,0  ; playback active: cancel idling
                push    ax
                mov     ax,ss:SampleDivisor
                cmp     ax,ss:TimerFreq ; PIT idled meanwhile? re-arm it
                je      @@Hot
                call    SetTimerFreq
@@Hot:          pop     ax
                mov     word ptr ss:EnablePatch,bx
                pop     bx
                ret
@@Off:          mov     word ptr ss:EnablePatch,bx
                mov     ss:IdleTicks,IdleDelay
                pop     bx
                ret
                endp

; 1 - Enable sound; 0 - disable sound
EnableSB        proc    near
                push    eax
                or      al,al
                mov     eax,90909090h
                je      @@Set
                mov     eax,dword ptr ss:PatchIRQ
@@Set:          mov     dword ptr ss:PatchHere,eax
                pop     eax
                ret
                endp

SetTimerFreq    proc    near
                push    ax
                push    dx
                mov     ss:TimerFreq,ax
                mov     ax,ss:IRQ0freq
                cmp     ax,MinTimerFreq
                ja      @@freqOK
                mov     ax,MinTimerFreq
@@freqOK:       or      ax,ax
                jne     @@NoZero
                dec     ax
@@NoZero:       push    bx
                mov     bx,ax
                mov     dx,ss:TimerFreq
                xor     ax,ax
                cmp     dx,bx
                jae     @@Overflow
                div     bx
@@PutRes:       mov     ss:Int8Coeff,ax
                mov     ax,ss:TimerFreq
                push    ax
                mov     al,36h
                out     43h,al
                pop     ax
                out     40h,al
                mov     al,ah
                out     40h,al
                cmp     ss:Speaker,0
                je      @@NoInit
                in      al,61h
                or      al,3
                out     61h,al
                mov     al,90h
                out     43h,al
@@NoInit:       pop     bx
                pop     dx
                pop     ax
                ret
@@Overflow:     dec     ax
                mov     ss:IRQ0freq,bx
                mov     ss:TimerFreq,bx
                jmp     @@PutRes
                endp

; Return the physical PIT to the game's own programmed rate while no DMA
; playback is active; every physical tick then chains to the virtual game
; timer. IRQ0freq of 0 (divisor 65536) must stay 0 here, which is why this
; does not reuse SetTimerFreq (its MinTimerFreq clamp would turn 0 into a
; fast rate).
SetIdleFreq     proc    near
                push    ax
                mov     ax,ss:IRQ0freq
                mov     ss:TimerFreq,ax
                mov     ss:Int8Coeff,0FFFFh
                push    ax
                mov     al,36h
                out     43h,al
                pop     ax
                out     40h,al
                mov     al,ah
                out     40h,al
                pop     ax
                ret
                endp

Int15entry      proc
                cmp     ah,087h
                jne     @@DoOld
                push    ecx
                push    esi
                push    edi
                mov     edi,es:[si+26]
                mov     esi,es:[si+18]
                shl     esi,8
                shr     esi,8
                shl     edi,8
                shr     edi,8
                movzx   ecx,cx
                int     3

                pop     edi
                pop     esi
                pop     ecx
                clc
                retf    2
@@DoOld:        db      0EAh
Old15           dd      0
Int15entry      endp

SlowAdlib       db      0
SBirq           db      5
Phase_E2        db      0
PrevE2          db      0
ReadWrite       db      0
PICmask         db      0
DoAnIRQ         db      0
AutoInit        db      0
DMAflipFlop     db      0
DMAch1ad        dw      0
DMAch1count     dw      0
DMAch1page      db      0
DMAcounter      dw      0
SBcounter       dw      0
FlipFlop        db      0
Speaker         db      0
Counter         dw      0
SBDMAcount      dw      0
SampleDivisor   dw      1000h
LinearBase      dd      0
AEOImode        db      0
QMode           db      0
StepK           db      1
IdleTicks       db      0
IRQ0freq        dw      0FFFFh
TimerFreq       dw      1000h
PatchData1      dw      0EBh or ((offset ShutUp0 - offset EnablePatch - 2) shl 8)
PatchData2      dw      0
PatchIRQ:       shr     al,1
                out     42h,al
CovoxPatch:     mov     dx,5FE0h
DACport         equ     word ptr $-2
                out     dx,al

IfDef VSB_DPMI
                include s386dpmi.asm    ; built-in DPMI host (resident part)
EndIf

LastByte        label   near

CheckCmdLine    proc    near
                cld
                mov     si,81h
@@NextChar:     lodsb
                cmp     al,' '
                je      @@NextChar
                cmp     al,13
                je      @@EndCmdLine
                cmp     al,'/'
                jne     @@BadOption
                lodsb
                and     al,0DFh
                cmp     al,'H'
                je      @@PrintHelp
                cmp     al,1Fh
                je      @@PrintHelp
                cmp     al,'S'
                je      @@Speaker
                cmp     al,'L'
                je      @@Covox
                cmp     al,'A'
                je      @@Adlib
                cmp     al,'W'
                je      @@SlowAdlib
                cmp     al,'I'
                je      @@SetIRQ
                cmp     al,'E'
                je      @@AEOI
                cmp     al,'Q'
                je      @@QCap
                cmp     al,'F'
                je      @@NextChar
@@BadOption:    mov     dx,offset BadOption
                jmp     PrintAndExit

@@PrintHelp:    mov     dx,offset HelpText
                jmp     PrintAndExit

@@Speaker:      inc     Speaker
                jmp     @@NextChar

@@Adlib:        mov     CatchAdlib,0
                jmp     @@NextChar

@@SlowAdlib:    mov     SlowAdlib,1
                jmp     @@NextChar

@@AEOI:         mov     AEOImode,1
                jmp     @@NextChar

@@QCap:         mov     QMode,1
                jmp     @@NextChar

@@SetIRQ:       lodsb
                sub     al,'0'
                jc      @@BadOption
                cmp     al,7
                je      @@IRQok
                cmp     al,5
                jne     @@BadOption
@@IRQok:        mov     SBirq,al
                jmp     @@NextChar

@@Covox:        lodsb
                sub     al,'1'
                jc      @@BadOption
                cmp     al,4
                jae     @@BadOption
                push    es
                push    0
                pop     es
                movzx   bx,al
                shl     bx,1
                mov     ax,es:[bx+408h]
                mov     DACport,ax
                mov     Speaker,0
                pop     es
                jmp     @@NextChar

@@EndCmdLine:   retn
                endp

SetupRoutines   proc    near
                mov     ax,3515h
                int     21h
                mov     word ptr Old15,bx
                mov     word ptr Old15+2,es
                mov     dx,offset Int15entry
                mov     ah,25h
                int     21h
                push    cs
                pop     es
                in      al,61h
                and     al,11111100b
                out     61h,al
                cmp     Speaker,0
                jne     @@NoChange
                mov     eax,dword ptr CovoxPatch
                mov     dword ptr PatchHere,eax
                mov     dword ptr PatchIRQ,eax
@@NoChange:     mov     idInt32.SegLimit,offset IRQ0handler
                mov     ax,TimerFreq
                call    SetTimerFreq
                mov     IOportMap[000h/8],00001100b  ;Ports 000h...007h
                mov     IOportMap[008h/8],11111111b  ;Ports 008h...00Fh
                mov     IOportMap[020h/8],00000011b  ;Ports 020h & 021h
                mov     IOportMap[040h/8],00001001b  ;Ports 040h & 043h
                mov     IOportMap[080h/8],00001000b  ;Port  083h
                mov     IOportMap[220h/8],01000000b  ;Ports 220h...227h
                mov     IOportMap[228h/8],01010111b  ;Ports 228h...22Eh
                mov     IOportMap[388h/8],00000011b  ;Ports 388h...389h
CatchAdlib      equ     byte ptr $-1
                mov     ax,word ptr EnablePatch
                mov     PatchData2,ax
                mov     al,0
                call    EnableSB
                mov     al,0
                call    EnableDMA
                mov     al,SBirq
                mov     cl,al
                mov     ah,1
                shl     ah,cl

                mov     IRQpatch1,ax
                mov     IRQpatch2,ax
                mov     IRQpatch5,ah
                mov     IRQpatch6,ah
                add     al,8
                mov     IRQpatch3,al
                mov     IRQpatch4,al
                xor     eax,eax         ; TSR linear base for the flat-SS
                mov     ax,cs           ; sample addressing
                shl     eax,4
                mov     dword ptr LinearBase,eax
                mov     gdData.Granularity,df4GbLimit
                cmp     AEOImode,0
                je      @@NoEOIpatch
                mov     word ptr EOIpatch1,02EBh
                mov     word ptr EOIpatch2,02EBh
@@NoEOIpatch:   retn
                endp

IfDef VSB_DPMI
;***** Chain our DPMI-detection handler into the real-mode int 2Fh vector *****
; Transient (runs once, in real mode, during Init). The handler itself is
; resident (s386dpmi.asm, before LastByte).
InstallDPMI     proc    near
                push    es
                xor     ax,ax
                mov     es,ax                   ; IVT segment
                cli
                mov     ax,es:[2Fh*4]           ; save old offset
                mov     word ptr cs:OldInt2F,ax
                mov     ax,es:[2Fh*4+2]         ; save old segment
                mov     word ptr cs:OldInt2F+2,ax
                mov     word ptr es:[2Fh*4],offset Dpmi2F
                mov     word ptr es:[2Fh*4+2],cs
                sti
                pop     es
                ret
InstallDPMI     endp
EndIf

Init:           call    CheckCmdLine
IfDef VSB_DPMI
                call    InstallDPMI     ; hook int 2Fh for the built-in host
EndIf
                call    CheckCPU
                call    SetupRoutines
                call    SwitchToPM
                cmp     AEOImode,0      ; /E: master PIC to auto-EOI (ring 0,
                je      NoAEOI0         ; after SetPIC, slave stays normal)
                in      al,21h
                mov     ah,al           ; keep IMR
                mov     al,11h
                out     20h,al
                SettleBus
                mov     al,20h          ; base vector (matches SetPIC 2820h)
                out     21h,al
                SettleBus
                mov     al,04h          ; slave cascade on IRQ2
                out     21h,al
                SettleBus
                mov     al,03h          ; 8086 mode + auto-EOI
                out     21h,al
                SettleBus
                mov     al,ah
                out     21h,al
NoAEOI0:        call    SwitchToVM86
                mov     ah,9                    ; Now running in VM86 mode
                mov     dx,offset Header
                int     21h
                mov     dx,offset LastByte
                int     27h                     ; Stay resident

                include ..\386rdata.asm         ; Real-mode data
                include ..\386preal.asm         ; Then real-mode subroutines
                include s386data.asm

                end     Start
