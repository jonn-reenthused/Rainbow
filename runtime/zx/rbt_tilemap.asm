; ============================================================================
; rbt_tilemap_asm - tile / tilemap engine (tile-step scrolling)
;
; Tileset layout: defb n, n*8 bitmaps, n attrs, n flag bytes (bit0 = solid)
; Tilemap layout: defb w, h, w*h tile indices (row-major)
;
; View: screen window in char cells (vx,vy,vw,vh); camera in map tile coords.
; Scrolling = camera move + full view redraw.
; ============================================================================

; State vars and rbt_tm_mapat live in rbt_tmdata.asm (shared with the sprite
; compositor).

; ----------------------------------------------------------------------------
; rbt_tm_settiles - HL = tileset data
; ----------------------------------------------------------------------------
rbt_tm_settiles:
        ld      (rbt_tm_tiles),hl
        ld      a,(hl)
        ld      (rbt_tm_n),a
        inc     hl
        ld      (rbt_tm_bmp),hl
        ; attr base = bmp + n*8
        ld      e,a
        ld      d,0
        sla     e
        rl      d
        sla     e
        rl      d
        sla     e
        rl      d               ; DE = n*8
        add     hl,de
        ld      (rbt_tm_tattr),hl
        ; flag base = attr + n
        ld      a,(rbt_tm_n)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (rbt_tm_tflags),hl
        ret

; ----------------------------------------------------------------------------
; rbt_tm_setmap - HL = tilemap data
; ----------------------------------------------------------------------------
rbt_tm_setmap:
        ld      (rbt_tm_map),hl
        ld      a,(hl)
        ld      (rbt_tm_mw),a
        inc     hl
        ld      a,(hl)
        ld      (rbt_tm_mh),a
        inc     hl
        ld      (rbt_tm_cells),hl
        ; clamp the camera into the new map's bounds (it may be smaller
        ; than the previous map while scrolled)
        ld      a,(rbt_tm_mw)
        ld      c,a
        ld      a,(rbt_tm_vw)
        ld      b,a
        ld      a,c
        sub     b
        jr      nc,_cmx
        xor     a
_cmx    ld      b,a             ; B = max(0, mw - vw)
        ld      a,(rbt_tm_camx)
        cp      b
        jr      c,_cy
        ld      a,b
        ld      (rbt_tm_camx),a
_cy     ld      a,(rbt_tm_mh)
        ld      c,a
        ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,c
        sub     b
        jr      nc,_cmy
        xor     a
_cmy    ld      c,a             ; C = max(0, mh - vh)
        ld      a,(rbt_tm_camy)
        cp      c
        jr      c,_cdone
        ld      a,c
        ld      (rbt_tm_camy),a
_cdone  ret

; ----------------------------------------------------------------------------
; rbt_tm_view - B=x, C=y, D=w, E=h (screen cells, clamped to 32x24)
; ----------------------------------------------------------------------------
rbt_tm_view:
        ld      a,b
        and     31
        ld      (rbt_tm_vx),a
        ld      a,c
        cp      24
        jr      c,_vy
        ld      a,23
_vy     ld      (rbt_tm_vy),a
        ld      a,d
        or      a
        jr      nz,_vw
        inc     a
_vw     cp      33
        jr      c,_vw2
        ld      a,32
_vw2    ld      (rbt_tm_vw),a
        ld      a,e
        or      a
        jr      nz,_vh
        inc     a
_vh     cp      25
        jr      c,_vh2
        ld      a,24
_vh2    ld      (rbt_tm_vh),a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_camera - B=tx, C=ty (map coords, clamped so view fits in map)
; ----------------------------------------------------------------------------
rbt_tm_camera:
        ; camx = min(b, max(0, mw - vw))
        ld      a,(rbt_tm_mw)
        ld      e,a
        ld      a,(rbt_tm_vw)
        ld      d,a
        ld      a,e
        sub     d
        jr      nc,_cx          ; A = mw - vw (max camera)
        xor     a
_cx     cp      b
        jr      nc,_cxs         ; max >= b -> keep b
        ld      b,a             ; clamp to max
