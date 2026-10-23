; ============================================================================
; rbt_sprite_asm - masked sprite engine
; 16 slots x 14 bytes. Draws 1bpp sprites (any byte width, any pixel height)
; with per-byte masks at arbitrary pixel-x (on-the-fly right shift).
; Modes: 0 = mask (screen&mask)|bmp, 1 = or, 2 = xor.
; Erasing is the game's job (TILEMAP REDRAW / CLS) - AGD-style explicit model.
; 128K: slot +14 holds the asset's bank (#FF resident); every asset
; dereference is wrapped in rbt_pg_in/out so banked sprites just work.
; ============================================================================

RBT_NSLOTS      equ 16
RBT_SLOT        equ 15          ; bytes per slot
; slot offsets:
;  +0  flags: bit0 active, bit1 hidden
;  +1  x (pixels) +2  y (pixels)
;  +3  w (bytes) +4  h (pixels)
;  +5  frame +6,7 asset ptr
;  +8  attr +9  mode
;  +10 animFirst +11 animLast
;  +12 animFlags: bit0 pingpong, bit1 animating
;  +13 animDir (1 / -1)
;  +14 asset bank (#ff = resident)

rbt_sprites     defs RBT_NSLOTS*RBT_SLOT

; ----------------------------------------------------------------------------
; rbt_slot - A = sprite id -> IX = slot address. Preserves BC,DE,HL.
; ----------------------------------------------------------------------------
rbt_slot:
        and     RBT_NSLOTS-1
        push    de
        ld      e,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; id*16
        sub     e               ; id*15
        ld      e,a
        ld      d,0
        ld      ix,rbt_sprites
        add     ix,de
        pop     de
        ret

; ----------------------------------------------------------------------------
; rbt_sp_create - A=id, HL=asset, B=mode(0/1/2), C=x, D=y, E=asset bank
; asset: defb wb,h,nframes,attr, frame data...
; ----------------------------------------------------------------------------
rbt_sp_create:
        push    hl
        call    rbt_slot        ; preserves DE (E = bank)
        pop     hl
        ld      a,e
        ld      (ix+14),a       ; asset bank (#ff resident)
        ld      (ix+6),l
        ld      (ix+7),h        ; asset ptr
        ld      (ix+0),1        ; active
        ld      (ix+1),c        ; x
        ld      (ix+2),d        ; y
        ld      a,(hl)
        ld      (ix+3),a        ; w bytes
        inc     hl
        ld      a,(hl)
        ld      (ix+4),a        ; h
        inc     hl
        inc     hl              ; skip nframes
        ld      a,(hl)
        ld      (ix+8),a        ; attr
        xor     a
        ld      (ix+5),a        ; frame 0
        ld      (ix+9),b        ; mode
        ld      (ix+12),a       ; anim off
        ret

; ----------------------------------------------------------------------------
; rbt_sp_move - A=id, B=dx (signed), C=dy (signed). Clamps to screen.
; ----------------------------------------------------------------------------
rbt_sp_move:
        call    rbt_slot
        ; x += B with clamp to [0, 256 - w*8]
        ld      e,(ix+1)        ; old x
        ld      a,e
        add     a,b
        bit     7,b
        jr      nz,_mvxn
        ; positive dx: clamp to maxX
        jr      c,_mvxmax       ; wrapped past 255
        ld      d,a             ; D = new x
        ld      a,(ix+3)
        add     a,a
        add     a,a
        add     a,a             ; w*8
        neg                     ; 256 - w*8 = maxX
        cp      d
        jr      c,_mvxset       ; new > maxX -> store maxX (A)
        ld      a,d
        jr      _mvxset
_mvxmax ld      a,(ix+3)
        add     a,a
        add     a,a
        add     a,a
        neg
        jr      _mvxset
_mvxn   ; negative dx: underflow (new > old) -> 0
        cp      e
        jr      c,_mvxset       ; new < old: normal move, A = new x
        xor     a
_mvxset ld      (ix+1),a
_mvy    ; y += C with clamp to [0, 192 - h]
        ld      e,(ix+2)
        ld      a,e
        add     a,c
        bit     7,c
        jr      nz,_mvyn
        jr      c,_mvymax
        ld      d,a             ; D = new y
        ld      a,(ix+4)
        neg                     ; 256 - h
        add     a,192-256       ; = 192 - h
        cp      d
        jr      c,_mvyset
        ld      a,d
        jr      _mvyset
_mvymax ld      a,(ix+4)
        neg
        add     a,192-256
        jr      _mvyset
_mvyn   cp      e
        jr      c,_mvyset
        xor     a
_mvyset ld      (ix+2),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_place - A=id, B=x, C=y
; ----------------------------------------------------------------------------
rbt_sp_place:
        call    rbt_slot
        ld      (ix+1),b
        ld      (ix+2),c
        ret

; ----------------------------------------------------------------------------
; rbt_sp_frame - A=id, B=frame (clamped to nframes-1)
; ----------------------------------------------------------------------------
rbt_sp_frame:
        call    rbt_slot
        ld      a,(ix+14)       ; asset bank
        ld      hl,rbt_sp_prev
        call    rbt_pg_in
        ld      l,(ix+6)
        ld      h,(ix+7)
        inc     hl
        inc     hl
        ld      a,(hl)          ; nframes
        dec     a
        cp      b
        jr      nc,_ok
        ld      b,a
_ok     ld      (ix+5),b
        ld      hl,rbt_sp_prev
        jp      rbt_pg_out

; ----------------------------------------------------------------------------
; rbt_sp_anim - A=id, B=first frame, C=last frame, D=0 loop / 1 pingpong
; ----------------------------------------------------------------------------
rbt_sp_anim:
        call    rbt_slot
        ld      (ix+10),b
        ld      (ix+11),c
        ld      (ix+5),b        ; frame = first
        ld      a,d
        and     1
        or      2               ; bit1 = animating
        ld      (ix+12),a
        ld      (ix+13),1
        ret

; ----------------------------------------------------------------------------
; rbt_sp_show / rbt_sp_hide / rbt_sp_kill - A=id
; ----------------------------------------------------------------------------
rbt_sp_show:
        call    rbt_slot
        ld      (ix+0),1
        ret
rbt_sp_hide:
        call    rbt_slot
        ld      a,(ix+0)
        or      2
        ld      (ix+0),a
        ret
rbt_sp_kill:
        call    rbt_slot
        ld      (ix+0),0
        ret

; ----------------------------------------------------------------------------
; rbt_sp_attr - A=id, B=attr byte
; ----------------------------------------------------------------------------
rbt_sp_attr:
        call    rbt_slot
        ld      (ix+8),b
        ret

; ----------------------------------------------------------------------------
; rbt_spx / rbt_spy - A=id -> A = x / y
; ----------------------------------------------------------------------------
rbt_spx:
        call    rbt_slot
        ld      a,(ix+1)
        ret
rbt_spy:
        call    rbt_slot
        ld      a,(ix+2)
        ret

; ----------------------------------------------------------------------------
; rbt_paddr - A = pixel y -> HL = bitmap address of line start (col 0).
; Preserves BC,DE. Clips nothing: caller must range-check y.
; ----------------------------------------------------------------------------
rbt_paddr:
        ld      l,a
        and     #c0
        rrca
        rrca
        rrca                    ; third * 8
        ld      h,a
        ld      a,l
        and     7
        or      h
        add     a,#40
        ld      h,a             ; H = #40 + third*8 + line
        ld      a,l
        and     #38
        add     a,a
        add     a,a             ; row * 32
        ld      l,a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_draw - A = id: draw slot now (if active and not hidden).
; ----------------------------------------------------------------------------
rbt_sp_draw:
        call    rbt_slot
        ; fall through to draw at IX
rbt_sp_drawix:
        ld      a,(ix+0)
        bit     0,a
        ret     z               ; inactive
        bit     1,a
        ret     nz              ; hidden
        ld      a,(ix+14)       ; page the sprite asset's bank
        ld      hl,rbt_sp_prev
        call    rbt_pg_in
        ; ---- compute frame data pointers ----
        ld      l,(ix+6)
        ld      h,(ix+7)        ; HL = asset
        ld      a,(hl)
        ld      (rbt_sp_w),a    ; w bytes
        inc     hl
        ld      a,(hl)
        ld      (rbt_sp_h),a    ; h
        inc     hl
        ld      a,(hl)          ; nframes -> frame data skips the
        inc     hl              ; nframes*8 u16 offset table (F*16 bytes)
        inc     hl
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; A = F*16
        call    rbt_sp_idx      ; HL += A -> frame data start
        ; frame size = 2*w*h; off = frame * size
        ld      a,(rbt_sp_w)
        ld      e,a
        ld      a,(rbt_sp_h)
        ld      d,a
        call    rbt_sp_mul         ; DE = w*h (E*w? -> see _mul_de: DE=result)
        ld      a,(ix+5)        ; frame
        or      a
        jr      z,_f0
        ld      b,a
_fmul   add     hl,de
        add     hl,de           ; += 2*w*h
        djnz    _fmul
_f0     ld      (rbt_sp_mptr),hl
        add     hl,de           ; bmp ptr = mptr + w*h
        ld      (rbt_sp_bptr),hl
        ; ---- shift / column counts ----
        ld      a,(ix+1)
        and     7
        ld      (rbt_sp_shift),a
        ld      a,(ix+1)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_sp_col0),a ; x>>3
        ld      a,(rbt_sp_w)
        ld      b,a
        ld      a,(rbt_sp_shift)
        or      a
        jr      z,_nc
        inc     b
_nc     ld      a,b
        ld      (rbt_sp_ncols),a
        ; ---- row loop ----
        xor     a
        ld      (rbt_sp_row),a
_rloop  ld      a,(rbt_sp_row)
        ld      b,a
        ld      a,(rbt_sp_h)
        cp      b
        jp      z,_attrs        ; all rows done
        ; sy = y + row, skip if > 191
        ld      a,(ix+2)
        add     a,b
        jp      c,_nextrow      ; wrapped: off screen bottom
        cp      192
        jp      nc,_nextrow
        call    rbt_paddr       ; HL = line base for this pixel row
        ld      (rbt_sp_line),hl
        ; src pointers for this row
        ld      hl,(rbt_sp_mptr)
        ld      (rbt_sp_srcm),hl
        ld      hl,(rbt_sp_bptr)
        ld      (rbt_sp_srcb),hl
        ; ---- column loop ----
        xor     a
        ld      (rbt_sp_k),a
_kloop  ld      a,(rbt_sp_k)
        ld      b,a
        ld      a,(rbt_sp_ncols)
        cp      b
        jp      z,_nextrow
        ; ---- shifted mask byte ----
        ; cur byte into E first (H must survive for the prev byte)
        ld      a,(rbt_sp_k)
        ld      b,a
        ld      a,(rbt_sp_w)
        cp      b
        jr      z,_kcurmx       ; k == w: virtual cur = #ff
        ld      hl,(rbt_sp_srcm)
        ld      a,b
        call    rbt_sp_idx
        ld      e,(hl)
        jr      _kpm
_kcurmx ld      e,#ff
_kpm    ld      a,(rbt_sp_k)
        or      a
        jr      nz,_kprev
        ld      h,#ff           ; virtual prev mask = opaque screen-keep
        jr      _kprevd
_kprev  dec     a
        ld      hl,(rbt_sp_srcm)
        call    rbt_sp_idx
        ld      h,(hl)
_kprevd ld      l,e
_kshm   ld      a,(rbt_sp_shift)
        or      a
        jr      z,_kmdone       ; shift 0: L = cur already correct? no!
        ; when shift==0 we only iterate k<w and want cur -> handled below
        ld      b,a
_kshl   srl     h
        rr      l
        djnz    _kshl
_kmdone ld      a,l
        ld      (rbt_sp_mout),a ; mask out byte (shift 0 path below fixes)
        ld      a,(rbt_sp_shift)
        or      a
        jr      nz,_kbmp
        ; shift==0: mask out = cur byte (L already), ok as-is
_kbmp   ; ---- shifted bitmap byte ----
        ld      a,(rbt_sp_k)
        ld      b,a
        ld      a,(rbt_sp_w)
        cp      b
        jr      z,_kbcx         ; k == w: virtual cur = 0
        ld      hl,(rbt_sp_srcb)
        ld      a,b
        call    rbt_sp_idx
        ld      e,(hl)
        jr      _kpb
_kbcx   ld      e,0
_kpb    ld      a,(rbt_sp_k)
        or      a
        jr      nz,_kbprev
        ld      h,0
        jr      _kprevb
_kbprev dec     a
        ld      hl,(rbt_sp_srcb)
        call    rbt_sp_idx
        ld      h,(hl)
_kprevb ld      l,e
_kshb   ld      a,(rbt_sp_shift)
        or      a
        jr      z,_kbdone
        ld      b,a
_kshbl  srl     h
        rr      l
        djnz    _kshbl
_kbdone ld      b,l             ; B = bitmap out byte
        ld      a,(rbt_sp_mout)
        ld      c,a             ; C = mask out byte
        ; ---- screen write ----
        ld      a,(rbt_sp_col0)
        ld      hl,rbt_sp_k
        add     a,(hl)          ; screen column
        cp      32
        jr      nc,_kskip
        ld      e,a
        ld      hl,(rbt_sp_line)
        ld      a,l
        add     a,e
        ld      l,a             ; HL = screen byte addr
        ld      a,(ix+9)        ; mode
        cp      1
        jr      z,_mor
        cp      2
        jr      z,_mxor
        ; mask mode: (scr & mout) | bout
        ld      a,(hl)
        and     c
        or      b
        ld      (hl),a
        jr      _kskip
_mor    ld      a,(hl)
        or      b
        ld      (hl),a
        jr      _kskip
_mxor   ld      a,(hl)
        xor     b
        ld      (hl),a
_kskip  ld      a,(rbt_sp_k)
        inc     a
        ld      (rbt_sp_k),a
        jp      _kloop
_nextrow:
        ; advance src pointers by w
        ld      a,(rbt_sp_w)
        ld      e,a
        ld      d,0
        ld      hl,(rbt_sp_mptr)
        add     hl,de
        ld      (rbt_sp_mptr),hl
        ld      hl,(rbt_sp_bptr)
        add     hl,de
        ld      (rbt_sp_bptr),hl
        ld      a,(rbt_sp_row)
        inc     a
        ld      (rbt_sp_row),a
        jp      _rloop
        ; ---- attribute fill ----
_attrs  ; attr cells: rows (y>>3)..((y+h-1)>>3), cols (x>>3)..(x>>3)+ncols-1
        ld      a,(ix+8)
        cp      #ff
        jr      z,_dexit        ; attr $FF = don't touch attributes (no clash)
        ld      a,(ix+2)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_sp_ar0),a  ; first attr row
        ld      a,(ix+2)
        ld      b,a
        ld      a,(ix+4)
        dec     a
        add     a,b             ; y+h-1
        jr      c,_ar1max
        and     #f8
        rrca
        rrca
        rrca
        jr      _ar1
