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

;--- SAVECLI: stash the ring-3 client's int-31 frame + GP regs into ExCli* ----
; Ring-0 stack at a service entry (int gate + our pushed ds): [esp]=ds
; [esp+2]=EIP [esp+6]=CS [esp+0Ah]=EFLAGS [esp+0Eh]=ESP3 [esp+12h]=SS3.
SAVECLI         macro
                mov     eax,[esp+2]
                mov     [ExCliEIP],eax
                mov     eax,[esp+6]
                mov     [ExCliCS],eax
                mov     eax,[esp+0Ah]
                mov     [ExCliFL],eax
                mov     eax,[esp+0Eh]
                mov     [ExCliESP],eax
                mov     eax,[esp+12h]
                mov     [ExCliSS],eax
                mov     [ExCliEBX],ebx
                mov     [ExCliECX],ecx
                mov     [ExCliEDX],edx
                mov     [ExCliESI],esi
                mov     [ExCliEDI],edi
                mov     [ExCliEBP],ebp
                mov     ax,[esp]
                mov     [ExCliDS],ax
                mov     [ExCliES],es
                endm

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
CliCodeBase     dd      0               ; PM client's code linear base (M4c decode)

;--- Milestone 4: V86-excursion state (simulate real-mode interrupt) ---------
; DPMI real-mode call structure (RMCS) field offsets:
RMCS_EDI        equ     000h
RMCS_ESI        equ     004h
RMCS_EBP        equ     008h
RMCS_EBX        equ     010h
RMCS_EDX        equ     014h
RMCS_ECX        equ     018h
RMCS_EAX        equ     01Ch
RMCS_FLAGS      equ     020h            ; word
RMCS_ES         equ     022h            ; word
RMCS_DS         equ     024h            ; word
RMCS_FS         equ     026h            ; word
RMCS_GS         equ     028h            ; word
RMCS_IP         equ     02Ah            ; word
RMCS_CS         equ     02Ch            ; word
RMCS_SP         equ     02Eh            ; word
RMCS_SS         equ     030h            ; word

ExRmcs          dd      0               ; linear address of the caller's RMCS
ExCliEIP        dd      0               ; saved PM-client resume frame
ExCliCS         dd      0
ExCliFL         dd      0
ExCliESP        dd      0
ExCliSS         dd      0
ExCliEAX        dd      0               ; saved PM-client GP regs (restored on return)
ExCliEBX        dd      0
ExCliECX        dd      0
ExCliEDX        dd      0
ExCliESI        dd      0
ExCliEDI        dd      0
ExCliEBP        dd      0
ExCliDS         dw      0
ExCliES         dw      0
ExInt           db      0               ; real-mode int number for the excursion
                db      0               ; pad to word
ExMode          db      0               ; excursion mode: 0=fn0300, 1=alloc, 2=free
                db      0               ; pad to word
DosResFL        dw      0               ; int 21h result FLAGS from a DOS excursion
ExFreeSel       dw      0               ; selector being freed (fn 0101)
DosRmcs         db      34h dup (0)     ; private RMCS for the DOS-memory excursion
                dd      32 dup (0)      ; real-mode excursion stack
RmExStkTop      label   word

;--- PM interrupt/exception handler table (int 31h fn 0204/0205) --------------
; 256 entries of {selector(word), offset(dword)} = 6 bytes each. Set by the
; client; consulted when a HW interrupt is delivered to the PM client (M4b).
PmVecTable      db      256*6 dup (0)

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
LDT_ENTRIES     equ     256             ; total LDT slots: 5 fixed + 251 free
                db      (LDT_ENTRIES-5)*8 dup (0)   ; free pool for int 31h fn 0000
                                        ; (DOS4GW/DOOM allocate a few dozen)
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
                movzx   eax,dx                  ; client code linear base, for the
                shl     eax,4                   ; PM-fault opcode decode (M4c)
                mov     [CliCodeBase],eax

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
                and     eax,not 3000h           ; IOPL=0: client I/O to bitmapped
                                                ; ports (SB/DMA/OPL) #GP-traps
                or      eax,202h                ; IF=1, reserved bit 1 = 1
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

