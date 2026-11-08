; ============================================================================
; rbt_input_asm - keyboard matrix + joystick input (MSX1)
;
; The keyboard is an 11x8 matrix scanned through the 8255 PPI: select a
; row on port #AA bits 0-3 (upper nibble = CAPS/cassette, preserved),
; read column bits on port #A9 (0 = pressed). Codes use
; the ZX encoding (code = row*8 + bit) so KEY(n) stays source-portable —
; rbt_zx2msxkey translates ZX positions to MSX matrix positions.
;
; Matrix (international layout; bit0 first within each row byte):
;   R0 '0'-'7'   R1 '8' '9' '-' '=' '\' '[' ']' ';'
;   R2 ` ~ , . / (dead) A B
;   R3 'C'-'J'   R4 'K'-'R'   R5 'S'-'Z'
;   R6 SHIFT CTRL GRAPH CAPS KANA F1 F2 F3
;   R7 F4 F5 ESC TAB STOP BS SELECT RETURN
;   R8 SPACE HOME INS DEL LEFT UP DOWN RIGHT
;   R9-10 numeric pad
;
; Joystick: PSG registers 14/15 (ports #A0 sel / #A1 write / #A2 read).
; R15 bit6 = port select (0 = joystick 1). R14: bits 0-3 dir, 4 trigA,
; 5 trigB, 0 = pressed. Fire = trigA|trigB -> result bit4.
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_kbd_scan - read one matrix row.
;   In:  A = row (0-10)
;   Out: A = column bits (0 = pressed)
;   DI/EI bracket the PPI transaction so the BIOS ISR can't retarget the
;   row select mid-read.
; ----------------------------------------------------------------------------
rbt_kbd_scan:
        di
        ld      e,a             ; row number
        in      a,(#aa)
        and     #f0             ; keep CAPS LED / cassette bits
        or      e
        out     (#aa),a         ; select row on PPI port C low nibble
        in      a,(#a9)         ; read columns on port B
        ei
        ret

; ----------------------------------------------------------------------------
; ZX key code (Spectrum row*8+bit) -> MSX matrix code (row*8+bit), #ff =
; no MSX equivalent. Same number, same key — source-portable KEY(n).
; ----------------------------------------------------------------------------
rbt_zx2msxkey:
        defb    48,47,45,24,43,#ff,#ff,#ff  ; ZX row0: SHIFT Z X C V
        defb    22,40,25,27,28,#ff,#ff,#ff  ; row1: A S D F G
        defb    38,44,26,39,41,#ff,#ff,#ff  ; row2: Q W E R T
        defb    1,2,3,4,5,#ff,#ff,#ff       ; row3: 1 2 3 4 5
        defb    0,9,8,7,6,#ff,#ff,#ff       ; row4: 0 9 8 7 6
        defb    37,36,30,42,46,#ff,#ff,#ff  ; row5: P O I U Y
        defb    63,33,32,31,29,#ff,#ff,#ff  ; row6: ENTER L K J H
        defb    64,49,34,35,23,#ff,#ff,#ff  ; row7: SPACE SYM(ctrl) M N B

; ----------------------------------------------------------------------------
; rbt_key - test one key. In: A = ZX code (row<<3 | bit). Out: A=1, 0 not.
; ----------------------------------------------------------------------------
rbt_key:
        and     #3f
        ld      e,a
        ld      d,0
        ld      hl,rbt_zx2msxkey
        add     hl,de
        ld      a,(hl)          ; MSX row*8+bit, or #ff
        inc     a
        ret     z               ; unmapped -> never pressed
        dec     a
        ld      e,a             ; E = code
        and     7
        ld      b,a             ; B = bit index
        push    bc
        ld      a,e
        rrca
        rrca
        rrca
        and     #0f             ; A = matrix row
        call    rbt_kbd_scan
        pop     bc
        inc     b
_sh     rra                     ; shift bit B into carry
        djnz    _sh
        ld      a,0
        ret     c               ; bit was 1 -> not pressed
        inc     a
        ret

; ----------------------------------------------------------------------------
; rbt_anykey - A = 1 if any key pressed
; ----------------------------------------------------------------------------
rbt_anykey:
        call    rbt_kbd_any     ; core's raw sweep: A=#ff when nothing held
        cpl
        and     #ff
        ret     z
        ld      a,1
        ret

; ----------------------------------------------------------------------------
; rbt_inkey - scan the matrix, return ASCII of first pressed key (or 0).
; Shift (row6 bit0) selects the shifted table.
; ----------------------------------------------------------------------------
rbt_inkey:
        ld      c,0             ; C = matrix row
_il     ld      a,c
        push    bc
        call    rbt_kbd_scan
        pop     bc
        cp      #ff
        jr      nz,_ibits       ; something held on this row
        inc     c
        ld      a,c
        cp      11
        jr      c,_il
        xor     a
        ret
_ibits  ld      e,#ff           ; first 0 bit = first pressed key
_ibl    inc     e
        rra
        jr      c,_ibl          ; bit 1 = not pressed -> next bit
        ld      a,c             ; index = row*8 + bit
        add     a,a
        add     a,a
        add     a,a
        or      e
        push    af
        ld      a,6
        call    rbt_kbd_scan    ; shift held? row 6 bit 0
        bit     0,a
        pop     af
        ld      hl,rbt_kbdasc
        jr      nz,_ilut        ; shift up -> unshifted table
        ld      hl,rbt_kbdasc_sh
_ilut   ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        ret

; ----------------------------------------------------------------------------
; MSX matrix -> ASCII, index = row*8+bit (bit 0 first). 0 = non-printing
; key (arrows, function keys, control keys, numeric pad reports digits).
; ----------------------------------------------------------------------------
rbt_kbdasc:
        defb    '0','1','2','3','4','5','6','7'   ; R0
        defb    '8','9','-','=',0,'[',']',';'     ; R1 (\ unmapped intl)
        defb    0,0,',','.','/',0,'a','b'         ; R2
        defb    'c','d','e','f','g','h','i','j'   ; R3
        defb    'k','l','m','n','o','p','q','r'   ; R4
        defb    's','t','u','v','w','x','y','z'   ; R5
        defb    0,0,0,0,0,0,0,0                   ; R6 mods/f-keys
        defb    0,0,27,9,0,8,0,13                 ; R7 f4 f5 esc tab stop bs sel ret
        defb    ' ',0,127,0,0,0,0,0               ; R8 space home ins del arrows
        defb    '/','.',',','0','1','2','3','4'   ; R9 numpad
        defb    '5','6','7','8','9','*','+',0     ; R10 numpad

rbt_kbdasc_sh:                          ; same matrix, shift held
        defb    ')','!','"','#','$','%','&','/'   ; R0
        defb    '(',0,'_',0,0,'{','}',':'         ; R1
        defb    0,0,';','<','?',0,'A','B'         ; R2
        defb    'C','D','E','F','G','H','I','J'   ; R3
        defb    'K','L','M','N','O','P','Q','R'   ; R4
        defb    'S','T','U','V','W','X','Y','Z'   ; R5
        defb    0,0,0,0,0,0,0,0                   ; R6
        defb    0,0,27,9,0,8,0,13                 ; R7
        defb    ' ',0,127,0,0,0,0,0               ; R8
        defb    '/','.',',','0','1','2','3','4'   ; R9
        defb    '5','6','7','8','9','*','+',0     ; R10

; ----------------------------------------------------------------------------
; rbt_joy - read joystick 1 via the PSG.
;   Out: A = bitmask %000FUDLR (fire,up,down,left,right) - same shape as ZX.
;   R15 bit6 selects the port (0 = joy1, 1 = joy2); R14 returns up/down/
;   left/right/trigA/trigB, active low. joymode kept for source compat.
; ----------------------------------------------------------------------------
rbt_joymode     defb 0          ; written by JOYSTICK stmt; ignored on MSX

rbt_joy:
        di                      ; BIOS ISR touches the PSG too
        ld      a,15
        out     (#a0),a
        in      a,(#a2)
        and     #bf             ; bit6 = 0 -> joystick port 1
        out     (#a1),a
        ld      a,14
        out     (#a0),a
        in      a,(#a2)         ; b0-3 dir, b4 trigA, b5 trigB (0=pressed)
        ei
        cpl                     ; now 1 = pressed
        ld      b,a
        and     #30             ; either trigger -> result bit4
        jr      z,_nof
        ld      a,16
        jr      _f
_nof    xor     a
_f      ld      c,a
        ld      a,b
        and     4               ; left -> bit1
        rra
        or      c
        ld      c,a
        ld      a,b
        and     8               ; right -> bit0
        rra
        rra
        rra
        or      c
        ld      c,a
        ld      a,b
        and     2               ; down -> bit2
        add     a,a
        or      c
        ld      c,a
        ld      a,b
        and     1               ; up -> bit3
        add     a,a
        add     a,a
        add     a,a
        or      c
        ret

; ----------------------------------------------------------------------------
; rbt_input - line editor. HL = dest buffer, B = max length (array size-1).
; Echoes via rbt_putchar; 8/127 delete, 13 ends and NUL-terminates.
; No auto-repeat: each accepted char waits for key release.
; ----------------------------------------------------------------------------
rbt_input:
        ld      (rbt_in_ptr),hl
        ld      a,b
        ld      (rbt_in_max),a
        xor     a
        ld      (rbt_in_len),a
_iw     call    rbt_inkey       ; A = ascii or 0
        or      a
        jr      z,_iw           ; wait for a press
        cp      13
        jr      z,_idone
        cp      8
        jr      z,_ibs
        cp      127
        jr      z,_ibs
        cp      32
        jr      c,_irel         ; ignore other control codes
        ld      d,a             ; keep the char
        ld      a,(rbt_in_max)
        ld      e,a
        ld      a,(rbt_in_len)
        cp      e
        jr      nc,_irel        ; buffer full
        ld      a,d
        ld      hl,(rbt_in_ptr)
        ld      (hl),a
        inc     hl
        ld      (rbt_in_ptr),hl
        ld      a,(rbt_in_len)
        inc     a
        ld      (rbt_in_len),a
        ld      a,d
        call    rbt_putchar     ; echo (clobbers regs - all state is in vars)
        jr      _irel
_ibs    ld      a,(rbt_in_len)  ; backspace
        or      a
        jr      z,_irel
        dec     a
        ld      (rbt_in_len),a
        ld      hl,(rbt_in_ptr)
        dec     hl
        ld      (rbt_in_ptr),hl
        call    _ibsch          ; erase the last printed char
        jr      _irel
_irel   call    rbt_inkey       ; wait for release before next press
        or      a
        jr      nz,_irel
        jr      _iw
_idone  ld      hl,(rbt_in_ptr)
        xor     a
        ld      (hl),a          ; NUL terminate
_idrel  call    rbt_inkey       ; a held ENTER must release before we
        or      a               ; return, or the next INPUT sees it again
        jr      nz,_idrel
        ret

; erase one char: cursor back (wrapping up a row at col 0), space, back again
_ibsch  ld      a,(rbt_col)
        or      a
        jr      nz,_bl
        ld      a,(rbt_row)
        dec     a
        ld      (rbt_row),a
        ld      a,31
        jr      _bc
_bl     dec     a
_bc     ld      (rbt_col),a
        ld      a,' '
        call    rbt_putchar     ; prints space, advances cursor
        ld      a,(rbt_col)
        or      a
        jr      nz,_b2
        ld      a,(rbt_row)
        dec     a
        ld      (rbt_row),a
        ld      a,31
        jr      _b3
_b2     dec     a
_b3     ld      (rbt_col),a
        ret

; ----------------------------------------------------------------------------
; rbt_match - HL = NUL-terminated buffer, DE = length-prefixed literal
;   (defb len,"text"). Out: A = 1 on exact match else 0.
; ----------------------------------------------------------------------------
rbt_match:
        ld      a,(de)          ; literal length
        inc     de
        ld      b,a
_ml     ld      a,(de)
        cp      (hl)
        jr      nz,_mno
        inc     hl
        inc     de
        djnz    _ml
        ld      a,(hl)          ; buffer must end here too
        or      a
        jr      nz,_mno
        ld      a,1
        ret
_mno    xor     a
        ret

rbt_in_ptr      defw    0
rbt_in_len      defb    0
rbt_in_max      defb    0