_ar1max ld      a,23
_ar1    ld      (rbt_sp_ar1),a
        ld      a,(rbt_sp_ar0)
        ld      (rbt_sp_ar),a   ; current attr row
_arow   ld      a,(rbt_sp_ar)
        cp      24
        jr      nc,_done
        ld      b,a
        ld      a,(rbt_sp_ar1)
        cp      b
        jr      c,_done         ; past last
        ; col loop: c = col0 .. col0+ncols-1, clip <32
        ld      a,(rbt_sp_col0)
        ld      (rbt_sp_ac),a
_acol   ld      a,(rbt_sp_ac)
        cp      32
        jr      nc,_arnext
        ld      b,a
        ld      a,(rbt_sp_col0)
        ld      c,a
        ld      a,(rbt_sp_ncols)
        dec     a
        add     a,c             ; last col
        cp      b
        jr      c,_arnext
        ; addr = #5800 + arow*32 + acol
        ld      a,(rbt_sp_ar)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(rbt_sp_ac)
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ld      a,(ix+8)
        ld      (hl),a
        ld      a,(rbt_sp_ac)
        inc     a
        ld      (rbt_sp_ac),a
        jr      _acol
_arnext ld      a,(rbt_sp_ar)
        inc     a
        ld      (rbt_sp_ar),a
        jr      _arow
