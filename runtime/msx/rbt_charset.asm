; ============================================================================
; rbt_charset_asm - text/attribute engine (MSX1 Screen 2 / MSX2 Screen 5)
; Cursor-based PRINT. Cell (row,col) owns pattern (row*32+col) thanks to
; core's identity name table — glyph rows land at pattern addr idx*8 and
; the fg/bg colour row at colour addr #2000+idx*8.
;
; On RBT_MSX2 (rbt_smode=1) glyphs expand 1bpp -> fg/bg nibbles via
; rbt_xpnib: cell (row,col) covers VRAM (row*8+j)*128 + col*4, and the
; pattern byte also lands in rbt_shadow for POINT/FILLATTR.
;
; rbt_attr keeps the ZX FBPPPIII format; rbt_colbyte (core) converts it
; to an MSX fg<<4|bg nibble pair (FLASH toggles the swap on a timer).
; ============================================================================

rbt_font        defw rbt_cartfont ; embedded Spectrum font — the BIOS
                                  ; font lives in ROM and slot-paging it
                                  ; in isn't portable; cartfont is always
                                  ; emitted for msx builds (see compiler)
rbt_fontbank    defb #ff          ; charset stmt writes this; MSX has no
                                  ; banking so fonts are always resident

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
; rbt_cell - cursor -> HL = pattern-table VRAM address of the char cell
;   (idx = row*32+col; pattern addr = idx*8; colour addr = #2000+idx*8)
; ----------------------------------------------------------------------------
rbt_cell:
        ld      a,(rbt_row)
        ld      b,a
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; row*32
        ld      a,(rbt_col)
        and     31
        or      l
        ld      l,a             ; HL = idx
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8 -> pattern addr (colour: +#2000)
        ret

; ----------------------------------------------------------------------------
; rbt_putchar - print char A at cursor, advance cursor.
; Writes 8 glyph bytes + 8 colour bytes through the VDP.
; ----------------------------------------------------------------------------
rbt_putchar:
        if      RBT_MSX2
        push    af
        ld      a,(rbt_smode)
        or      a
        jr      z,_sc2
        pop     af
        jp      rbt_putchar5
_sc2    pop     af
        endif
        push    af
        call    rbt_cell        ; HL = pattern addr for cell
        ld      (rbt_cs_addr),hl
        ex      de,hl           ; DE = pattern addr
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
        pop     hl              ; HL = pattern addr (no ld hl,de on Z80)
        call    rbt_vwaddr      ; VRAM write addr = pattern addr
        pop     hl
        ld      a,(rbt_over)
        or      a
        jr      nz,_inv
        ld      b,8
_cp     ld      a,(hl)
        out     (#98),a         ; auto-incs through the glyph rows
        inc     hl
        djnz    _cp
        jr      _col
_inv    ld      b,8
_cpi    ld      a,(hl)
        cpl
        out     (#98),a
        inc     hl
        djnz    _cpi
_col    call    rbt_colbyte     ; A = fg<<4|bg
        ld      c,a
        ld      hl,(rbt_cs_addr)
        ld      de,#2000
        add     hl,de           ; colour-table addr for the cell
        call    rbt_vwaddr
        ld      b,8
_cc     ld      a,c
        out     (#98),a
        djnz    _cc
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

rbt_cs_addr     defw 0          ; cell pattern addr for the current putchar

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_putchar5 - Screen 5 putchar: glyph rows expand 1bpp -> fg/bg
; nibbles (rbt_xpnib) into the bitmap; the pattern byte also lands in
; rbt_shadow. Cell (row,col) covers VRAM row*1024 + col*4, stride 128.
; ----------------------------------------------------------------------------
rbt_putchar5:                   ; A = char
        push    af
        call    rbt_cell        ; HL = cell idx*8 = shadow offset
        ld      de,rbt_shadow
        add     hl,de
        ld      (rbt_cs_shp),hl ; running shadow pointer
        ld      a,(rbt_row)
        add     a,a
        add     a,a             ; row*4 -> hi byte of row*1024
        ld      h,a
        ld      a,(rbt_col)
        add     a,a
        add     a,a             ; col*4
        ld      l,a
        ld      (rbt_cs_va),hl  ; cell top-left VRAM addr
        pop     af
        sub     32
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; (char-32)*8
        ld      bc,(rbt_font)
        add     hl,bc           ; HL = glyph
        ld      (rbt_cs_gl),hl
        call    rbt_colbyte     ; A = fg<<4|bg
        ld      (rbt_cs_cb),a
        ld      b,8
_row    push    bc
        ld      hl,(rbt_cs_gl)  ; pattern byte -> E, glyph ptr++
        ld      e,(hl)
        inc     hl
        ld      (rbt_cs_gl),hl
        ld      a,(rbt_over)
        or      a
        jr      z,_ni
        ld      a,e
        cpl
        ld      e,a
_ni     ld      hl,(rbt_cs_shp) ; shadow store, ptr++
        ld      (hl),e
        inc     hl
        ld      (rbt_cs_shp),hl
        ld      hl,(rbt_cs_va)
        call    rbt_vwaddr5     ; DE-preserved 17-bit vaddr
        ld      a,(rbt_cs_cb)
        ld      c,a             ; C = fg<<4|bg
        ld      a,e             ; A = pattern
        call    rbt_xpnib       ; 8 bits -> 4 bytes out #98
        ld      hl,(rbt_cs_va)
        ld      de,128
        add     hl,de
        ld      (rbt_cs_va),hl  ; next row
        pop     bc
        djnz    _row
        ; advance cursor: col++, wrap -> row++ (mod 24)
        ld      a,(rbt_col)
        inc     a
        and     31
        ld      (rbt_col),a
        ret     nz
        ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_sr
        xor     a
_sr     ld      (rbt_row),a
        ret

rbt_cs_shp      defw 0          ; running shadow pointer (putchar5)
rbt_cs_va       defw 0          ; current cell-row VRAM addr
rbt_cs_gl       defw 0          ; running glyph pointer
rbt_cs_cb       defb 0          ; colour byte for the current char
        endif

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
; rbt_fillattr - recolour a cell rectangle with the current attr.
; In: B = x, C = y, D = w, E = h. MSX colour is per-pattern-row, so each
; cell gets its colour byte written to all 8 rows.
; ----------------------------------------------------------------------------
rbt_fillattr:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_fillattr5
        endif
        ld      a,e
        or      a
        ret     z
        call    rbt_colbyte     ; A = fg<<4|bg for current attr
        ld      (rbt_fa_col),a
_row    push    bc
        push    de
        ; cell idx = y*32 + x -> colour addr #2000 + idx*8
        ld      a,c
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; y*32
        ld      a,b
        or      l
        ld      l,a
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8
        ld      de,#2000
        add     hl,de
        call    rbt_vwaddr
        pop     de
        push    de
        ; write D cells x 8 colour bytes
        ld      a,(rbt_fa_col)
        sla     d
        sla     d
        sla     d               ; D*8 bytes — cells are contiguous in VRAM
        ld      b,d
_fc     out     (#98),a
        djnz    _fc
        pop     de
        pop     bc
        inc     c
        dec     e
        jr      nz,_row
        ret

rbt_fa_col      defb 0

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_fillattr5 - Screen 5 recolour: repaint each cell from the shadow
; pattern plane with the current fg/bg pair — exact ZX attr semantics
; (pixels unchanged, colours swapped). In: B = x, C = y, D = w, E = h.
; ----------------------------------------------------------------------------
rbt_fillattr5:
        ld      a,e
        or      a
        ret     z
        ld      a,b
        ld      (rbt_fa_x),a
        ld      a,c
        ld      (rbt_fa_y),a
        ld      a,d
        ld      (rbt_fa_w),a
        ld      a,e
        ld      (rbt_fa_h),a
        call    rbt_colbyte     ; A = fg<<4|bg for current attr
        ld      (rbt_fa_col),a
_y      ; vram row base = y*1024; shadow row base = rbt_shadow + y*256
        ld      a,(rbt_fa_y)
        add     a,a
        add     a,a             ; y*4 -> hi byte of y*1024
        ld      h,a
        ld      l,0
        ld      (rbt_fa_va),hl
        ld      a,(rbt_fa_x)
        ld      (rbt_fa_cx),a   ; current column
        ld      a,(rbt_fa_w)
        ld      (rbt_fa_i),a    ; columns left
_x      ; cell shadow base = rbt_shadow + (y*32 + cx)*8
        ld      a,(rbt_fa_y)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; y*32
        ld      a,(rbt_fa_cx)
        or      l
        ld      l,a             ; cellidx
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8
        ld      de,rbt_shadow
        add     hl,de
        ld      (rbt_fa_sh),hl
        ; cell vram addr = y*1024 + cx*4
        ld      a,(rbt_fa_cx)
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,(rbt_fa_va)
        add     hl,de
        ld      (rbt_fa_cva),hl
        ld      b,8             ; 8 rows
_r      push    bc
        ld      hl,(rbt_fa_sh)  ; pattern byte -> shadow ptr++
        ld      a,(hl)
        inc     hl
        ld      (rbt_fa_sh),hl
        push    af
        ld      hl,(rbt_fa_cva)
        call    rbt_vwaddr5
        pop     af              ; A = pattern
        push    af
        ld      a,(rbt_fa_col)
        ld      c,a             ; C = fg<<4|bg
        pop     af              ; A = pattern
        call    rbt_xpnib       ; recoloured 8 bits -> 4 bytes
        ld      hl,(rbt_fa_cva)
        ld      de,128
        add     hl,de
        ld      (rbt_fa_cva),hl
        pop     bc
        djnz    _r
        ld      a,(rbt_fa_cx)
        inc     a
        ld      (rbt_fa_cx),a
        ld      a,(rbt_fa_i)
        dec     a
        ld      (rbt_fa_i),a
        jp      nz,_x
        ld      a,(rbt_fa_y)
        inc     a
        ld      (rbt_fa_y),a
        ld      a,(rbt_fa_h)
        dec     a
        ld      (rbt_fa_h),a
        jp      nz,_y
        ret

rbt_fa_x        defb 0
rbt_fa_y        defb 0
rbt_fa_w        defb 0
rbt_fa_h        defb 0
rbt_fa_i        defb 0
rbt_fa_cx       defb 0
rbt_fa_va       defw 0
rbt_fa_sh       defw 0
rbt_fa_cva      defw 0
        endif
