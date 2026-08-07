;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;∩┐╜           Virtual Sound Blaster - built-in DPMI host (WIP)             ∩┐╜∩┐╜
;∩┐╜          Milestone 1: detection   +   Milestone 2: PM switch          ∩┐╜∩┐╜
;∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∞╗┤∩┐╜
;
; Guarded by VSB_DPMI (TASM /dVSB_DPMI). Absent from the shipping vsb_real.com.
;
; Teaching classic VSB to be its own DPMI host so DOS-extender games run under
; it (see build/harness/vsb-dpmi-host-plan.md). All routines live in the
; RESIDENT region (before LastByte). The .COM is one segment; ring-0 monitor
; code and V86 resident code share it - the same offset is reachable at ring 0
; via gdCode/gdData (base = resident seg << 4) and in V86 via CS = resident seg.
;
;   Milestone 1  int 2Fh AX=1687h detection responder (runs in V86 via the IVT)
;   Milestone 2  the mode switch: client far-calls the entry, we transition it
;                from V86 into ring-3 protected mode with an LDT of client
;                selectors. The entry HLTs (privileged -> always #GP-traps to
;                the monitor from V86, whatever the IOPL); the monitor's DoHalt
;                hook recognises our entry and vectors to DpmiDoSwitch at ring 0.

;--- LDT selector values (index<<3 | TI=4 | RPL=3) ---------------------------
selCode         equ     (1 shl 3) or 4 or 3     ; 0Fh - client code
selData         equ     (2 shl 3) or 4 or 3     ; 17h - client DS
selStack        equ     (3 shl 3) or 4 or 3     ; 1Fh - client SS
selPSP          equ     (4 shl 3) or 4 or 3     ; 27h - client ES/PSP

;--- resident state ----------------------------------------------------------
ResidentSeg     dw      0               ; our real-mode segment (PSP), captured
                                        ; at Init - lets DoHalt spot our entry
DpmSaveIP       dw      0               ; client far-return IP
DpmSaveAX       dd      0               ; client GP regs preserved across switch
DpmSaveBX       dd      0
DpmSaveBP       dd      0
DpmSaveFL       dd      0
DpmSaveSP       dd      0
OldInt2F        dd      0               ; previous int 2Fh vector (chained)

;--- client LDT (built per switch) -------------------------------------------
                NOWARN  ALN
                align   8
                WARN    ALN
ClientLDT       label   byte
                Desc386 <>              ; LDT[0] - unused
ldtCode         Desc386 <>              ; LDT[1] - client code   (selCode)
ldtData         Desc386 <>              ; LDT[2] - client data   (selData)
ldtStack        Desc386 <>              ; LDT[3] - client stack  (selStack)
ldtPSP          Desc386 <>              ; LDT[4] - client PSP/ES  (selPSP)
ClientLDTend    label   byte

;===== Milestone 2: fill a Desc386 (cx=segment, di=offset, al=access) =========
; Runs at ring 0 with ds = @gdData. 64K byte-granular 16-bit segment.
DpmFillDesc     proc    near
                mov     byte ptr [di+5],al      ; AccessRights
                mov     word ptr [di+0],0FFFFh  ; SegLimit
                mov     byte ptr [di+6],0       ; Granularity (G=0,D/B=0)
                movzx   eax,cx
                shl     eax,4
                mov     [di+2],ax               ; Base0to15
                shr     eax,16
                mov     [di+4],al               ; Base16to23
                mov     byte ptr [di+7],0       ; Base24to31 (real seg < 20 bits)
                ret
DpmFillDesc     endp