_done
_dexit  ld      hl,rbt_sp_prev
        jp      rbt_pg_out      ; restore bank, return to caller

; helpers ---------------------------------------------------------------------
rbt_sp_idx                      ; HL += A (k index)
        add     a,l
        ld      l,a
        ret     nc
        inc     h
        ret
rbt_sp_mul                      ; D=h, E=w -> DE = w*h (w*h <= 31*192 fits 16b)
        push    bc
        push    hl
        ld      hl,0
        ld      b,e             ; w
        ld      a,b
        or      a
        jr      z,_zero
        ld      a,d             ; h
        ld      d,0
        ld      e,a             ; DE = h (addend)
_mdl    add     hl,de
        djnz    _mdl
        ex      de,hl           ; DE = result
        jr      _out
_zero   ld      de,0
_out    pop     hl
        pop     bc
        ret

; ----------------------------------------------------------------------------
; rbt_sp_drawall - draw every drawable slot, then advance animations.
; ----------------------------------------------------------------------------
rbt_sp_drawall:
        ld      b,RBT_NSLOTS
        ld      ix,rbt_sprites
_dal    push    bc
        ld      a,(ix+0)
        bit     0,a
        jr      z,_dan          ; inactive
        bit     1,a
        jr      nz,_dan         ; hidden
        call    rbt_sp_drawix
_dan    ld      de,RBT_SLOT
        add     ix,de
        pop     bc
        djnz    _dal
        ; ---- advance animations ----
        ld      b,RBT_NSLOTS
        ld      ix,rbt_sprites
_daa    push    bc
        ld      a,(ix+0)
        bit     0,a
        jr      z,_danx
        ld      a,(ix+12)
        bit     1,a
        jr      z,_danx         ; not animating
        ld      a,(ix+5)
        add     a,(ix+13)       ; frame += dir
        bit     0,(ix+12)
        jr      nz,_ping
        ; loop mode: wrap first..last
        ld      b,a
        ld      a,(ix+11)       ; last
        cp      b
        jr      nc,_setf
        ld      b,(ix+10)       ; wrap to first
        jr      _setf
