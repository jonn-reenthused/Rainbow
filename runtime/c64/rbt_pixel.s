; ============================================================================
; rbt_pixel - hires bitmap pixel ops + SHOWPIC (Commodore 64, ca65)
;
; MODE 1 (rbt_scrmode, in core) switches the VIC to bank 1 and hires
; bitmap mode:
;   bitmap        $4000 (8000 bytes, 320x200, 1bpp)
;   colour matrix $7C00 (1000 bytes, fg<<4|bg per 8x8 cell)
;   sprite pool   $7800 (mux relocates automatically via rbt_sppool)
;   sprite ptrs   $7FF8 (matrix+$3F8 — the mux writes both tables)
;
; Logical coords match the other targets: x 0-255, y 0-191, top-left of
; the 320x200 hires area (the CPC port makes the same choice). PLOT/
; POINT/LINE write the bitmap regardless of mode — they're only visible
; in MODE 1.
;
; SHOWPIC "name": .rbc assets are re-encoded by the build to the cbm
; layout — 8000 bitmap bytes (hires y-linear) then 1000 matrix bytes —
; and rbt_showpic switches to bitmap mode and blits them.
; ============================================================================

        .zeropage
rbt_lx:         .res 1          ; LINE endpoint x
rbt_ly:         .res 1          ; LINE endpoint y
rbt_ldx:        .res 1          ; |dx|
rbt_ldy:        .res 1          ; |dy|
rbt_lsx:        .res 1          ; x step (+1/-1)
rbt_lsy:        .res 1          ; y step (+1/-1)
rbt_lerr:       .res 1          ; Bresenham error (signed 8-bit)
rbt_le2:        .res 1          ; 2*err
        .code

; ----------------------------------------------------------------------------
; rbt_pix - pixel address. In: rbt_c = x, rbt_b = y. Out: rbt_ptr =
; bitmap byte, rbt_t1 = bit mask ($80 >> x&7).
; Clobbers A/X, rbt_ptr, rbt_t1, rbt_t2.
;
; addr = $4000 + (y&$F8)*40 + (x&$F8) + (y&7)
; ----------------------------------------------------------------------------
rbt_bitmask:    .byte $80,$40,$20,$10,$08,$04,$02,$01

rbt_pix:
        lda     rbt_b
        and     #$f8            ; t = y&$F8 (0..184)
        sta     rbt_ptr
        lda     #0
        sta     rbt_ptr+1
        asl     rbt_ptr         ; t*8
        rol     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1
        lda     rbt_ptr         ; stash t*8
        sta     rbt_t2
        lda     rbt_ptr+1
        sta     rbt_t2+1
        asl     rbt_ptr         ; t*32
        rol     rbt_ptr+1
        asl     rbt_ptr
        rol     rbt_ptr+1
        clc
        lda     rbt_ptr         ; t*32 + t*8 = t*40
        adc     rbt_t2
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     rbt_t2+1
        sta     rbt_ptr+1
        lda     rbt_c
        and     #$f8            ; + x&$F8
        clc
        adc     rbt_ptr
        sta     rbt_ptr
        bcc     @n1
        inc     rbt_ptr+1
@n1:    lda     rbt_b
        and     #$07            ; + y&7
        clc
        adc     rbt_ptr
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #$40            ; + $4000 (carry in from the add)
        sta     rbt_ptr+1
        lda     rbt_c
        and     #$07
        tax
        lda     rbt_bitmask,x
        sta     rbt_t1          ; bit mask
        rts

; ----------------------------------------------------------------------------
; rbt_plot - plot pixel (x=C, y=B). Honours rbt_over (nonzero = invert).
; ----------------------------------------------------------------------------
rbt_plot:
        jsr     rbt_pix
        ldy     #0
        ldx     rbt_over
        beq     @set
        lda     (rbt_ptr),y
        eor     rbt_t1
        jmp     @wr
@set:   lda     (rbt_ptr),y
        ora     rbt_t1
@wr:    sta     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_point - test pixel (x=C, y=B). Out: A = 1 set, 0 clear
; ----------------------------------------------------------------------------
rbt_point:
        jsr     rbt_pix
        ldy     #0
        lda     (rbt_ptr),y
        and     rbt_t1
        beq     @no
        lda     #1
        rts
@no:    lda     #0
        rts

