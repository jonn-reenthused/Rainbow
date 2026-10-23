; ============================================================================
; rbt_input_asm - keyboard matrix + joystick input (Amstrad CPC)
;
; The keyboard is a 10x8 matrix scanned through the AY-3-8912's I/O port
; (register 14) via the 8255 PPI. Key codes use the same encoding as the
; Spectrum runtime (code = line*8 + bit) but CPC line/bit positions:
;   lines 0-9, bit 0..7 of the line byte; bit = 0 means pressed.
; Matrix line 9 = joystick 0 (bits: 0=up 1=down 2=left 3=right 4=fire2 5=fire1).
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_kbd_scan - read one matrix line.
;   In:  A = line (0-9)
;   Out: A = column bits (0 = pressed)
;   Clobbers B, C, E. DI/EI bracket the PSG transaction so the firmware ISR
;   cannot retarget register 14 mid-read.
; ----------------------------------------------------------------------------
rbt_kbd_scan:
        di
        ld      e,a             ; E = matrix line
        ld      bc,#f40e        ; write PSG reg number 14 to PPI port A
        out     (c),c
        ld      bc,#f6c0        ; PSG operation: latch register
        out     (c),c
        ld      bc,#f600        ; PSG operation: inactive
        out     (c),c
        ld      bc,#f792        ; PPI control: port A = input
        out     (c),c
        ld      a,e
        or      #40             ; port C: PSG read op (01) | matrix line
        ld      bc,#f600
        out     (c),a
        ld      b,#f4           ; read PPI port A = matrix column bits
        in      a,(c)
        push    af
        xor     a
        ld      bc,#f600        ; port C = 0: PSG inactive, decoder line 0
        out     (c),a
        ld      bc,#f782        ; restore PPI port A = output
        out     (c),c
        pop     af
        ei
        ret

; ----------------------------------------------------------------------------
; ZX key code (Spectrum row*8+bit) -> CPC matrix code (line*8+bit), #ff = no
; CPC equivalent. Keeps KEY(n) source-portable: same number, same key.
; ----------------------------------------------------------------------------
rbt_zx2cpckey:
        defb    21,71,63,62,55,#ff,#ff,#ff  ; row0: SHIFT Z X C V
        defb    69,60,61,53,52,#ff,#ff,#ff  ; row1: A S D F G
        defb    67,59,58,50,51,#ff,#ff,#ff  ; row2: Q W E R T
        defb    64,65,57,56,49,#ff,#ff,#ff  ; row3: 1 2 3 4 5
        defb    32,33,40,41,48,#ff,#ff,#ff  ; row4: 0 9 8 7 6
        defb    27,34,35,42,43,#ff,#ff,#ff  ; row5: P O I U Y
        defb    18,36,37,45,44,#ff,#ff,#ff  ; row6: ENTER L K J H
        defb    47,23,38,46,54,#ff,#ff,#ff  ; row7: SPACE SYM(ctrl) M N B

; ----------------------------------------------------------------------------
; rbt_key - test one key. In: A = ZX code (row<<3 | bit). Out: A=1, 0 not.
; ----------------------------------------------------------------------------
rbt_key:
        and     #3f
        ld      e,a
        ld      d,0
        ld      hl,rbt_zx2cpckey
        add     hl,de
        ld      a,(hl)          ; CPC line*8+bit, or #ff
        inc     a
        ret     z               ; unmapped -> never pressed
        dec     a
        ld      e,a             ; E = code
        and     7
        ld      b,a             ; B = bit index (scanline clobbers E)
        push    bc
        ld      a,e
        rrca
        rrca
        rrca
        and     #0f             ; A = line (0-9)
        call    rbt_kbd_scan
        pop     bc
        inc     b
_sh     rra                     ; shift bit B into carry
        djnz    _sh
        ld      a,0
        ret     c               ; bit was 1 -> not pressed
        inc     a
        ret

        if      RBT_CART
; ----------------------------------------------------------------------------
; rbt_inkey (cart) - scan the matrix directly and map to ASCII. There is no
; firmware key buffer: returns the first pressed key found, or 0. Shift
; (line 2 bit 5) selects the shifted table.
; ----------------------------------------------------------------------------
rbt_inkey:
        ld      c,0             ; C = matrix line
_il     ld      a,c
        push    bc
        call    rbt_kbd_scan
        pop     bc
        cp      #ff
        jr      nz,_ibits       ; something held on this line
        inc     c
        ld      a,c
        cp      10
        jr      c,_il
        xor     a
        ret
