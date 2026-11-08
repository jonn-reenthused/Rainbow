; ============================================================================
; rbt_pixel_asm - pixel addressing, PLOT / POINT / LINE / SHOWPIC (MSX1/MSX2)
;
; Screen 2 with the identity name table: cell (y>>3, x>>3) owns pattern
; index (y>>3)*32 + (x>>3), so pixel (x,y)'s pattern byte lives at VRAM
; ((y>>3)*32 + (x>>3))*8 + (y&7) — a linear bitmap. Access is read-
; modify-write through port #98.
;
; On RBT_MSX2 the *_5 paths run when rbt_smode=1: Screen 5 is a 4bpp
; bitmap (addr = y*128 + x/2, nibble = x&1), and the 1bpp truth lives in
; the rbt_shadow RAM plane (same index the SC2 routine computes) so
; PLOT/POINT keep ZX bit semantics.
; ============================================================================

rbt_bitmask     defb #80,#40,#20,#10,#08,#04,#02,#01

; ----------------------------------------------------------------------------
; rbt_pix - pixel (x=C, y=B) -> HL = VRAM pattern address, A = bit mask
; ----------------------------------------------------------------------------
rbt_pix:
        ld      a,b
        and     #f8
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl           ; (y&~7)*4 = (y>>3)*32 = cell-row base
        ld      a,c
        rrca
        rrca
        rrca
        and     31              ; x>>3
        or      l
        ld      l,a             ; HL = cell index
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8
        ld      a,b
        and     7
        or      l
        ld      l,a             ; += pixel row (low bits are 0)
        ld      a,c
        and     7
        push    hl
        ld      hl,rbt_bitmask
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        pop     hl
        ret