_cxs    ld      a,b
        ld      (rbt_tm_camx),a
        ; camy = min(c, max(0, mh - vh))
        ld      a,(rbt_tm_mh)
        ld      e,a
        ld      a,(rbt_tm_vh)
        ld      d,a
        ld      a,e
        sub     d
        jr      nc,_cy
        xor     a
_cy     cp      c
        jr      nc,_cys
        ld      c,a
_cys    ld      a,c
        ld      (rbt_tm_camy),a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_blit - draw tile A at screen cell B=x, C=y. Clobbers everything.
; ----------------------------------------------------------------------------
rbt_tm_blit:
        ld      hl,rbt_tm_tprev
        push    af
        ld      a,(rbt_tm_tbank)
        call    rbt_pg_in       ; page tileset bank (no-op when resident)
        pop     af
        call    _blb
        ld      hl,rbt_tm_tprev
        jp      rbt_pg_out

_blb    ld      (rbt_tm_tid),a
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
        ; dst = cell addr: H = #40+(cy>>3)*8, L = (cy&7)*32+cx
        ld      a,c
        and     #f8
        rrca
        rrca
        rrca
        add     a,a
        add     a,a
        add     a,a
        add     a,#40
        ld      h,a
        ld      a,c
        and     7
        rrca
        rrca
        rrca
        or      b
        ld      l,a
        ld      b,8
_tbl    ld      a,(de)
        ld      (hl),a
        inc     de
        inc     h
        djnz    _tbl
        ; attr = #5800 + cy*32 + cx
        ld      a,c
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; cy*32
        pop     bc
        ld      a,b
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ld      a,(rbt_tm_tid)
        ld      e,a
        ld      d,0
        push    hl
        ld      hl,(rbt_tm_tattr)
        add     hl,de
        ld      a,(hl)
        pop     hl
        ld      (hl),a
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
; rbt_tm_laddr - B = byte col, C = pixel line -> HL = bitmap address. Uses A,HL.
; ----------------------------------------------------------------------------
rbt_tm_laddr:
        ld      a,c
        and     #c0
        rrca
        rrca
        rrca
        add     a,#40
        ld      h,a
        ld      a,c
        and     7
        or      h
        ld      h,a             ; H = #40 + (y&#C0)>>3 + (y&7)
        ld      a,c
        and     #38
        add     a,a
        add     a,a
        or      b
        ld      l,a             ; L = ((y&#38)<<2) | x
        ret

; ----------------------------------------------------------------------------
; rbt_tm_arow - B = col, C = attr row -> HL = #5800 + row*32 + col. Uses A,HL.
; ----------------------------------------------------------------------------
rbt_tm_arow:
        ld      l,c
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,b
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_shl / rbt_tm_shr - shift the view's bitmap+attr bytes left/right by
; one cell (8 pixels). Does not draw anything.
; ----------------------------------------------------------------------------
rbt_tm_shl:                     ; content moves left (camera right)
        ld      a,(rbt_tm_vw)
        dec     a
        ret     z               ; 1-cell view: nothing to shift
        ld      (rbt_tm_cnt),a
        ld      a,(rbt_tm_vy)
        add     a,a
        add     a,a
        add     a,a
        ld      (rbt_ct_r),a    ; current pixel line
        ld      b,a
        ld      a,(rbt_tm_vh)
        add     a,a
        add     a,a
        add     a,a
        add     a,b
        ld      (rbt_ct_r1),a   ; end line
_shll   ld      a,(rbt_ct_r)
        ld      b,a
        ld      a,(rbt_ct_r1)
        cp      b
        jp      z,_shla
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_laddr
        ex      de,hl           ; DE = dst (vx, line)
        inc     b
        call    rbt_tm_laddr    ; HL = src (vx+1, line)
        ld      a,(rbt_tm_cnt)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shll
_shla   ; attr rows
        ld      a,(rbt_tm_vy)
        ld      (rbt_ct_r),a
        ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,(rbt_ct_r)
        add     a,b
        ld      (rbt_ct_r1),a
_shlal  ld      a,(rbt_ct_r)
        ld      b,a
        ld      a,(rbt_ct_r1)
        cp      b
        ret     z
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_arow     ; HL = dst
        push    hl
        pop     de              ; DE = dst
        inc     hl              ; HL = src (vx+1)
        ld      a,(rbt_tm_cnt)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shlal

rbt_tm_shr:                     ; content moves right (camera left)
        ld      a,(rbt_tm_vw)
        dec     a
        ret     z
        ld      (rbt_tm_cnt),a
        ld      a,(rbt_tm_vy)
        add     a,a
        add     a,a
        add     a,a
        ld      (rbt_ct_r),a
        ld      b,a
        ld      a,(rbt_tm_vh)
        add     a,a
        add     a,a
        add     a,a
        add     a,b
        ld      (rbt_ct_r1),a
_shrl   ld      a,(rbt_ct_r)
        ld      b,a
        ld      a,(rbt_ct_r1)
        cp      b
        jp      z,_shra
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_tm_vw)
        add     a,b
        dec     a
        ld      b,a             ; B = vx+vw-1 (rightmost col)
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_laddr
        ex      de,hl           ; DE = dst (rightmost)
        dec     b
        call    rbt_tm_laddr    ; HL = src (rightmost-1)
        ld      a,(rbt_tm_cnt)
        ld      c,a
        ld      b,0
        lddr
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shrl
_shra   ld      a,(rbt_tm_vy)
        ld      (rbt_ct_r),a
        ld      a,(rbt_tm_vh)
        ld      b,a
        ld      a,(rbt_ct_r)
        add     a,b
        ld      (rbt_ct_r1),a
_shral  ld      a,(rbt_ct_r)
        ld      b,a
        ld      a,(rbt_ct_r1)
        cp      b
        ret     z
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_tm_vw)
        add     a,b
        dec     a
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_arow     ; HL = dst (rightmost)
        push    hl
        pop     de              ; DE = dst
        dec     hl              ; HL = src (rightmost-1)
        ld      a,(rbt_tm_cnt)
        ld      c,a
        ld      b,0
        lddr
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shral

