; testint31 - probe VSB's built-in DPMI int 31h services (Milestone 3).
;
; Real-mode .COM. Detects the host, switches to protected mode, then calls
; int 31h services and writes results to the LPT port 0x378 for the harness:
;   get-version (0400), allocate-descriptor (0000), set-base (0007),
;   set-limit (0008), set-access (0009). Finally it loads the new selector and
;   reads a canary byte through it - proving the descriptor actually maps
;   memory. All of this runs in ring-3 protected mode.
;
; Wire format on 0x378:
;   'I','3','1'
;   verAL, verAH        version (expect 5A 00 = 0.90)
;   sel_lo, sel_hi      allocated selector (expect 2F 00 = LDT[5], RPL3)
;   canary              byte read through the new selector (expect A5)
;   'E','N','D'
; or 'I31ERR'<code_lo><code_hi>'END' if any int 31h call set CF.

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h            ; detect DPMI host
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [entry_off],di
                mov     [entry_seg],es
                mov     ax,cs               ; remember our real-mode segment
                mov     [savedseg],ax

                xor     ax,ax               ; 16-bit switch
                call    dword ptr [entry_off]
                jc      nohost              ; declined -> bail (still real mode)

                ; ---- protected mode from here ----
                mov     ax,0400h            ; get version
                int     31h
                jc      failed
                mov     [r_ver],ax

                mov     ax,0000h            ; allocate 1 descriptor
                mov     cx,1
                int     31h
                jc      failed
                mov     [r_sel],ax
                mov     bx,ax               ; selector for the next calls

                movzx   eax,word ptr [savedseg]
                shl     eax,4               ; linear base of our segment
                mov     dx,ax
                shr     eax,16
                mov     cx,ax
                mov     ax,0007h            ; set base = savedseg<<4
                int     31h
                jc      failed

                mov     bx,[r_sel]
                xor     cx,cx
                mov     dx,0FFFFh           ; limit 64K-1 (byte granular)
                mov     ax,0008h            ; set limit
                int     31h
                jc      failed

                mov     bx,[r_sel]
                mov     cl,0F2h             ; ring-3 data, present
                xor     ch,ch
                mov     ax,0009h            ; set access rights
                int     31h
                jc      failed

                mov     es,[r_sel]          ; load the new selector
                mov     bx,offset canary
                mov     al,es:[bx]          ; read the canary through it
                mov     [r_can],al

                ; ---- emit results ----
                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,byte ptr [r_ver]
                out     dx,al
                mov     al,byte ptr [r_ver+1]
                out     dx,al
                mov     al,byte ptr [r_sel]
                out     dx,al
                mov     al,byte ptr [r_sel+1]
                out     dx,al
                mov     al,[r_can]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

failed:         mov     [r_ver],ax          ; reuse: stash error code
                mov     dx,378h
                mov     si,offset emsg
                mov     cx,6
                call    emit
                mov     al,byte ptr [r_ver]
                out     dx,al
                mov     al,byte ptr [r_ver+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
                jmp     hang

nohost:         mov     ax,4C01h
                int     21h

; emit CX bytes from DS:SI to port DX
emit            proc    near
emit1:          mov     al,[si]
                out     dx,al
                inc     si
                loop    emit1
                ret
emit            endp

sig             db      'I31'
term            db      'END'
emsg            db      'I31ERR'
entry_off       dw      0
entry_seg       dw      0
savedseg        dw      0
r_ver           dw      0
r_sel           dw      0
r_can           db      0
canary          db      0A5h
                end     start
