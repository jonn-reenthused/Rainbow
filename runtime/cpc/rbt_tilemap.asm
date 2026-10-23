; ============================================================================
; rbt_tilemap_asm - CPC tilemap engine (mode 1).
; Same state machine as the ZX module: a view window of cells (vx,vy,vw,vh)
; over a map at camera (camx,camy). Tiles are 8x8 1bpp expanded to pen1/pen0
; on the fly by rbt_tile8; a cell is 2 bytes wide x 8 lines on screen.
; Attr bytes in the tileset are ignored (CPC has no attribute plane).
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_tm_settiles - HL = tileset data
; ----------------------------------------------------------------------------
rbt_tm_settiles:
        ld      (rbt_tm_tiles),hl
        ld      a,(hl)
        ld      (rbt_tm_n),a
        inc     hl
        ld      (rbt_tm_bmp),hl
        ld      a,(rbt_tm_n)
        add     a,a
        add     a,a
        add     a,a             ; n*8
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (rbt_tm_tattr),hl
        ld      a,(rbt_tm_n)
        ld      e,a
        add     hl,de
        ld      (rbt_tm_tflags),hl
        ret

; ----------------------------------------------------------------------------
; rbt_tm_setmap - HL = tilemap data
; ----------------------------------------------------------------------------
rbt_tm_setmap:
        ld      (rbt_tm_map),hl
        ld      a,1
        ld      (rbt_tm_on),a   ; sprite erase switches to map repainting
        ld      a,(hl)
        ld      (rbt_tm_mw),a
        inc     hl
        ld      a,(hl)
        ld      (rbt_tm_mh),a
        inc     hl
        ld      (rbt_tm_cells),hl
        ; fall through: clamp the camera so the view fits in the map

; cam = 0 when view >= map on that axis, else min(cam, map - view)
rbt_tm_clampcam:
        ld      a,(rbt_tm_vw)
        ld      b,a
        ld      a,(rbt_tm_mw)
        cp      b
        jr      c,_x0           ; mw < vw
        jr      z,_x0
        sub     b               ; mw - vw = max cam
        ld      b,a
        ld      a,(rbt_tm_camx)
        cp      b
        jr      c,_cx
        jr      z,_cx
        ld      a,b
        jr      _cx
_x0     xor     a
_cx     ld      (rbt_tm_camx),a
        ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,(rbt_tm_mh)
        cp      b
        jr      c,_y0
        jr      z,_y0
        sub     b
        ld      b,a
        ld      a,(rbt_tm_camy)
        cp      b
        jr      c,_cy
        jr      z,_cy
        ld      a,b
        jr      _cy
_y0     xor     a
_cy     ld      (rbt_tm_camy),a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_view - B=x, C=y, D=w, E=h (screen cells, clamped to 32x24)
; ----------------------------------------------------------------------------
rbt_tm_view:
        ld      a,b
        cp      32
        jr      c,_vx
        xor     a
_vx     ld      (rbt_tm_vx),a
        ld      a,c
        cp      24
        jr      c,_vy
        xor     a
_vy     ld      (rbt_tm_vy),a
        ld      a,d
        or      a
        jr      z,_vw1
        cp      33
        jr      c,_vw2
_vw1    ld      a,32
_vw2    ld      (rbt_tm_vw),a
        ld      a,e
        or      a
        jr      z,_vh1
        cp      25
        jr      c,_vh2
_vh1    ld      a,24
_vh2    ld      (rbt_tm_vh),a
        ; band split: smallest raster-aligned row >= vy+vh. The GA int
        ; counter resets 2 lines after vsync (row 30), so raster ints land
        ; inside char rows 4,10,17,23,30,36 and a mid-frame CRTC write can
        ; only take effect at rows 5,11,18,24,31,37 - the usable band
        ; starts are 5,11,18,24 (rbt_split_int = the int index: the first
        ; vsync int is 0, then 34->2, 86->3, 138->4, 190->5).
        ; 0 = no band - the whole screen scrolls.
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_tm_vh)
        add     a,b             ; first row below the view
        cp      6
        jr      c,_sp05
        cp      12
        jr      c,_sp11
        cp      19
        jr      c,_sp18
        cp      25
        jr      c,_sp24
        xor     a
        ld      b,a
        jr      _sps
_sp05   ld      a,5
        ld      b,2
        jr      _sps
_sp11   ld      a,11
        ld      b,3
        jr      _sps
_sp18   ld      a,18
        ld      b,4
        jr      _sps
