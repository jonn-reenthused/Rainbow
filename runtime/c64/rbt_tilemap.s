; ============================================================================
; rbt_tilemap - text-mode tilemap engine (Commodore 64, ca65)
;
; On the C64 the screen IS a tilemap: a tile is an 8x8 character cell.
; TILESET copies the .rbt bitmaps into charset RAM at screen codes 128+
; ($3C00, charset base $3800), so TILEMAP DRAW writes tile indices straight
; to screen RAM ($0400) and the tile's colour nibble to colour RAM ($D800).
;
; To keep text rendering intact TILESET first fills charset RAM from the
; chargen ROM when no custom font is bound (rbt_font == 0); a bound font
; already covers every text code 0-63, so only the tile glyphs go in.
; Consequence: reverse-video text (FLASH/OVER set) collides with tile
; glyphs — a documented limitation of the shared charset.
;
; .rbt binary: defb n; n*8 bitmaps; n attrs; n flags  (n clamped to 128)
; .rbm binary: defb w,h; w*h tile indices row-major
;
; Register contract (matches the Z80 engine): byte args in rbt_b/c/d/e,
; pointers in rbt_hl; routines clobber A/X/Y and all rbt_ regs.
; ============================================================================

RBT_TM_CODEBASE = $80           ; tile i -> screen code $80+i

        .code

; ----------------------------------------------------------------------------
; rbt_tm_settiles - rbt_hl = tileset data. Parses the tables and copies tile
; bitmaps into charset RAM.
; ----------------------------------------------------------------------------
rbt_tm_settiles:
        lda     rbt_hl
        sta     rbt_tm_tiles
        lda     rbt_hl+1
        sta     rbt_tm_tiles+1
        ; rbt_tm_bmp = tiles+1
        clc
        lda     rbt_hl
        adc     #1
        sta     rbt_tm_bmp
        lda     rbt_hl+1
        adc     #0
        sta     rbt_tm_bmp+1
        ; n = tiles[0], clamped to 128
        ldy     #0
        lda     (rbt_hl),y
        cmp     #129
        bcc     @nok
        lda     #128
@nok:   sta     rbt_tm_n
        ; rbt_tm_tattr = bmp + n*8; tflags = tattr + n
        sta     rbt_t0
        sta     rbt_de
        lda     #0
        sta     rbt_de+1
        asl     rbt_de
        rol     rbt_de+1        ; *2
        asl     rbt_de
        rol     rbt_de+1        ; *4
        asl     rbt_de
        rol     rbt_de+1        ; de = n*8
        clc
        lda     rbt_tm_bmp
        adc     rbt_de
        sta     rbt_tm_tattr
        lda     rbt_tm_bmp+1
        adc     rbt_de+1
        sta     rbt_tm_tattr+1
        clc
        lda     rbt_tm_tattr
        adc     rbt_t0
        sta     rbt_tm_tflags
        lda     rbt_tm_tattr+1
        adc     #0
        sta     rbt_tm_tflags+1

        ; --- populate charset RAM from the chargen ROM ---
        ; CHAREN=0 maps the chargen ROM over $D000-$DFFF for CPU reads.
        ; Only needed when no custom font is bound — a bound font already
        ; covers every text code (0-63), and copying chargen codes 0-31
        ; over $3800-$38FF would clobber its letter glyphs.
        lda     rbt_font
        ora     rbt_font+1
        bne     @tiles          ; font bound: skip chargen copy
        sei
        lda     #$37
        and     #%11111011
        sta     $01
        ldx     #8              ; 8 pages: $D000-$D7FF -> charset RAM
        lda     #$00
        sta     rbt_ptr
        lda     #$d0
        sta     rbt_ptr+1
        lda     #$00
        sta     rbt_hl
        lda     #>RBT_CSET
        sta     rbt_hl+1
@cpg:   ldy     #0
@cpl:   lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @cpl
        inc     rbt_ptr+1
        inc     rbt_hl+1
        dex
        bne     @cpl
        lda     #$37
        sta     $01
        cli
