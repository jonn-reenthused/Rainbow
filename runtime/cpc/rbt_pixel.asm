; ============================================================================
; rbt_pixel_asm - CPC screen primitives (mode 1 assumed: 320x200, 2bpp)
;
; The Rainbow logical screen is 256x192 at the top-left of the CPC screen.
; The base is RBT_SCRB - #C000 on both: on cpc6128 #4000-#7FFF is
; the bank window (the compiler emits the equ). CPC mode-1 layout:
; 4 pixels per byte, pixel k of a byte holds its 2-bit pen at positions
; (7-k) hi and (3-k) lo. Lines are interleaved:
;   addr = RBT_SCRB + (y & 7) * #800 + (y >> 3) * 80 + xbyte
; resolved via the 192-entry line table below.
;
; Pen convention for the port layer:
;   pen 0 = PAPER colour, pen 1 = INK colour (text, sprites, tiles)
;   pens 2,3 are free for future multicolour sprite work.
; Sprite/tile/font data expand 1bpp -> pen1/paper0, for which the nibble
; bits land directly at positions 3..0 (expansion is free).
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_laddr - B = byte column (0..63), C = line (0..191) -> HL = screen addr.
; Uses A, DE, HL. Line 0 = RBT_SCRB.
;
; When hardware scrolling is active (rbt_scr_son) and the line's char row is
; above the band split, the address anchors to the LOGICAL position: the
; 2048-byte band holding the line is a circular buffer indexed by
;   off = (soff + charrow*80 + bytecol) & 2047
; so screen byte (col,row) maps to the tape position the CRTC displays there.
; off is also stored in rbt_scr_woff for the band-wrap checks in the sprite
; copy loops; rbt_scr_wnat marks lines that stayed natural (band rows).
; ----------------------------------------------------------------------------
rbt_laddr:
        ld      a,(rbt_scr_son)
        or      a
        jr      z,rbt_laddrn
        ld      a,(rbt_scr_split)
        or      a
        jr      z,_lscr         ; no band -> every row scrolls
        ld      d,a
        ld      a,c
        rrca
        rrca
        rrca
        and     #1f             ; char row = line/8
        cp      d
        jr      c,_lscr         ; scrolled region
        ld      a,1
        ld      (rbt_scr_wnat),a ; band row: natural addressing
        jr      rbt_laddrn
_lscr   xor     a
        ld      (rbt_scr_wnat),a
        ; off = (soff + charrow*80 + B) & #7ff
        ld      a,c
        rrca
        rrca
        rrca
        and     #1f
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,rbt_scr_r80
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)          ; DE = charrow*80
        ld      hl,(rbt_scr_soff)
        add     hl,de
        ld      e,b
        ld      d,0
        add     hl,de           ; + byte col
        ld      a,h
        and     #07
        ld      h,a             ; mod 2048
        ld      (rbt_scr_woff),hl ; band offset for the copy loops' wrap check
        push    hl
        ld      a,c
        and     7
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,rbt_scr_lines
        add     hl,de           ; entries 0-7 are the band bases
        ld      a,(hl)
        inc     hl
        ld      h,(hl)
        ld      l,a             ; HL = band base for line&7
        pop     de
        add     hl,de           ; + off
        ret
rbt_laddrn:                     ; natural-layout address (ignores scroll)
        ld      a,b             ; column -> scratch (returned via HL add)
        ld      l,c
        ld      h,0
        add     hl,hl
        ld      de,rbt_scr_lines
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)
        ex      de,hl           ; HL = line base
        ld      e,a
        ld      d,0
        add     hl,de           ; + column
        ret

; char row * 80 lookup for the scrolled address path (25 rows, row*80)
rbt_scr_r80:    defw 0,80,160,240,320,400,480,560,640,720,800,880,960
                defw 1040,1120,1200,1280,1360,1440,1520,1600,1680,1760,1840,1920