; SelBase: ax = LDT selector -> eax = 32-bit linear base (ds=@gdData). bx kept.
SelBase         proc    near
                push    bx
                movzx   ebx,ax
                and     bx,0FFF8h               ; index*8 = offset in ClientLDT
                add     bx,offset ClientLDT
                xor     eax,eax
                mov     al,[bx+7]               ; base 24-31
                shl     eax,8
                mov     al,[bx+4]               ; base 16-23
                shl     eax,16
                mov     ax,[bx+2]               ; base 0-15
                pop     bx
                ret
SelBase         endp

; PmVecOff: bl = int number -> si = PmVecTable byte offset (int*6). ax clobbered.
PmVecOff        proc    near
                movzx   si,bl
                mov     ax,si
                shl     si,1                    ; *2
                add     si,ax                   ; *3
                shl     si,1                    ; *6
                ret
PmVecOff        endp

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
                cmp     ax,0300h
                je      d31_simint
                cmp     ax,0200h
                je      d31_getrmvec
                cmp     ax,0201h
                je      d31_setrmvec
                cmp     ax,0204h
                je      d31_getpmvec
                cmp     ax,0205h
                je      d31_setpmvec
                cmp     ax,0100h
                je      d31_dosalloc
                cmp     ax,0101h
                je      d31_dosfree
                mov     ax,8001h                ; unsupported function
                jmp     d31_fail

;--- int 31h fn 0200/0201: real-mode interrupt vector (via the IVT) -----------
d31_getrmvec:   movzx   ebx,bl                  ; BL=int -> CX:DX = seg:off
                push    fs
                mov     ax,@gdFlat
                mov     fs,ax
                mov     dx,fs:[ebx*4]
                mov     cx,fs:[ebx*4+2]
                pop     fs
                jmp     d31_ok
d31_setrmvec:   movzx   ebx,bl                  ; BL=int, CX:DX = seg:off
                push    fs
                mov     ax,@gdFlat
                mov     fs,ax
                mov     fs:[ebx*4],dx
                mov     fs:[ebx*4+2],cx
                pop     fs
                jmp     d31_ok

;--- int 31h fn 0204/0205: protected-mode interrupt vector (host table) -------
; entry = PmVecTable + int*6 : selector(word) + offset(dword)
d31_getpmvec:   call    PmVecOff                ; si = table offset for BL
                mov     cx,word ptr [PmVecTable+si]     ; CX = selector
                mov     edx,dword ptr [PmVecTable+si+2] ; EDX = offset
                jmp     d31_ok
d31_setpmvec:   call    PmVecOff
                mov     word ptr [PmVecTable+si],cx
                mov     dword ptr [PmVecTable+si+2],edx
                jmp     d31_ok

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

;===== Milestone 4d: int 31h fn 0100/0101 - DOS memory via a V86 excursion =====
; fn 0100 (BX = paragraphs -> AX = real segment, DX = selector) and fn 0101
; (DX = selector) run int 21h AH=48h / AH=49h in a real-mode excursion. We reuse
; the RmExGo/RmExDone machinery with a private RMCS (DosRmcs) and ExMode != 0, so
; RmExDone routes to RmExDoneDos to stage AX/DX/CF for the PM client.
d31_dosalloc:   SAVECLI
                mov     byte ptr [ExMode],1
                mov     dword ptr [DosRmcs+RMCS_EAX],00004800h
                movzx   eax,word ptr [D31bx]    ; client BX = paragraphs
                mov     dword ptr [DosRmcs+RMCS_EBX],eax
                xor     eax,eax
                mov     dword ptr [DosRmcs+RMCS_ECX],eax
                mov     dword ptr [DosRmcs+RMCS_EDX],eax
                mov     dword ptr [DosRmcs+RMCS_ESI],eax
                mov     dword ptr [DosRmcs+RMCS_EDI],eax
                mov     dword ptr [DosRmcs+RMCS_EBP],eax
                mov     word ptr  [DosRmcs+RMCS_ES],ax
                mov     word ptr  [DosRmcs+RMCS_DS],ax
                mov     word ptr  [DosRmcs+RMCS_FS],ax
                mov     word ptr  [DosRmcs+RMCS_GS],ax
                mov     word ptr  [DosRmcs+RMCS_FLAGS],ax
                jmp     DosExGo