;===== Milestone 2: the V86 -> ring-3 PM mode switch (ring 0) =================
; Reached from the DoHalt hook when the trapped V86 CS:IP is our DpmiSwitch
; entry. The Int13h frame is live: ebp -> [ebp]=IP [ebp+4]=CS [ebp+8]=FLAGS
; [ebp+0Ch]=SP [ebp+10h]=SS [ebp+14h]=ES [ebp+18h]=DS; client GP regs saved at
; [ebp-4]=EAX [ebp-8]=EBX [ebp-0Eh]=EBP.  Frame reads use SS (=@gdData), so
; they stay valid whatever DS holds.
DpmiDoSwitch:
                mov     ax,@gdData
                mov     ds,ax
                mov     ax,@gdFlat
                mov     es,ax                   ; flat view of client stack
                movzx   esi,word ptr [ebp+10h]  ; client SS
                shl     esi,4
                movzx   edi,word ptr [ebp+0Ch]  ; client SP
                mov     bx,es:[esi+edi]         ; far-return IP
                mov     dx,es:[esi+edi+2]       ; far-return CS (client code seg)
                add     word ptr [ebp+0Ch],4    ; pop the far return
                mov     [DpmSaveIP],bx

                mov     cx,dx                   ; LDT[1] code <- return CS
                mov     di,offset ldtCode
                mov     al,0FAh                 ; P,DPL3,code,readable
                call    DpmFillDesc
                mov     cx,[ebp+18h]            ; LDT[2] data <- client DS
                mov     di,offset ldtData
                mov     al,0F2h                 ; P,DPL3,data,writable
                call    DpmFillDesc
                mov     cx,[ebp+10h]            ; LDT[3] stack <- client SS
                mov     di,offset ldtStack
                mov     al,0F2h
                call    DpmFillDesc
                mov     cx,[ebp+14h]            ; LDT[4] PSP <- client ES
                mov     di,offset ldtPSP
                mov     al,0F2h
                call    DpmFillDesc

                ; point gdLDT at ClientLDT and load LDTR
                movzx   eax,word ptr [ResidentSeg]
                shl     eax,4
                add     eax,offset ClientLDT
                mov     word ptr [gdLDT+2],ax
                shr     eax,16
                mov     byte ptr [gdLDT+4],al
                mov     byte ptr [gdLDT+7],ah
                mov     word ptr [gdLDT+0],ClientLDTend-ClientLDT-1
                mov     ax,@gdLDT
                lldt    ax

                ; preserve client GP regs + build the ring-3 return
                mov     eax,[ebp-4]
                mov     [DpmSaveAX],eax
                mov     eax,[ebp-8]
                mov     [DpmSaveBX],eax
                mov     eax,[ebp-0Eh]
                mov     [DpmSaveBP],eax
                mov     eax,[ebp+8]
                mov     [DpmSaveFL],eax
                movzx   eax,word ptr [ebp+0Ch]
                mov     [DpmSaveSP],eax

                mov     esp,offset P0ESP        ; clean ring-0 stack for iret frame
                push    large selStack          ; ring-3 SS
                push    dword ptr [DpmSaveSP]    ; ring-3 ESP
                mov     eax,[DpmSaveFL]
                and     eax,not 20000h          ; clear VM
                or      eax,3000h               ; IOPL=3 (client OUT/IN allowed)
                or      eax,2                   ; reserved bit 1 = 1
                push    eax                     ; EFLAGS
                push    large selCode           ; ring-3 CS
                movzx   eax,word ptr [DpmSaveIP]
                push    eax                     ; EIP

                mov     ebx,[DpmSaveBX]
                mov     ebp,[DpmSaveBP]
                mov     eax,[DpmSaveAX]
                mov     cx,selData
                mov     ds,cx
                mov     cx,selPSP
                mov     es,cx
                xor     cx,cx
                mov     fs,cx
                mov     gs,cx
                iretd                           ; -> ring-3 protected mode client

;--- DPMI mode-switch entry point (the client far-CALLs this in V86) ---------
; AX=0 -> 16-bit client, AX=1 -> 32-bit. The HLT #GP-traps to the monitor,
; which recognises this entry and performs the switch (does not return here).
; If the monitor ever declines, control falls through to a clean CF=set retf.
DpmiSwitch      proc    far
                hlt                             ; -> DoHalt hook -> DpmiDoSwitch
                stc
                retf
DpmiSwitch      endp

;--- int 2Fh handler (Milestone 1) -------------------------------------------
Dpmi2F          proc    far
                cmp     ax,1687h                ; DPMI installation check?
                je      @@Detect
                jmp     dword ptr cs:OldInt2F   ; chain, frame intact

@@Detect:       push    bp
                mov     bp,sp                   ; [bp+6] = caller FLAGS
                and     word ptr [bp+6],0FFFEh  ; clear CF (present)
                pop     bp
                xor     ax,ax                   ; DPMI installed
                mov     bx,1                    ; bit0: 32-bit supported
                mov     cl,3                    ; 80386
                mov     dx,005Ah                ; DPMI version 0.90
                xor     si,si                   ; host data paragraphs
                push    cs
                pop     es
                mov     di,offset DpmiSwitch     ; ES:DI = mode-switch entry
                iret
Dpmi2F          endp
