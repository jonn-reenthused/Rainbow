; ============================================================================
; rbt_charset_asm - text output via the CPC firmware TXT pack
;
; INK/PAPER take ZX colour indices (0-7) and program pen 1 / pen 0 inks so
; portable code keeps its colours (INK 7 = white text on both machines).
; BRIGHT selects the bright-ink translation table; FLASH programs pen 1 to
; alternate between the current ink and paper colours.
; (rbt_col/rbt_row/rbt_over/rbt_attr vars live in core)
; ============================================================================

rbt_inkv        defb 7          ; current logical ink   (ZX colour)
rbt_papv        defb 0          ; current logical paper (ZX colour)
rbt_brightv     defb 0          ; 0 = normal, 1 = bright inks
rbt_flashv      defb 0          ; 0 = steady, 1 = ink/paper alternating
        if      RBT_CART
rbt_font        defw rbt_cartfont ; embedded font — there is no firmware one
        else
rbt_font        defw 0          ; .rbf glyph data (0 = use the firmware font)
        endif
rbt_fontbank    defb #ff        ; stored by CHARSET (#ff = resident)
rbt_fontprev    defb 0          ; mapping save byte for the glyph guard
rbt_p16s        defb 0          ; print_u16 leading-zero flag (B' is unsafe:
                                ; the firmware ISR owns the alt registers)

; bright variants of rbt_zx2cpc (in core): blue->2 red->6 magenta->8
; green->19 cyan->21 yellow->24 white->26
rbt_zx2cpc_b:   defb 0,2,6,8,19,21,24,26

; ----------------------------------------------------------------------------
; rbt_locate - set cursor. In: B = column (0-31), C = row (0-23).
; Firmware coordinates are 1-based; CPC has no 32-column mode so columns
; beyond the mode width wrap harmlessly in the firmware.
; ----------------------------------------------------------------------------
rbt_locate:
        ld      a,b
        cp      32
        jr      c,_colok
        xor     a
_colok  ld      (rbt_col),a
        if      RBT_CART
        else                    ; logical vars are all the font path needs
        inc     a
        call    FW_TXT_SET_COL           ; TXT SET COLUMN
        endif
        ld      a,c
        cp      24
        jr      c,_rowok
        xor     a
_rowok  ld      (rbt_row),a
        if      RBT_CART
        else
        inc     a
        call    FW_TXT_SET_ROW           ; TXT SET ROW
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_putchar - print char A. With a custom font (CHARSET) glyphs are drawn
; via rbt_tile8 at the logical cell; otherwise the firmware cursor prints
; (auto-advance, wrap, scroll). Keeps rbt_col/rbt_row in step.
; ----------------------------------------------------------------------------
rbt_putchar:
        push    af              ; keep the char - the font probe clobbers A
        push    hl
        ld      hl,(rbt_font)
        ld      a,h
        or      l
        pop     hl
        jr      nz,_font
        pop     af
        call    FW_TXT_OUTPUT           ; TXT OUTPUT
        ld      a,(rbt_col)
        inc     a
        cp      32
        jr      c,_adv
        xor     a
        ld      (rbt_col),a
        ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_advrow
        xor     a
_advrow ld      (rbt_row),a
        ld      a,(rbt_col)
        ret
_adv    ld      (rbt_col),a
        ret
_font   pop     af
        ; fall through
; ----------------------------------------------------------------------------
; rbt_cs_putf - draw char A as an 8x8 pen1/pen0 glyph at (rbt_col,rbt_row).
; .rbf data = 96 glyphs x 8 bytes, 1bpp, expanded by rbt_tile8.
; ----------------------------------------------------------------------------
rbt_cs_putf:
        sub     32
        cp      96
        jr      c,_glyph
        ld      a,'?'-32        ; out-of-range -> '?'
