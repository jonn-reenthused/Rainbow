; ============================================================================
; rbt_spcoll_asm - sprite <-> tilemap collision bridge.
; Requires BOTH the sprite module (rbt_slot) and the tilemap module
; (rbt_tm_* vars, rbt_tm_mapat, rbt_ct_* scratch).
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_colltile - A = sprite id -> A = flags of first solid tile overlapped
; (0 = none). Requires the sprite module (uses rbt_sprites via rbt_slot).
; ----------------------------------------------------------------------------
rbt_colltile:
        call    rbt_slot        ; IX = slot
        ld      a,(ix+0)
        bit     0,a
        ret     z               ; inactive -> no collision
        ; cell range from pixel bbox
        ld      a,(ix+1)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_c0),a   ; x>>3
        ld      a,(ix+3)
        add     a,a
        add     a,a
        add     a,a             ; w*8
        dec     a
        add     a,(ix+1)        ; x+w*8-1
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_c1),a
        ld      a,(ix+2)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_r0),a   ; y>>3
        ld      a,(ix+4)
        dec     a
        add     a,(ix+2)        ; y+h-1
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_r1),a
        ; loop rows r0..r1
        ld      a,(rbt_ct_r0)
        ld      (rbt_ct_r),a
_cr     ld      a,(rbt_ct_c0)
        ld      (rbt_ct_c),a
_cc     ; inside view?
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jp      c,_cskip
        ld      a,(rbt_tm_vw)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jp      nc,_cskip
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jp      c,_cskip
        ld      a,(rbt_tm_vh)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jp      nc,_cskip
        ; map coords
        ld      a,(rbt_ct_c)
        ld      b,a
        ld      a,(rbt_tm_vx)
        ld      c,a
        ld      a,b
        sub     c
        ld      b,a
        ld      a,(rbt_tm_camx)
        add     a,b
        ld      b,a             ; mx
        ld      a,(rbt_ct_r)
        ld      c,a
        ld      a,(rbt_tm_vy)
        ld      d,a
        ld      a,c
        sub     d
        ld      c,a
        ld      a,(rbt_tm_camy)
        add     a,c
        ld      c,a             ; my
        ; in map? (else treat as not solid)
        ld      a,(rbt_tm_mw)
        cp      b
        jp      c,_cskip
        jp      z,_cskip
        ld      a,(rbt_tm_mh)
        cp      c
        jp      c,_cskip
        jp      z,_cskip
        call    rbt_tm_mapat
        call    rbt_tileflags   ; A = flags (self-pages tileset bank)
        bit     0,a
        ret     nz              ; solid -> return flags
_cskip  ld      a,(rbt_ct_c)
        inc     a
        ld      (rbt_ct_c),a
        ld      b,a
        ld      a,(rbt_ct_c1)
        cp      b
        jp      nc,_cc
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        ld      b,a
        ld      a,(rbt_ct_r1)
        cp      b
        jp      nc,_cr
        xor     a               ; none
        ret
