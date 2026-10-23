; ============================================================================
; rbt_charset_asm - text/attribute engine
; Cursor-based PRINT through a charset (default: ROM font at #3D00).
; Screen layout: bitmap #4000-#57FF, attributes #5800-#5AFF (32x24 cells).
; ============================================================================

        if RBT_CART
rbt_font        defw rbt_cartfont ; cart: no ROM font — embedded instead
        else
rbt_font        defw #3d00      ; glyph base: chars 32-127, 8 bytes each
        endif
rbt_fontbank    defb #ff        ; font bank (#ff = resident, 128K)
rbt_cs_prev     defb 0          ; pg guard save
                                ; (rbt_col/rbt_row cursor vars live in core)

; ----------------------------------------------------------------------------
; rbt_locate - set cursor. In: B = column (0-31), C = row (0-23)
; ----------------------------------------------------------------------------
rbt_locate:
        ld      a,b
        and     31
        ld      (rbt_col),a
        ld      a,c
        cp      24
        jr      c,_ok
        ld      a,23
_ok     ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_cell - cursor -> HL = screen address of char cell top line
; ----------------------------------------------------------------------------
rbt_cell:
        ld      a,(rbt_row)
        ld      c,a
        and     7
        rrca
        rrca
        rrca                    ; A = (row & 7) * 32
        ld      l,a
        ld      a,(rbt_col)
        and     31
        or      l
        ld      l,a             ; L = (row&7)*32 + col
        ld      a,c
        and     #f8
        rrca
        rrca
        rrca                    ; A = row >> 3
        add     a,a
        add     a,a
        add     a,a             ; *8
        add     a,#40
        ld      h,a             ; H = #40 + (row>>3)*8
        ret

; ----------------------------------------------------------------------------
; rbt_putchar - print char A at cursor, advance cursor.
; Writes glyph + current attribute. Clobbers BC,DE,HL.
; ----------------------------------------------------------------------------
rbt_putchar:
        push    af
        call    rbt_cell
        ex      de,hl           ; DE = screen cell
        pop     af
        sub     32
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; (char-32)*8
        ld      bc,(rbt_font)
        add     hl,bc           ; HL = glyph
        push    hl
        push    de
        ld      hl,rbt_cs_prev
        ld      a,(rbt_fontbank)
        call    rbt_pg_in       ; page font bank (no-op when resident)
        pop     de
        pop     hl
        ld      b,8
        ld      a,(rbt_over)
        or      a
        jr      nz,_inv
_cp     ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     d               ; next screen line
        djnz    _cp
        jr      _unpg
_inv    ld      a,(hl)
        cpl
        ld      (de),a
        inc     hl
        inc     d
        djnz    _inv
_unpg   push    hl
        ld      hl,rbt_cs_prev
        call    rbt_pg_out      ; restore bank (preserves A)
        pop     hl
_attr   ld      a,(rbt_row)     ; attr addr = #5800 + row*32 + col
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; row*32
        ld      a,(rbt_col)
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ld      a,(rbt_attr)
        ld      (hl),a
        ; advance cursor: col++, wrap -> row++ (mod 24)
        ld      a,(rbt_col)
        inc     a
        and     31
        ld      (rbt_col),a
        ret     nz
        ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_setrow
        xor     a
_setrow ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_newline - move cursor to start of next row (wraps to 0 at bottom)
; ----------------------------------------------------------------------------
rbt_newline:
        xor     a
        ld      (rbt_col),a
        ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_ok
        xor     a
_ok     ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_print_str - print length-prefixed string at HL: defb len,"text"
; ----------------------------------------------------------------------------
rbt_print_str:
        ld      b,(hl)
        inc     hl
        ld      a,b
        or      a
        ret     z
_ps     ld      a,(hl)
        push    hl
        push    bc
        call    rbt_putchar
        pop     bc
        pop     hl
        inc     hl
        djnz    _ps
        ret

; ----------------------------------------------------------------------------
; rbt_print_u8 - print A as decimal (no leading zeros)
; ----------------------------------------------------------------------------
rbt_print_u8:
        ld      l,a
        ld      h,0
        ; fall through
; ----------------------------------------------------------------------------
; rbt_print_u16 - print HL as decimal (no leading zeros). B = started flag.
; ----------------------------------------------------------------------------
rbt_print_u16:
        exx
        ld      b,0             ; B' = leading-zero flag (putchar clobbers BC)
        exx
        ld      de,-10000
        call    _digit
        ld      de,-1000
        call    _digit
        ld      de,-100
        call    _digit
        ld      de,-10
        call    _digit
        exx
        ld      b,1             ; units digit always prints
        exx
        ld      de,-1
        call    _digit
        ret
_digit                          ; A = count of |de| subtracted (0-9)
        xor     a
_dl     add     hl,de           ; de is negative; carry means HL >= |de|
        jr      nc,_ovf         ; result went negative -> stop
        inc     a
        jr      _dl
_ovf    or      a               ; clear carry
        sbc     hl,de           ; undo the failed subtraction
        or      a               ; is count zero?
        jr      nz,_show
        exx
        ld      a,b
        or      a
        exx
        ret     z               ; leading zero, suppress
        xor     a               ; mid-number zero
_show   exx
        ld      b,1
        exx
        add     a,'0'
        push    hl              ; putchar clobbers HL
        call    rbt_putchar
        pop     hl
        ret

; ----------------------------------------------------------------------------
; rbt_ink / rbt_paper / rbt_bright / rbt_flash - modify rbt_attr. A = value.
; ----------------------------------------------------------------------------
rbt_ink:
        and     7
        ld      b,a
        ld      a,(rbt_attr)
        and     #f8
        or      b
        ld      (rbt_attr),a
        ret

rbt_paper:
        and     7
        add     a,a
        add     a,a
        add     a,a
        ld      b,a
        ld      a,(rbt_attr)
        and     #c7
        or      b
        ld      (rbt_attr),a
        ret

rbt_bright:
        and     1
        rrca
        rrca                    ; bit0 -> bit6
        ld      b,a
        ld      a,(rbt_attr)
        and     #bf
        or      b
        ld      (rbt_attr),a
        ret

rbt_flash:
        and     1
        rrca                    ; bit0 -> bit7
        ld      b,a
        ld      a,(rbt_attr)
        and     #7f
        or      b
        ld      (rbt_attr),a
        ret

; ----------------------------------------------------------------------------
; rbt_fillattr - fill attribute rectangle.
; In: B = x, C = y, D = w, E = h. Uses current rbt_attr.
; ----------------------------------------------------------------------------
rbt_fillattr:
        ld      a,e
        or      a
        ret     z
_row    push    bc
        push    de
        ; HL = #5800 + y*32 + x
        ld      a,c
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,b
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ; fill D cells
        ld      a,(rbt_attr)
_fc     ld      (hl),a
        inc     hl
        dec     d
        jr      nz,_fc
        pop     de
        pop     bc
        inc     c
        dec     e
        jr      nz,_row
        ret