d31_dosfree:    SAVECLI
                mov     byte ptr [ExMode],2
                mov     [ExFreeSel],dx          ; selector to free after the call
                mov     ax,dx
                call    SelBase                 ; eax = linear base of the block
                shr     eax,4                   ; -> real-mode segment
                mov     dword ptr [DosRmcs+RMCS_EAX],00004900h
                mov     word ptr [DosRmcs+RMCS_ES],ax ; ES = block seg (AH=49h in)
                xor     eax,eax
                mov     dword ptr [DosRmcs+RMCS_EBX],eax
                mov     dword ptr [DosRmcs+RMCS_ECX],eax
                mov     dword ptr [DosRmcs+RMCS_EDX],eax
                mov     dword ptr [DosRmcs+RMCS_ESI],eax
                mov     dword ptr [DosRmcs+RMCS_EDI],eax
                mov     dword ptr [DosRmcs+RMCS_EBP],eax
                mov     word ptr  [DosRmcs+RMCS_DS],ax
                mov     word ptr  [DosRmcs+RMCS_FS],ax
                mov     word ptr  [DosRmcs+RMCS_GS],ax
                mov     word ptr  [DosRmcs+RMCS_FLAGS],ax
                ; fall into DosExGo

DosExGo:        mov     byte ptr [ExInt],21h
                movzx   eax,word ptr [ResidentSeg]
                shl     eax,4
                add     eax,offset DosRmcs
                mov     [ExRmcs],eax
                jmp     RmExGo

;===== Milestone 4: simulate real-mode interrupt (int 31h fn 0300) ============
; BL = int number, ES:DI -> RMCS (16-bit client). Runs IVT[BL] in a V86
; excursion and writes the resulting registers back to the RMCS. The excursion
; enters V86 at the handler with a resident real-mode stack whose iret frame
; returns to RmExSentinel (a HLT); that #GP-traps to ring 0 (DoHalt hook ->
; RmExDone), which restores the PM client and returns with CF clear.
; Ring-0 stack here (int31 gate + our pushed ds): [esp]=ds [esp+2]=EIP
; [esp+6]=CS [esp+0Ah]=EFLAGS [esp+0Eh]=ESP [esp+12h]=SS.
d31_simint:     mov     eax,[esp+2]             ; save PM-client resume frame
                mov     [ExCliEIP],eax
                mov     eax,[esp+6]
                mov     [ExCliCS],eax
                mov     eax,[esp+0Ah]
                mov     [ExCliFL],eax
                mov     eax,[esp+0Eh]
                mov     [ExCliESP],eax
                mov     eax,[esp+12h]
                mov     [ExCliSS],eax
                mov     [ExCliECX],ecx          ; save PM-client GP regs
                mov     [ExCliEDX],edx
                mov     [ExCliESI],esi
                mov     [ExCliEDI],edi
                mov     [ExCliEBP],ebp
                movzx   eax,word ptr [D31bx]
                mov     [ExCliEBX],eax
                mov     dword ptr [ExCliEAX],0300h
                mov     byte ptr [ExMode],0
                mov     ax,[esp]                ; client DS (pushed)
                mov     [ExCliDS],ax
                mov     [ExCliES],es
                mov     al,bl                   ; int number
                mov     [ExInt],al
                mov     ax,es                   ; RMCS linear = ES.base + DI
                call    SelBase
                movzx   edx,di
                add     eax,edx
                mov     [ExRmcs],eax
                ; fall into RmExGo