_glyph  ; glyph = font + a*8
        ld      e,a
        ld      d,0
        sla     e
        rl      d
        sla     e
        rl      d
        sla     e
        rl      d               ; DE = (code-32)*8
        ld      hl,(rbt_font)
        add     hl,de
        ex      de,hl           ; DE = glyph src
        ld      a,(rbt_col)
        ld      b,a
        ld      a,(rbt_row)
        ld      c,a
        ld      a,(rbt_fontbank)
        ld      hl,rbt_fontprev
        call    rbt_pg_in       ; page the font bank (#ff = resident)
        call    rbt_tile8       ; B=cell x, C=cell y, DE=src
        ld      hl,rbt_fontprev
        call    rbt_pg_out
        ; advance the logical cursor (wrap, no scroll)
        ld      a,(rbt_col)
        inc     a
        cp      32
        jr      c,_padv
        xor     a
        ld      (rbt_col),a
        ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_prw
        xor     a
_prw    ld      (rbt_row),a
        ret
_padv   ld      (rbt_col),a
        ret

; ----------------------------------------------------------------------------
; rbt_newline - CR + LF (firmware path only; the font path just wraps vars)
; ----------------------------------------------------------------------------
rbt_newline:
        xor     a
        ld      (rbt_col),a
        push    hl
        ld      hl,(rbt_font)
        ld      a,h
        or      l
        pop     hl
        jr      nz,_nlrow       ; font path: skip firmware output
        ld      a,13
        call    FW_TXT_OUTPUT
        ld      a,10
        call    FW_TXT_OUTPUT
_nlrow  ld      a,(rbt_row)
        inc     a
        cp      24
        jr      c,_r
        xor     a
_r      ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_cs_inkval - ZX colour A -> CPC ink, honouring rbt_brightv
; ----------------------------------------------------------------------------
rbt_cs_inkval:
        and     7
        ld      hl,rbt_zx2cpc
        ld      b,a
        ld      a,(rbt_brightv)
        or      a
        jr      z,_tab
        ld      hl,rbt_zx2cpc_b
_tab    ld      a,b
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        ret

; ----------------------------------------------------------------------------
; rbt_cs_apply - program pen 1 (text) and pen 0 (paper) from the logical vars.
; FLASH alternates pen 1 between ink and paper inks.
; ----------------------------------------------------------------------------
rbt_cs_apply:
        ld      a,(rbt_inkv)
        call    rbt_cs_inkval         ; A = CPC ink for text
        ld      b,a
        ld      a,(rbt_flashv)
        or      a
        jr      z,_steady
        ld      a,(rbt_papv)
        call    rbt_cs_inkval         ; flash: second colour = paper ink
        ld      c,a
        jr      _setpen
_steady ld      c,b
_setpen ld      a,1             ; pen 1 = text pen
        if      RBT_CART
        ld      d,b             ; rbt_gpen: A=pen, D=ink1, E=ink2
        ld      e,c
        call    rbt_gpen
        ld      a,(rbt_papv)
        call    rbt_cs_inkval
        ld      d,a
        ld      e,a
        xor     a               ; pen 0 = paper
        call    rbt_gpen
        else
        call    FW_SCR_SET_INK           ; SCR SET INK A=pen B=ink1 C=ink2
        ld      a,(rbt_papv)
        call    rbt_cs_inkval
        ld      b,a
        ld      c,a
        xor     a               ; pen 0 = paper
        call    FW_SCR_SET_INK
        ld      a,1
        call    FW_TXT_SET_PEN           ; TXT SET PEN 1
        xor     a
        call    FW_TXT_SET_PAP           ; TXT SET PAPER 0
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_ink / rbt_paper / rbt_bright / rbt_flash - attribute state (A = value)
; ----------------------------------------------------------------------------
rbt_ink:
        ld      (rbt_inkv),a
        jr      rbt_cs_apply
rbt_paper:
        ld      (rbt_papv),a
        jr      rbt_cs_apply
rbt_bright:
        ld      (rbt_brightv),a
        jr      rbt_cs_apply
rbt_flash:
        ld      (rbt_flashv),a
        jr      rbt_cs_apply

; ----------------------------------------------------------------------------
; rbt_fillattr - FILLATTR x,y,w,h. CPC has no attribute plane, so the
; ZX meaning (recolour a cell rect) maps to programming the pen inks from
; the logical INK/PAPER vars - a whole-screen recolour. Correct for the
; common full-screen use; partial rects recolour everything.
; ----------------------------------------------------------------------------
rbt_fillattr:
        jp      rbt_cs_apply

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
; rbt_print_u16 - print HL as decimal (no leading zeros). rbt_p16s = started
; flag - the ZX version kept it in B' via EXX, but on CPC the firmware ISR
; owns the alternate registers, so EXX here would corrupt the interrupt
; handler's state.
; ----------------------------------------------------------------------------
rbt_print_u16:
        xor     a
        ld      (rbt_p16s),a
        ld      de,-10000
        call    _digit
        ld      de,-1000
        call    _digit
        ld      de,-100
        call    _digit
        ld      de,-10
        call    _digit
        ld      a,1             ; units digit always prints
        ld      (rbt_p16s),a
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
        ld      a,(rbt_p16s)
        or      a
        ret     z               ; leading zero, suppress
        xor     a               ; mid-number zero
_show   push    af
        ld      a,1
        ld      (rbt_p16s),a
        pop     af
        add     a,'0'
        push    hl              ; putchar clobbers HL
        call    rbt_putchar
        pop     hl
        ret