; ----------------------------------------------------------------------------
; rbt_wsplit - split a dst byte run at the circular band's 2048-byte
; boundary. In: B = byte count, HL = dst (fresh from rbt_laddr so
; rbt_scr_woff/rbt_scr_wnat describe this row). Out: B = first-run count,
; rbt_scr_w2 = second-run count (0 = no wrap). Callers wrap HL themselves
; after the first run: HL -= #800 lands on this band's base (even when the
; band end crossed #ffff). Preserves DE,HL.
; ----------------------------------------------------------------------------
rbt_wsplit:
        xor     a
        ld      (rbt_scr_w2),a
        ld      a,(rbt_scr_son)
        or      a
        ret     z               ; not scrolling -> single run
        ld      a,(rbt_scr_wnat)
        or      a
        ret     nz              ; band row (natural) -> single run
        push    hl
        push    de
        ld      hl,(rbt_scr_woff)
        ld      de,#0800
        ex      de,hl           ; HL = 2048, DE = band offset
        or      a
        sbc     hl,de           ; HL = bytes to the band end (1..2048)
        ld      a,h
        or      a
        jr      nz,_wok         ; >= 256: whole run fits
        ld      a,l
        cp      b
        jr      nc,_wok         ; run ends before the band edge
        ld      e,a             ; E = first run = bytes to the edge
        ld      a,b
        sub     e
        ld      (rbt_scr_w2),a  ; second run = remainder
        ld      b,e
_wok    pop     de
        pop     hl
        ret

rbt_scr_w2      defb 0          ; band-wrap second-run count

; ----------------------------------------------------------------------------
; rbt_plot - C = pixel x (0..255), B = line y (0..191): plot a pen-1 pixel.
; ----------------------------------------------------------------------------
rbt_plot:
        ld      a,c
        and     3
        ld      e,a             ; E = pixel-in-byte
        ld      a,c
        rrca
        rrca
        and     #3f             ; byte col
        ld      d,a
        ld      c,b             ; C = line
        ld      b,d             ; B = col
        push    de              ; laddr clobbers DE
        call    rbt_laddr
        pop     de
        ; pen-1 bit for pixel k sits at position 3-k: mask = #08 >> k
        ld      a,#08
        ld      b,e
        or      b
        jr      z,_plw
        ld      b,e
_plsh   srl     a
        djnz    _plsh
_plw    or      (hl)
        ld      (hl),a
        ret

; ----------------------------------------------------------------------------
; rbt_point - C = x, B = y -> A = 1 if the pixel is non-paper, else 0
; ----------------------------------------------------------------------------
rbt_point:
        ld      a,c
        and     3
        ld      e,a
        ld      a,c
        rrca
        rrca
        and     #3f
        ld      d,a
        ld      c,b
        ld      b,d
        push    de
        call    rbt_laddr
        pop     de
        ; both pen bits of pixel k: #88 >> k
        ld      a,#88
        ld      b,e
        or      b
        jr      z,_ptt
        ld      b,e
_ptsh   srl     a
        djnz    _ptsh
_ptt    and     (hl)
        ret     z
        ld      a,1
        ret

; ----------------------------------------------------------------------------
; rbt_scrfill - fill a byte-rect with A.
;   B = byte col, C = start line, D = byte count, E = line count.
; ----------------------------------------------------------------------------
rbt_scrfill:
        ld      (rbt_sf_bv),a
        ld      a,e
        ld      (rbt_sf_lc),a
        ld      a,d
        ld      (rbt_sf_bw),a
_sfrow  call    rbt_laddr       ; HL = row base (B=col, C=line)
        push    bc
        ld      a,(rbt_sf_bw)
        ld      b,a
        call    rbt_wsplit      ; split at the band edge when scrolling
        ld      a,b
        pop     bc
        ld      e,a
        ld      a,(rbt_sf_bv)
_sfb    ld      (hl),a
        inc     hl
        dec     e
        jr      nz,_sfb
        ld      a,(rbt_scr_w2)
        or      a
        jr      z,_sfd
        ld      e,a
        ld      a,h
        sub     8
        ld      h,a             ; wrapped -> band base
        ld      a,(rbt_sf_bv)
_sfb2   ld      (hl),a
        inc     hl
        dec     e
        jr      nz,_sfb2
_sfd    inc     c
        ld      a,(rbt_sf_lc)
        dec     a
        ld      (rbt_sf_lc),a
        jr      nz,_sfrow
        ret

rbt_sf_bv       defb 0
rbt_sf_lc       defb 0
rbt_sf_bw       defb 0

; ----------------------------------------------------------------------------
; rbt_tile8 - draw an 8x8 1bpp tile/glyph, pen1 ink on pen0 paper.
;   DE = src (8 bytes), B = cell x (0..31), C = cell y (0..23)
; Each src byte expands to two pen-1 nibbles: hi nibble -> byte0, lo -> byte1.
; ----------------------------------------------------------------------------
rbt_tile8:
        ld      a,b
        add     a,a             ; byte col = cell*2
        ld      b,a
        ld      a,c
        add     a,a
        add     a,a
        add     a,a             ; line = cell*8
        ld      c,a
        ld      a,8
        ld      (rbt_t8_cnt),a
