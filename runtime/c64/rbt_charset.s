; ============================================================================
; rbt_charset - text engine (Commodore 64, ca65)
; 40x25 screen RAM at $0400 + colour RAM at $D800. Chars are written as VIC
; screen codes (ASCII converted by rbt_a2sc); the colour byte is rbt_attr's
; low nibble, its bit7 (FLASH) selects reverse video per char.
; (rbt_col/rbt_row cursor vars live in core)
; ============================================================================

        .code

rbt_font:        .word 0         ; font asset ptr (CHARSET); 0 = ROM chargen
rbt_fontbank:    .byte $ff       ; unused (no banked RAM) — kept for parity

; ----------------------------------------------------------------------------
; rbt_fset - apply rbt_font: copy .rbf glyphs into charset RAM (base $3800)
; at their *screen-code* slots — rbt_a2sc folds ASCII to codes 0-63, so a
; linear copy would leave codes 0-31 ('@'-'_' + folded lowercase) reading
; garbage RAM (letters rendered as solid blocks):
;   font idx  0-31 (ASCII 32-63) -> codes 32-63   $3900-$39FF
;   font idx 32-63 (ASCII 64-95) -> codes 0-31    $3800-$38FF
; font idx 64-95 (ASCII 96-127 lowercase) is unused — a2sc folds it onto
; codes 0-31, so 'a' shows the 'A' glyph. Then point the VIC at charset
; RAM: $D018 = screen $0400 + charset $3800.
; ----------------------------------------------------------------------------
rbt_fset:
        ; font+$000 (idx 0-31) -> $3900 (codes 32-63)
        lda     rbt_font
        sta     rbt_ptr
        lda     rbt_font+1
        sta     rbt_ptr+1       ; rbt_ptr = src
        lda     #$00
        sta     rbt_hl
        lda     #>(RBT_CSET+$100)
        sta     rbt_hl+1        ; rbt_hl = dst charset+$100 (codes 32-63)
        jsr     _fpage
        ; font+$100 (idx 32-63) -> charset+$000 (codes 0-31); rbt_ptr has
        ; rolled on to font+$100 inside _fpage
        lda     #>RBT_CSET
        sta     rbt_hl+1
        jsr     _fpage
        lda     #RBT_D018T      ; screen + charset in the active VIC bank
        jsr     rbt_mapio       ; preserves A
        sta     $d018
        jsr     rbt_maprun
        sta     rbt_d018        ; text-mode shadow (rbt_scrmode restores it)
        rts

; _fpage - copy 256 bytes rbt_ptr -> rbt_hl, advancing both src/dst a page.
_fpage: ldy     #0
@cp:    lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @cp
        inc     rbt_ptr+1
        inc     rbt_hl+1
        rts

; ----------------------------------------------------------------------------
; rbt_locate - set cursor. In: rbt_b = column (0-39), rbt_c = row (0-24)
; ----------------------------------------------------------------------------
rbt_locate:
        lda     rbt_b
        cmp     #40
        bcc     @cok
        lda     #39
@cok:   sta     rbt_col
        lda     rbt_c
        cmp     #25
        bcc     @rok
        lda     #24
@rok:   sta     rbt_row
        rts

; ----------------------------------------------------------------------------
; rbt_a2sc - ASCII in A -> VIC screen code in A.
;   '@'-$5F map to 0-31 by subtracting $40; lowercase folds to upper.
;   32-63 (space, digits, most punctuation) are already screen codes.
; ----------------------------------------------------------------------------
rbt_a2sc:
        cmp     #$60
        bcc     @nolc
        and     #$5f            ; fold a-z (and `,{,|,},~) onto @,A-Z,[...
@nolc:  cmp     #$40
        bcc     @done
        sec
        sbc     #$40
@done:  rts