_sp24   ld      a,24
        ld      b,5
_sps    ld      (rbt_scr_split),a
        ld      a,b
        ld      (rbt_split_int),a
        ret                     ; rbt_scr_son arms on the first SCROLL

; ----------------------------------------------------------------------------
; rbt_tm_camera - B=tx, C=ty (map coords, clamped so view fits in map)
; ----------------------------------------------------------------------------
rbt_tm_camera:
        ld      a,b
        ld      (rbt_tm_camx),a
        ld      a,c
        ld      (rbt_tm_camy),a
        jp      rbt_tm_clampcam

; ----------------------------------------------------------------------------
; rbt_tm_blit - draw tile A at screen cell B=x, C=y. Clobbers everything.
; ----------------------------------------------------------------------------
rbt_tm_blit:
        push    bc
        ; src = bmp + id*8
        ld      e,a
        ld      d,0
        sla     e
        rl      d
        sla     e
        rl      d
        sla     e
        rl      d               ; DE = id*8
        ld      hl,(rbt_tm_bmp)
        add     hl,de
        ex      de,hl           ; DE = src
        ld      a,(rbt_tm_tbank)
        ld      hl,rbt_tm_tprev
        call    rbt_pg_in       ; page tileset bank (no-op when resident)
        call    rbt_tile8       ; B=cell x, C=cell y
        ld      hl,rbt_tm_tprev
        call    rbt_pg_out
        pop     bc
        ret

; ----------------------------------------------------------------------------
; rbt_tm_draw - draw the whole view window
; ----------------------------------------------------------------------------
rbt_tm_draw:
        xor     a
        ld      (rbt_tm_r),a
_dr     ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,(rbt_tm_r)
        cp      b
        ret     nc
        xor     a
        ld      (rbt_tm_c),a
_dc     ld      a,(rbt_tm_vw)
        ld      b,a
        ld      a,(rbt_tm_c)
        cp      b
        jp      nc,_dnext
        ; map coords
        ld      a,(rbt_tm_camx)
        ld      b,a
        ld      a,(rbt_tm_c)
        add     a,b
        ld      b,a             ; mx = camx + c
        ld      a,(rbt_tm_camy)
        ld      c,a
        ld      a,(rbt_tm_r)
        add     a,c
        ld      c,a             ; my = camy + r
        call    rbt_tm_mapat          ; A = tile id
        push    af
        ; screen cell = (vx+c, vy+r)
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_tm_c)
        add     a,b
        ld      b,a
        ld      a,(rbt_tm_vy)
        ld      c,a
        ld      a,(rbt_tm_r)
        add     a,c
        ld      c,a
        pop     af
        call    rbt_tm_blit
        ld      a,(rbt_tm_c)
        inc     a
        ld      (rbt_tm_c),a
        jp      _dc
_dnext  ld      a,(rbt_tm_r)
        inc     a
        ld      (rbt_tm_r),a
        jp      _dr

; ----------------------------------------------------------------------------
; rbt_tm_redraw - B=x, C=y, D=w, E=h: repair a screen-cell region from the map
; ----------------------------------------------------------------------------
rbt_tm_redraw:
        ld      a,e
        ld      (rbt_ct_r1),a   ; rows remaining
        ld      a,d
        ld      (rbt_tm_dir),a  ; spare var: original col count
        ld      a,c
        ld      (rbt_ct_r),a    ; current row
        ld      a,b
        ld      (rbt_ct_c0),a   ; start col
_rr     ld      a,(rbt_ct_r1)
        or      a
        ret     z
        ld      a,(rbt_tm_dir)
        ld      (rbt_ct_c1),a   ; cols remaining this row
        ld      a,(rbt_ct_c0)
        ld      (rbt_ct_c),a
_rc     ld      a,(rbt_ct_c1)
        or      a
        jp      z,_rnext
        ; inside view? c in [vx,vx+vw), r in [vy,vy+vh)
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jp      c,_rskip
        ld      a,(rbt_tm_vw)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        jp      nc,_rskip
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jp      c,_rskip
        ld      a,(rbt_tm_vh)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        jp      nc,_rskip
        ; map coords = cell - view origin + camera
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
        call    rbt_tm_mapat
        push    af
        ld      a,(rbt_ct_c)
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        pop     af
        call    rbt_tm_blit
_rskip  ld      a,(rbt_ct_c1)
        dec     a
        ld      (rbt_ct_c1),a
        ld      a,(rbt_ct_c)
        inc     a
        ld      (rbt_ct_c),a
        jp      _rc