@tiles:

        ; --- tile bitmaps -> charset+$400 (screen codes 128+) ---
        ; count = n*8 bytes; n<=128 so <=4 pages + partial.
        lda     rbt_tm_bmp
        sta     rbt_ptr
        lda     rbt_tm_bmp+1
        sta     rbt_ptr+1
        lda     #$00
        sta     rbt_hl
        lda     #>(RBT_CSET+$400)
        sta     rbt_hl+1
        ldx     rbt_de+1        ; full pages of n*8
        ldy     #0
        cpx     #0
        beq     @rem
@tpg:   lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @tpg
        inc     rbt_ptr+1
        inc     rbt_hl+1
        dex
        bne     @tpg
@rem:   ; remaining de.lo bytes (0..255)
        lda     rbt_de
        beq     @done
        sta     rbt_t0
@rl:    lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        cpy     rbt_t0
        bne     @rl
@done:
        ; VIC: screen + charset bases for the active bank
        lda     #RBT_D018T
        jsr     rbt_mapio       ; preserves A
        sta     $d018
        jsr     rbt_maprun
        sta     rbt_d018        ; text-mode shadow (rbt_scrmode restores it)
        rts

; ----------------------------------------------------------------------------
; rbt_tm_setmap - rbt_hl = map data (defb w,h; cells)
; ----------------------------------------------------------------------------
rbt_tm_setmap:
        ldy     #0
        lda     (rbt_hl),y
        sta     rbt_tm_mw
        iny
        lda     (rbt_hl),y
        sta     rbt_tm_mh
        clc
        lda     rbt_hl
        adc     #2
        sta     rbt_tm_cells
        lda     rbt_hl+1
        adc     #0
        sta     rbt_tm_cells+1
        lda     rbt_hl
        sta     rbt_tm_map
        lda     rbt_hl+1
        sta     rbt_tm_map+1
        ; clamp camera into the map
        jsr     rbt_tm_camclamp
        rts

; ----------------------------------------------------------------------------
; rbt_tm_view - rbt_b=x, rbt_c=y, rbt_d=w, rbt_e=h (screen cells, clamped
; to the 40x25 screen)
; ----------------------------------------------------------------------------
rbt_tm_view:
        lda     rbt_b
        cmp     #40
        bcc     @vxok
        lda     #0
@vxok:  sta     rbt_tm_vx
        lda     rbt_c
        cmp     #25
        bcc     @vyok
        lda     #0
@vyok:  sta     rbt_tm_vy
        ; vw = min(d, 40-vx); clamp 1..40
        lda     #40
        sec
        sbc     rbt_tm_vx
        sta     rbt_t0          ; max w
        lda     rbt_d
        cmp     rbt_t0
        bcc     @wok
        lda     rbt_t0
@wok:   beq     @w1
        cmp     #1
        bcs     @ws
@w1:    lda     #1
@ws:    sta     rbt_tm_vw
        lda     #25
        sec
        sbc     rbt_tm_vy
        sta     rbt_t0
        lda     rbt_e
        cmp     rbt_t0
        bcc     @hok
        lda     rbt_t0
@hok:   beq     @h1
        cmp     #1
        bcs     @hs
@h1:    lda     #1
@hs:    sta     rbt_tm_vh
        ; raster window for the scroll's beam-safe shift (row r of the
        ; text screen starts at line 50+r*8)
        lda     rbt_tm_vy
        asl
        asl
        asl
        clc
        adc     #50
        sta     rbt_tm_vbt
        lda     rbt_tm_vh
        asl
        asl
        asl
        clc
        adc     rbt_tm_vbt
        sta     rbt_tm_vbb
        rts

; ----------------------------------------------------------------------------
; rbt_tm_camera - rbt_b=cx, rbt_c=cy (map cells); clamped so the view
; stays inside the map.
; ----------------------------------------------------------------------------
rbt_tm_camera:
        lda     rbt_b
        sta     rbt_tm_camx
        lda     rbt_c
        sta     rbt_tm_camy