; ----------------------------------------------------------------------------
; rbt_putchar - print char A at cursor, advance cursor.
; Writes the screen code + current colour. Preserves X.
; ----------------------------------------------------------------------------
rbt_putchar:
        sta     rbt_t0          ; char
        ; rbt_ptr = $0400 + row*40 + col  (row*40 = row*32 + row*8)
        lda     rbt_row
        sta     rbt_ptr
        lda     #0
        sta     rbt_ptr+1
        asl     rbt_ptr         ; *2
        rol     rbt_ptr+1
        asl     rbt_ptr         ; *4
        rol     rbt_ptr+1
        asl     rbt_ptr         ; *8
        rol     rbt_ptr+1
        lda     rbt_ptr         ; stash row*8
        sta     rbt_t2
        lda     rbt_ptr+1
        sta     rbt_t2+1
        asl     rbt_ptr         ; *16
        rol     rbt_ptr+1
        asl     rbt_ptr         ; *32
        rol     rbt_ptr+1
        clc
        lda     rbt_ptr         ; + row*8 -> row*40
        adc     rbt_t2
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t2+1
        sta     rbt_ptr+1
        clc
        lda     rbt_ptr         ; + col + RBT_SCRN
        adc     rbt_col
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #>RBT_SCRN
        sta     rbt_ptr+1
        ; screen code (+ reverse bit when OVER or FLASH is set)
        lda     rbt_t0
        jsr     rbt_a2sc
        ldx     rbt_over
        beq     @nrev
        ora     #$80
@nrev:  ldx     rbt_attr
        bpl     @nfl
        ora     #$80
@nfl:   ldy     #0
        sta     (rbt_ptr),y
        ; colour RAM = screen + RBT_CDELTA (lives in the I/O window on c128)
        lda     rbt_ptr+1
        clc
        adc     #>RBT_CDELTA
        sta     rbt_ptr+1
        jsr     rbt_mapio
        lda     rbt_attr
        and     #$0f
        sta     (rbt_ptr),y
        jsr     rbt_maprun
        ; advance cursor: col++, wrap -> row++ (wraps to 0 at bottom)
        inc     rbt_col
        lda     rbt_col
        cmp     #40
        bcc     @done
        lda     #0
        sta     rbt_col
        inc     rbt_row
        lda     rbt_row
        cmp     #25
        bcc     @done
        lda     #0
        sta     rbt_row
@done:  rts

; ----------------------------------------------------------------------------
; rbt_newline - move cursor to start of next row (wraps to 0 at bottom)
; ----------------------------------------------------------------------------
rbt_newline:
        lda     #0
        sta     rbt_col
        inc     rbt_row
        lda     rbt_row
        cmp     #25
        bcc     @ok
        lda     #0
        sta     rbt_row
@ok:    rts

; ----------------------------------------------------------------------------
; rbt_print_str - print length-prefixed string at rbt_hl: .byte len,"text"
; ----------------------------------------------------------------------------
rbt_print_str:
        ldy     #0
        lda     (rbt_hl),y
        sta     rbt_slen
        beq     @done
        inc     rbt_hl          ; skip len byte
        bne     @s
        inc     rbt_hl+1
@s:     lda     #0
        sta     rbt_sidx
@loop:  ldy     rbt_sidx
        lda     (rbt_hl),y
        jsr     rbt_putchar
        inc     rbt_sidx
        lda     rbt_sidx
        cmp     rbt_slen
        bcc     @loop
@done:  rts

; ----------------------------------------------------------------------------
; rbt_print_u8 / rbt_print_u16 - print A / rbt_hl as decimal (no leading zeros)
; ----------------------------------------------------------------------------
rbt_print_u8:
        sta     rbt_hl
        lda     #0
        sta     rbt_hl+1
rbt_print_u16:
        lda     #0
        sta     rbt_pstart      ; bit7 = printing has started
        lda     #<10000
        sta     rbt_de
        lda     #>10000
        sta     rbt_de+1
        jsr     rbt_prdiv
        lda     #<1000
        sta     rbt_de
        lda     #>1000
        sta     rbt_de+1
        jsr     rbt_prdiv
        lda     #<100
        sta     rbt_de
        lda     #>100
        sta     rbt_de+1
        jsr     rbt_prdiv
        lda     #<10
        sta     rbt_de
        lda     #>10
        sta     rbt_de+1
        jsr     rbt_prdiv
        lda     #1
        sta     rbt_de
        lda     #0
        sta     rbt_de+1
        lda     #$80            ; units digit always prints
        sta     rbt_pstart
        jsr     rbt_prdiv
        rts

; rbt_prdiv - one decimal digit: count rbt_de subtractions from rbt_hl.
rbt_prdiv:
        ldx     #0
