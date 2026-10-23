; ============================================================================
; rbt_spcoll - sprite <-> tilemap collision bridge (Commodore 64, ca65)
; Requires BOTH the sprite module (rbt_slot) and the tilemap module
; (rbt_tm_* vars, rbt_tm_mapat, rbt_ct_* scratch).
; ============================================================================

        .code

; ----------------------------------------------------------------------------
; rbt_colltile - A = sprite id -> A = flags of first solid tile overlapped
; (0 = none). Cell range comes from the slot's logical pixel bbox; sprite
; cells outside the tile view are skipped, then map coords = camera +
; (cell - view origin), same contract as the ZX engine.
; ----------------------------------------------------------------------------
rbt_colltile:
        jsr     rbt_slot        ; ptr = slot
        ldy     #0
        lda     (rbt_ptr),y
        and     #1
        bne     @live
        jmp     @none           ; inactive -> no collision
@live:
        ; c0 = x>>3, c1 = (x+w-1)>>3
        ldy     #1
        lda     (rbt_ptr),y     ; x
        lsr
        lsr
        lsr
        sta     rbt_ct_c0
        ldy     #1
        lda     (rbt_ptr),y     ; x
        ldy     #3
        clc
        adc     (rbt_ptr),y     ; x+w (w<=24, x<=255 -> may wrap; clamp)
        bcc     @nw
        lda     #$ff
@nw:    sec
        sbc     #1              ; x+w-1
        lsr
        lsr
        lsr
        sta     rbt_ct_c1
        ; r0 = y>>3, r1 = (y+h-1)>>3
        ldy     #2
        lda     (rbt_ptr),y     ; y
        lsr
        lsr
        lsr
        sta     rbt_ct_r0
        ldy     #2
        lda     (rbt_ptr),y
        ldy     #4
        clc
        adc     (rbt_ptr),y     ; y+h
        bcc     @nh
        lda     #$ff
@nh:    sec
        sbc     #1
        lsr
        lsr
        lsr
        sta     rbt_ct_r1
        ; loop rows r0..r1
        lda     rbt_ct_r0
        sta     rbt_ct_r
@cr:    lda     rbt_ct_c0
        sta     rbt_ct_c
@cc:    ; inside view?
        lda     rbt_ct_c
        cmp     rbt_tm_vx
        bcc     @cskip
        lda     rbt_tm_vx
        clc
        adc     rbt_tm_vw
        cmp     rbt_ct_c
        beq     @cskip
        bcc     @cskip
        lda     rbt_ct_r
        cmp     rbt_tm_vy
        bcc     @cskip
        lda     rbt_tm_vy
        clc
        adc     rbt_tm_vh
        cmp     rbt_ct_r
        beq     @cskip
        bcc     @cskip
        ; map coords: mx = camx + c - vx, my = camy + r - vy
        clc
        lda     rbt_tm_camx
        adc     rbt_ct_c
        sec
        sbc     rbt_tm_vx
        sta     rbt_b
        clc
        lda     rbt_tm_camy
        adc     rbt_ct_r
        sec
        sbc     rbt_tm_vy
        sta     rbt_c
        jsr     rbt_tm_mapat    ; A = tile (0 when out of map)
        jsr     rbt_tileflags   ; A = flags byte
        sta     rbt_t0
        and     #1
        beq     @cskip
        lda     rbt_t0          ; solid -> return its flags
        rts
@cskip: inc     rbt_ct_c
        lda     rbt_ct_c
        cmp     rbt_ct_c1
        bcc     @cc
        beq     @cc             ; c <= c1: keep scanning the row
        inc     rbt_ct_r
        lda     rbt_ct_r
        cmp     rbt_ct_r1
        bcc     @cr
        beq     @cr             ; r <= r1: next row
@none:  lda     #0
        rts