_t8l    push    de              ; laddr clobbers DE (src ptr)
        call    rbt_laddr       ; HL = line base + col; BC kept
        pop     de
        ld      a,(de)          ; 8 src pixels -> two pen-1 nibbles
        inc     de
        push    de
        ld      e,a
        rrca
        rrca
        rrca
        rrca
        and     #0f             ; hi nibble = px0..3
        ld      (hl),a
        inc     hl
        ld      a,e
        and     #0f             ; lo nibble = px4..7
        ld      (hl),a
        pop     de
        inc     c               ; next line
        ld      a,(rbt_t8_cnt)
        dec     a
        ld      (rbt_t8_cnt),a
        jr      nz,_t8l
        ret

rbt_t8_cnt      defb 0

; ----------------------------------------------------------------------------
; rbt_showpic - HL = CPC-encoded .rbc (192 lines x 64 bytes, y-linear,
; pen1/pen0 expanded). Copies each line into the interleaved screen.
; ----------------------------------------------------------------------------
rbt_showpic:
        xor     a
        ld      (rbt_sp_ln0),a  ; line
_spr    ld      a,(rbt_sp_ln0)
        cp      192
        ret     nc
        ld      c,a
        ld      b,0
        push    hl              ; src
        call    rbt_laddrn      ; loading screens fill the natural layout
        ex      de,hl           ; DE = dst
        pop     hl              ; HL = src
        ld      bc,64
        ldir
        ld      a,(rbt_sp_ln0)
        inc     a
        ld      (rbt_sp_ln0),a
        jr      _spr

rbt_sp_ln0      defb 0

