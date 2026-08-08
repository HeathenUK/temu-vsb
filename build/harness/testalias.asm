; testalias - probe VSB's DPMI create-alias service (int 31h fn 000A).
;
; Real-mode .COM. Switches to PM, builds a CODE selector over our own segment,
; then asks fn 000A for a DATA alias of it. Proves the alias (a) maps the same
; base - reads a canary planted in our segment through the alias - and (b) is
; writable - writes a byte through the alias and reads it back via DS. DOS4GW
; aliases its read-only code block as data exactly this way.
;
; Wire format on 0x378:
;   'A','L','I'
;   r_read              canary read through the alias   (expect 5A)
;   r_write             byte written via alias, read via DS (expect C3)
;   sel_lo, sel_hi      the alias selector               (LDT, RPL 3)
;   'E','N','D'
; or 'ALIERR'<code_lo><code_hi>'END' if a service set CF.

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [entry_off],di
                mov     [entry_seg],es
                mov     ax,cs
                mov     [savedseg],ax

                xor     ax,ax
                call    dword ptr [entry_off]
                jc      nohost

                ; ---- protected mode ----
                mov     cx,1                ; allocate one descriptor
                xor     ax,ax
                int     31h
                jc      failed
                mov     [srcsel],ax
                mov     bx,ax

                movzx   eax,word ptr [savedseg]
                shl     eax,4               ; base = our segment linear
                mov     dx,ax
                shr     eax,16
                mov     cx,ax
                mov     bx,[srcsel]
                mov     ax,0007h            ; set base
                int     31h
                jc      failed
                mov     bx,[srcsel]
                xor     cx,cx
                mov     dx,0FFFFh
                mov     ax,0008h            ; set limit 64K-1
                int     31h
                jc      failed
                mov     bx,[srcsel]
                mov     cl,0FAh             ; ring-3 CODE, readable (a code sel)
                xor     ch,ch
                mov     ax,0009h            ; set access
                int     31h
                jc      failed

                mov     bx,[srcsel]         ; alias it as data
                mov     ax,000Ah
                int     31h
                jc      failed
                mov     [alisel],ax

                mov     es,ax               ; read the canary through the alias
                mov     bx,offset canary
                mov     al,es:[bx]
                mov     [r_read],al

                mov     bx,offset scratch   ; write through the alias...
                mov     byte ptr es:[bx],0C3h
                push    ds
                pop     es
                mov     al,[scratch]        ; ...and read it back via DS
                mov     [r_write],al

                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,[r_read]
                out     dx,al
                mov     al,[r_write]
                out     dx,al
                mov     al,byte ptr [alisel]
                out     dx,al
                mov     al,byte ptr [alisel+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

failed:         mov     [savedseg],ax
                mov     dx,378h
                mov     si,offset emsg
                mov     cx,6
                call    emit
                mov     al,byte ptr [savedseg]
                out     dx,al
                mov     al,byte ptr [savedseg+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
                jmp     hang

nohost:         mov     ax,4C01h
                int     21h

emit            proc    near
emit1:          mov     al,[si]
                out     dx,al
                inc     si
                loop    emit1
                ret
emit            endp

sig             db      'ALI'
term            db      'END'
emsg            db      'ALIERR'
entry_off       dw      0
entry_seg       dw      0
savedseg        dw      0
srcsel          dw      0
alisel          dw      0
r_read          db      0
r_write         db      0
canary          db      5Ah
scratch         db      0
                end     start
