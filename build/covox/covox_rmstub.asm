; Real-mode Covox drain stub (Stage 13). Assembled with nasm -f bin.
; Lives at offset 80 inside a conventional-memory block whose segment is the
; stub's CS. Block layout (offsets):
;   0..63   CVCB (shared with the ring-0 fast path and the PM backend)
;   64..79  RM-only state: gameaccum dw, gamecoeff dw, pumpaccum dw,
;           pumpcoeff dw, oldvec dd (pre-us IVT int8), pumpvec dd (heavy
;           RM wrapper: full RM->PM body for producer/idle work)
;   80..    this code (IVT int8 points at seg:80)
;   256..   sample ring, 16-bit signed stereo frames (16 KB)
; Active tick: drain one sample (~30 core cycles + 2 ISA OUTs, no PM
; transition), then either EOI+iret (common), chain the game's int8
; (gameaccum carry), or jump to the heavy wrapper (pumpaccum carry - the
; wrapper EOIs/pumps; it does not drain again). Idle ticks go straight to
; the heavy wrapper, which owns idle chaining and stream-start detection.
BITS 16
ORG 80

CV_ACTIVE   equ 4
CV_LPTPORT  equ 8
CV_BUFSIZE  equ 16
CV_PLAYPOS  equ 20
CV_WRITEPOS equ 24
CV_LASTOUT  equ 36
CV_TICKCNT  equ 40
RM_GACC     equ 64
RM_GCOEFF   equ 66
RM_PACC     equ 68
RM_PCOEFF   equ 70
RM_OLDVEC   equ 72
RM_PUMPVEC  equ 76
RING        equ 256

entry:
    push ax
    cmp byte [cs:CV_ACTIVE], 0
    je  pump_ax                  ; idle: heavy path does chain+start detection
    push bx
    push dx
    mov bx, [cs:CV_PLAYPOS]
    cmp bx, [cs:CV_WRITEPOS]
    je  under                    ; underrun: repeat last byte, no advance
    mov ax, [cs:bx+RING]         ; L (signed 16)
    mov dx, [cs:bx+RING+2]       ; R
    sar ax, 1
    sar dx, 1
    add ax, dx                   ; ~(L+R)/2
    xor ah, 0x80                 ; bias to unsigned, keep high byte
    mov al, ah
    mov [cs:CV_LASTOUT], al
    add bx, 4
    cmp bx, [cs:CV_BUFSIZE]
    jb  store
    xor bx, bx
store:
    mov [cs:CV_PLAYPOS], bx
    jmp short out_dac
under:
    mov al, [cs:CV_LASTOUT]
out_dac:
    mov dx, [cs:CV_LPTPORT]
    out dx, al
    inc word [cs:CV_TICKCNT]
    mov ax, [cs:RM_PCOEFF]
    add [cs:RM_PACC], ax
    jc  pump                     ; producer wake: heavy path EOIs and pumps
    mov ax, [cs:RM_GCOEFF]
    add [cs:RM_GACC], ax
    jc  game                     ; game tick: chain the pre-us IVT handler
    mov al, 0x60                 ; specific EOI, IRQ0
    out 0x20, al
    pop dx
    pop bx
    pop ax
    iret
game:
    pop dx
    pop bx
    pop ax
    jmp far [cs:RM_OLDVEC]       ; game handler EOIs and irets
pump:
    pop dx
    pop bx
pump_ax:
    pop ax
    jmp far [cs:RM_PUMPVEC]      ; heavy RM wrapper (no second drain in stub mode)
