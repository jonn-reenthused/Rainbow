; ============================================================================
; rbt_tilemap_asm - tilemap engine (MSX1/MSX2)
;
; Screen 2's name table IS the tile grid: a tile = 8 pattern bytes + 8
; colour bytes in the cell's VRAM slots. No shifting, no masks — the
; whole engine is camera maths + table lookups.
;
; On RBT_MSX2 (rbt_smode=1) cells expand into the 4bpp bitmap instead —
; no nametable means the scroll fast path falls back to camera-step +
; full-view redraw, and rbt_tm_cell5 is the only SC5 draw entry.
;
;   TILESET "x"   -> rbt_tm_settiles   .rbt: defb n, 8n bitmap, n attr, n flags
;   TILEMAP BIND  -> rbt_tm_setmap     .rbm: defb w, h, w*h cells
;   TILEMAP VIEW  -> rbt_tm_view       B,C,D,E = x,y,w,h (screen cells)
;   TILEMAP CAMERA-> rbt_tm_camera     B,C = map cell offset
;   TILEMAP DRAW  -> rbt_tm_draw       blit the view from the camera
;   TILEMAP SCROLL-> rbt_tm_scroll     A = dir (0L 1R 2U 3D), B = steps
;   TILEMAP REDRAW-> rbt_tm_redraw     B,C,D,E = view cells to redraw
;
; v1 scrolls by camera-step + full redraw — correct but not optimal.
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_tm_settiles - HL = tileset asset
; ----------------------------------------------------------------------------
rbt_tm_settiles:
        ld      (rbt_tm_tiles),hl
        ld      a,(hl)
        ld      (rbt_tm_n),a
        inc     hl
        ld      (rbt_tm_bmp),hl
        ld      e,a
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
; rbt_tm_setmap - HL = map asset: defb w, h, cells...
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
        ret

; ----------------------------------------------------------------------------
; rbt_tm_view - B,C,D,E = x,y,w,h screen cells
; ----------------------------------------------------------------------------
rbt_tm_view:
        ld      a,b
        ld      (rbt_tm_vx),a
        ld      a,c
        ld      (rbt_tm_vy),a
        ld      a,d
        ld      (rbt_tm_vw),a
        ld      a,e
        ld      (rbt_tm_vh),a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_camera - B,C = map cell offset
; ----------------------------------------------------------------------------
rbt_tm_camera:
        ld      a,b
        ld      (rbt_tm_camx),a
        ld      a,c
        ld      (rbt_tm_camy),a
        ret

; ----------------------------------------------------------------------------
; rbt_tm_acol - A = ZX attr -> A = MSX colour byte (fg<<4|bg via palette)
; ----------------------------------------------------------------------------
rbt_tm_acol:
        ld      e,a
        and     7
        ld      c,a
        ld      a,e
        and     #40
        rrca
        rrca
        rrca
        or      c               ; fg index
        ld      hl,rbt_zx2msx
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        ld      c,a             ; fg<<4
        ld      a,(rbt_tm_att)
        rrca
        rrca
        rrca
        and     #0f             ; paper|bright -> index
        ld      hl,rbt_zx2msx
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        or      c
        ret