_ping   ; pingpong: bounce at bounds
        ld      b,a
        ld      a,(ix+11)
        cp      b
        jr      nc,_plo
        ; past last: reverse, frame = last-1
        ld      a,(ix+13)
        neg
        ld      (ix+13),a
        ld      a,(ix+11)
        dec     a
        ld      b,a
        jr      _setf
_plo    ld      a,(ix+10)
        cp      b
        jr      c,_setf         ; frame >= first ok
        jr      nz,_phi         ; frame < first -> below first
        ; frame == first ok
        jr      _setf
_phi    ; frame < first: reverse, frame = first+1
        ld      a,(ix+13)
        neg
        ld      (ix+13),a
        ld      a,(ix+10)
        inc     a
        ld      b,a
_setf   ld      (ix+5),b
_danx   ld      de,RBT_SLOT
        add     ix,de
        pop     bc
        djnz    _daa
        ret

; ----------------------------------------------------------------------------
; rbt_spcoll - A=id1, B=id2 -> A = 1 if bounding boxes overlap.
; ----------------------------------------------------------------------------
rbt_spcoll:
        push    bc
        call    rbt_slot        ; IX = slot a
        pop     bc
        ld      a,(ix+0)
        bit     0,a
        jr      z,_no
        push    iy
        ; IY = slot b
        ld      a,b
        and     RBT_NSLOTS-1
        ld      e,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        sub     e               ; id*15
        ld      e,a
        ld      d,0
        ld      iy,rbt_sprites
        add     iy,de
        ld      a,(iy+0)
        bit     0,a
        jr      z,_noy
        ; x1 < x2 + w2*8 ?
        ld      a,(iy+3)
        add     a,a
        add     a,a
        add     a,a
        add     a,(iy+1)        ; x2 + w2*8
        ld      b,a
        ld      a,(ix+1)
        cp      b
        jr      nc,_noy
        ; x2 < x1 + w1*8 ?
        ld      a,(ix+3)
        add     a,a
        add     a,a
        add     a,a
        add     a,(ix+1)
        ld      b,a
        ld      a,(iy+1)
        cp      b
        jr      nc,_noy
        ; y1 < y2 + h2 ?
        ld      a,(iy+4)
        add     a,(iy+2)
        ld      b,a
        ld      a,(ix+2)
        cp      b
        jr      nc,_noy
        ; y2 < y1 + h1 ?
        ld      a,(ix+4)
        add     a,(ix+2)
        ld      b,a
        ld      a,(iy+2)
        cp      b
        jr      nc,_noy
        pop     iy
        ld      a,1
        ret
_noy    pop     iy
_no     xor     a
        ret

; ----------------------------------------------------------------------------
; SP1-style composited sprite update.
;
; Each slot tracks the cell rect it was last composited into (rbt_sp_old, valid
; when flags bit2 set). rbt_sp_update:
;   1. marks dirty every cell in old-rect (drawn sprites) + new-rect (visible
;      sprites), then updates rbt_sp_old
;   2. recomposites each dirty cell in RAM: background (bound tilemap tile, else
;      blank) + every covering sprite slice, then writes the 8 bitmap bytes and
;      the attr byte to the screen in ONE burst. The screen never contains a
;      "sprite erased" intermediate state, so there is nothing to flicker.
; Do NOT mix with SPRITES DRAWALL/SPRITE REDRAW on the same slots.
; ----------------------------------------------------------------------------