_rnext  ld      a,(rbt_ct_r1)
        dec     a
        ld      (rbt_ct_r1),a
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _rr

; ----------------------------------------------------------------------------
; rbt_tm_soff - add signed byte delta A to the CRTC scroll offset (rbt_scr_soff,
; bytes, mod 2048) and push it to the display-start registers. One cell = 2
; bytes horizontal, 80 bytes vertical. di/ei keeps the split ticker from
; interleaving a register select mid-pair.
; ----------------------------------------------------------------------------
rbt_tm_soff:
        ld      e,a
        rla
        sbc     a,a
        ld      d,a             ; DE = sign-extended delta
        ld      hl,(rbt_scr_soff)
        add     hl,de
        ld      a,h
        and     #07
        ld      h,a             ; wrap the 2048-byte band
        ld      (rbt_scr_soff),hl
        srl     h
        rr      l               ; CRTC units = bytes/2
        if      RBT_CART
        call    rbt_crtc_r1213  ; no ISR on cart - nothing to race
        else
        di                      ; keep the split ticker out of the pair
        call    rbt_crtc_r1213
        ei
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_tm_colid - draw view column B=screen cell x from map column C, all rows.
; rbt_tm_rowid - draw view row B=screen cell y from map row C, all cols.
; ----------------------------------------------------------------------------
rbt_tm_colid:
        ld      a,b
        ld      (rbt_ct_c),a
        ld      a,c
        ld      (rbt_ct_c0),a
        xor     a
        ld      (rbt_ct_r),a
_ccl    ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        ret     nc
        ld      a,(rbt_ct_c0)
        ld      b,a             ; mx
        ld      a,(rbt_tm_camy)
        ld      c,a
        ld      a,(rbt_ct_r)
        add     a,c
        ld      c,a             ; my = camy + r
        call    rbt_tm_mapat
        push    af
        ld      a,(rbt_ct_c)
        ld      b,a
        ld      a,(rbt_tm_vy)
        ld      c,a
        ld      a,(rbt_ct_r)
        add     a,c
        ld      c,a
        pop     af
        call    rbt_tm_blit
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _ccl

rbt_tm_rowid:
        ld      a,b
        ld      (rbt_ct_r),a
        ld      a,c
        ld      (rbt_ct_r0),a
        xor     a
        ld      (rbt_ct_c),a
_crl    ld      a,(rbt_tm_vw)
        ld      b,a
        ld      a,(rbt_ct_c)
        cp      b
        ret     nc
        ld      a,(rbt_tm_camx)
        ld      b,a
        ld      a,(rbt_ct_c)
        add     a,b
        ld      b,a             ; mx = camx + c
        ld      a,(rbt_ct_r0)
        ld      c,a             ; my
        call    rbt_tm_mapat
        push    af
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_c)
        add     a,b
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        pop     af
        call    rbt_tm_blit
        ld      a,(rbt_ct_c)
        inc     a
        ld      (rbt_ct_c),a
        jp      _crl

; ----------------------------------------------------------------------------
; rbt_tm_scroll - A = dir (0=left,1=right,2=up,3=down), B = steps.
; Hardware scroll: per step the CRTC display start moves one cell around the
; circular 2048-byte band (2 bytes horizontal, 80 vertical) and only the
; newly exposed edge column/row is drawn. Rows >= rbt_scr_split stay static
; via the raster-split restore in rbt_split_isr.
; ----------------------------------------------------------------------------
rbt_tm_scroll:
        and     3
        ld      (rbt_tm_dir),a
        ld      a,b
        or      a
        ret     z
        ld      (rbt_tm_steps),a
        ld      a,(rbt_tm_on)
        ld      (rbt_scr_son),a ; scrolled addressing once a scroll happens
        call    rbt_split_install       ; arm the static band (fw builds)
_slp    ld      a,(rbt_tm_dir)
        or      a
        jr      nz,_sr
        ; left: camx--
        ld      a,(rbt_tm_camx)
        or      a
        jp      z,_sdone
        dec     a
        ld      (rbt_tm_camx),a
        ld      a,-2
        call    rbt_tm_soff
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_tm_camx)
        ld      c,a
        call    rbt_tm_colid            ; draw left edge column
        jp      _snext