; ----------------------------------------------------------------------------
; rbt_plot - plot pixel (x=C, y=B). Honours rbt_over (1 = invert).
; ----------------------------------------------------------------------------
rbt_plot:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_plot5
        endif
        call    rbt_pix         ; HL = addr, A = mask
        ld      c,a             ; C = mask
        call    rbt_vraddr
        in      a,(#98)
        ld      b,a             ; B = current byte
        ld      a,(rbt_over)
        or      a
        jr      z,_set
        ld      a,b
        xor     c
        jr      _wr
_set    ld      a,b
        or      c
_wr     ld      b,a
        call    rbt_vwaddr      ; HL still holds the cell addr
        ld      a,b
        out     (#98),a
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_plot5 - Screen 5 pixel plot. Updates the shadow bit (set, or toggle
; on OVER), then RMWs the VRAM nibble: bit set -> fg, clear -> bg.
; ----------------------------------------------------------------------------
rbt_plot5:                      ; pixel (x=C, y=B)
        call    rbt_pix         ; HL = shadow index, A = bit mask
        push    de
        ld      de,rbt_shadow
        add     hl,de           ; HL = shadow byte
        pop     de
        ld      d,a             ; D = mask
        ld      a,(rbt_over)
        or      a
        jr      z,_s
        ld      a,d
        xor     (hl)
        jr      _w
_s      ld      a,d
        or      (hl)
_w      ld      (hl),a          ; shadow updated
        and     d               ; NZ = pixel now set
        push    af
        push    bc              ; save x in C (colbyte clobbers it)
        call    rbt_colbyte     ; A = fg<<4|bg
        ld      e,a             ; E = colour byte
        pop     bc              ; B = y, C = x
        pop     af              ; Z/NZ from the shadow bit
        ld      a,e
        jr      nz,_ink
        and     #0f             ; bg nibble value
        jr      _have
_ink    rrca
        rrca
        rrca
        rrca
        and     #0f             ; fg nibble value
_have   ld      d,a             ; D = pixel colour nibble
        ; VRAM addr = y*128 + x/2
        ld      l,b
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; y*128
        ld      a,c
        and     1               ; x&1: 0 = left (hi nibble), 1 = right
        ld      b,a
        srl     c               ; x/2
        ld      a,c
        or      l
        ld      l,a             ; HL = VRAM addr
        call    rbt_vraddr5
        in      a,(#98)
        ld      c,a             ; C = old byte
        ld      a,b
        or      a
        jr      nz,_lo
        ld      a,d
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; colour in the high nibble
        ld      b,a
        ld      a,c
        and     #0f
        jr      _mg
_lo     ld      a,c
        and     #f0
        ld      b,d
_mg     or      b               ; merged byte
        ld      b,a
        call    rbt_vwaddr5
        ld      a,b
        out     (#98),a
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_point - test pixel (x=C, y=B). Out: A = 1 set, 0 clear
; ----------------------------------------------------------------------------
rbt_point:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_point5
        endif
        call    rbt_pix
        ld      b,a
        call    rbt_vraddr
        in      a,(#98)
        and     b
        ret     z
        ld      a,1
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_point5 - Screen 5 point test: the shadow plane holds the ZX-exact
; bit, so no VRAM read is needed at all.
; ----------------------------------------------------------------------------
rbt_point5:
        call    rbt_pix         ; HL = shadow index, A = mask
        ld      b,a
        ld      de,rbt_shadow
        add     hl,de
        ld      a,(hl)
        and     b
        ret     z
        ld      a,1
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_line - draw line from (C,B) to (rbt_lx,rbt_ly) - Bresenham in the
; additive form (all accumulators unsigned, no signed compares).
; Honours rbt_over via rbt_plot. Clobbers everything.
; ----------------------------------------------------------------------------
rbt_line:
        ld      a,b
        ld      (rbt_y0),a
        ld      a,c
        ld      (rbt_x0),a
        ; dx = |x1 - x|, sx = step
        ld      a,(rbt_lx)
        sub     c
        jr      nc,_dxp
        neg
_dxp    ld      l,a
        ld      h,0
        ld      (rbt_ldx),hl
        ld      a,(rbt_lx)
        cp      c
        ld      a,1
        jr      nc,_sx
        ld      a,-1
_sx     ld      (rbt_lsx),a
        ; dy = |y1 - y|, sy = step
        ld      a,(rbt_ly)
        sub     b
        jr      nc,_dyp
        neg
_dyp    ld      l,a
        ld      h,0
        ld      (rbt_ldy),hl
        ld      a,(rbt_ly)
        cp      b
        ld      a,1
        jr      nc,_sy
        ld      a,-1
_sy     ld      (rbt_lsy),a
        ; major axis: 0 = x (dx >= dy), 1 = y
        ld      hl,(rbt_ldx)
        ld      de,(rbt_ldy)
        or      a
        sbc     hl,de
        ld      a,0
        jr      nc,_maj
        inc     a
_maj    ld      (rbt_laxis),a
        ld      hl,(rbt_ldx)
        or      a
        jr      z,_acc
        ld      hl,(rbt_ldy)
_acc    srl     h
        rr      l               ; acc = long-axis delta / 2
        ld      (rbt_lacc),hl
_lp     ld      a,(rbt_x0)
        ld      c,a
        ld      a,(rbt_y0)
        ld      b,a
        call    rbt_plot
        ld      a,(rbt_x0)
        ld      hl,rbt_lx
        cp      (hl)
        jr      nz,_go
        ld      a,(rbt_y0)
        ld      hl,rbt_ly
        cp      (hl)
        ret     z               ; reached the endpoint
_go     ld      a,(rbt_laxis)
        or      a
        jr      nz,_ym
        ; x-major: x += sx; acc += dy; if acc >= dx: acc -= dx, y += sy
        ld      a,(rbt_lsx)
        ld      hl,rbt_x0
        add     a,(hl)
        ld      (hl),a
        ld      hl,(rbt_lacc)
        ld      de,(rbt_ldy)
        add     hl,de
        ld      de,(rbt_ldx)
        or      a
        sbc     hl,de
        jr      c,_xns
        ld      (rbt_lacc),hl
        ld      a,(rbt_lsy)
        ld      hl,rbt_y0
        add     a,(hl)
        ld      (hl),a
        jr      _lp
_xns    add     hl,de           ; acc+dy < dx: keep acc+dy
        ld      (rbt_lacc),hl
        jr      _lp
_ym     ; y-major: y += sy; acc += dx; if acc >= dy: acc -= dy, x += sx
        ld      a,(rbt_lsy)
        ld      hl,rbt_y0
        add     a,(hl)
        ld      (hl),a
        ld      hl,(rbt_lacc)
        ld      de,(rbt_ldx)
        add     hl,de
        ld      de,(rbt_ldy)
        or      a
        sbc     hl,de
        jr      c,_yns
        ld      (rbt_lacc),hl
        ld      a,(rbt_lsx)
        ld      hl,rbt_x0
        add     a,(hl)
        ld      (hl),a
        jr      _lp
_yns    add     hl,de
        ld      (rbt_lacc),hl
        jr      _lp

; ----------------------------------------------------------------------------
; rbt_showpic - blit an encoded .rbc screen: 6144 pattern bytes then 6144
; colour bytes, straight into the Screen 2 tables. In: HL = asset data.
; ----------------------------------------------------------------------------
rbt_showpic:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_showpic5
        endif
        ld      (rbt_sp_src),hl
        push    hl
        pop     de              ; DE = source
        ld      hl,#0000        ; pattern table
        ld      bc,6144
        call    rbt_vwrite
        ld      hl,(rbt_sp_src)
        ld      de,6144
        add     hl,de           ; source = asset + 6144 (colour data)
        push    hl
        pop     de
        ld      hl,#2000        ; colour table
        ld      bc,6144
        call    rbt_vwrite
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_showpic5 - Screen 5 .rbc: per cell-row expand the pattern byte with
; its colour byte into 4 nibbles (rbt_xpnib) and mirror the pattern into
; the shadow plane. Three running pointers walk the source halves; the
; VRAM destination is recomputed per cell-row (cells aren't contiguous).
; ----------------------------------------------------------------------------
rbt_showpic5:                   ; HL = .rbc (6144 pattern + 6144 colour)
        ld      (rbt_sp_src),hl ; pattern src ptr
        push    hl
        pop     de
        ld      hl,rbt_shadow
        ld      (rbt_sp_sh),hl  ; shadow dst ptr
        ld      hl,6144
        add     hl,de
        ld      (rbt_sp_cp),hl  ; colour src ptr
        ld      hl,0
        ld      (rbt_sp_i),hl   ; cell counter 0..767
_cell   ld      hl,(rbt_sp_i)
        ld      a,h
        cp      3               ; 768 cells = #0300
        ret     nc
        ; VA of cell top-left = (idx>>5)*1024 + (idx&31)*4
        ld      a,l
        rrca
        rrca
        rrca
        rrca
        rrca
        and     7               ; l>>5 (rows above this 8-col band)
        ld      e,a
        ld      a,h
        add     a,a
        add     a,a
        add     a,a             ; h*8
        or      e               ; A = cell row r
        add     a,a
        add     a,a             ; r*4 -> hi byte of r*1024
        ld      d,a
        ld      a,l
        and     #1f             ; cell col
        add     a,a
        add     a,a             ; col*4
        ld      e,a             ; DE = vram addr
        ld      (rbt_sp_va),de
        ld      b,8             ; 8 rows in the cell
_row    push    bc
        ld      hl,(rbt_sp_src) ; pattern byte -> A, ptr++
        ld      a,(hl)
        inc     hl
        ld      (rbt_sp_src),hl
        ld      hl,(rbt_sp_sh)  ; shadow store, ptr++
        ld      (hl),a
        inc     hl
        ld      (rbt_sp_sh),hl
        ld      hl,(rbt_sp_cp)  ; colour byte -> C, ptr++
        ld      c,(hl)
        inc     hl
        ld      (rbt_sp_cp),hl
        push    af              ; pattern byte survives vaddr set
        ld      hl,(rbt_sp_va)
        call    rbt_vwaddr5
        pop     af
        call    rbt_xpnib       ; 8 bits -> 4 bytes out #98
        ld      hl,(rbt_sp_va)  ; next row: +128 bytes
        ld      de,128
        add     hl,de
        ld      (rbt_sp_va),hl
        pop     bc
        djnz    _row
        ld      hl,(rbt_sp_i)
        inc     hl
        ld      (rbt_sp_i),hl
        jp      _cell

rbt_sp_sh       defw 0          ; running shadow pointer (showpic5)
rbt_sp_cp       defw 0          ; running colour-source pointer
rbt_sp_va       defw 0          ; current cell-row VRAM address
rbt_sp_i        defw 0          ; cell counter
        endif

; data
rbt_x0          defb 0
rbt_y0          defb 0
rbt_lx          defb 0
rbt_ly          defb 0
rbt_lsx         defb 0
rbt_lsy         defb 0
rbt_laxis       defb 0
rbt_ldx         defw 0
rbt_ldy         defw 0
rbt_lacc        defw 0
rbt_sp_src      defw 0