rbt_sp_old      defs RBT_NSLOTS*4     ; per slot: col0,row0,col1,row1
rbt_sp_dirty    defs 96               ; 32x24 cell dirty bitmap
rbt_sp_cmplo    defs 96               ; covering-sprite mask per cell, sids 0-7
rbt_sp_cmphi    defs 96               ; same, sids 8-15
rbt_uc_buf      defs 8                ; composited cell bytes
rbt_uc_cx       defb 0
rbt_uc_cy       defb 0
rbt_uc_row      defb 0
rbt_uc_sid      defb 0
rbt_uc_bga      defb 0                ; pending attr (#ff = leave screen attr)
rbt_uc_w        defb 0
rbt_uc_h        defb 0
rbt_uc_shf      defb 0
rbt_uc_c0       defb 0
rbt_uc_c1       defb 0
rbt_uc_lr       defb 0
rbt_uc_t        defb 0
rbt_uc_mr       defb 0
rbt_uc_mc       defb 0
rbt_uc_bit      defb 0                ; pass-2 dirty-bit index (cellcomp clobbers sid)
rbt_uc_db       defb 0                ; pass-2 dirty byte (cellcomp clobbers t)
rbt_uc_nr       defs 4                ; pass-1: new sprite cell rect col0,row0,col1,row1
rbt_uc_off      defw 0                ; cellcomp: lr*w + i source offset
rbt_uc_of       defb 0                ; cellcomp: rbt_uc_off initialised flag
rbt_uc_ci       defb 0                ; cellcomp: cx - col0 (constant per cell)
rbt_uc_cm       defb 0                ; cellcomp: cmap candidate mask byte
rbt_uc_cb       defb 0                ; cellcomp: cmap candidate bit index
rbt_uc_rh       defb 0                ; cellcomp: last covered row (rowhi)
rbt_uc_ow2      defb 0                ; cellcomp: pre-shifted row stride (wb+1)*2
rbt_uc_n        defb 0                ; cellcomp: rows left to composite
rbt_uc_bp       defw 0                ; cellcomp: buf write pointer
rbt_uc_mptr     defw 0
rbt_uc_bptr     defw 0

; rbt_sp_srect - IX=slot -> sprite cell rect into rbt_uc_c0/c1-style regs:
; B=col0 C=row0 D=col1 E=row1, A=1 if on screen else A=0.
rbt_sp_srect:
        ld      l,(ix+6)
        ld      h,(ix+7)
        ld      a,(hl)
        ld      (rbt_uc_w),a        ; w bytes
        inc     hl
        ld      a,(hl)
        ld      (rbt_uc_h),a        ; h px
        ; col0 = x>>3
        ld      a,(ix+1)
        and     #f8
        rrca
        rrca
        rrca
        ld      b,a
        cp      32
        jr      nc,_srno            ; fully off right
        ; ncols = w + (x&7 ? 1 : 0); col1 = col0+ncols-1
        ld      a,(ix+1)
        and     7
        ld      c,a
        ld      a,(rbt_uc_w)
        dec     a
        inc     c
        dec     c
        jr      z,_sra              ; shift 0: ncols=w
        inc     a
_sra    add     a,b
        ld      d,a                 ; col1 (may exceed 31)
        ; row0 = y>>3
        ld      a,(ix+2)
        and     #f8
        rrca
        rrca
        rrca
        ld      c,a
        cp      24
        jr      nc,_srno
        ; row1 = (y+h-1)>>3, saturate 255
        ld      a,(rbt_uc_h)
        dec     a
        add     a,(ix+2)
        jr      nc,_srb
        ld      a,#ff
_srb    and     #f8
        rrca
        rrca
        rrca
        ld      e,a                 ; row1
        ; clip col1<=31, row1<=23
        ld      a,d
        cp      32
        jr      c,_src
        ld      d,31
_src    ld      a,e
        cp      24
        jr      c,_srd
        ld      e,23
_srd    ld      a,1
        ret
_srno   xor     a
        ret

; rbt_sp_markrect - set dirty bits for B=col0,C=row0,D=col1,E=row1 (inclusive,
; already clipped). Preserves DE.
rbt_sp_markrect:
        inc     d
        inc     e                   ; -> exclusive ends
        ld      a,b
        ld      (rbt_uc_mc),a       ; col0 stash (B is the djnz counter)
        ld      a,c
        ld      (rbt_uc_mr),a
_mr1    ld      a,(rbt_uc_mr)
        cp      e
        ret     nc                  ; past last row -> done
        add     a,a
        add     a,a                 ; row*4 = dirty byte base
        ld      c,a
        ld      a,(rbt_uc_mc)
        rrca
        rrca
        rrca
        and     #1f                 ; col0>>3
        add     a,c
        ld      hl,rbt_sp_dirty
        call    rbt_sp_idx          ; HL = first dirty byte of this row span
        ; C = start bit 1<<(col0&7), walks left; carry out -> next byte
        ld      a,(rbt_uc_mc)
        and     7
        ld      c,a
        ld      a,1
        inc     c
_mrm    dec     c
        jr      z,_mrd
        add     a,a
        jr      _mrm
_mrd    ld      c,a
        ld      a,(rbt_uc_mc)
        ld      b,a
        ld      a,d
        sub     b
        ld      b,a                 ; B = col count -> djnz
_mrcl   ld      a,(hl)
        or      c
        ld      (hl),a
        ld      a,c
        add     a,a
        jr      nc,_mrsb
        inc     hl                  ; bit wrapped -> next dirty byte
        ld      a,1
_mrsb   ld      c,a
        djnz    _mrcl
_mrnext ld      a,(rbt_uc_mr)
        inc     a
        ld      (rbt_uc_mr),a
        jr      _mr1

; ----------------------------------------------------------------------------
; rbt_sp_markcov - OR the current slot's bit into the covering-sprite map for
; every cell of rbt_uc_nr (the sprite's new rect). Lets cellcomp iterate only
; the sprites that actually cover a dirty cell. Preserves nothing.
; ----------------------------------------------------------------------------
rbt_sp_markcov:
        ; sid bit -> rbt_uc_t ; plane base -> rbt_uc_mptr
        ld      a,(rbt_uc_sid)
        and     7
        ld      b,a
        ld      a,1
        inc     b
_cvm    dec     b
        jr      z,_cvmd
        add     a,a
        jr      _cvm
_cvmd   ld      (rbt_uc_t),a
        ld      a,(rbt_uc_sid)
        and     8
        ld      hl,rbt_sp_cmplo
        jr      z,_cvp
        ld      hl,rbt_sp_cmphi
_cvp    ld      (rbt_uc_mptr),hl
        ; for r = row0..row1, c = col0..col1: plane[cell byte] |= sid bit
        ld      a,(rbt_uc_nr+1)
        ld      (rbt_uc_mr),a         ; r = row0
_cvr1   ld      a,(rbt_uc_mr)
        ld      b,a
        ld      a,(rbt_uc_nr+3)
        cp      b
        ret     c                     ; r > row1 -> done
        ld      a,(rbt_uc_mr)
        add     a,a
        add     a,a                   ; row*4
        ld      c,a
        ld      a,(rbt_uc_nr)
        rrca
        rrca
        rrca
        and     #1f                   ; col0>>3
        add     a,c
        ld      hl,(rbt_uc_mptr)
        call    rbt_sp_idx            ; HL = plane + row*4 + col0>>3
        ; byte walk: every covered cell ORs the same sid bit; advance the
        ; cell byte only when the column crosses a byte boundary
        ld      a,(rbt_uc_nr)
        and     7
        ld      c,a                   ; C = col0&7 (bit position)
        ld      a,(rbt_uc_nr+2)
        ld      b,a
        ld      a,(rbt_uc_nr)
        ld      d,a
        ld      a,b
        sub     d
        inc     a
        ld      b,a                   ; B = col count -> djnz
_cvc    ld      a,(rbt_uc_t)
        or      (hl)
        ld      (hl),a
        inc     c
        ld      a,c
        cp      8
        jr      nz,_cvs
        inc     hl                    ; col wrapped -> next cell byte
        xor     a
        ld      c,a
_cvs    djnz    _cvc
_cvn    ld      a,(rbt_uc_mr)
        inc     a
        ld      (rbt_uc_mr),a
        jr      _cvr1

; rbt_sp_update - recompose all dirty cells (see header comment).
rbt_sp_update:
        call    rbt_sfx_drain         ; drain queued SFX at the frame boundary
        ; ---- clear dirty map + covering-sprite maps (contiguous) ----
        ld      hl,rbt_sp_dirty
        ld      de,rbt_sp_dirty+1
        ld      bc,96*3-1
        ld      (hl),0
        ldir
        ; ---- pass 1: dirty old + new rects, refresh bookkeeping ----
        xor     a
        ld      (rbt_uc_sid),a
_udp1   ld      a,(rbt_uc_sid)
        call    rbt_slot            ; IX = slot
        ; old rect (if drawn)
        ; visible? -> rbt_uc_nr = new cell rect; else no new rect
        ld      a,(ix+0)
        bit     0,a
        jp      z,_unov             ; inactive
        bit     1,a
        jp      nz,_unov            ; hidden
        call    rbt_sp_srect        ; B,C,D,E = rect, or A=0 offscreen
        or      a
        jp      z,_unov
        ld      hl,rbt_uc_nr
        ld      (hl),b
        inc     hl
        ld      (hl),c
        inc     hl
        ld      (hl),d
        inc     hl
        ld      (hl),e
        bit     2,(ix+0)
        jr      z,_unonly           ; not drawn before -> mark new rect only
        ; union(old, new) -> B,C,D,E; one markrect covers both old and new
        ld      a,(rbt_uc_sid)
        add     a,a
        add     a,a
        ld      hl,rbt_sp_old
        call    rbt_sp_idx          ; HL = old + sid*4
        ld      a,(rbt_uc_nr)
        ld      b,a
        ld      a,(hl)
        cp      b
        jr      nc,_uu0             ; old >= new -> keep new (min col0)
        ld      b,a
_uu0    ld      a,(rbt_uc_nr+1)
        ld      c,a
        inc     hl
        ld      a,(hl)
        cp      c
        jr      nc,_uu1             ; min row0
        ld      c,a
_uu1    inc     hl
        ld      a,(rbt_uc_nr+2)
        ld      d,a
        ld      a,(hl)
        cp      d
        jr      c,_uu2              ; old < new -> keep new (max col1)
        ld      d,a
_uu2    inc     hl
        ld      a,(rbt_uc_nr+3)
        ld      e,a
        ld      a,(hl)
        cp      e
        jr      c,_uu3              ; max row1
        ld      e,a
_uu3    call    rbt_sp_markrect     ; mark the union once
        ; store new rect to rbt_sp_old for next frame / cellcomp reject
        ld      a,(rbt_uc_sid)
        add     a,a
        add     a,a
        ld      hl,rbt_sp_old
        call    rbt_sp_idx
        ld      a,(rbt_uc_nr)
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+1)
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+2)
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+3)
        ld      (hl),a
        call    rbt_sp_markcov      ; record covering sid for pass 2
        jr      _unx