; ----------------------------------------------------------------------------
; rbt_line - draw a line from (C,B) to (rbt_lx,rbt_ly), Bresenham.
; rbt_over honoured via rbt_plot. err is a signed byte: runs over ~127px
; can quantise but the loop still terminates.
; ----------------------------------------------------------------------------
rbt_line:
        ; dx = |lx - x|, sx = sign
        lda     rbt_lx
        sec
        sbc     rbt_c
        bpl     @dxp
        eor     #$ff
        clc
        adc     #1
@dxp:   sta     rbt_ldx
        lda     rbt_lx
        cmp     rbt_c
        lda     #1
        bcs     @sx
        lda     #$ff
@sx:    sta     rbt_lsx
        ; dy = |ly - y|, sy = sign
        lda     rbt_ly
        sec
        sbc     rbt_b
        bpl     @dyp
        eor     #$ff
        clc
        adc     #1
@dyp:   sta     rbt_ldy
        lda     rbt_ly
        cmp     rbt_b
        lda     #1
        bcs     @sy
        lda     #$ff
@sy:    sta     rbt_lsy
        ; err = dx - dy
        lda     rbt_ldx
        sec
        sbc     rbt_ldy
        sta     rbt_lerr
@loop:  jsr     rbt_plot        ; plot (C,B)
        lda     rbt_lx
        cmp     rbt_c
        bne     @step
        lda     rbt_ly
        cmp     rbt_b
        beq     @done
@step:  lda     rbt_lerr
        asl                     ; e2 = 2*err (signed)
        sta     rbt_le2
        ; x step iff e2 > -dy: skip iff -dy >= e2. Signed compares via
        ; the eor #$80 bias (signed(a)>=signed(b) <=> a^$80 >= b^$80).
        lda     rbt_le2
        eor     #$80
        sta     rbt_t0          ; mem = biased e2
        lda     rbt_ldy
        eor     #$ff
        clc
        adc     #1              ; -dy
        eor     #$80            ; A = biased -dy
        cmp     rbt_t0          ; C iff -dy >= e2
        bcs     @skipx
        lda     rbt_lerr
        sec
        sbc     rbt_ldy         ; err -= dy
        sta     rbt_lerr
        lda     rbt_c
        clc
        adc     rbt_lsx         ; x += sx
        sta     rbt_c
@skipx: ; y step iff e2 < dx: skip iff e2 >= dx (signed)
        lda     rbt_ldx
        eor     #$80
        sta     rbt_t0          ; mem = biased dx
        lda     rbt_le2
        eor     #$80            ; A = biased e2
        cmp     rbt_t0          ; C iff e2 >= dx
        bcs     @skipy
        lda     rbt_lerr
        clc
        adc     rbt_ldx         ; err += dx
        sta     rbt_lerr
        lda     rbt_b
        clc
        adc     rbt_lsy         ; y += sy
        sta     rbt_b
@skipy: jmp     @loop
@done:  rts

; ----------------------------------------------------------------------------
; rbt_showpic - rbt_hl -> cbm screen payload (8000 bitmap + 1000 matrix).
; Switches to hires bitmap mode and blits.
; ----------------------------------------------------------------------------
rbt_showpic:
        lda     #1
        jsr     rbt_scrmode
        ; src -> rbt_ptr, dst $4000 -> rbt_hl
        lda     rbt_hl
        sta     rbt_ptr
        lda     rbt_hl+1
        sta     rbt_ptr+1
        lda     #$00
        sta     rbt_hl
        lda     #$40
        sta     rbt_hl+1
        ldx     #31             ; 31 pages + 64 bytes = 8000
        ldy     #0
@p:     lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @p
        inc     rbt_ptr+1
        inc     rbt_hl+1
        dex
        bne     @p
        ldy     #63
@t:     lda     (rbt_ptr),y
        sta     (rbt_hl),y
        dey
        bpl     @t
        lda     rbt_ptr         ; src -> matrix bytes (7936 + 64 = 8000)
        clc
        adc     #64
        sta     rbt_ptr
        bcc     @nm
        inc     rbt_ptr+1
@nm:    lda     #$00
        sta     rbt_hl
        lda     #$7c
        sta     rbt_hl+1        ; dst = $7C00 matrix
        ldx     #3              ; 3 pages + 232 = 1000
        ldy     #0
@p2:    lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @p2
        inc     rbt_ptr+1
        inc     rbt_hl+1
        dex
        bne     @p2
        ldy     #0
@t2:    lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        cpy     #232
        bne     @t2
        rts
