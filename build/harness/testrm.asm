; testrm - probe VSB's built-in DPMI fn 0300 (simulate real-mode int) - M4a.
;
; Real-mode .COM. Detects the host, switches to protected mode, then from PM
; calls int 31h fn 0300 to run real-mode int 21h AH=30h (get DOS version) via a
; V86 excursion, and reports the version returned in the RMCS. A plausible
; nonzero DOS major version proves the excursion ran real-mode DOS and round-
; tripped registers back.
;
; Wire format on 0x378:
;   'R','M','3'   major, minor   'E','N','D'      (success)
;   'R','M','E','R','R'          'E','N','D'      (fn 0300 returned CF)

                .model  tiny
                .386
                .code
                org     100h
start:
                mov     ax,1687h
                int     2Fh
                or      ax,ax
                jnz     nohost
                mov     [eoff],di
                mov     [eseg],es
                xor     ax,ax               ; 16-bit switch
                call    dword ptr [eoff]
                jc      nohost

                ; ---- protected mode ----
                push    ds
                pop     es                  ; ES = DS (same linear base)
                mov     di,offset rmcs      ; zero the RMCS (0x32 bytes)
                mov     cx,25
                xor     ax,ax
                cld
                rep     stosw
                mov     word ptr [rmcs+1Ch],3000h   ; RMCS.EAX = AH=30h

                push    ds
                pop     es
                mov     di,offset rmcs      ; ES:DI -> RMCS
                mov     bx,0021h            ; BL = int 21h
                xor     cx,cx
                mov     ax,0300h            ; simulate real-mode interrupt
                int     31h
                jc      failed

                mov     ax,word ptr [rmcs+1Ch]  ; AL=major, AH=minor
                mov     [result],ax

                mov     dx,378h
                mov     si,offset sig
                mov     cx,3
                call    emit
                mov     al,byte ptr [result]
                out     dx,al
                mov     al,byte ptr [result+1]
                out     dx,al
                mov     si,offset term
                mov     cx,3
                call    emit
hang:           jmp     hang

failed:         mov     dx,378h
                mov     si,offset emsg
                mov     cx,5
                call    emit
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

sig             db      'RM3'
term            db      'END'
emsg            db      'RMERR'
eoff            dw      0
eseg            dw      0
result          dw      0
                align   2
rmcs            db      50h dup (0)
                end     start
