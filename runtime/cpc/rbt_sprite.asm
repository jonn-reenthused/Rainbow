; ============================================================================
; rbt_sprite_asm - CPC masked sprite engine (mode 1 assumed)
;
; 16 slots x 18 bytes. Sprites are 1bpp source expanded at encode time to
; pen-1/pen-0 2bpp mask+bitmap pairs, pre-shifted for 4 pixel phases, so
; draw is a per-byte (screen & mask) | bmp merge - no runtime shifting.
;
; Erase model: MASK/OR sprites keep a saved copy of the background they
; cover (per-slot buffer, up to RBT_SPSAVE bytes; bigger rects draw
; without a save and then can't auto-erase). XOR sprites erase by
; redrawing. rbt_sp_place/frame only set state + dirty; rbt_sp_update
; commits dirty sprites (restore old rect, save + draw new). rbt_sp_draw
; (SPRITE REDRAW) commits one slot immediately.
;
; Slot layout:
;  +0  flags: bit0 active, bit1 hidden, bit2 dirty (pos/frame changed)
;  +1  x +2  y               (target position, pixels)
;  +3  wpx +4 h              (w in PIXELS, h lines)
;  +5  frame +6,7 asset ptr
;  +8  attr (stored, ignored) +9 mode (0 mask, 1 or, 2 xor)
;  +10 animFirst +11 animLast
;  +12 animFlags: bit0 pingpong, bit1 animating
;  +13 animDir (1 / -1)
;  +14 asset bank (#ff = resident; cpc6128 pages it per access)
;  +15 committed: 0 = nothing on screen, 1 = drawn at +16/+17
;  +16 cx +17 cy             (committed position)
;
; CPC sprite asset (.rbs encoded for cpc):
;   defb wpx, h, nframes, attr
;   defw nframes*4           ; offs[phase*nframes + frame], from asset start
;   blocks: h rows x (wpx/4+1) cols of {mask,bmp} pen-1 expanded pairs
; ============================================================================

RBT_NSLOTS      equ 16
RBT_SLOT        equ 18
RBT_SPSAVE      equ 160         ; save-buffer bytes per slot (max covered rect)

rbt_sprites     defs RBT_NSLOTS*RBT_SLOT
rbt_spsave      defs RBT_NSLOTS*RBT_SPSAVE

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
        add     a,e
        add     a,e             ; id*18 (id=15 -> 270: carry!)
        ld      e,a
        ld      d,0
        jr      nc,_nc
        inc     d               ; keep id*18 in 16 bits or slot 15
_nc     ld      ix,rbt_sprites  ; lands on slot0+14 and stomps it
        add     ix,de
        pop     de
        ret

; ----------------------------------------------------------------------------
; rbt_sp_savebuf - IX = slot -> HL = its save buffer. Uses A,DE,HL.
; ----------------------------------------------------------------------------
rbt_sp_savebuf:
        push    ix
        pop     de
        ld      hl,-rbt_sprites
        add     hl,de           ; HL = id*18 (0..270)
        ld      de,0
        ld      bc,18
_sbdv   or      a
        sbc     hl,bc
        jr      c,_sbd
        inc     e
        jr      _sbdv
_sbd    ; E = slot id -> HL = id*160
        ld      l,e
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *32
        ld      d,h
        ld      e,l             ; DE = id*32
        add     hl,hl
        add     hl,hl           ; *128
        add     hl,de           ; *160
        ld      de,rbt_spsave
        add     hl,de
        ret

; ----------------------------------------------------------------------------
; rbt_sp_create - A=id, HL=asset, B=mode(0/1/2), C=x, D=y, E=asset bank
; ----------------------------------------------------------------------------
rbt_sp_create:
        push    hl
        call    rbt_slot        ; preserves DE (E = bank)
        pop     hl
        ld      a,e
        ld      (ix+14),a       ; asset bank byte
        ld      (ix+6),l
        ld      (ix+7),h        ; asset ptr
        ld      (ix+0),1        ; active
        ld      (ix+1),c        ; x
        ld      (ix+2),d        ; y
        ld      a,(hl)
        ld      (ix+3),a        ; wpx
        inc     hl
        ld      a,(hl)
        ld      (ix+4),a        ; h
        inc     hl
        inc     hl              ; skip nframes
        ld      a,(hl)
        ld      (ix+8),a        ; attr (unused)
        xor     a
        ld      (ix+5),a        ; frame 0
        ld      (ix+9),b        ; mode
        ld      (ix+12),a       ; anim off
        ld      (ix+15),a       ; not committed
        ld      (ix+0),5        ; active + dirty -> first UPDATE draws it
        ret

; ----------------------------------------------------------------------------
; rbt_sp_place - A=id, B=x, C=y
; ----------------------------------------------------------------------------
rbt_sp_place:
        call    rbt_slot
        ld      (ix+1),b
        ld      (ix+2),c
        ld      a,(ix+0)
        or      4
        ld      (ix+0),a        ; dirty
        ret

; ----------------------------------------------------------------------------
; rbt_sp_move - A=id, B=dx (signed), C=dy (signed). Clamps to screen.
; ----------------------------------------------------------------------------
rbt_sp_move:
        call    rbt_slot
        ld      e,(ix+1)        ; old x
        ld      a,e
        add     a,b
        bit     7,b
        jr      nz,_mvxn
        jr      c,_mvxmax       ; wrapped past 255
        ld      d,a             ; D = new x
        ld      a,(ix+3)        ; wpx
        neg                     ; 256 - wpx = maxX
        cp      d
        jr      c,_mvxset       ; new > maxX -> store maxX (A)
        ld      a,d
        jr      _mvxset
_mvxmax ld      a,(ix+3)
        neg
        jr      _mvxset
_mvxn   cp      e
        jr      c,_mvxset       ; new < old: normal move
        xor     a
_mvxset ld      (ix+1),a
_mvy    ld      e,(ix+2)
        ld      a,e
        add     a,c
        bit     7,c
        jr      nz,_mvyn
        jr      c,_mvymax
        ld      d,a             ; D = new y
        ld      a,(ix+4)
        neg
        add     a,192-256       ; 192 - h
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
        ld      a,(ix+0)
        or      4               ; dirty
        ld      (ix+0),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_frame - A=id, B=frame (clamped to nframes-1)
; ----------------------------------------------------------------------------
rbt_sp_frame:
        call    rbt_slot
        ld      a,(ix+14)       ; asset bank (#ff = resident)
        ld      hl,rbt_sp_prev
        call    rbt_pg_in       ; page sprite asset for the header read
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
        ld      a,(ix+0)
        or      4
        ld      (ix+0),a
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
        ld      a,(ix+0)
        or      4
        ld      (ix+0),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_animstep - advance the animating frame of slot IX (loop/pingpong).
; ----------------------------------------------------------------------------
rbt_sp_animstep:
        ld      a,(ix+12)
        bit     1,a
        ret     z               ; not animating
        ld      a,(ix+13)
        bit     7,a
        jr      nz,_backw
        ; forward
        ld      a,(ix+5)
        inc     a
        cp      (ix+11)
        jr      c,_set
        jr      z,_set
        ; past last
        ld      a,(ix+12)
        bit     0,a
        jr      z,_loop         ; plain loop: back to first
        ld      a,#ff
        ld      (ix+13),a       ; pingpong: bounce back
        ld      a,(ix+11)
        dec     a
        jr      _set
_loop   ld      a,(ix+10)
        jr      _set
_backw  ld      a,(ix+5)
        dec     a
        cp      (ix+10)
        jr      nc,_set         ; >= first
        ld      a,1
        ld      (ix+13),a       ; bounce forward
        ld      a,(ix+10)
        inc     a
_set    ld      (ix+5),a
        ld      a,(ix+0)
        or      4               ; frame change -> dirty
        ld      (ix+0),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_show / rbt_sp_hide / rbt_sp_kill - A=id
; ----------------------------------------------------------------------------
rbt_sp_show:
        call    rbt_slot
        ld      a,(ix+0)
        and     #fd             ; clear hidden
        or      5               ; active + dirty -> redrawn
        ld      (ix+0),a
        ret
rbt_sp_hide:
        call    rbt_slot
        ld      a,(ix+0)
        or      6               ; hidden + dirty: the next commit/update
        ld      (ix+0),a        ; restores its rect in z-order (immediate
        ret                     ; restore could re-paste stale copies of
                                ; lower sprites it was saved over)
rbt_sp_kill:
        call    rbt_slot
        ld      (ix+0),4        ; inactive + dirty
        ret

; ----------------------------------------------------------------------------
; rbt_sp_attr - A=id, B=attr byte (stored, ignored on CPC)
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
; rbt_sp_cols - IX slot -> A = nominal byte columns (wpx/4 + 1, covers p<=3).
; ----------------------------------------------------------------------------
rbt_sp_cols:
        ld      a,(ix+3)
        rrca
        rrca
        and     #3f
        inc     a
        ret

; rbt_sp_colsclip - nominal cols clipped to the 64-byte logical row from the
; byte col in rbt_sp_bc. -> A (1..cols)
; ----------------------------------------------------------------------------
rbt_sp_colsclip:
        push    hl              ; callers hold the screen ptr in HL here
        call    rbt_sp_cols
        ld      b,a
        ld      a,64
        ld      hl,rbt_sp_bc
        sub     (hl)            ; cols left in the row
        cp      b
        jr      nc,_ccr
        ld      b,a
_ccr    ld      a,b
        or      a
        jr      nz,_ccx
        inc     a
_ccx    pop     hl
        ret

; ----------------------------------------------------------------------------
; rbt_sp_srcptr - IX slot, B = draw x -> DE = asset phase/frame block,
; A = nominal cols. Phase comes from the DRAW x (committed and target
; positions can differ).
; ----------------------------------------------------------------------------
rbt_sp_srcptr:
        ld      l,(ix+6)
        ld      h,(ix+7)        ; HL = asset
        push    hl
        inc     hl
        inc     hl
        ld      a,(hl)          ; nframes
        ld      c,a
        ld      a,b
        and     3               ; phase p
        ld      b,a
        or      a
        jr      z,_p0
        ld      e,c             ; E = nframes
        xor     a
_pmul   add     a,e
        djnz    _pmul           ; A = p*nframes
_p0     add     a,(ix+5)        ; + frame
        add     a,a             ; *2 (u16 entries)
        ld      e,a
        ld      d,0
        pop     hl
        push    hl
        inc     hl
        inc     hl
        inc     hl
        inc     hl              ; HL = asset+4 (offset table)
        add     hl,de
        ld      e,(hl)
        inc     hl
        ld      d,(hl)          ; DE = block offset from asset
        pop     hl
        add     hl,de
        ex      de,hl           ; DE = block ptr
        call    rbt_sp_cols
        ret

; ----------------------------------------------------------------------------
; rbt_sp_rect - IX slot, B = x, C = y -> A = clipped cols, rbt_sp_rh = rows,
; rbt_sp_bc = byte col.
; ----------------------------------------------------------------------------
rbt_sp_rect:
        ld      a,b
        rrca
        rrca
        and     #3f
        ld      (rbt_sp_bc),a   ; byte col
        call    rbt_sp_colsclip    ; A = cols
        push    af
        ; rows = min(h, 192-y), 0 when y >= 192
        ld      a,c
        cp      192
        jr      c,_rc3
        xor     a
        jr      _rc4
_rc3    ld      d,a
        ld      a,192
        sub     d               ; lines left
        ld      d,a
        ld      a,(ix+4)
        cp      d
        jr      c,_rc4
        ld      a,d
_rc4    ld      (rbt_sp_rh),a
        pop     af
        ret

; ----------------------------------------------------------------------------
; rbt_sp_save - save the screen rect under the sprite's (x,y) into the slot
; buffer -> A = 1 saved, 0 skipped (too big / off screen: no auto-erase).
; ----------------------------------------------------------------------------
rbt_sp_save:
        ld      b,(ix+1)
        ld      c,(ix+2)
        call    rbt_sp_rect        ; A = cols, rbt_sp_rh = rows
        ld      b,a
        ld      a,(rbt_sp_rh)
        or      a
        jr      z,_skp
        ld      d,a             ; D = rows
        ld      a,b             ; A = cols
        call    rbt_sp_mul      ; DE = cols*rows
        ld      a,d
        or      a
        jr      nz,_skp         ; > 255: too big
        ld      a,e
        cp      RBT_SPSAVE+1
        jr      nc,_skp         ; > 160: too big
        ; row loop
        call    rbt_sp_savebuf  ; HL = save buf
        ex      de,hl           ; DE = save ptr
        ld      a,(rbt_sp_rh)
        ld      (rbt_sp_rc),a   ; rows left
        ld      a,(ix+1)
        rrca
        rrca
        and     #3f
        ld      (rbt_sp_bc),a   ; byte col
        ld      c,(ix+2)        ; C = line
_svr    ld      a,(rbt_sp_bc)
        ld      b,a
        push    de
        call    rbt_laddr
        pop     de
        call    rbt_sp_colsclip
        ld      b,a
        call    rbt_wsplit   ; split at the band edge when scrolling
_svcpy  ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        djnz    _svcpy
        ld      a,(rbt_scr_w2)
        or      a
        jr      z,_svd2
        ld      b,a
        ld      a,h
        sub     8
        ld      h,a             ; wrapped -> band base
_svc2   ld      a,(hl)
        ld      (de),a
        inc     hl
        inc     de
        djnz    _svc2
_svd2   inc     c
        ld      a,(rbt_sp_rc)
        dec     a
        ld      (rbt_sp_rc),a
        jr      nz,_svr
        ld      a,1
        ret
_skp    xor     a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_restore - write the slot's save buffer back at its committed pos.
; ----------------------------------------------------------------------------
rbt_sp_restore:
        ld      a,(ix+16)
        rrca
        rrca
        and     #3f
        ld      (rbt_sp_bc),a   ; committed byte col
        ld      a,(ix+17)
        cp      192
        ret     nc
        ; rows = min(h, 192-cy)
        ld      c,a
        ld      a,192
        sub     c
        ld      d,a
        ld      a,(ix+4)
        cp      d
        jr      c,_rs1
        ld      a,d
_rs1    or      a
        ret     z
        ld      (rbt_sp_rc),a
        call    rbt_sp_savebuf
        ex      de,hl           ; DE = save ptr
        ld      c,(ix+17)
_rsr    ld      a,(rbt_sp_bc)
        ld      b,a
        push    de
        call    rbt_laddr
        pop     de
        call    rbt_sp_colsclip
        ld      b,a
        call    rbt_wsplit   ; split at the band edge when scrolling
_rscpy  ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        djnz    _rscpy
        ld      a,(rbt_scr_w2)
        or      a
        jr      z,_rsd2
        ld      b,a
        ld      a,h
        sub     8
        ld      h,a             ; wrapped -> band base
_rsc2   ld      a,(de)
        ld      (hl),a
        inc     hl
        inc     de
        djnz    _rsc2
_rsd2   inc     c
        ld      a,(rbt_sp_rc)
        dec     a
        ld      (rbt_sp_rc),a
        jr      nz,_rsr
        ret

; ----------------------------------------------------------------------------
; rbt_sp_eraseix - erase whatever slot IX has committed (internal + hide/kill)
; With a tilemap set (rbt_tm_on) the background is repainted from the map;
; otherwise the saved rect is restored (or the sprite redrawn for XOR).
; ----------------------------------------------------------------------------
rbt_sp_eraseix:
        ld      a,(ix+15)
        or      a
        ret     z
        ld      a,(rbt_tm_on)
        or      a
        jr      nz,_erm         ; tilemap active -> repaint cells
        ld      a,(ix+9)
        cp      2
        jr      z,_erx          ; xor: redraw to erase
        call    rbt_sp_restore
        xor     a
        ld      (ix+15),a
        ret
_erm    ; repaint the map cells under the committed rect
        ld      a,(ix+16)       ; cx
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_sp_md),a   ; spare: x0 cell
        ld      a,(ix+3)
        dec     a
        add     a,(ix+16)       ; cx + w - 1
        and     #f8
        rrca
        rrca
        rrca                    ; x1 cell
        ld      b,a
        ld      a,(rbt_sp_md)
        ld      c,a
        ld      a,b
        sub     c
        inc     a
        ld      (rbt_sp_nc),a   ; cell width
        ld      a,(ix+17)       ; cy
        and     #f8
        rrca
        rrca
        rrca
        ld      (rbt_sp_md),a   ; y0 cell
        ld      a,(ix+4)
        dec     a
        add     a,(ix+17)       ; cy + h - 1
        and     #f8
        rrca
        rrca
        rrca                    ; y1 cell
        ld      b,a
        ld      a,(rbt_sp_md)
        ld      c,a
        ld      a,b
        sub     c
        inc     a
        ld      e,a             ; E = cell height
        ld      a,(rbt_sp_nc)
        ld      d,a             ; D = cell width
        ld      a,(rbt_sp_md)
        ld      c,a             ; C = y0 cell
        ld      a,(ix+16)
        and     #f8
        rrca
        rrca
        rrca
        ld      b,a             ; B = x0 cell
        push    ix
        call    rbt_tm_redraw
        pop     ix
        xor     a
        ld      (ix+15),a
        ret
_erx    ; draw XOR at committed pos
        push    ix
        ld      a,(ix+16)
        ld      b,a
        ld      a,(ix+17)
        ld      c,a
        call    rbt_sp_bli        ; uses B,C as draw pos
        pop     ix
        xor     a
        ld      (ix+15),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_bli - draw the sprite's frame at B=x, C=y using its mode.
; ----------------------------------------------------------------------------
rbt_sp_bli:
        ld      a,c
        ld      (rbt_sp_ln),a   ; first line
        ld      a,(ix+14)       ; asset bank (#ff = resident)
        ld      hl,rbt_sp_prev
        call    rbt_pg_in       ; the block data streams straight from it
        push    bc              ; srcptr clobbers B (phase) and C
        call    rbt_sp_srcptr      ; B = x -> DE = block, A = cols
        pop     bc
        push    de
        call    rbt_sp_rect        ; B,C = pos -> A = clipped cols, rh = rows
        pop     de
        ld      (rbt_sp_nc),a   ; cols
        ld      a,(rbt_sp_rh)
        or      a
        jp      z,_blout
        ld      (rbt_sp_rc),a   ; rows left
        ld      a,(ix+9)
        ld      (rbt_sp_md),a
_blr    ; per row: B = byte col, C = line
        ld      a,(rbt_sp_bc)
        ld      b,a
        ld      a,(rbt_sp_ln)
        ld      c,a
        push    de
        call    rbt_laddr       ; HL = dst row base
        pop     de
        ld      a,(rbt_sp_nc)
        ld      b,a             ; cols left
        call    rbt_wsplit   ; split at the band edge when scrolling
_bldisp ld      a,(rbt_sp_md)
        cp      2
        jr      z,_bxx          ; xor: bmp only
        cp      1
        jr      z,_bro          ; or: bmp only
_blm    ; mask: (scr & m) | b
        ld      a,(de)
        inc     de
        and     (hl)
        ld      c,a
        ld      a,(de)
        inc     de
        or      c
        ld      (hl),a
        inc     hl
        djnz    _blm
        jr      _blw
_bro    ; or: scr | bmp (skip mask byte)
        inc     de              ; skip mask
        ld      a,(de)
        inc     de
        or      (hl)
        ld      (hl),a
        inc     hl
        djnz    _bro
        jr      _blw
_bxx    ; xor: scr ^ bmp
        inc     de
        ld      a,(de)
        inc     de
        xor     (hl)
        ld      (hl),a
        inc     hl
        djnz    _bxx
_blw    ld      a,(rbt_scr_w2)   ; band-wrapped tail of this row
        or      a
        jr      z,_blnext
        ld      b,a
        xor     a
        ld      (rbt_scr_w2),a   ; consumed
        ld      a,h
        sub     8
        ld      h,a             ; dst wraps to the band base
        jr      _bldisp         ; same mode, tail run
_blnext ld      a,(rbt_sp_rc)
        dec     a
        ld      (rbt_sp_rc),a
        jr      z,_blout
        ld      a,(rbt_sp_ln)
        inc     a
        ld      (rbt_sp_ln),a
        jp      _blr
_blout  ld      hl,rbt_sp_prev
        jp      rbt_pg_out      ; restore mapping (ret)

; ----------------------------------------------------------------------------
; rbt_sp_commit - commit slot IX: erase committed pixels, save + draw at
; current (x,y). Used by update/draw/hide/kill paths.
; ----------------------------------------------------------------------------
rbt_sp_commit:
        ld      a,(ix+0)
        bit     0,a
        jr      z,_cmno         ; inactive: erase only
        bit     1,a
        jr      nz,_cmno        ; hidden: erase only
        call    rbt_sp_eraseix
        jr      rbt_sp_donew
_cmno   call    rbt_sp_eraseix
        ld      a,(ix+0)
        and     #fb
        ld      (ix+0),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_donew - pass-2 half of a commit: save the backdrop under (x,y) and
; draw there. rbt_sp_update calls this directly after its own erase pass so
; every save sees the lower slots' final positions.
; ----------------------------------------------------------------------------
rbt_sp_donew:
        ; save bg under new rect (mask/or modes)
        ld      a,(ix+9)
        cp      2
        jr      z,_dnxor
        call    rbt_sp_save        ; A = 1 if the rect was saved
        ld      (ix+15),a       ; committed only if auto-erase is possible
        jr      _dndr
_dnxor  ld      (ix+15),1       ; xor erases by redraw
_dndr   ; draw at (x,y)
        ld      b,(ix+1)
        ld      c,(ix+2)
        call    rbt_sp_bli
        ld      a,(ix+1)
        ld      (ix+16),a
        ld      a,(ix+2)
        ld      (ix+17),a
        ld      a,(ix+0)
        and     #fb             ; clear dirty
        ld      (ix+0),a
        ret

; ----------------------------------------------------------------------------
; rbt_sp_reset - drop all committed/screen state after CLS (called by
; rbt_cls; stubbed by the compiler when the sprite module is absent).
; ----------------------------------------------------------------------------
rbt_sp_reset:
        xor     a
        ld      (rbt_sp_i),a
_rsl    ld      a,(rbt_sp_i)
        call    rbt_slot
        ld      a,(ix+0)
        and     3               ; keep active+hidden, drop dirty
        ld      (ix+0),a
        bit     0,a
        jr      z,_rsk          ; inactive -> stays undrawn
        bit     1,a
        jr      nz,_rsk         ; hidden -> stays undrawn
        or      4
        ld      (ix+0),a        ; active+visible -> dirty: redrawn
_rsk    ld      (ix+15),0       ; nothing committed
        ld      a,(rbt_sp_i)
        inc     a
        ld      (rbt_sp_i),a
        cp      RBT_NSLOTS
        jr      c,_rsl
        ret

; ----------------------------------------------------------------------------
; rbt_sp_draw - A = id: draw slot now (commit). SPRITE REDRAW.
; ----------------------------------------------------------------------------
rbt_sp_draw:
        call    rbt_slot
        call    rbt_sp_commit
        jp      rbt_sp_animstep

; ----------------------------------------------------------------------------
; rbt_sp_update - commit every dirty slot (SPRITES UPDATE).
;
; Two passes keep save-under restores honest: a slot's save buffer can hold
; slices of lower-z sprites drawn beneath it when it was saved. Pass 1
; restores dirty slots high->low, so a sprite whose image a higher slot
; captured gets its own restore in afterwards, covering the stale copy.
; Pass 2 saves + redraws low->high, so every save records the lower slots'
; final positions — the next frame's restores stay consistent.
;
; An erase also damages any other committed sprite it overlaps: lower slots
; are pulled into the same erase pass (mark bit0 -> full recommit in pass 2),
; higher slots only need their bitmap repainted over the restored backdrop
; (mark bit1 -> rbt_sp_bli at the committed pos in pass 2). Marks chain, so
; a damaged slot's own erase propagates the marks further down.
; ----------------------------------------------------------------------------
rbt_sp_update:
        call    rbt_sfx_drain
        ld      hl,rbt_sp_mark
        ld      b,RBT_NSLOTS
        xor     a
_uc     ld      (hl),a          ; clear damage marks
        inc     hl
        djnz    _uc
        ; pass 1: restore dirty or damage-marked slots, high->low
        ld      a,RBT_NSLOTS-1
_u1     ld      (rbt_sp_i),a
        call    rbt_slot
        ld      a,(ix+0)
        bit     2,a
        jr      nz,_u1e         ; dirty
        ld      a,(rbt_sp_i)
        call    _markp
        bit     0,(hl)
        jp      z,_u1n          ; clean and undamaged
_u1e    ld      a,(ix+15)
        or      a
        jp      z,_u1x          ; nothing committed -> nothing to restore
        ; capture the rect about to be restored (committed pos + size)
        ld      a,(ix+16)
        ld      (rbt_sp_x0),a
        add     a,(ix+3)
        dec     a
        ld      (rbt_sp_x1),a
        ld      a,(ix+17)
        ld      (rbt_sp_y0),a
        add     a,(ix+4)
        dec     a
        ld      (rbt_sp_y1),a
        call    rbt_sp_eraseix
        ; mark committed neighbours overlapping the restored rect
        xor     a
_u1s    ld      (rbt_sp_j),a
        ld      hl,rbt_sp_i
        cp      (hl)
        jr      z,_u1sn         ; self
        call    rbt_slot        ; IX = slot j
        ld      a,(ix+0)
        bit     0,a
        jr      z,_u1sn         ; inactive
        bit     1,a
        jr      nz,_u1sn        ; hidden: the dirty flag erases it anyway
        ld      a,(ix+15)
        or      a
        jr      z,_u1sn         ; not committed
        ld      a,(ix+16)
        add     a,(ix+3)
        dec     a               ; jx1 = jx + jw - 1
        ld      hl,rbt_sp_x0
        cp      (hl)
        jr      c,_u1sn         ; j right edge left of the restored rect
        ld      a,(rbt_sp_x1)
        cp      (ix+16)
        jr      c,_u1sn         ; rect right edge left of j
        ld      a,(ix+17)
        add     a,(ix+4)
        dec     a               ; jy1
        ld      hl,rbt_sp_y0
        cp      (hl)
        jr      c,_u1sn
        ld      a,(rbt_sp_y1)
        cp      (ix+17)
        jr      c,_u1sn
        ld      a,(rbt_sp_j)
        ld      hl,rbt_sp_i
        cp      (hl)
        ld      b,1             ; j < i: erase + recommit later in this pass
        jr      c,_um1
        ld      b,2             ; j > i: repaint only (already erased pass)
_um1    ld      a,(rbt_sp_j)
        call    _markp
        ld      a,(hl)
        or      b
        ld      (hl),a
_u1sn   ld      a,(rbt_sp_j)
        inc     a
        cp      RBT_NSLOTS
        jr      c,_u1s
        jr      _u1n
_u1x    call    rbt_sp_eraseix  ; dirty but uncommitted: no-op, keeps flags
_u1n    ld      a,(rbt_sp_i)
        dec     a
        jp      p,_u1
        ; pass 2: save + draw dirty/marked slots, low->high
        xor     a
_u2     ld      (rbt_sp_i),a
        call    rbt_slot
        ld      a,(rbt_sp_i)
        call    _markp
        ld      a,(ix+0)
        bit     2,a
        jr      nz,_u2d         ; dirty
        bit     0,(hl)
        jr      nz,_u2dn        ; damage-recommit: erased in pass 1
        bit     1,(hl)
        jr      z,_u2n          ; untouched
        ld      b,(ix+16)       ; damage-repaint: bitmap over restored bg
        ld      c,(ix+17)
        call    rbt_sp_bli
        jr      _u2n
_u2d    bit     0,a
        jr      z,_u2c          ; inactive: just clear dirty
        bit     1,a
        jr      nz,_u2c         ; hidden: just clear dirty
_u2dn   call    rbt_sp_donew
        jr      _u2n
_u2c    ld      a,(ix+0)
        and     #fb             ; clear dirty
        ld      (ix+0),a
_u2n    call    rbt_sp_animstep
        ld      a,(rbt_sp_i)
        inc     a
        cp      RBT_NSLOTS
        jr      c,_u2
        ret
_markp  ld      hl,rbt_sp_mark  ; HL = damage-mark byte for slot A
        add     a,l
        ld      l,a
        ret     nc
        inc     h
        ret

; ----------------------------------------------------------------------------
; rbt_sp_drawall - commit every drawable slot (SPRITES DRAW).
; ----------------------------------------------------------------------------
rbt_sp_drawall:
        xor     a
        ld      (rbt_sp_i),a
_dl     ld      a,(rbt_sp_i)
        call    rbt_slot
        ld      a,(ix+0)
        bit     0,a
        jr      z,_dnext
        bit     1,a
        jr      nz,_dnext
        call    rbt_sp_commit
        call    rbt_sp_animstep
_dnext  ld      a,(rbt_sp_i)
        inc     a
        ld      (rbt_sp_i),a
        cp      RBT_NSLOTS
        jr      c,_dl
        ret

; ----------------------------------------------------------------------------
; rbt_spcoll - A = id a, B = id b -> A = 1 if their bboxes overlap.
; ----------------------------------------------------------------------------
rbt_spcoll:
        push    bc
        call    rbt_slot        ; IX = slot a
        pop     bc
        ld      a,(ix+0)
        bit     0,a
        jr      z,_no
        push    iy
        ld      a,b
        and     RBT_NSLOTS-1
        ld      e,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; *16
        add     a,e
        add     a,e             ; *18 (id=15 -> 270: carry!)
        ld      e,a
        ld      d,0
        jr      nc,_sc_nc
        inc     d
_sc_nc  ld      iy,rbt_sprites
        add     iy,de
        ld      a,(iy+0)
        bit     0,a
        jr      z,_noy
        ; x1 < x2 + w2 ?
        ld      a,(iy+3)
        add     a,(iy+1)
        ld      b,a
        ld      a,(ix+1)
        cp      b
        jr      nc,_noy
        ; x2 < x1 + w1 ?
        ld      a,(ix+3)
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
; rbt_sp_mul - A = x, D = y -> DE = x*y (8x8 -> 16). Preserves BC.
; ----------------------------------------------------------------------------
rbt_sp_mul:
        ld      e,a             ; DE = x
        ld      a,d             ; A = y (bit loop)
        ld      d,0
        ld      hl,0
        ld      b,8
_mdl    add     hl,hl
        rla
        jr      nc,_mdn
        add     hl,de
_mdn    djnz    _mdl
        ex      de,hl           ; DE = product
        ret

; ----------------------------------------------------------------------------
; scratch
; ----------------------------------------------------------------------------
rbt_sp_i        defb 0          ; slot index for update/drawall
rbt_sp_j        defb 0          ; update damage-scan inner index
rbt_sp_x0       defb 0          ; erased rect for damage marking
rbt_sp_x1       defb 0
rbt_sp_y0       defb 0
rbt_sp_y1       defb 0
rbt_sp_mark     defs RBT_NSLOTS ; update marks: bit0 recommit, bit1 repaint
rbt_sp_rc       defb 0          ; row counter
rbt_sp_rh       defb 0          ; clipped rows
rbt_sp_nc       defb 0          ; clipped cols
rbt_sp_bc       defb 0          ; byte col
rbt_sp_ln       defb 0          ; current line
rbt_sp_md       defb 0          ; draw mode
rbt_sp_prev     defb 0          ; mapping save byte for asset-bank guards
rbt_sp_rw       defb 0          ; spare