; ----------------------------------------------------------------------------
; rbt_tm_shu / rbt_tm_shd - shift the view's bitmap+attr bytes up/down by
; one cell (8 lines).
; ----------------------------------------------------------------------------
rbt_tm_shd:                     ; content moves up (camera down)
        ld      a,(rbt_tm_vh)
        dec     a
        ret     z
        xor     a
        ld      (rbt_ct_r),a    ; d = 0 .. vh*8-9
_shdl   ld      a,(rbt_tm_vh)
        add     a,a
        add     a,a
        add     a,a
        sub     8
        ld      b,a             ; vh*8 - 8
        ld      a,(rbt_ct_r)
        cp      b
        jp      nc,_shda
        ld      a,(rbt_tm_vy)
        add     a,a
        add     a,a
        add     a,a
        ld      b,a             ; vy*8
        ld      a,(rbt_ct_r)
        add     a,b
        ld      c,a             ; dst line = vy*8 + d
        ld      a,(rbt_tm_vx)
        ld      b,a
        call    rbt_tm_laddr
        ex      de,hl           ; DE = dst
        ld      a,c
        add     a,8
        ld      c,a             ; src line = dst+8
        call    rbt_tm_laddr    ; HL = src
        ld      a,(rbt_tm_vw)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shdl
_shda   ; attr rows: dst row r <- src row r+1, r = vy .. vy+vh-2
        ld      a,(rbt_tm_vy)
        ld      (rbt_ct_r),a
_shdal  ld      a,(rbt_tm_vh)
        dec     a
        ld      b,a
        ld      a,(rbt_tm_vy)
        add     a,b
        ld      b,a             ; vy+vh-1 (exclusive end)
        ld      a,(rbt_ct_r)
        cp      b
        ret     nc
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_arow
        ex      de,hl           ; DE = dst row r
        ld      a,(rbt_ct_r)
        inc     a
        ld      c,a
        call    rbt_tm_arow     ; HL = src row r+1
        ld      a,(rbt_tm_vw)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        inc     a
        ld      (rbt_ct_r),a
        jp      _shdal

rbt_tm_shu:                     ; content moves down (camera up)
        ld      a,(rbt_tm_vh)
        dec     a
        ret     z
        ld      a,(rbt_tm_vh)
        add     a,a
        add     a,a
        add     a,a
        dec     a
        ld      (rbt_ct_r),a    ; d = vh*8-1 .. 8