@dl:    jsr     rbt_cmp16       ; C = 1 iff hl >= de
        bcc     @show
        jsr     rbt_sub16
        inx
        jmp     @dl
@show:  txa
        bne     @dig
        bit     rbt_pstart
        bpl     @done           ; leading zero, suppress
@dig:   lda     #$80
        sta     rbt_pstart
        txa
        ora     #'0'
        jsr     rbt_putchar
@done:  rts

; ----------------------------------------------------------------------------
; rbt_ink / rbt_paper / rbt_bright / rbt_flash - modify rbt_attr / $D021.
; A = value. C64 colour RAM is a nibble per cell: INK picks the nibble,
; BRIGHT adds 8 (lighter variant), FLASH sets bit7 -> reverse video.
; PAPER is the global background $D021 — C64 text cells have no per-cell
; background, so it takes effect immediately.
; ----------------------------------------------------------------------------
rbt_ink:
        and     #$0f
        sta     rbt_t0
        lda     rbt_attr
        and     #$f0
        ora     rbt_t0
        sta     rbt_attr
        rts

rbt_paper:
        and     #$0f
        jsr     rbt_mapio       ; preserves A
        sta     $d021
        jsr     rbt_maprun
        sta     rbt_papn        ; bitmap matrix pairs ink<<4 with this
        rts

rbt_bright:
        and     #1
        beq     @off
        lda     rbt_attr
        ora     #$08
        bne     @set            ; always taken
@off:   lda     rbt_attr
        and     #$f7
@set:   sta     rbt_attr
        rts

rbt_flash:
        and     #1
        beq     @off
        lda     rbt_attr
        ora     #$80
        bne     @set            ; always taken
@off:   lda     rbt_attr
        and     #$7f
@set:   sta     rbt_attr
        rts

; ----------------------------------------------------------------------------
; rbt_fillattr - fill a cell rectangle with the current colours.
; Text mode: colour RAM nibbles at $D800. Bitmap mode: the hires colour
; matrix at $7C00 holds ink<<4|paper per cell. In: B=x, C=y, D=w, E=h.
; ----------------------------------------------------------------------------
rbt_fillattr:
        lda     rbt_e
        beq     @done
        ; base hi + fill byte by screen mode
        ldx     #$d8
        lda     rbt_attr
        and     #$0f
        ldy     rbt_smode
        beq     @cfg
        ldx     #$7c            ; hires matrix at $7C00
        asl                     ; ink nibble -> hi nibble
        asl
        asl
        asl
        ora     rbt_papn
@cfg:   stx     rbt_t1          ; base hi ($D8/$7C)
        sta     rbt_t0          ; fill byte
        lda     rbt_t1
        cmp     #$d8
        bne     @row            ; $7C00 hires matrix is ordinary RAM
        jsr     rbt_mapio       ; $D800 colour RAM is in the I/O window
@row:   ; rbt_ptr = base + y*40 + x
        lda     rbt_c
        sta     rbt_ptr
        lda     #0
        sta     rbt_ptr+1
        asl     rbt_ptr         ; y*2
        rol     rbt_ptr+1
        asl     rbt_ptr         ; y*4
        rol     rbt_ptr+1
        asl     rbt_ptr         ; y*8
        rol     rbt_ptr+1
        lda     rbt_ptr
        sta     rbt_t2          ; stash y*8
        lda     rbt_ptr+1
        sta     rbt_t2+1
        asl     rbt_ptr         ; y*16
        rol     rbt_ptr+1
        asl     rbt_ptr         ; y*32
        rol     rbt_ptr+1
        clc
        lda     rbt_ptr         ; y*40
        adc     rbt_t2
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t2+1
        sta     rbt_ptr+1
        clc
        lda     rbt_ptr
        adc     rbt_b
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t1          ; base hi ($D8/$7C)
        sta     rbt_ptr+1
        ; fill rbt_d cells
        lda     rbt_t0
        ldy     #0
@fc:    sta     (rbt_ptr),y
        iny
        cpy     rbt_d
        bcc     @fc
        inc     rbt_c
        dec     rbt_e
        bne     @row
        lda     rbt_t1
        cmp     #$d8
        bne     @done
        jsr     rbt_maprun
@done:  rts