_ibits  ld      e,#ff           ; first 0 bit = first pressed key
_ibl    inc     e
        rra
        jr      c,_ibl          ; bit 1 = not pressed -> next bit
        ld      a,c             ; index = line*8 + bit
        add     a,a
        add     a,a
        add     a,a
        or      e
        push    af
        ld      a,2
        call    rbt_kbd_scan    ; shift held? line 2 bit 5
        bit     5,a
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
; CPC matrix -> ASCII, index = line*8+bit (bit 0 first). 0 = non-printing
; key. Cursor keys, function keys, joystick and control keys report 0;
; CPC-specific keys follow the firmware's usual ASCII where one exists
; (Return/Enter 13, Clr 12, Esc 27, Tab 9, Del 127).
; ----------------------------------------------------------------------------
rbt_kbdasc:
        defb    0,0,0,0,0,0,13,0        ; L0: up right dn f9 f6 f3 ent f.
        defb    0,0,0,0,0,0,0,0         ; L1: left copy f7 f8 f5 f1 f2 f0
        defb    12,91,13,93,0,0,92,0    ; L2: clr [ ret ] f4 shft \ ctrl
        defb    94,45,64,112,59,58,47,46  ; L3: ^ - @ P ; : / .
        defb    48,57,111,105,108,107,109,44 ; L4: 0 9 O I L K M ,
        defb    56,55,117,121,104,106,110,32 ; L5: 8 7 U Y H J N spc
        defb    54,53,114,116,103,102,98,118 ; L6: 6 5 R T G F B V
        defb    52,51,101,119,115,100,99,120 ; L7: 4 3 E W S D C X
        defb    49,50,27,113,9,97,0,122  ; L8: 1 2 esc Q tab A cap Z
        defb    0,0,0,0,0,0,0,127       ; L9: joy0, -, del

rbt_kbdasc_sh:                          ; same matrix, shift held
        defb    0,0,0,0,0,0,13,0        ; L0
        defb    0,0,0,0,0,0,0,0         ; L1
        defb    12,123,13,125,0,0,124,0 ; L2: [ ] \ -> { } |
        defb    96,61,124,80,43,42,63,62  ; L3: ^ - @ P ; : / . -> ` = | P + * ? >
        defb    95,41,79,73,76,75,77,60 ; L4: 0 9 , -> _ ) <
        defb    40,39,85,89,72,74,78,32 ; L5: 8 7 -> ( '
        defb    38,37,82,84,71,70,66,86 ; L6: 6 5 -> & %
        defb    36,35,69,87,83,68,67,88 ; L7: 4 3 -> $ #
        defb    33,34,27,81,9,65,0,90   ; L8: 1 2 -> ! "
        defb    0,0,0,0,0,0,0,127       ; L9
        else
; ----------------------------------------------------------------------------
; rbt_inkey - return ASCII of next buffered key (or 0). Uses the firmware
; key buffer filled by the ROM ISR (rbt_start leaves EI on).
; ----------------------------------------------------------------------------
rbt_inkey:
        call    FW_KM_READ_CHAR           ; KM READ CHAR -> carry set: A = char
        ret     c
        xor     a
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_joy - read joystick 0 (matrix line 9).
;   Out: A = bitmask %000FUDLR (fire,up,down,left,right) - same shape as ZX.
;   CPC bits: 5=fire1 4=fire2 3=right 2=left 1=down 0=up (pressed = 0).
;   Fire 1 and fire 2 both count as fire.
; ----------------------------------------------------------------------------
rbt_joymode     defb 0          ; written by JOYSTICK stmt; ignored on CPC

rbt_joy:
        ld      a,9
        call    rbt_kbd_scan
        cpl                     ; now 1 = pressed
        ld      b,a
        and     #30             ; either fire bit -> result bit 4
        jr      z,_nofire
        ld      a,16
        jr      _fired
_nofire xor     a
_fired  ld      c,a
        ld      a,b
        and     8               ; right -> bit 0
        rra
        rra
        rra
        or      c
        ld      c,a
        ld      a,b
        and     4               ; left -> bit 1
        rra
        or      c
        ld      c,a
        ld      a,b
        and     2               ; down -> bit 2
        add     a,a
        or      c
        ld      c,a
        ld      a,b
        and     1               ; up -> bit 3
        add     a,a
        add     a,a
        add     a,a
        or      c
        ret
