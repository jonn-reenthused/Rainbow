; ============================================================================
; rbt_pixel_asm - pixel addressing, PLOT / POINT / LINE
; ============================================================================

rbt_bitmask     defb #80,#40,#20,#10,#08,#04,#02,#01

; ----------------------------------------------------------------------------
; rbt_pix - pixel (x=C, y=B) -> HL = screen address, A = bit mask
; ----------------------------------------------------------------------------
rbt_pix:
        ld      a,b
        and     #c0
        rra
        rra
        rra
        and     %00011000       ; y7y6 -> H bits 4,3
        ld      h,a
        ld      a,b
        and     7
        or      h
        or      #40
        ld      h,a             ; H = #40 | (y&c0)>>3 | (y&7)
        ld      a,b
        and     #38
        add     a,a
        add     a,a             ; (y&38)<<2
        ld      l,a
        ld      a,c
        rra
        rra
        rra
        and     %00011111       ; x>>3
        or      l
        ld      l,a
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
        call    rbt_pix
        ld      b,a
        ld      a,(rbt_over)
        or      a
        ld      a,(hl)
        jr      z,_set
        xor     b
        jr      _wr
_set    or      b
_wr     ld      (hl),a
        ret

; ----------------------------------------------------------------------------
; rbt_point - test pixel (x=C, y=B). Out: A = 1 set, 0 clear
; ----------------------------------------------------------------------------
rbt_point:
        call    rbt_pix
        and     (hl)
        ret     z
        ld      a,1
        ret

; ----------------------------------------------------------------------------
; rbt_line - draw line from (C,B) to (rbt_lx,rbt_ly) - Bresenham.
; Clobbers everything. rbt_over honoured via rbt_plot.
; ----------------------------------------------------------------------------
rbt_lx          defb 0
rbt_ly          defb 0

rbt_line:
        ; compute dx = |lx - x|, sx = sign
        ld      a,(rbt_lx)
        sub     c
        jr      nc,_dxp
        neg
_dxp    ld      d,a             ; D = dx
        ld      a,(rbt_lx)
        cp      c
        ld      a,1
        jr      nc,_sx
        ld      a,-1
_sx     ld      (rbt_lsx),a
        ld      a,(rbt_ly)
        sub     b
        jr      nc,_dyp
        neg
_dyp    ld      e,a             ; E = dy
        ld      a,(rbt_ly)
        cp      b
        ld      a,1
        jr      nc,_sy
        ld      a,-1
_sy     ld      (rbt_lsy),a
        ; err = dx - dy
        ld      a,d
        sub     e
        ld      h,a             ; H = err
_loop   push    hl
        push    de
        call    rbt_plot        ; plot (C,B)
        pop     de
        pop     hl
        ; if x==lx and y==ly done
        ld      a,(rbt_lx)
        cp      c
        jr      nz,_step
        ld      a,(rbt_ly)
        cp      b
        ret     z
_step   ; e2 = 2*err
        ld      a,h
        add     a,a
        ; if e2 > -dy: err -= dy; x += sx
        ld      l,a
        ld      a,e
        neg
        cp      l               ; -dy vs e2: e2 > -dy?
        jr      nc,_skipx       ; if -dy >= e2 skip? (cp l: NC means -dy>=e2)
        ld      a,h
        sub     e
        ld      h,a             ; err -= dy
        ld      a,(rbt_lsx)
        add     a,c
        ld      c,a             ; x += sx
_skipx  ; if e2 < dx: err += dx; y += sy
        ld      a,l             ; e2
        cp      d               ; e2 < dx?
        jr      nc,_skipy
        ld      a,h
        add     a,d
        ld      h,a             ; err += dx
        ld      a,(rbt_lsy)
        add     a,b
        ld      b,a             ; y += sy
_skipy  jr      _loop

rbt_lsx         defb 0
rbt_lsy         defb 0

; ----------------------------------------------------------------------------
; rbt_showpic - HL -> 6912-byte screen (bitmap + attrs) copied to #4000.
; ----------------------------------------------------------------------------
rbt_showpic:
        ld      de,#4000
        ld      bc,6912
        ldir
        ret
