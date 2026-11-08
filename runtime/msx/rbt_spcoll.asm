; ============================================================================
; rbt_spcoll_asm - sprite <-> tilemap collision bridge (MSX1)
; Sprite/sprite AABB lives in rbt_sprite.asm (same split as ZX/CPC);
; this module only maps sprite bboxes onto map cells. Sprites are
; uniformly 16x16 so the bbox is fixed-size.
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_colltile - A = sprite id -> A = flags of first solid tile overlapped
; (0 = none). Cell bbox spans (x..x+15, y..y+15).
; ----------------------------------------------------------------------------
rbt_colltile:
        call    rbt_slot
        ld      a,(ix+0)
        bit     0,a
        ret     z               ; inactive -> no collision
        ld      a,(ix+1)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_c0),a   ; x>>3
        ld      a,(ix+1)        ; (x+w-1)>>3 — real pixel width from the
        add     a,(ix+13)       ; asset, not the 16px SAT slot
        dec     a
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
        ld      (rbt_ct_r0),a
        ld      a,(ix+2)
        add     a,(ix+14)
        dec     a
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_ct_r1),a
        ; loop rows r0..r1, cols c0..c1
        ld      a,(rbt_ct_r0)
        ld      (rbt_ct_r),a
_cr     ld      a,(rbt_ct_c0)
        ld      (rbt_ct_c),a
_cc     ; inside view? (screen cell c,r within vx..vx+vw / vy..vy+vh)
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jr      c,_cskip
        ld      a,(rbt_tm_vw)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jr      nc,_cskip
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jr      c,_cskip
        ld      a,(rbt_tm_vh)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jr      nc,_cskip
        ; map coords: mx = camx + (c - vx), my = camy + (r - vy)
        ld      a,(rbt_ct_c)
        ld      hl,rbt_tm_vx
        sub     (hl)
        ld      hl,rbt_tm_camx
        add     a,(hl)
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      hl,rbt_tm_vy
        sub     (hl)
        ld      hl,rbt_tm_camy
        add     a,(hl)
        ld      c,a
        call    rbt_tm_mapat    ; A = tile id
        call    rbt_tileflags   ; A = flags
        or      a
        ret     nz              ; solid -> return flag bits
_cskip  ld      a,(rbt_ct_c)
        inc     a
        ld      (rbt_ct_c),a
        ld      hl,rbt_ct_c1
        cp      (hl)
        jr      c,_cc
        jr      z,_cc
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        ld      hl,rbt_ct_r1
        cp      (hl)
        jr      c,_cr
        jr      z,_cr
        xor     a
        ret

; tile-bbox scratch (tmdata defines the rbt_ct_* set on ZX — kept here)
rbt_ct_c0       defb 0
rbt_ct_c1       defb 0
rbt_ct_r0       defb 0
rbt_ct_r1       defb 0
rbt_ct_r        defb 0
rbt_ct_c        defb 0