_unonly ; first draw: mark new rect only, store it, set drawn
        ld      a,(rbt_uc_sid)
        add     a,a
        add     a,a
        ld      hl,rbt_sp_old
        call    rbt_sp_idx
        ld      a,(rbt_uc_nr)
        ld      b,a
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+1)
        ld      c,a
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+2)
        ld      d,a
        ld      (hl),a
        inc     hl
        ld      a,(rbt_uc_nr+3)
        ld      e,a
        ld      (hl),a
        set     2,(ix+0)
        call    rbt_sp_markrect
        call    rbt_sp_markcov
        jr      _unx
_unov   ; no new rect: erase old if drawn
        bit     2,(ix+0)
        jr      z,_unx
        ld      a,(rbt_uc_sid)
        add     a,a
        add     a,a
        ld      hl,rbt_sp_old
        call    rbt_sp_idx
        ld      b,(hl)
        inc     hl
        ld      c,(hl)
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      e,(hl)
        call    rbt_sp_markrect
        res     2,(ix+0)
_unx    ld      a,(rbt_uc_sid)
        inc     a
        cp      RBT_NSLOTS
        jr      c,_unxok
        jr      _upd2
_unxok  ld      (rbt_uc_sid),a
        jp      _udp1
        ; ---- pass 2: recompose dirty cells ----
        ; byte-wise scan: dirty byte i covers cy=i>>2, cols (i&3)*8+bit
_upd2   xor     a
        ld      (rbt_uc_mr),a         ; byte index i
_usc    ld      a,(rbt_uc_mr)
        cp      96
        ret     nc                    ; scanned whole map -> done
        ld      e,a
        ld      d,0
        ld      hl,rbt_sp_dirty
        add     hl,de
        ld      a,(hl)
        or      a
        jr      z,_usnx               ; clean byte
        ; cy = i>>2 ; cxbase = (i&3)<<3 ; bit counter reuses uc_sid
        ld      a,(rbt_uc_mr)
        rrca
        rrca
        and     #3f
        ld      (rbt_uc_cy),a
        ld      a,(rbt_uc_mr)
        and     3
        add     a,a
        add     a,a
        add     a,a
        ld      (rbt_uc_mc),a         ; col base for this byte
        ld      a,(hl)
        ld      (rbt_uc_db),a         ; stash byte
        xor     a
        ld      (rbt_uc_bit),a        ; bit index 0..7
_usb    ld      a,(rbt_uc_db)
        and     1
        jr      z,_usbn
        ld      a,(rbt_uc_mc)
        ld      b,a
        ld      a,(rbt_uc_bit)
        add     a,b
        ld      (rbt_uc_cx),a         ; cx = base + bit
        call    rbt_sp_cellcomp
_usbn   ld      a,(rbt_uc_db)
        rra
        ld      (rbt_uc_db),a
        ld      a,(rbt_uc_bit)
        inc     a
        cp      8
        jr      nc,_usnx
        ld      (rbt_uc_bit),a
        jr      _usb
_usnx   ld      a,(rbt_uc_mr)
        inc     a
        ld      (rbt_uc_mr),a
        jr      _usc

; rbt_sp_cellcomp - recompose cell (rbt_uc_cx, rbt_uc_cy) and write once.
rbt_sp_cellcomp:
        ; ---- background bytes + attr ----
        ld      a,#ff
        ld      (rbt_uc_bga),a
        ld      hl,(rbt_tm_map)
        ld      a,h
        or      l
        jr      z,_bg0
        ; mx = cx - vx + camx ; my = cy - vy + camy
        ld      a,(rbt_tm_vx)
        ld      b,a
        ld      a,(rbt_uc_cx)
        sub     b
        ld      b,a
        ld      a,(rbt_tm_camx)
        add     a,b
        ld      b,a                 ; B = mx (mapat bounds-checks)
        ld      a,(rbt_tm_vy)
        ld      c,a
        ld      a,(rbt_uc_cy)
        sub     c
        ld      c,a
        ld      a,(rbt_tm_camy)
        add     a,c
        ld      c,a                 ; C = my
        call    rbt_tm_mapat        ; A = tile id (0 when out of map)
        ld      e,a
        ld      a,(rbt_tm_tbank)    ; page tileset bank for tattr/bmp reads
        ld      hl,rbt_tm_tprev
        call    rbt_pg_in
        ld      d,0
        ld      hl,(rbt_tm_tattr)
        add     hl,de
        ld      a,(hl)
        ld      (rbt_uc_bga),a      ; tile attr
        sla     e
        rl      d
        sla     e
        rl      d
        sla     e
        rl      d
        ld      hl,(rbt_tm_bmp)
        add     hl,de               ; src = bmp + tid*8
        ld      de,rbt_uc_buf
        ld      bc,8
        ldir
        ld      hl,rbt_tm_tprev
        call    rbt_pg_out
        jr      _bgs
