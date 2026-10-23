; ============================================================================
; rbt_tmdata - tilemap state + map query (Commodore 64, ca65)
; Mirrors runtime/zx/rbt_tmdata.asm minus the bank-page vars — a stock C64
; has no pageable RAM (rbt_tm_tbank/rbt_tm_mbank exist only because the
; emitter stores to them).
; ============================================================================

        .code

rbt_tm_tiles:   .res 2          ; tileset base
rbt_tm_bmp:     .res 2          ; bitmaps (tiles+1)
rbt_tm_tattr:   .res 2          ; attr table (tiles+1+8n)
rbt_tm_tflags:  .res 2          ; flag table (tiles+1+9n)
rbt_tm_n:       .res 1          ; tile count (clamped to 128)
rbt_tm_tbank:   .res 1          ; written by codegen ($ff) — unused
rbt_tm_map:     .res 2          ; map base
rbt_tm_mbank:   .res 1          ; written by codegen ($ff) — unused
rbt_tm_cells:   .res 2          ; map cells (map+2)
rbt_tm_mw:      .res 1          ; map width
rbt_tm_mh:      .res 1          ; map height
rbt_tm_vx:      .res 1          ; view: screen cells
rbt_tm_vy:      .res 1
rbt_tm_vw:      .byte 40
rbt_tm_vh:      .byte 25
rbt_tm_vbt:     .byte 50        ; raster line of the view's top edge
rbt_tm_vbb:     .byte 250       ; raster line of the view's bottom edge
rbt_tm_sv:      .res 4          ; saved bytes for the fast-shift exit patch
rbt_tm_camx:    .res 1          ; camera: map cell at view top-left
rbt_tm_camy:    .res 1
rbt_tm_r:       .res 1          ; row loop temp
rbt_tm_c:       .res 1          ; col loop temp
rbt_tm_dir:     .res 1          ; scroll dir
rbt_tm_steps:   .res 1          ; scroll steps left
rbt_tm_cnt:     .res 1          ; scratch counter
rbt_tm_tid:     .res 1          ; tile-id temp
rbt_ct_c0:      .res 1          ; COLLIDETILE cell-range scratch
rbt_ct_c1:      .res 1
rbt_ct_r0:      .res 1
rbt_ct_r1:      .res 1
rbt_ct_r:       .res 1
rbt_ct_c:       .res 1

; ----------------------------------------------------------------------------
; rbt_tm_mapat - rbt_b=mx, rbt_c=my -> A = tile id (0 when out of bounds).
; ----------------------------------------------------------------------------
rbt_tm_mapat:
        lda     rbt_b
        cmp     rbt_tm_mw
        bcs     @oob
        lda     rbt_c
        cmp     rbt_tm_mh
        bcs     @oob
        ; rbt_ptr = cells + my*mw + mx
        lda     rbt_tm_cells
        sta     rbt_ptr
        lda     rbt_tm_cells+1
        sta     rbt_ptr+1
        ldx     rbt_c
        beq     @addx
@rloop: clc
        lda     rbt_ptr
        adc     rbt_tm_mw
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #0
        sta     rbt_ptr+1
        dex
        bne     @rloop
@addx:  clc
        lda     rbt_ptr
        adc     rbt_b
        sta     rbt_ptr
        lda     rbt_ptr+1
        adc     #0
        sta     rbt_ptr+1
        ldy     #0
        lda     (rbt_ptr),y
        rts
@oob:   lda     #0
        rts