rbt_tm_camclamp:
        ; camx <= mw-vw (or 0 when the map is narrower than the view)
        sec
        lda     rbt_tm_mw
        sbc     rbt_tm_vw
        bcs     @mx
        lda     #0
@mx:    cmp     rbt_tm_camx
        bcs     @cxok
        sta     rbt_tm_camx
@cxok:  sec
        lda     rbt_tm_mh
        sbc     rbt_tm_vh
        bcs     @my
        lda     #0
@my:    cmp     rbt_tm_camy
        bcs     @cyok
        sta     rbt_tm_camy
@cyok:  rts

; ----------------------------------------------------------------------------
; rbt_tm_blit - draw tile A at screen cell rbt_b=x, rbt_c=y.
; ----------------------------------------------------------------------------
rbt_tm_blit:
        sta     rbt_t0          ; tile index
        ; rbt_ptr = $0400 + y*40 + x   (y*40 = y*32 + y*8)
        lda     rbt_c
        sta     rbt_t2
        lda     #0
        sta     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1        ; t2 = y*8
        lda     rbt_t2
        sta     rbt_ptr
        lda     rbt_t2+1
        sta     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1       ; ptr = y*32
        clc
        lda     rbt_ptr
        adc     rbt_t2
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t2+1
        sta     rbt_ptr+1       ; ptr = y*40
        clc
        lda     rbt_ptr
        adc     rbt_b
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #>RBT_SCRN
        sta     rbt_ptr+1       ; ptr = screen cell addr
        ; screen code
        ldy     #0
        lda     rbt_t0
        cmp     rbt_tm_n
        bcc     @valid
        lda     #32             ; out-of-range tile -> space
        bne     @wr
@valid: clc
        adc     #RBT_TM_CODEBASE
@wr:    sta     (rbt_ptr),y
        ; colour cell = ptr + RBT_CDELTA
        lda     rbt_ptr
        sta     rbt_t2
        lda     rbt_ptr+1
        clc
        adc     #>RBT_CDELTA
        sta     rbt_t2+1
        lda     rbt_t0
        cmp     rbt_tm_n
        bcc     @cok
        lda     rbt_attr        ; invalid tile: current ink
        bne     @cw
@cok:   ; colour = tattr[tile] & $0f
        clc
        lda     rbt_tm_tattr
        adc     rbt_t0
        sta     rbt_bc
        lda     rbt_tm_tattr+1
        adc     #0
        sta     rbt_bc+1
        lda     (rbt_bc),y      ; y is still 0
@cw:    and     #$0f
        sta     (rbt_t2),y
        rts

; ----------------------------------------------------------------------------
; rbt_tm_draw - draw the whole view window from the map
; ----------------------------------------------------------------------------
rbt_tm_draw:
        lda     #0
        sta     rbt_tm_r
@rloop: lda     #0
        sta     rbt_tm_c
@cloop: ; map coords (camx+c, camy+r)
        clc
        lda     rbt_tm_camx
        adc     rbt_tm_c
        sta     rbt_b
        clc
        lda     rbt_tm_camy
        adc     rbt_tm_r
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_tm_tid
        ; screen coords (vx+c, vy+r)
        clc
        lda     rbt_tm_vx
        adc     rbt_tm_c
        sta     rbt_b
        clc
        lda     rbt_tm_vy
        adc     rbt_tm_r
        sta     rbt_c
        lda     rbt_tm_tid
        jsr     rbt_tm_blit
        inc     rbt_tm_c
        lda     rbt_tm_c
        cmp     rbt_tm_vw
        bcc     @cloop
        inc     rbt_tm_r
        lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcc     @rloop
        rts