; ----------------------------------------------------------------------------
; rbt_tm_cell - draw tile D at screen cell (col B, row C).
; Writes 8 pattern bytes + 8 colour bytes. Clobbers all.
; ----------------------------------------------------------------------------
rbt_tm_cell:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_tm_cell5
        endif
        ld      a,d
        ld      (rbt_tm_tid),a
        ; cell index = row*32+col; its high byte is the pattern third
        ld      a,c
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; row*32
        ld      a,b
        or      l
        ld      l,a             ; hl = row*32+col (h = third 0/1/2)
        ld      a,h
        ld      (rbt_tm_th),a   ; remember the third
        ; read the cell's nametable value -> the pattern index it shows.
        ; (after a nametable-shift scroll this is a neighbour's index —
        ; writing there keeps the redraw on the right pattern slot)
        ld      de,#1800
        add     hl,de
        call    rbt_vraddr
        in      a,(#98)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; index*8
        ld      a,(rbt_tm_th)
        add     a,a
        add     a,a
        add     a,a             ; third*8 = high byte of third*0x800
        ld      d,a
        ld      e,0
        add     hl,de           ; pa = third*0x800 + index*8
        ld      (rbt_tm_pa),hl
        ; src = bmp + tid*8
        ld      hl,(rbt_tm_bmp)
        ld      a,(rbt_tm_tid)
        add     a,a
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        add     hl,de
        ex      de,hl           ; DE = src
        ld      hl,(rbt_tm_pa)
        ld      bc,8
        call    rbt_vwrite
        ; colour byte from tile attr
        ld      hl,(rbt_tm_tattr)
        ld      a,(rbt_tm_tid)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        ld      (rbt_tm_att),a
        call    rbt_tm_acol     ; A = colour byte
        ld      c,a
        ld      hl,(rbt_tm_pa)
        ld      de,#2000
        add     hl,de
        call    rbt_vwaddr
        ld      b,8
_cf     ld      a,c
        out     (#98),a
        djnz    _cf
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_tm_cell5 - Screen 5 tile draw at screen cell (col B, row C): no
; nametable — the bitmap address is fixed (row*1024 + col*4, stride
; 128). Each pattern byte lands in rbt_shadow and expands via rbt_xpnib
; with the tile's colour byte.
; ----------------------------------------------------------------------------
rbt_tm_cell5:
        ld      a,d
        ld      (rbt_tm_tid),a
        ; shadow ptr = rbt_shadow + (row*32+col)*8
        ld      a,c
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; row*32
        ld      a,b
        or      l
        ld      l,a             ; cellidx
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8
        ld      de,rbt_shadow
        add     hl,de
        ld      (rbt_tm_sh5),hl
        ; vram addr = row*1024 + col*4
        ld      a,c
        add     a,a
        add     a,a             ; row*4 -> hi byte of row*1024
        ld      h,a
        ld      a,b
        add     a,a
        add     a,a             ; col*4
        ld      l,a
        ld      (rbt_tm_va5),hl
        ; src = bmp + tid*8
        ld      hl,(rbt_tm_bmp)
        ld      a,(rbt_tm_tid)
        add     a,a
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        add     hl,de
        ld      (rbt_tm_src5),hl
        ; colour byte from the tile's attr
        ld      hl,(rbt_tm_tattr)
        ld      a,(rbt_tm_tid)
        ld      e,a
        ld      d,0
        add     hl,de
        ld      a,(hl)
        ld      (rbt_tm_att),a
        call    rbt_tm_acol     ; A = fg<<4|bg
        ld      (rbt_tm_cb5),a
        ld      b,8
_row    push    bc
        ld      hl,(rbt_tm_src5)  ; pattern byte, src ptr++
        ld      e,(hl)
        inc     hl
        ld      (rbt_tm_src5),hl
        ld      hl,(rbt_tm_sh5)  ; shadow store, ptr++
        ld      (hl),e
        inc     hl
        ld      (rbt_tm_sh5),hl
        ld      hl,(rbt_tm_va5)
        call    rbt_vwaddr5     ; DE-preserved 17-bit vaddr
        ld      a,(rbt_tm_cb5)
        ld      c,a             ; C = fg<<4|bg
        ld      a,e             ; A = pattern
        call    rbt_xpnib       ; 8 bits -> 4 bytes out #98
        ld      hl,(rbt_tm_va5)
        ld      de,128
        add     hl,de
        ld      (rbt_tm_va5),hl
        pop     bc
        djnz    _row
        ret

rbt_tm_sh5      defw 0          ; running shadow pointer (cell5)
rbt_tm_va5      defw 0          ; current cell-row VRAM addr
rbt_tm_src5     defw 0          ; running tile-pattern pointer
rbt_tm_cb5      defb 0          ; colour byte of the tile being drawn
        endif

; ----------------------------------------------------------------------------
; rbt_tm_blit - draw a view-rect of map cells to the screen.
; Rect (view-relative cells) in rbt_tm_rx/ry/rw/rh.
; ----------------------------------------------------------------------------
rbt_tm_blit:
        xor     a
        ld      (rbt_tm_r),a
_dr     ld      a,(rbt_tm_r)
        ld      hl,rbt_tm_rh
        cp      (hl)
        ret     nc
        xor     a
        ld      (rbt_tm_c),a
_dc     ld      a,(rbt_tm_c)
        ld      hl,rbt_tm_rw
        cp      (hl)
        jr      nc,_rdone
        ; map coords: mx = camx + rx + c, my = camy + ry + r
        ld      a,(rbt_tm_camx)
        ld      hl,rbt_tm_rx
        add     a,(hl)
        ld      hl,rbt_tm_c
        add     a,(hl)
        ld      b,a
        ld      a,(rbt_tm_camy)
        ld      hl,rbt_tm_ry
        add     a,(hl)
        ld      hl,rbt_tm_r
        add     a,(hl)
        ld      c,a
        call    rbt_tm_mapat    ; A = tile id (0 OOB)
        ld      d,a
        ; screen cell: col = vx + rx + c, row = vy + ry + r
        ld      a,(rbt_tm_vx)
        ld      hl,rbt_tm_rx
        add     a,(hl)
        ld      hl,rbt_tm_c
        add     a,(hl)
        ld      b,a
        ld      a,(rbt_tm_vy)
        ld      hl,rbt_tm_ry
        add     a,(hl)
        ld      hl,rbt_tm_r
        add     a,(hl)
        ld      c,a
        call    rbt_tm_cell
        ld      hl,rbt_tm_c
        inc     (hl)
        jr      _dc
_rdone  ld      hl,rbt_tm_r
        inc     (hl)
        jr      _dr

; ----------------------------------------------------------------------------
; rbt_tm_draw - blit the whole view
; ----------------------------------------------------------------------------
rbt_tm_draw:
        xor     a
        ld      (rbt_tm_rx),a
        ld      (rbt_tm_ry),a
        ld      a,(rbt_tm_vw)
        ld      (rbt_tm_rw),a
        ld      a,(rbt_tm_vh)
        ld      (rbt_tm_rh),a
        jp      rbt_tm_blit

; ----------------------------------------------------------------------------
; rbt_tm_redraw - B,C,D,E = view cells to redraw
; ----------------------------------------------------------------------------
rbt_tm_redraw:
        ld      a,b
        ld      (rbt_tm_rx),a
        ld      a,c
        ld      (rbt_tm_ry),a
        ld      a,d
        ld      (rbt_tm_rw),a
        ld      a,e
        ld      (rbt_tm_rh),a
        jp      rbt_tm_blit

; ----------------------------------------------------------------------------
; rbt_tm_scroll - A = dir (0=left 1=right 2=up 3=down), B = steps.
; v1: adjust camera + full redraw per step.
; ----------------------------------------------------------------------------
rbt_tm_scroll:
        and     3
        ld      e,a             ; dir
        ld      (rbt_tm_dir),a  ; keep it — the dispatch below consumes e
        ld      a,b
        or      a
        ret     z
        ld      d,a             ; steps
_sl     push    de
        ld      a,e
        or      a
        jr      nz,_s1
        ld      a,(rbt_tm_camx) ; left: camx--
        or      a
        jr      z,_snext
        dec     a
        ld      (rbt_tm_camx),a
        jr      _sgo
_s1     dec     e
        jr      nz,_s2
        ld      a,(rbt_tm_camx) ; right: camx++ while camx+vw < mw
        ld      hl,rbt_tm_vw
        add     a,(hl)
        ld      hl,rbt_tm_mw
        cp      (hl)
        jr      nc,_snext
        ld      hl,rbt_tm_camx
        inc     (hl)
        jr      _sgo
_s2     dec     e
        jr      nz,_s3
        ld      a,(rbt_tm_camy) ; up: camy--
        or      a
        jr      z,_snext
        dec     a
        ld      (rbt_tm_camy),a
        jr      _sgo
_s3     ld      a,(rbt_tm_camy) ; down: camy++ while camy+vh < mh
        ld      hl,rbt_tm_vh
        add     a,(hl)
        ld      hl,rbt_tm_mh
        cp      (hl)
        jr      nc,_snext
        ld      hl,rbt_tm_camy
        inc     (hl)
_sgo
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jr      nz,_sfull       ; SC5 has no nametable to shift —
        endif                   ; every direction redraws the view
        ld      a,(rbt_tm_dir)
        or      a
        jr      z,_sleft
        dec     a
        jr      z,_sright
_sfull  call    rbt_tm_draw     ; up/down (and all dirs on SC5): full redraw
        jr      _snext
_sright call    rbt_tm_shiftl   ; camx++ -> content shifts left
        call    rbt_tm_edger
        jr      _snext
_sleft  call    rbt_tm_shiftr   ; camx-- -> content shifts right
        call    rbt_tm_edgel
_snext  pop     de
        dec     d
        jr      nz,_sl
        ret

; ----------------------------------------------------------------------------
; rbt_tm_shiftl / rbt_tm_shiftr - shift the view's nametable cells by one
; horizontally, so each cell shows its neighbour's pattern (content scroll).
; ----------------------------------------------------------------------------
rbt_tm_shiftl:
        xor     a
        ld      (rbt_tm_r),a    ; r = 0..vh-1
_slrow  ld      a,(rbt_tm_r)
        ld      hl,rbt_tm_vh
        cp      (hl)
        ret     nc
        ; dest addr = nt + (row)*32 + vx ... write right-neighbour's value
        call    rbt_tm_ntrow          ; HL = nt + row*32 + vx
        ld      b,0
        ld      a,(rbt_tm_vw)
        dec     a
        ld      b,a
_slcol  push    bc
        push    hl
        inc     hl
        call    rbt_vraddr
        in      a,(#98)         ; value of cell to the right
        pop     hl
        push    af
        call    rbt_vwaddr
        pop     af
        out     (#98),a
        inc     hl
        pop     bc
        djnz    _slcol
        ld      hl,rbt_tm_r
        inc     (hl)
        jr      _slrow

rbt_tm_shiftr:
        xor     a
        ld      (rbt_tm_r),a
_srrow  ld      a,(rbt_tm_r)
        ld      hl,rbt_tm_vh
        cp      (hl)
        ret     nc
        call    rbt_tm_ntrow
        ld      a,(rbt_tm_vw)
        dec     a
        ld      d,0
        ld      e,a
        add     hl,de           ; start at the right edge, walk left
        ld      b,a
_srcol  push    bc
        push    hl
        dec     hl
        call    rbt_vraddr
        in      a,(#98)
        pop     hl
        push    af
        call    rbt_vwaddr
        pop     af
        out     (#98),a
        dec     hl
        pop     bc
        djnz    _srcol
        ld      hl,rbt_tm_r
        inc     (hl)
        jr      _srrow

; HL = nametable addr of view-cell (vx, vy+r)
rbt_tm_ntrow  ld      a,(rbt_tm_vy)
        ld      hl,rbt_tm_r
        add     a,(hl)          ; screen row
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; row*32
        ld      a,(rbt_tm_vx)
        ld      d,#18           ; nt base #1800
        ld      e,a
        add     hl,de
        ret

; ----------------------------------------------------------------------------
; edge column redraws after a shift — draw the newly-revealed map cells.
; ----------------------------------------------------------------------------
rbt_tm_edger:
        ld      a,(rbt_tm_vw)
        dec     a
        ld      (rbt_tm_c),a    ; view col = vw-1
        jp      rbt_tm_edge
rbt_tm_edgel:
        xor     a
        ld      (rbt_tm_c),a    ; view col = 0
rbt_tm_edge:
        xor     a
        ld      (rbt_tm_r),a
_er     ld      a,(rbt_tm_r)
        ld      hl,rbt_tm_vh
        cp      (hl)
        ret     nc
        ; map coords: mx = camx + c, my = camy + r
        ld      a,(rbt_tm_camx)
        ld      hl,rbt_tm_c
        add     a,(hl)
        ld      b,a
        ld      a,(rbt_tm_camy)
        ld      hl,rbt_tm_r
        add     a,(hl)
        ld      c,a
        call    rbt_tm_mapat
        ld      d,a
        ; screen cell: col = vx + c, row = vy + r
        ld      a,(rbt_tm_vx)
        ld      hl,rbt_tm_c
        add     a,(hl)
        ld      b,a
        ld      a,(rbt_tm_vy)
        ld      hl,rbt_tm_r
        add     a,(hl)
        ld      c,a
        call    rbt_tm_cell
        ld      hl,rbt_tm_r
        inc     (hl)
        jr      _er

; ----------------------------------------------------------------------------
; rbt_tileat - B=tx, C=ty (map coords) -> A = tile id, 255 when OOB
; ----------------------------------------------------------------------------
rbt_tileat:
        ld      a,b
        ld      hl,rbt_tm_mw
        cp      (hl)
        jr      nc,_oob
        ld      a,c
        ld      hl,rbt_tm_mh
        cp      (hl)
        jr      nc,_oob
        jp      rbt_tm_mapat
_oob    ld      a,255
        ret

; ----------------------------------------------------------------------------
; rbt_tileatset - B=tx, C=ty, D=id : write map cell if in bounds, then
; redraw the cell when it's inside the view.
; ----------------------------------------------------------------------------
rbt_tileatset:
        ld      a,b
        ld      hl,rbt_tm_mw
        cp      (hl)
        ret     nc
        ld      a,c
        ld      hl,rbt_tm_mh
        cp      (hl)
        ret     nc
        ld      a,d
        ld      (rbt_tm_tid),a
        ; addr = cells + ty*mw + tx  (same calc as mapat)
        ld      a,c
        ld      hl,rbt_tm_mw
        ld      e,(hl)
        ld      d,0
        ld      hl,0
        or      a
        jr      z,_row
_mul    add     hl,de
        dec     a
        jr      nz,_mul
_row    ld      d,0
        ld      e,b
        add     hl,de
        ld      de,(rbt_tm_cells)
        add     hl,de
        ld      a,(rbt_tm_tid)
        ld      (hl),a
        ; in view? view col = tx - camx, row = ty - camy
        ld      a,b
        ld      hl,rbt_tm_camx
        sub     (hl)
        ret     c
        ld      hl,rbt_tm_vw
        cp      (hl)
        ret     nc
        ld      b,a
        ld      a,c
        ld      hl,rbt_tm_camy
        sub     (hl)
        ret     c
        ld      hl,rbt_tm_vh
        cp      (hl)
        ret     nc
        ld      c,a
        ld      a,(rbt_tm_vx)
        add     a,b
        ld      b,a
        ld      a,(rbt_tm_vy)
        add     a,c
        ld      c,a
        ld      a,(rbt_tm_tid)
        ld      d,a
        jp      rbt_tm_cell

; ----------------------------------------------------------------------------
; rbt_tileflags - A = tile id -> A = flags byte (0 if out of range)
; ----------------------------------------------------------------------------
rbt_tileflags:
        ld      hl,rbt_tm_n
        cp      (hl)
        jr      nc,_z
        ld      hl,(rbt_tm_tflags)
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        ret
_z      xor     a
        ret

; ----------------------------------------------------------------------------
; data
; ----------------------------------------------------------------------------
rbt_tm_pa       defw 0          ; pattern addr of cell being drawn
rbt_tm_th       defb 0          ; pattern third (0/1/2) of the cell
rbt_tm_dir      defb 0          ; last scroll direction
rbt_tm_att      defb 0          ; attr byte being converted
rbt_tm_tid      defb 0          ; tile id scratch
rbt_tm_rx       defb 0          ; blit rect (view cells)
rbt_tm_ry       defb 0
rbt_tm_rw       defb 0
rbt_tm_rh       defb 0