_sr     cp      1
        jr      nz,_su
        ; right: camx++ iff camx+vw < mw
        ld      a,(rbt_tm_camx)
        ld      b,a
        ld      a,(rbt_tm_vw)
        add     a,b
        ld      b,a
        ld      a,(rbt_tm_mw)
        cp      b
        jp      c,_sdone
        jp      z,_sdone
        ld      a,(rbt_tm_camx)
        inc     a
        ld      (rbt_tm_camx),a
        ld      a,2
        call    rbt_tm_soff
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_tm_vw)
        add     a,b
        dec     a
        ld      b,a                     ; screen col vx+vw-1
        ld      a,(rbt_tm_camx)
        ld      c,a
        ld      a,(rbt_tm_vw)
        add     a,c
        dec     a
        ld      c,a                     ; map col camx+vw-1
        call    rbt_tm_colid            ; draw right edge column
        jp      _snext
_su     cp      2
        jr      nz,_sdn
        ; up: camy--
        ld      a,(rbt_tm_camy)
        or      a
        jp      z,_sdone
        dec     a
        ld      (rbt_tm_camy),a
        ld      a,-80
        call    rbt_tm_soff
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_tm_camy)
        ld      c,a
        call    rbt_tm_rowid            ; draw top edge row
        jp      _snext
_sdn    ; down: camy++ iff camy+vh < mh
        ld      a,(rbt_tm_camy)
        ld      b,a
        ld      a,(rbt_tm_vh)
        add     a,b
        ld      b,a
        ld      a,(rbt_tm_mh)
        cp      b
        jp      c,_sdone
        jp      z,_sdone
        ld      a,(rbt_tm_camy)
        inc     a
        ld      (rbt_tm_camy),a
        ld      a,80
        call    rbt_tm_soff
        ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_tm_vh)
        add     a,b
        dec     a
        ld      b,a                     ; screen row vy+vh-1
        ld      a,(rbt_tm_camy)
        ld      c,a
        ld      a,(rbt_tm_vh)
        add     a,c
        dec     a
        ld      c,a                     ; map row camy+vh-1
        call    rbt_tm_rowid            ; draw bottom edge row
_snext  ld      a,(rbt_tm_steps)
        dec     a
        ld      (rbt_tm_steps),a
        jp      nz,_slp
_sdone  ret

; ----------------------------------------------------------------------------
; rbt_tileat - B=tx, C=ty (map coords) -> A = tile id (255 = out of bounds)
; ----------------------------------------------------------------------------
rbt_tileat:
        ld      a,(rbt_tm_mw)
        cp      b
        jr      c,_ta0
        jr      z,_ta0
        ld      a,(rbt_tm_mh)
        cp      c
        jr      c,_ta0
        jr      z,_ta0
        call    rbt_tm_mapat
        ret
_ta0    ld      a,255
        ret

; ----------------------------------------------------------------------------
; rbt_tileatset - B=tx, C=ty, D=id : write map cell if in bounds
; ----------------------------------------------------------------------------
rbt_tileatset:
        ld      a,(rbt_tm_mw)
        cp      b
        ret     c
        ret     z
        ld      a,(rbt_tm_mh)
        cp      c
        ret     c
        ret     z
        ld      a,(rbt_tm_mbank)
        ld      hl,rbt_tm_mprev
        call    rbt_pg_in       ; page map bank for the cell write
        push    de
        push    bc
        ld      hl,(rbt_tm_cells)
        ld      a,c
        or      a
        jr      z,_tax
        ld      b,a
        ld      a,(rbt_tm_mw)
        ld      e,a
        ld      d,0
_tal    add     hl,de
        djnz    _tal
_tax    pop     bc
        ld      e,b
        ld      d,0
        add     hl,de
        pop     de
        ld      (hl),d
        ld      hl,rbt_tm_mprev
        jp      rbt_pg_out

; ----------------------------------------------------------------------------
; rbt_tileflags - A = tile id -> A = flags byte (0 if out of range)
; ----------------------------------------------------------------------------
rbt_tileflags:
        ld      b,a
        ld      a,(rbt_tm_n)
        cp      b
        jr      c,_tf0
        jr      z,_tf0
        ld      a,(rbt_tm_tbank)
        ld      hl,rbt_tm_tprev
        call    rbt_pg_in       ; page tileset bank for the flag read
        ld      a,b
        ld      e,a
        ld      d,0
        ld      hl,(rbt_tm_tflags)
        add     hl,de
        ld      a,(hl)
        ld      hl,rbt_tm_tprev
        jp      rbt_pg_out
_tf0    xor     a
        ret