; ----------------------------------------------------------------------------
; rbt_tm_redraw - rbt_b=x, rbt_c=y, rbt_d=w, rbt_e=h: repair a screen-cell
; rect (clipped to the view) from the map.
; ----------------------------------------------------------------------------
rbt_tm_redraw:
        ; clip rect to the view: x0..x1, y0..y1 in rbt_tm_r0-style temps
        lda     rbt_b
        sta     rbt_tm_tid      ; x0 (absolute screen col)
        lda     rbt_c
        sta     rbt_tm_cnt      ; y0
        clc
        lda     rbt_b
        adc     rbt_d
        sta     rbt_tm_dir      ; x1 (exclusive)
        clc
        lda     rbt_c
        adc     rbt_e
        sta     rbt_tm_steps    ; y1 (exclusive)
        ; clip x0,y0 up to view origin; x1,y1 down to view end
        lda     rbt_tm_tid
        cmp     rbt_tm_vx
        bcs     @x0ok
        lda     rbt_tm_vx
        sta     rbt_tm_tid
@x0ok:  lda     rbt_tm_cnt
        cmp     rbt_tm_vy
        bcs     @y0ok
        lda     rbt_tm_vy
        sta     rbt_tm_cnt
@y0ok:  clc
        lda     rbt_tm_vx
        adc     rbt_tm_vw
        cmp     rbt_tm_dir
        bcs     @x1ok
        sta     rbt_tm_dir
@x1ok:  clc
        lda     rbt_tm_vy
        adc     rbt_tm_vh
        cmp     rbt_tm_steps
        bcs     @y1ok
        sta     rbt_tm_steps
@y1ok:  ; r = y0..y1-1
        lda     rbt_tm_cnt
        sta     rbt_tm_r
@rl:    lda     rbt_tm_r
        cmp     rbt_tm_steps
        bcs     @rdone
        lda     rbt_tm_tid
        sta     rbt_tm_c
@cl:    lda     rbt_tm_c
        cmp     rbt_tm_dir
        bcs     @cdone
        ; map coords = camx + (c - vx), camy + (r - vy)
        sec
        lda     rbt_tm_c
        sbc     rbt_tm_vx
        clc
        adc     rbt_tm_camx
        sta     rbt_b
        sec
        lda     rbt_tm_r
        sbc     rbt_tm_vy
        clc
        adc     rbt_tm_camy
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_t0
        lda     rbt_tm_c
        sta     rbt_b
        lda     rbt_tm_r
        sta     rbt_c
        lda     rbt_t0
        jsr     rbt_tm_blit
        inc     rbt_tm_c
        jmp     @cl
@cdone: inc     rbt_tm_r
        jmp     @rl
@rdone: rts

; ----------------------------------------------------------------------------
; rbt_tm_scroll - A = dir (0=left,1=right,2=up,3=down), rbt_b = steps.
; Moves the camera one cell per step, shifts the view's screen+colour
; bytes and draws only the newly exposed edge.
; ----------------------------------------------------------------------------
rbt_tm_scroll:
        and     #3
        sta     rbt_tm_dir
        lda     rbt_b
        beq     @done
        sta     rbt_tm_steps
@step:  jsr     _tm_shift       ; move camera + shift + draw edge
        dec     rbt_tm_steps
        bne     @step
@done:  rts

; _tm_shift: one scroll step for rbt_tm_dir.
_tm_shift:
        jsr     _tm_beam        ; shift inside the beam-safe window
        lda     rbt_tm_dir
        cmp     #0
        bne     @n0
        jmp     _left
@n0:    cmp     #1
        bne     @n1
        jmp     _right
@n1:    cmp     #2
        bne     @n2
        jmp     _up
@n2:    jmp     _down

; --- helpers ---------------------------------------------------------------