; ----------------------------------------------------------------------------
; Line base addresses for pixel lines 0..191 - RBT_SCRB + the mode-1
; interleave offset.
; ----------------------------------------------------------------------------
rbt_scr_lines:
        defw RBT_SCRB+#0000,RBT_SCRB+#0800,RBT_SCRB+#1000,RBT_SCRB+#1800,RBT_SCRB+#2000,RBT_SCRB+#2800,RBT_SCRB+#3000,RBT_SCRB+#3800
        defw RBT_SCRB+#0050,RBT_SCRB+#0850,RBT_SCRB+#1050,RBT_SCRB+#1850,RBT_SCRB+#2050,RBT_SCRB+#2850,RBT_SCRB+#3050,RBT_SCRB+#3850
        defw RBT_SCRB+#00a0,RBT_SCRB+#08a0,RBT_SCRB+#10a0,RBT_SCRB+#18a0,RBT_SCRB+#20a0,RBT_SCRB+#28a0,RBT_SCRB+#30a0,RBT_SCRB+#38a0
        defw RBT_SCRB+#00f0,RBT_SCRB+#08f0,RBT_SCRB+#10f0,RBT_SCRB+#18f0,RBT_SCRB+#20f0,RBT_SCRB+#28f0,RBT_SCRB+#30f0,RBT_SCRB+#38f0
        defw RBT_SCRB+#0140,RBT_SCRB+#0940,RBT_SCRB+#1140,RBT_SCRB+#1940,RBT_SCRB+#2140,RBT_SCRB+#2940,RBT_SCRB+#3140,RBT_SCRB+#3940
        defw RBT_SCRB+#0190,RBT_SCRB+#0990,RBT_SCRB+#1190,RBT_SCRB+#1990,RBT_SCRB+#2190,RBT_SCRB+#2990,RBT_SCRB+#3190,RBT_SCRB+#3990
        defw RBT_SCRB+#01e0,RBT_SCRB+#09e0,RBT_SCRB+#11e0,RBT_SCRB+#19e0,RBT_SCRB+#21e0,RBT_SCRB+#29e0,RBT_SCRB+#31e0,RBT_SCRB+#39e0
        defw RBT_SCRB+#0230,RBT_SCRB+#0a30,RBT_SCRB+#1230,RBT_SCRB+#1a30,RBT_SCRB+#2230,RBT_SCRB+#2a30,RBT_SCRB+#3230,RBT_SCRB+#3a30
        defw RBT_SCRB+#0280,RBT_SCRB+#0a80,RBT_SCRB+#1280,RBT_SCRB+#1a80,RBT_SCRB+#2280,RBT_SCRB+#2a80,RBT_SCRB+#3280,RBT_SCRB+#3a80
        defw RBT_SCRB+#02d0,RBT_SCRB+#0ad0,RBT_SCRB+#12d0,RBT_SCRB+#1ad0,RBT_SCRB+#22d0,RBT_SCRB+#2ad0,RBT_SCRB+#32d0,RBT_SCRB+#3ad0
        defw RBT_SCRB+#0320,RBT_SCRB+#0b20,RBT_SCRB+#1320,RBT_SCRB+#1b20,RBT_SCRB+#2320,RBT_SCRB+#2b20,RBT_SCRB+#3320,RBT_SCRB+#3b20
        defw RBT_SCRB+#0370,RBT_SCRB+#0b70,RBT_SCRB+#1370,RBT_SCRB+#1b70,RBT_SCRB+#2370,RBT_SCRB+#2b70,RBT_SCRB+#3370,RBT_SCRB+#3b70
        defw RBT_SCRB+#03c0,RBT_SCRB+#0bc0,RBT_SCRB+#13c0,RBT_SCRB+#1bc0,RBT_SCRB+#23c0,RBT_SCRB+#2bc0,RBT_SCRB+#33c0,RBT_SCRB+#3bc0
        defw RBT_SCRB+#0410,RBT_SCRB+#0c10,RBT_SCRB+#1410,RBT_SCRB+#1c10,RBT_SCRB+#2410,RBT_SCRB+#2c10,RBT_SCRB+#3410,RBT_SCRB+#3c10
        defw RBT_SCRB+#0460,RBT_SCRB+#0c60,RBT_SCRB+#1460,RBT_SCRB+#1c60,RBT_SCRB+#2460,RBT_SCRB+#2c60,RBT_SCRB+#3460,RBT_SCRB+#3c60
        defw RBT_SCRB+#04b0,RBT_SCRB+#0cb0,RBT_SCRB+#14b0,RBT_SCRB+#1cb0,RBT_SCRB+#24b0,RBT_SCRB+#2cb0,RBT_SCRB+#34b0,RBT_SCRB+#3cb0
        defw RBT_SCRB+#0500,RBT_SCRB+#0d00,RBT_SCRB+#1500,RBT_SCRB+#1d00,RBT_SCRB+#2500,RBT_SCRB+#2d00,RBT_SCRB+#3500,RBT_SCRB+#3d00
        defw RBT_SCRB+#0550,RBT_SCRB+#0d50,RBT_SCRB+#1550,RBT_SCRB+#1d50,RBT_SCRB+#2550,RBT_SCRB+#2d50,RBT_SCRB+#3550,RBT_SCRB+#3d50
        defw RBT_SCRB+#05a0,RBT_SCRB+#0da0,RBT_SCRB+#15a0,RBT_SCRB+#1da0,RBT_SCRB+#25a0,RBT_SCRB+#2da0,RBT_SCRB+#35a0,RBT_SCRB+#3da0
        defw RBT_SCRB+#05f0,RBT_SCRB+#0df0,RBT_SCRB+#15f0,RBT_SCRB+#1df0,RBT_SCRB+#25f0,RBT_SCRB+#2df0,RBT_SCRB+#35f0,RBT_SCRB+#3df0
        defw RBT_SCRB+#0640,RBT_SCRB+#0e40,RBT_SCRB+#1640,RBT_SCRB+#1e40,RBT_SCRB+#2640,RBT_SCRB+#2e40,RBT_SCRB+#3640,RBT_SCRB+#3e40
        defw RBT_SCRB+#0690,RBT_SCRB+#0e90,RBT_SCRB+#1690,RBT_SCRB+#1e90,RBT_SCRB+#2690,RBT_SCRB+#2e90,RBT_SCRB+#3690,RBT_SCRB+#3e90
        defw RBT_SCRB+#06e0,RBT_SCRB+#0ee0,RBT_SCRB+#16e0,RBT_SCRB+#1ee0,RBT_SCRB+#26e0,RBT_SCRB+#2ee0,RBT_SCRB+#36e0,RBT_SCRB+#3ee0
        defw RBT_SCRB+#0730,RBT_SCRB+#0f30,RBT_SCRB+#1730,RBT_SCRB+#1f30,RBT_SCRB+#2730,RBT_SCRB+#2f30,RBT_SCRB+#3730,RBT_SCRB+#3f30
