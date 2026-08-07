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
LdtNextFree     dw      5               ; bump allocator: next free LDT index
D31bx           dw      0               ; client BX saved across an int 31h call

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
LDT_ENTRIES     equ     64             ; free pool for int 31h fn 0000 allocs
                db      (LDT_ENTRIES-5)*8 dup (0)
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

;===== Milestone 3: int 31h DPMI services (ring 0, called from ring-3 client) =
; Reached via a DPL-3 IDT gate on vector 31h (routed in InitializeIDT). The int
; gate loads SS0:ESP0 from the TSS and pushes EIP,CS,EFLAGS,ESP3,SS3. Only DS is
; pushed by us, so the client FLAGS sit at [esp+0Ah]; CF there is the DPMI
; success/fail flag. Client GP regs are live = the DPMI register ABI; we clobber
; only documented outputs (BX is saved/restored via D31bx so input-BX services
; preserve it).

; SelToDesc: bx = selector in -> bx = descriptor offset (ds=@gdData), CF=invalid
SelToDesc       proc    near
                push    ax
                mov     ax,bx
                test    ax,4                    ; TI must select the LDT
                jz      @@bad
                shr     ax,3                    ; descriptor index
                cmp     ax,LDT_ENTRIES
                jae     @@bad
                shl     ax,3
                add     ax,offset ClientLDT
                mov     bx,ax
                pop     ax
                clc
                ret
@@bad:          pop     ax
                stc
                ret
SelToDesc       endp

Dpmi31h:
                push    ds
                push    ax
                mov     ax,@gdData
                mov     ds,ax
                pop     ax
                mov     [D31bx],bx              ; preserve client BX by default

                cmp     ax,0400h
                je      d31_ver
                cmp     ax,0000h
                je      d31_alloc
                cmp     ax,0001h
                je      d31_free
                cmp     ax,0006h
                je      d31_getbase
                cmp     ax,0007h
                je      d31_setbase
                cmp     ax,0008h
                je      d31_setlimit
                cmp     ax,0009h
                je      d31_setaccess
                mov     ax,8001h                ; unsupported function
                jmp     d31_fail

d31_ver:        mov     ax,005Ah                ; AH=0 major, AL=90 (0.90)
                mov     word ptr [D31bx],0      ; BX = flags (0)
                mov     cl,3                    ; 80386
                mov     dh,08h                  ; master PIC base (int 8)
                mov     dl,70h                  ; slave PIC base (int 70h)
                jmp     d31_ok

d31_alloc:      ; CX = count -> AX = base selector
                mov     ax,[LdtNextFree]
                mov     bx,ax
                add     bx,cx
                cmp     bx,LDT_ENTRIES
                ja      d31_alloc_fail
                mov     [LdtNextFree],bx
                push    si
                mov     si,ax
@@ai:           cmp     si,bx
                jae     @@adone
                push    bx
                mov     bx,si
                shl     bx,3
                add     bx,offset ClientLDT
                mov     word ptr [bx+0],0       ; limit 0
                mov     word ptr [bx+2],0       ; base 0-15
                mov     byte ptr [bx+4],0       ; base 16-23
                mov     byte ptr [bx+5],0F2h    ; ring-3 data, present
                mov     byte ptr [bx+6],0       ; granularity
                mov     byte ptr [bx+7],0       ; base 24-31
                pop     bx
                inc     si
                jmp     @@ai
@@adone:        pop     si
                shl     ax,3
                or      ax,7                    ; AX = base selector (TI=4|RPL=3)
                jmp     d31_ok                  ; d31_ok restores client BX; AX kept

d31_alloc_fail: mov     ax,8011h                ; descriptor unavailable
                jmp     d31_fail

d31_free:       call    SelToDesc               ; BX = selector
                jc      d31_selbad
                mov     byte ptr [bx+5],0       ; clear present -> freed
                jmp     d31_ok

d31_getbase:    call    SelToDesc
                jc      d31_selbad
                mov     dx,[bx+2]               ; CX:DX = base
                mov     cl,[bx+4]
                mov     ch,[bx+7]
                jmp     d31_ok

d31_setbase:    call    SelToDesc               ; CX:DX = base (preserved by helper)
                jc      d31_selbad
                mov     [bx+2],dx
                mov     [bx+4],cl
                mov     [bx+7],ch
                jmp     d31_ok

d31_setlimit:   call    SelToDesc               ; CX:DX = limit
                jc      d31_selbad
                test    cx,cx
                jnz     @@page                  ; > 64K -> page granular
                mov     [bx+0],dx               ; byte-granular limit 0-15
                mov     al,[bx+6]
                and     al,40h                  ; keep D/B, clear G + limit nibble
                mov     [bx+6],al
                jmp     d31_ok
@@page:         push    eax
                movzx   eax,cx
                shl     eax,16
                mov     ax,dx                   ; EAX = CX:DX
                shr     eax,12                  ; page-granular limit
                mov     [bx+0],ax               ; limit 0-15
                shr     eax,16
                and     al,0Fh                  ; limit 16-19
                mov     ah,[bx+6]
                and     ah,40h                  ; keep D/B
                or      al,ah
                or      al,80h                  ; G = 1
                mov     [bx+6],al
                pop     eax
                jmp     d31_ok

d31_setaccess:  call    SelToDesc               ; CL = access, CH = extended
                jc      d31_selbad
                mov     [bx+5],cl
                mov     al,[bx+6]
                and     al,0Fh                  ; keep limit 16-19
                mov     ah,ch
                and     ah,0F0h                 ; take G/D/B/AVL from CH
                or      al,ah
                mov     [bx+6],al
                jmp     d31_ok

d31_selbad:     mov     ax,8022h                ; invalid selector
                jmp     d31_fail

;--- exits: CF on the client FLAGS at [esp+0Ah] (only DS pushed) --------------
d31_ok:         mov     bx,[D31bx]              ; restore/deliver client BX
                and     word ptr [esp+0Ah],0FFFEh   ; CF = 0 (success)
                pop     ds
                iretd
d31_fail:       mov     bx,[D31bx]
                or      word ptr [esp+0Ah],1    ; CF = 1 (error), AX = code
                pop     ds
                iretd

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