; _rowbase: rbt_c = absolute screen row -> rbt_ptr = $0400+row*40+vx,
; rbt_t2 = same in colour RAM ($D800+...).
_rowbase:
        lda     rbt_c
        sta     rbt_t2
        lda     #0
        sta     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1
        asl     rbt_t2
        rol     rbt_t2+1        ; t2 = row*8
        lda     rbt_t2
        sta     rbt_ptr
        lda     rbt_t2+1
        sta     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1       ; ptr = row*32
        clc
        lda     rbt_ptr
        adc     rbt_t2
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t2+1
        sta     rbt_ptr+1       ; ptr = row*40
        clc
        lda     rbt_ptr
        adc     rbt_tm_vx
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #>RBT_SCRN
        sta     rbt_ptr+1       ; ptr = screen addr of view cell (vx,row)
        lda     rbt_ptr
        sta     rbt_t2
        lda     rbt_ptr+1
        clc
        adc     #>RBT_CDELTA
        sta     rbt_t2+1        ; t2 = colour addr
        rts

; _tm_beam - wait until the raster is outside the view band (below its
; bottom edge or above its top) so the shift can't tear mid-row. Striker-
; style callers scroll right after HALT, so this almost never waits; a
; mid-frame SCROLL stalls to the border instead of shearing.
_tm_beam:
        .if RBT_C128
        jsr     rbt_mapio       ; $d011/$d012 live in the I/O window
        .endif
@w:     lda     $d011
        bmi     @go             ; raster > 255: below every legal view
        lda     $d012
        cmp     rbt_tm_vbb
        bcs     @go             ; below the view bottom
        cmp     rbt_tm_vbt
        bcc     @go             ; above the view top
        jmp     @w
@go:
        .if RBT_C128
        jmp     rbt_maprun
        .else
        rts
        .endif

; --- fast view shift --------------------------------------------------------
; The old (zp),y shift cost ~38c per screen+colour cell (~22K cycles for a
; 32x18 view — a whole frame). These blocks use unrolled absolute-indexed
; copies at ~16c per cell: X carries the row's byte offset, and since a
; 1K span needs four 256-byte pages there's one block per page, dispatched
; through the _shX_tab tables. Content-right and row-copy blocks execute
; descending and are entered mid-block at (width gap)*12; content-left must
; run ascending, so _right patches an exit RTS at (vw-1)*12 before the row
; loop and restores it after.

.macro  shlblk  g
        .repeat 31, I
        lda     RBT_SCRN+g*$100+I+1,x
        sta     RBT_SCRN+g*$100+I,x
        lda     RBT_SCRN+RBT_CDELTA+g*$100+I+1,x
        sta     RBT_SCRN+RBT_CDELTA+g*$100+I,x
        .endrepeat
        rts
.endmacro

.macro  shrblk  g
        .repeat 31, I
        lda     RBT_SCRN+g*$100+30-I,x
        sta     RBT_SCRN+g*$100+31-I,x
        lda     RBT_SCRN+RBT_CDELTA+g*$100+30-I,x
        sta     RBT_SCRN+RBT_CDELTA+g*$100+31-I,x
        .endrepeat
        rts
.endmacro

_shl_b0:        shlblk  0
_shl_b1:        shlblk  1
_shl_b2:        shlblk  2
_shl_b3:        shlblk  3
_shr_b0:        shrblk  0
_shr_b1:        shrblk  1
_shr_b2:        shrblk  2
_shr_b3:        shrblk  3

_shl_tab:       .word _shl_b0, _shl_b1, _shl_b2, _shl_b3
_shr_tab:       .word _shr_b0, _shr_b1, _shr_b2, _shr_b3

; _offjmp - rbt_t2 += A*12 then jmp (rbt_t2). X preserved.
_offjmp:
        sta     rbt_t0
        asl
        asl                     ; t*4 (t<=40 -> <256)
        sta     rbt_t1
        lda     rbt_t0
        asl
        asl
        asl                     ; t*8 lo
        sta     rbt_bc
        lda     #0
        rol                     ; t*8 hi
        tay
        clc
        lda     rbt_bc
        adc     rbt_t1          ; t*12 lo
        bcc     @n1
        iny
@n1:    clc
        adc     rbt_t2
        sta     rbt_t2
        tya
        adc     rbt_t2+1
        sta     rbt_t2+1
        jmp     (rbt_t2)