RmExGo:         mov     ax,@gdFlat
                mov     fs,ax                   ; flat access to RMCS + IVT
                ; sentinel return frame on the resident real-mode stack
                movzx   eax,word ptr [ResidentSeg]
                shl     eax,4
                add     eax,offset RmExStkTop-6
                mov     esi,eax
                mov     word ptr fs:[esi],offset RmExSentinel
                mov     ax,[ResidentSeg]
                mov     word ptr fs:[esi+2],ax
                mov     word ptr fs:[esi+4],0202h    ; flags (IF)
                ; build the V86 iret frame
                mov     esp,offset P0ESP
                mov     ebx,[ExRmcs]
                movzx   eax,word ptr fs:[ebx+RMCS_GS]
                push    eax
                movzx   eax,word ptr fs:[ebx+RMCS_FS]
                push    eax
                movzx   eax,word ptr fs:[ebx+RMCS_DS]
                push    eax
                movzx   eax,word ptr fs:[ebx+RMCS_ES]
                push    eax
                movzx   eax,word ptr [ResidentSeg]
                push    eax                     ; SS = resident segment
                push    large offset RmExStkTop-6   ; ESP
                push    large 23202h            ; EFLAGS: VM|IOPL3|IF
                movzx   ebx,byte ptr [ExInt]
                movzx   eax,word ptr fs:[ebx*4+2]
                push    eax                     ; CS  = IVT[int].seg
                movzx   eax,word ptr fs:[ebx*4]
                push    eax                     ; EIP = IVT[int].off
                mov     ebp,[ExRmcs]            ; load V86 GP regs from RMCS
                mov     eax,fs:[ebp+RMCS_EAX]
                mov     ecx,fs:[ebp+RMCS_ECX]
                mov     edx,fs:[ebp+RMCS_EDX]
                mov     esi,fs:[ebp+RMCS_ESI]
                mov     edi,fs:[ebp+RMCS_EDI]
                mov     ebx,fs:[ebp+RMCS_EBX]
                mov     ebp,fs:[ebp+RMCS_EBP]
                iretd                           ; -> V86 real-mode int handler

; RmExDone: entered at ring 0 from the DoHalt hook when V86 hits RmExSentinel.
; Int13h frame: [ebp]=IP [ebp+4]=CS [ebp+8]=FLAGS [ebp+14h]=ES [ebp+18h]=DS;
; V86 GP results: eax=[ebp-4] ebx=[ebp-8] ebp=[ebp-0Eh]; ecx/edx/esi/edi live.
RmExDone:       mov     ax,@gdData
                mov     ds,ax
                mov     ax,@gdFlat
                mov     fs,ax
                cmp     byte ptr [ExMode],0
                jne     RmExDoneDos
                mov     ebx,[ExRmcs]            ; write V86 results into RMCS
                mov     eax,[ebp-4]
                mov     fs:[ebx+RMCS_EAX],eax
                mov     fs:[ebx+RMCS_ECX],ecx
                mov     fs:[ebx+RMCS_EDX],edx
                mov     fs:[ebx+RMCS_ESI],esi
                mov     fs:[ebx+RMCS_EDI],edi
                mov     eax,[ebp-8]
                mov     fs:[ebx+RMCS_EBX],eax
                mov     eax,[ebp-0Eh]
                mov     fs:[ebx+RMCS_EBP],eax
                mov     ax,[ebp+8]
                mov     fs:[ebx+RMCS_FLAGS],ax
                mov     ax,[ebp+14h]
                mov     fs:[ebx+RMCS_ES],ax
                mov     ax,[ebp+18h]
                mov     fs:[ebx+RMCS_DS],ax
                ; fn 0300: success -> CF clear, then resume the PM client
                mov     eax,[ExCliFL]
                and     eax,not 1
                mov     [ExCliFL],eax
                jmp     RmExResume

; RmExResume: common tail - rebuild the int31-return iret frame for the PM
; client from the ExCli* save area and iretd back. Used by fn 0300 and the DOS
; memory services; all output regs must already be staged in ExCli*.
RmExResume:     mov     esp,offset P0ESP
                mov     eax,[ExCliSS]
                push    eax
                mov     eax,[ExCliESP]
                push    eax
                mov     eax,[ExCliFL]
                push    eax
                mov     eax,[ExCliCS]
                push    eax
                mov     eax,[ExCliEIP]
                push    eax
                mov     ecx,[ExCliECX]
                mov     edx,[ExCliEDX]
                mov     esi,[ExCliESI]
                mov     edi,[ExCliEDI]
                mov     ebp,[ExCliEBP]
                mov     ebx,[ExCliEBX]
                mov     eax,[ExCliEAX]
                push    eax
                mov     ax,[ExCliDS]
                mov     ds,ax
                mov     ax,[ExCliES]
                mov     es,ax
                pop     eax
                iretd                           ; -> back to the PM client