_bg0    ld      hl,rbt_uc_buf
        ld      b,8
        xor     a
_bg0l   ld      (hl),a
        inc     hl
        djnz    _bg0l
_bgs    ; ---- composite every covering sprite in slot order ----
        ; candidates come from the covering-sprite map: cmplo bit per sid 0-7,
        ; cmphi for 8-15, both indexed like the dirty map. Iterating the set
        ; bits skips the ~16-slot scan; the old-rect check below still rejects
        ; candidates that cover a neighbouring cell of the same byte.
        ld      a,(rbt_uc_cy)
        add     a,a
        add     a,a                 ; cy*4
        ld      b,a
        ld      a,(rbt_uc_cx)
        rrca
        rrca
        rrca
        and     #1f
        add     a,b
        ld      (rbt_uc_lr),a       ; cmap byte index for this cell
        ld      hl,rbt_sp_cmplo
        call    rbt_sp_idx
        ld      a,(hl)
        ld      (rbt_uc_cm),a       ; candidate mask byte
        xor     a
        ld      (rbt_uc_cb),a       ; bit index 0..7
        ld      (rbt_uc_nr),a       ; phase: 0 = sids 0-7, 8 = sids 8-15
        ; scan: shift cm right through carry; cb counts bits consumed. The
        ; loop exits the moment cm drains, so sparse maps cost little.
_cs     ld      a,(rbt_uc_cm)
        or      a
        jp      z,_csph             ; plane drained -> next plane / commit
        srl     a                   ; bit0 -> carry (inc/ld below keep it)
        ld      (rbt_uc_cm),a
        ld      a,(rbt_uc_cb)
        inc     a
        ld      (rbt_uc_cb),a
        jp      nc,_cs              ; bit was clear -> next
        ld      a,(rbt_uc_cb)
        dec     a
        ld      b,a
        ld      a,(rbt_uc_nr)
        add     a,b
        ld      (rbt_uc_sid),a      ; sid = phase + bit index
        call    rbt_slot            ; IX = slot
        ; cheap reject vs the slot's current cell rect (stored in pass 1):
        ; rbt_sp_old + sid*4 = col0,row0,col1,row1
        ld      a,(rbt_uc_sid)
        add     a,a
        add     a,a
        ld      e,a
        ld      d,0
        ld      hl,rbt_sp_old
        add     hl,de
        ld      b,(hl)              ; col0
        inc     hl
        ld      c,(hl)              ; row0
        inc     hl
        ld      a,(hl)              ; col1
        inc     hl
        ld      h,(hl)              ; row1
        ld      l,a                 ; L=col1 H=row1
        ld      a,(rbt_uc_cx)
        cp      b
        jp      c,_cs               ; cx < col0
        ld      a,(rbt_uc_cy)
        cp      c
        jp      c,_cs               ; cy < row0
        inc     l
        ld      a,(rbt_uc_cx)
        cp      l
        jp      nc,_cs              ; cx > col1
        inc     h
        ld      a,(rbt_uc_cy)
        cp      h
        jp      nc,_cs              ; cy > row1
        ld      a,(ix+14)           ; page the sprite asset's bank
        ld      hl,rbt_sp_prev
        call    rbt_pg_in
        ; load dims; keep the asset base in mptr for the offset-table lookup
        ld      l,(ix+6)
        ld      h,(ix+7)
        ld      (rbt_uc_mptr),hl
        ld      a,(hl)
        ld      (rbt_uc_w),a
        inc     hl
        ld      a,(hl)
        ld      (rbt_uc_h),a
        inc     hl
        ld      a,(hl)              ; nframes
        ld      (rbt_uc_t),a        ; stash for the fidx loop below
        ; col coverage: col0 = x>>3 ; col1 = col0 + ncols - 1
        ld      a,(ix+1)
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_uc_c0),a
        ld      a,(ix+1)
        and     7
        ld      (rbt_uc_shf),a
        ; col1 = col0 + ncols - 1 ; ncols = w + (shf ? 1 : 0)
        ld      a,(rbt_uc_w)
        dec     a
        ld      b,a
        ld      a,(rbt_uc_shf)
        or      a
        jr      z,_cnc2
        inc     b
_cnc2   ld      a,(rbt_uc_c0)
        add     a,b
        ld      (rbt_uc_c1),a
        ; ow2 = (wb+1)*2 : row stride of the pre-shifted blocks
        ld      a,(rbt_uc_w)
        inc     a
        add     a,a
        ld      (rbt_uc_ow2),a
        ; ---- find the pre-shifted block for (phase, frame) ----
        ; fidx = shf*nframes + frame ; block = asset + u16 offs[fidx]
        ld      a,(rbt_uc_t)
        ld      c,a                 ; C = nframes
        ld      a,(rbt_uc_shf)
        ld      b,a
        ld      a,(ix+5)            ; frame
        inc     b
_cfml   dec     b
        jr      z,_cf0
        add     a,c                 ; += nframes
        jr      _cfml
_cf0    add     a,a                 ; fidx*2 (table entries are u16)
        ld      hl,(rbt_uc_mptr)
        inc     hl
        inc     hl
        inc     hl
        inc     hl                  ; HL = asset+4 = offset table
        call    rbt_sp_idx          ; HL += A -> &offs[fidx]
        ld      e,(hl)
        inc     hl
        ld      d,(hl)              ; DE = block offset
        ld      hl,(rbt_uc_mptr)
        add     hl,de
        ld      (rbt_uc_mptr),hl    ; mptr = block base
        ; ---- per-row slice composite into buf ----
        ; i = cx - col0 (constant for this cell). Coverage is already proved,
        ; so iterate only the covered rows: rowlo = max(0, sy-cy*8),
        ; rowhi = min(7, sy+h-1-cy*8).
        ld      a,(rbt_uc_cx)
        ld      b,a
        ld      a,(rbt_uc_c0)
        ld      c,a
        ld      a,b
        sub     c
        ld      (rbt_uc_ci),a
        ld      a,(rbt_uc_cy)
        add     a,a
        add     a,a
        add     a,a                 ; A = cy*8
        ld      c,a
        ld      a,(ix+2)            ; sy
        sub     c                   ; sy - cy*8
        jr      c,_rlz
        jr      _rlv