_shul   ld      a,(rbt_ct_r)
        cp      8
        jp      c,_shua
        ld      a,(rbt_tm_vy)
        add     a,a
        add     a,a
        add     a,a
        ld      b,a
        ld      a,(rbt_ct_r)
        add     a,b
        ld      c,a             ; dst line = vy*8 + d
        ld      a,(rbt_tm_vx)
        ld      b,a
        call    rbt_tm_laddr
        ex      de,hl           ; DE = dst
        ld      a,c
        sub     8
        ld      c,a             ; src line = dst-8
        call    rbt_tm_laddr    ; HL = src
        ld      a,(rbt_tm_vw)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        dec     a
        ld      (rbt_ct_r),a
        jp      _shul
_shua   ; attr rows: dst row r+1 <- src row r, r = vy+vh-2 .. vy
        ld      a,(rbt_tm_vh)
        dec     a
        ld      b,a
        ld      a,(rbt_tm_vy)
        add     a,b
        dec     a
        ld      (rbt_ct_r),a    ; r = vy+vh-2
_shual  ld      a,(rbt_tm_vy)
        ld      b,a
        ld      a,(rbt_ct_r)
        cp      b
        ret     c               ; r < vy -> done
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_ct_r)
        inc     a
        ld      c,a
        call    rbt_tm_arow
        ex      de,hl           ; DE = dst row r+1
        ld      a,(rbt_ct_r)
        ld      c,a
        call    rbt_tm_arow     ; HL = src row r
        ld      a,(rbt_tm_vw)
        ld      c,a
        ld      b,0
        ldir
        ld      a,(rbt_ct_r)
        dec     a
        ld      (rbt_ct_r),a
        jp      _shual

; ----------------------------------------------------------------------------
; rbt_tm_colid - B = screen col, C = map col: draw vh cells down the column.
; rbt_tm_rowid - B = screen row, C = map row: draw vw cells across the row.
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
; Moves camera; per step, shifts the view's screen bytes one cell and draws
; only the newly exposed column/row.
; ----------------------------------------------------------------------------
rbt_tm_scroll:
        and     3
        ld      (rbt_tm_dir),a
        ld      a,b
        or      a
        ret     z
        ld      (rbt_tm_steps),a
_slp    ld      a,(rbt_tm_dir)
        or      a
        jr      nz,_sr
        ; left: camx--
        ld      a,(rbt_tm_camx)
        or      a
        jp      z,_sdone
        dec     a
        ld      (rbt_tm_camx),a
        call    rbt_tm_shr              ; content shifts right
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
        call    rbt_tm_shl              ; content shifts left
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
        call    rbt_tm_shu              ; content shifts down
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
        call    rbt_tm_shd              ; content shifts up
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
        ld      hl,rbt_tm_mprev
        ld      a,(rbt_tm_mbank)
        call    rbt_pg_in       ; page map bank
        call    _tsb
        ld      hl,rbt_tm_mprev
        jp      rbt_pg_out

_tsb    ld      a,(rbt_tm_mw)
        cp      b
        ret     c
        ret     z
        ld      a,(rbt_tm_mh)
        cp      c
        ret     c
        ret     z
        ; same offset calc as rbt_tm_mapat
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
        ret

; ----------------------------------------------------------------------------
; rbt_tileflags - A = tile id -> A = flags byte (0 if out of range)
; ----------------------------------------------------------------------------
rbt_tileflags:
        ld      b,a             ; B = tile id (pg_in preserves BC)
        ld      hl,rbt_tm_tprev
        ld      a,(rbt_tm_tbank)
        call    rbt_pg_in       ; page tileset bank
        call    _tfb
        ld      hl,rbt_tm_tprev
        jp      rbt_pg_out      ; restores bank; preserves A = flags

_tfb    ld      a,(rbt_tm_n)
        cp      b
        jr      c,_tf0
        jr      z,_tf0
        ld      a,b
        ld      e,a
        ld      d,0
        ld      hl,(rbt_tm_tflags)
        add     hl,de
        ld      a,(hl)
        ret
_tf0    xor     a
        ret