; _shlpatch - plant an exit RTS at (vw-1)*12 in every shl block. A = 0
; restores the saved bytes instead.
_shlpatch:
        sta     rbt_t1          ; 0 = restore
        lda     rbt_tm_vw
        sec
        sbc     #1              ; t = vw-1 (<=39)
        sta     rbt_t0
        asl
        asl                     ; t*4
        sta     rbt_bc
        lda     rbt_t0
        asl
        asl
        asl                     ; t*8 lo
        sta     rbt_t0
        lda     #0
        rol                     ; t*8 hi
        sta     rbt_t2+1
        clc
        lda     rbt_t0
        adc     rbt_bc
        sta     rbt_t2          ; offset lo
        lda     rbt_t2+1
        adc     #0
        sta     rbt_t2+1        ; offset hi
        ldx     #0
@pl:    txa
        asl
        tay
        clc
        lda     _shl_tab,y
        adc     rbt_t2
        sta     rbt_ptr
        lda     _shl_tab+1,y
        adc     rbt_t2+1
        sta     rbt_ptr+1
        ldy     #0
        lda     rbt_t1
        beq     @rs
        lda     (rbt_ptr),y
        sta     rbt_tm_sv,x
        lda     #$60            ; rts
        bne     @st
@rs:    lda     rbt_tm_sv,x
@st:    sta     (rbt_ptr),y
        inx
        cpx     #4
        bcc     @pl
        rts

; _shrow - shift one view row horizontally. rbt_tm_cnt: 0 = content right
; (descending mid-block entry), 1 = content left (top entry, exit-patched).
; rbt_ptr = screen addr of the row's first view cell.
_shrow:
        ldx     rbt_ptr         ; row byte offset lo (SCRN is page-aligned)
        lda     rbt_ptr+1
        sec
        sbc     #>RBT_SCRN      ; page group 0-3
        asl
        tay
        lda     rbt_tm_cnt
        bne     @lft
        lda     _shr_tab,y
        sta     rbt_t2
        lda     _shr_tab+1,y
        sta     rbt_t2+1
        lda     #32
        sec
        sbc     rbt_tm_vw
        jmp     _offjmp
@lft:   lda     _shl_tab,y
        sta     rbt_t2
        lda     _shl_tab+1,y
        sta     rbt_t2+1
        lda     #0
        jmp     _offjmp

; _vrow - copy one view row's bytes vertically (dual-pointer zp loop —
; the hot path is horizontal scrolling; this stays simple). rbt_ptr/t2 =
; src row, rbt_bc/rbt_hl = dst row.
_vrow:
        ldy     #0
@l:     lda     (rbt_ptr),y
        sta     (rbt_bc),y
        lda     (rbt_t2),y
        sta     (rbt_hl),y
        iny
        cpy     rbt_tm_vw
        bcc     @l
        rts

; --- scroll directions -----------------------------------------------------

_left:  ; camera left (content shifts right), new column = left edge
        lda     rbt_tm_camx
        beq     @done           ; at map edge: nothing moves
        dec     rbt_tm_camx
        ; shift all view rows right
        lda     #0
        sta     rbt_tm_r
@rows:  lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcs     @edge
        clc
        adc     rbt_tm_vy
        sta     rbt_c
        lda     #0
        sta     rbt_tm_cnt      ; 0 = shift right
        jsr     _rowbase
        jsr     _shrow
        inc     rbt_tm_r
        bne     @rows
@edge:  ; draw new left column
        lda     #0
        sta     rbt_tm_r
@ecl:   lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcs     @done
        lda     rbt_tm_camx
        sta     rbt_b
        clc
        lda     rbt_tm_camy
        adc     rbt_tm_r
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_t0
        lda     rbt_tm_vx
        sta     rbt_b
        clc
        lda     rbt_tm_vy
        adc     rbt_tm_r
        sta     rbt_c
        lda     rbt_t0
        jsr     rbt_tm_blit
        inc     rbt_tm_r
        bne     @ecl
@done:  rts