_rlz    xor     a
_rlv    ld      (rbt_uc_row),a      ; rowlo: first covered CELL row
        ; srow = rowlo - (sy-cy*8) = first covered SPRITE row: 0 when the
        ; sprite starts in this cell, cy*8-sy when it started above it.
        ; C must stay cy*8 for the rowhi computation below.
        ld      b,a
        ld      a,(ix+2)            ; sy
        neg
        add     a,c                 ; cy*8 - sy (8-bit wrap handles both cases)
        add     a,b
        ld      (rbt_uc_off),a      ; srow for mp
        ld      a,(rbt_uc_h)
        dec     a
        add     a,(ix+2)            ; sy+h-1 (carry if >255 -> covers whole cell)
        jr      c,_rh7
        sub     c                   ; sy+h-1-cy*8 (>= rowlo: coverage proved)
        cp      8
        jr      c,_rhc
_rh7    ld      a,7
_rhc    ld      (rbt_uc_rh),a
        ; mp = block + srow*ow2 + i*2 ; bp = buf+rowlo ; n = rowhi-rowlo+1
        ld      a,(rbt_uc_off)
        ld      d,a
        ld      a,(rbt_uc_ow2)
        ld      e,a
        call    rbt_sp_mul          ; DE = rowlo*ow2
        ld      a,(rbt_uc_ci)
        add     a,a
        add     a,e
        ld      e,a
        jr      nc,_mof
        inc     d
_mof    ld      hl,(rbt_uc_mptr)
        add     hl,de
        ld      (rbt_uc_mptr),hl    ; mp = &(m_i,b_i) of rowlo
        ld      hl,rbt_uc_buf
        ld      a,(rbt_uc_row)
        call    rbt_sp_idx
        ld      (rbt_uc_bp),hl      ; buf write ptr
        ld      a,(rbt_uc_rh)
        ld      b,a
        ld      a,(rbt_uc_row)
        ld      c,a
        ld      a,b
        sub     c
        inc     a
        ld      (rbt_uc_n),a        ; n = rows to composite
_crl    ld      a,(rbt_uc_n)
        or      a
        jp      z,_cattr
        dec     a
        ld      (rbt_uc_n),a
        ld      hl,(rbt_uc_mptr)
        ld      c,(hl)              ; pre-shifted mask for this cell col
        inc     hl
        ld      b,(hl)              ; pre-shifted bitmap
        dec     hl
        ld      a,(rbt_uc_ow2)
        add     a,l
        ld      l,a
        jr      nc,_mpa
        inc     h
_mpa    ld      (rbt_uc_mptr),hl    ; mp += ow2 (next row)
        ; apply mode to buf[row] via the write pointer
        ld      hl,(rbt_uc_bp)
        ld      a,(ix+9)            ; mode
        cp      1
        jr      z,_cmor
        cp      2
        jr      z,_cmxr
        ld      a,(hl)              ; mask: (buf & m) | b
        and     c
        or      b
        ld      (hl),a
        jr      _crn
_cmor   ld      a,(hl)
        or      b
        ld      (hl),a
        jr      _crn
_cmxr   ld      a,(hl)
        xor     b
        ld      (hl),a
_crn    inc     hl
        ld      (rbt_uc_bp),hl      ; bp++
        jp      _crl
_cattr  ; sprite attr overrides pending attr unless #ff
        ld      a,(ix+8)
        cp      #ff
        jr      z,_csout
        ld      (rbt_uc_bga),a
_csout  ld      hl,rbt_sp_prev
        call    rbt_pg_out          ; restore bank after this sprite
        jp      _cs
_csph   ld      a,(rbt_uc_nr)       ; plane phase
        or      a
        jr      nz,_cwr             ; hi plane done -> commit cell
        ld      a,(rbt_uc_lr)
        ld      hl,rbt_sp_cmphi
        call    rbt_sp_idx
        ld      a,(hl)
        ld      (rbt_uc_cm),a
        xor     a
        ld      (rbt_uc_cb),a
        ld      a,8
        ld      (rbt_uc_nr),a       ; phase -> sids 8-15
        jp      _cs
        ; ---- commit cell: 8 bitmap bytes + attr in one burst ----
_cwr    ld      a,(rbt_uc_cy)
        ld      b,a
        and     #f8
        add     a,#40
        ld      h,a                 ; H = #40 + (cy&F8) + r
        ld      a,b
        and     7
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a                 ; (cy&7)*32
        ld      b,a
        ld      a,(rbt_uc_cx)
        add     a,b
        ld      l,a                 ; L = (cy&7)*32 + cx
        ld      de,rbt_uc_buf
        ld      b,8
_cwl    ld      a,(de)
        ld      (hl),a
        inc     de
        inc     h
        djnz    _cwl
        ; attr: skip if #ff
        ld      a,(rbt_uc_bga)
        cp      #ff
        ret     z
        ld      a,(rbt_uc_cy)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        ld      a,(rbt_uc_cx)
        or      l
        ld      l,a
        ld      a,h
        add     a,#58
        ld      h,a
        ld      a,(rbt_uc_bga)
        ld      (hl),a
        ret

rbt_sp_prev     defb 0          ; pg guard save (asset bank)
rbt_sp_w        defb 0
rbt_sp_h        defb 0
rbt_sp_shift    defb 0
rbt_sp_col0     defb 0
rbt_sp_ncols    defb 0
rbt_sp_row      defb 0
rbt_sp_k        defb 0
rbt_sp_mout     defb 0
rbt_sp_ar0      defb 0
rbt_sp_ar1      defb 0
rbt_sp_ar       defb 0
rbt_sp_ac       defb 0
rbt_sp_line     defw 0
rbt_sp_mptr     defw 0
rbt_sp_bptr     defw 0
rbt_sp_srcm     defw 0
rbt_sp_srcb     defw 0