; RmExDoneDos: DOS-memory excursion completion (ExMode 1=alloc, 2=free). int 21h
; results are in the Int13h frame: AX=word[ebp-4] BX=word[ebp-8] FLAGS=[ebp+8].
; Stages AX/BX/DX/CF into ExCli* then joins RmExResume.
RmExDoneDos:    mov     si,[ebp-4]              ; int 21h AX (realseg / errcode)
                mov     di,[ebp-8]              ; int 21h BX (largest block)
                mov     ax,[ebp+8]
                mov     [DosResFL],ax           ; int 21h FLAGS (CF = bit 0)
                cmp     byte ptr [ExMode],2
                je      @@free
                ; ---- fn 0100 allocate ----
                test    byte ptr [DosResFL],1   ; DOS carry?
                jnz     @@allocfail
                mov     cx,si                   ; realseg -> allocate a selector
                call    AllocSel
                jc      @@nomem
                movzx   ecx,si
                mov     [ExCliEAX],ecx          ; AX = real-mode segment
                movzx   ecx,ax
                mov     [ExCliEDX],ecx          ; DX = selector for the block
                mov     eax,[ExCliFL]
                and     eax,not 1               ; CF clear
                mov     [ExCliFL],eax
                jmp     RmExResume
@@allocfail:    movzx   ecx,si
                mov     [ExCliEAX],ecx          ; AX = DOS error code
                movzx   ecx,di
                mov     [ExCliEBX],ecx          ; BX = largest available block
                jmp     @@setcf
@@nomem:        mov     dword ptr [ExCliEAX],8  ; AX = 8 (insufficient memory)
                mov     dword ptr [ExCliEBX],0
                jmp     @@setcf
@@free:         mov     bx,[ExFreeSel]          ; free the block's LDT selector
                call    SelToDesc
                jc      @@freecf
                mov     byte ptr [bx+5],0       ; clear present bit
@@freecf:       test    byte ptr [DosResFL],1
                jz      @@freeok
                movzx   ecx,si
                mov     [ExCliEAX],ecx          ; AX = DOS error code
                jmp     @@setcf
@@freeok:       mov     eax,[ExCliFL]
                and     eax,not 1
                mov     [ExCliFL],eax
                jmp     RmExResume
@@setcf:        mov     eax,[ExCliFL]
                or      eax,1                   ; CF set (error)
                mov     [ExCliFL],eax
                jmp     RmExResume

; AllocSel: cx = real-mode segment -> ax = LDT selector (base cx<<4, 64K data),
; CF set if the LDT pool is exhausted. ds = @gdData.
AllocSel        proc    near
                push    bx
                mov     bx,[LdtNextFree]
                cmp     bx,LDT_ENTRIES
                jae     @@full
                mov     ax,bx
                inc     ax
                mov     [LdtNextFree],ax
                push    bx                      ; keep the index
                shl     bx,3
                add     bx,offset ClientLDT     ; bx -> descriptor
                push    eax
                mov     word ptr [bx+0],0FFFFh   ; limit 64K (byte granular)
                movzx   eax,cx
                shl     eax,4                   ; base = seg << 4
                mov     [bx+2],ax
                shr     eax,16
                mov     [bx+4],al
                mov     byte ptr [bx+7],0
                pop     eax
                mov     byte ptr [bx+5],0F2h    ; ring-3 data, present
                mov     byte ptr [bx+6],0
                pop     bx                      ; index
                mov     ax,bx
                shl     ax,3
                or      ax,7                    ; TI=LDT, RPL=3
                pop     bx
                clc
                ret
@@full:         pop     bx
                stc
                ret
AllocSel        endp

;--- DPMI mode-switch entry point (the client far-CALLs this in V86) ---------
; AX=0 -> 16-bit client, AX=1 -> 32-bit. The HLT #GP-traps to the monitor,
; which recognises this entry and performs the switch (does not return here).
; If the monitor ever declines, control falls through to a clean CF=set retf.
DpmiSwitch      proc    far
                hlt                             ; -> DoHalt hook -> DpmiDoSwitch
                stc
                retf
DpmiSwitch      endp

;--- V86 excursion sentinel: the real-mode int handler IRETs here; the HLT
;    #GP-traps to ring 0 (DoHalt hook -> RmExDone).
RmExSentinel:   hlt
                jmp     RmExSentinel

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