_right: ; camera right (content shifts left), new column = right edge
        sec
        lda     rbt_tm_mw
        sbc     rbt_tm_vw
        bcs     @lim
        lda     #0
@lim:   cmp     rbt_tm_camx
        beq     @done           ; at map edge: nothing moves
        bcc     @done
        inc     rbt_tm_camx
        lda     #1
        jsr     _shlpatch       ; exit-patched left-shift blocks
        lda     #0
        sta     rbt_tm_r
@rows:  lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcs     @x
        clc
        adc     rbt_tm_vy
        sta     rbt_c
        lda     #1
        sta     rbt_tm_cnt      ; 1 = shift left
        jsr     _rowbase
        jsr     _shrow
        inc     rbt_tm_r
        bne     @rows
@x:     lda     #0
        jsr     _shlpatch       ; restore the patched exit
@edge:  lda     #0
        sta     rbt_tm_r
@ecl:   lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcs     @done
        clc
        lda     rbt_tm_camx
        adc     rbt_tm_vw
        sec
        sbc     #1
        sta     rbt_b
        clc
        lda     rbt_tm_camy
        adc     rbt_tm_r
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_t0
        clc
        lda     rbt_tm_vx
        adc     rbt_tm_vw
        sec
        sbc     #1
        sta     rbt_b
        clc
        lda     rbt_tm_vy
        adc     rbt_tm_r
        sta     rbt_c
        lda     rbt_t0
        jsr     rbt_tm_blit
        inc     rbt_tm_r
        bne     @ecl
@done:  rts

_up:    ; camera up (content shifts down), new row = top edge
        lda     rbt_tm_camy
        bne     @m
        rts                     ; at map edge: nothing moves
@m:     dec     rbt_tm_camy
        ; shift rows down: r = vh-2 downto 0 -> copy row r to r+1
        lda     rbt_tm_vh
        cmp     #2
        bcc     @edge
        sec
        sbc     #2
        sta     rbt_tm_r
@rows:  lda     rbt_tm_r
        bmi     @edge
        ; src row = vy + r, dst = src+1: copy vw cells screen+colour
        clc
        adc     rbt_tm_vy
        sta     rbt_c
        jsr     _rowbase        ; ptr/t2 = src row view start
        clc                     ; dst = src+40 (content moves down)
        lda     rbt_ptr
        adc     #40
        sta     rbt_bc
        lda     rbt_ptr+1
        adc     #0
        sta     rbt_bc+1
        clc
        lda     rbt_t2
        adc     #40
        sta     rbt_hl
        lda     rbt_t2+1
        adc     #0
        sta     rbt_hl+1
        jsr     _vrow
        dec     rbt_tm_r
        jmp     @rows
@edge:  ; draw new top row
        lda     #0
        sta     rbt_tm_c
@ecl:   lda     rbt_tm_c
        cmp     rbt_tm_vw
        bcs     @done
        clc
        lda     rbt_tm_camx
        adc     rbt_tm_c
        sta     rbt_b
        lda     rbt_tm_camy
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_t0
        clc
        lda     rbt_tm_vx
        adc     rbt_tm_c
        sta     rbt_b
        lda     rbt_tm_vy
        sta     rbt_c
        lda     rbt_t0
        jsr     rbt_tm_blit
        inc     rbt_tm_c
        bne     @ecl
@done:  rts

_down:  ; camera down (content shifts up), new row = bottom edge
        sec
        lda     rbt_tm_mh
        sbc     rbt_tm_vh
        bcs     @lim
        lda     #0
@lim:   cmp     rbt_tm_camy
        beq     @xit            ; at map edge: nothing moves
        bcc     @xit
        jmp     @go
@xit:   rts
@go:    inc     rbt_tm_camy
        lda     rbt_tm_vh
        cmp     #2
        bcc     @edge
        ; shift rows up: r = 1..vh-1 -> copy row r to r-1
        lda     #1
        sta     rbt_tm_r
@rows:  lda     rbt_tm_r
        cmp     rbt_tm_vh
        bcs     @edge
        clc
        adc     rbt_tm_vy
        sta     rbt_c
        jsr     _rowbase        ; ptr/t2 = src row view start
        sec                     ; dst = src-40 (content moves up)
        lda     rbt_ptr
        sbc     #40
        sta     rbt_bc
        lda     rbt_ptr+1
        sbc     #0
        sta     rbt_bc+1
        sec
        lda     rbt_t2
        sbc     #40
        sta     rbt_hl
        lda     rbt_t2+1
        sbc     #0
        sta     rbt_hl+1
        jsr     _vrow
        inc     rbt_tm_r
        bne     @rows
@edge:  lda     #0
        sta     rbt_tm_c
@ecl:   lda     rbt_tm_c
        cmp     rbt_tm_vw
        bcs     @done
        clc
        lda     rbt_tm_camx
        adc     rbt_tm_c
        sta     rbt_b
        clc
        lda     rbt_tm_camy
        adc     rbt_tm_vh
        sec
        sbc     #1
        sta     rbt_c
        jsr     rbt_tm_mapat
        sta     rbt_t0
        clc
        lda     rbt_tm_vx
        adc     rbt_tm_c
        sta     rbt_b
        clc
        lda     rbt_tm_vy
        adc     rbt_tm_vh
        sec
        sbc     #1
        sta     rbt_c
        lda     rbt_t0
        jsr     rbt_tm_blit
        inc     rbt_tm_c
        bne     @ecl
@done:  rts

; ----------------------------------------------------------------------------
; rbt_tileat - rbt_b=tx, rbt_c=ty -> A = tile id (255 = out of bounds)
; ----------------------------------------------------------------------------
rbt_tileat:
        lda     rbt_b
        cmp     rbt_tm_mw
        bcs     @oob
        lda     rbt_c
        cmp     rbt_tm_mh
        bcs     @oob
        jmp     rbt_tm_mapat
@oob:   lda     #255
        rts

; ----------------------------------------------------------------------------
; rbt_tileatset - rbt_b=tx, rbt_c=ty, rbt_d=id: write the map cell and
; repaint it when the cell is in view. There's no backdrop compositor on
; this platform (hardware sprites never touch screen RAM) — on ZX/CPC a
; map write under a sprite is picked up by the next SPRITES UPDATE, so
; the blit here is the only repaint a map change gets on C64.
; ----------------------------------------------------------------------------
rbt_tileatset:
        lda     rbt_b
        cmp     rbt_tm_mw
        bcs     @out
        lda     rbt_c
        cmp     rbt_tm_mh
        bcs     @out
        jsr     rbt_tm_mapat    ; rbt_ptr = cell addr (result A unused)
        lda     rbt_d
        ldy     #0
        sta     (rbt_ptr),y
        ; screen cell = view origin + (tx,ty) - camera
        sec
        lda     rbt_b
        sbc     rbt_tm_camx
        bmi     @out
        cmp     rbt_tm_vw
        bcs     @out
        clc
        adc     rbt_tm_vx
        sta     rbt_t0          ; screen x
        sec
        lda     rbt_c
        sbc     rbt_tm_camy
        bmi     @out
        cmp     rbt_tm_vh
        bcs     @out
        clc
        adc     rbt_tm_vy
        sta     rbt_c
        lda     rbt_t0
        sta     rbt_b
        lda     rbt_d
        jmp     rbt_tm_blit     ; draws screen + colour cell, rts to caller
@out:   rts

; ----------------------------------------------------------------------------
; rbt_tileflags - A = tile id -> A = flags byte (0 if out of range)
; ----------------------------------------------------------------------------
rbt_tileflags:
        cmp     rbt_tm_n
        bcc     @in
        lda     #0
        rts
@in:    clc
        adc     rbt_tm_tflags
        sta     rbt_ptr
        lda     rbt_tm_tflags+1
        adc     #0
        sta     rbt_ptr+1
        ldy     #0
        lda     (rbt_ptr),y
        rts
