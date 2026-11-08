; ============================================================================
; rbt_sprite_asm - hardware sprites via the Sprite Attribute Table (MSX1/2)
;
; 16 slots. Each sprite id owns SAT entry #id at #1B00+id*4 and SPT
; pattern #id at #3800+id*32 (R1 was initialised for 16x16 sprites).
; The .rbs encoder emits 32-byte octant patterns (TL,BL,TR,BR) + a
; colour nibble — FRAME/ANIMATE just recopy the pattern bytes.
;
; On RBT_MSX2 (rbt_smode=1) the V9938 runs sprite mode 2: SAT moves to
; #7600, patterns to #7800, and colour leaves the SAT for the Sprite
; Colour Table at #7400 (16 bytes per sprite, one per line — we write
; the same colour to all of them, keeping the single-colour contract).
; The hide terminator is 216 and 8 sprites fit per scanline.
; rbt_sp_remode re-uploads the tables after a MODE switch (hooked via
; rbt_hook_mode).
;
; TMS9918 quirks honoured here:
;   - SAT byte0 = screen row - 1 (sprite appears on line y+1), so
;     stored coords are written minus 1 (same convention in mode 2).
;   - y = 208 (#d0) is the SAT terminator — hiding writes 209, never 208.
;   - Max 4 sprites per scanline (hardware limit; VDP flags it, we don't).
;
; Slot layout (12 bytes):
;  +0  flags: bit0 active, bit1 hidden
;  +1  x  +2  y          (screen coords, before the -1)
;  +3  frame +4 nframes
;  +5,6 frame data ptr   (asset + 4 — past the w/h/nframes/colour header)
;  +7  colour nibble
;  +8  animFirst +9 animLast +10 animFlags(b0 pingpong,b1 on) +11 animDir
; ============================================================================

RBT_NSLOTS      equ 16
; slot layout (16 bytes — power-of-2 addressing):
;  +0  flags: bit0 active, bit1 hidden
;  +1  x  +2  y          (screen coords, before the -1)
;  +3  frame +4 nframes
;  +5,6 frame data ptr   (asset + 4 — past the w/h/nframes/colour header)
;  +7  colour nibble
;  +8  animFirst +9 animLast +10 animFlags(b0 pingpong,b1 on) +11 animDir
;  +12 SAT offset (id*4)
;  +13 w +14 h        (asset pixel size — COLLIDETILE's bbox; the SAT
;                     entry is always 16x16 but the sprite may be smaller)
;  +15 pad

rbt_sprites     defs RBT_NSLOTS*16

; ----------------------------------------------------------------------------
; rbt_slot - A = sprite id -> IX = slot address (id*16). Preserves BC,DE,HL.
; ----------------------------------------------------------------------------
rbt_slot:
        and     RBT_NSLOTS-1
        push    de
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; id*16
        ld      e,a
        ld      d,0
        ld      ix,rbt_sprites
        add     ix,de
        pop     de
        ret

; ----------------------------------------------------------------------------
; rbt_sp_spt - IX = slot -> copy the slot's current frame (32 bytes) into
; its SPT pattern (#3800 + id*32 = #3800 + satoff*8). Clobbers A,BC,DE,HL.
; ----------------------------------------------------------------------------
rbt_sp_spt:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_sp_spt5
        endif
        ld      a,(ix+12)       ; satoff = id*4 (max 60)
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; id*32 — 16-bit, must not wrap a byte
        ld      de,#3800
        add     hl,de           ; SPT addr
        ex      de,hl           ; DE = SPT dest
        ; source = frameptr + frame*32
        ld      l,(ix+5)
        ld      h,(ix+6)
        ld      a,(ix+3)        ; frame
        or      a
        jr      z,_src
        ld      b,a
_f32    ld      a,l
        add     a,32
        ld      l,a
        jr      nc,_fc
        inc     h
_fc     djnz    _f32
_src    ld      bc,32
        push    de
        push    hl
        pop     de              ; DE = src
        pop     hl              ; HL = dest
        call    rbt_vwrite
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_sp_spt5 - Screen 5 pattern upload: same 32-byte frame, SPT at
; #7800 + id*32 via the 17-bit writer.
; ----------------------------------------------------------------------------
rbt_sp_spt5:
        ld      a,(ix+12)       ; satoff = id*4
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; id*32
        ld      de,#7800
        add     hl,de           ; SPT addr
        ex      de,hl           ; DE = SPT dest
        ld      l,(ix+5)
        ld      h,(ix+6)
        ld      a,(ix+3)        ; frame
        or      a
        jr      z,_src
        ld      b,a
_f32    ld      a,l
        add     a,32
        ld      l,a
        jr      nc,_fc
        inc     h
_fc     djnz    _f32
_src    ld      bc,32
        push    de
        push    hl
        pop     de              ; DE = src
        pop     hl              ; HL = dest
        call    rbt_vwrite5
        ret

; ----------------------------------------------------------------------------
; rbt_sp_sct - write the sprite's colour to its 16 Sprite Colour Table
; bytes (#7400 + id*16) — one colour byte per line, same colour for all
; (the .rbs single-colour contract). No-op outside Screen 5.
; ----------------------------------------------------------------------------
rbt_sp_sct:
        ld      a,(rbt_smode)
        or      a
        ret     z               ; colour table only exists in mode 2
        ld      a,(ix+12)       ; satoff = id*4
        add     a,a
        add     a,a             ; id*16
        ld      l,a
        ld      h,#74           ; HL = #7400 + id*16
        call    rbt_vwaddr5
        ld      a,(ix+7)        ; colour nibble
        ld      b,16
_sc     out     (#98),a
        djnz    _sc
        ret
        else
rbt_sp_sct:                     ; no SCT on MSX1 — single-colour SAT byte
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_sp_sat - IX = slot -> write the 4-byte SAT entry for this sprite at
; #1B00 + satoff. Pattern number = id = satoff/4.
; ----------------------------------------------------------------------------
rbt_sp_sat:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jp      nz,rbt_sp_sat5
        endif
        ld      a,(ix+12)       ; SAT offset (id*4)
        ld      l,a
        ld      h,#1b           ; HL = #1B00 + offset
        ; hidden/inactive -> y = 209
        ld      a,(ix+0)
        and     3
        ld      e,(ix+2)        ; y
        cp      1
        jr      z,_yy           ; active & !hidden
        ld      e,209
        jr      _yw
_yy     dec     e               ; SAT y = row - 1
_yw     call    rbt_vwaddr
        ld      a,e
        out     (#98),a         ; y
        ld      a,(ix+1)
        out     (#98),a         ; x
        ld      a,l             ; pattern # = SAT offset (id*4): the VDP
        out     (#98),a         ; indexes SPT in 8-byte units — each 16x16
                                ; sprite occupies 4 consecutive 8-byte
                                ; patterns, so id*4 points at its first.
        ld      a,(ix+7)
        out     (#98),a         ; colour
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_sp_sat5 - Screen 5 SAT write at #7600 + satoff. Mode 2: byte3 is
; unused (colour lives in the SCT), hide value is 216.
; ----------------------------------------------------------------------------
rbt_sp_sat5:
        ld      a,(ix+12)       ; SAT offset (id*4)
        ld      l,a
        ld      h,#76           ; HL = #7600 + offset
        ld      a,(ix+0)
        and     3
        ld      e,(ix+2)        ; y
        cp      1
        jr      z,_yy           ; active & !hidden
        ld      e,216           ; mode 2 terminator
        jr      _yw
_yy     dec     e               ; SAT y = row - 1
_yw     call    rbt_vwaddr5
        ld      a,e
        out     (#98),a         ; y
        ld      a,(ix+1)
        out     (#98),a         ; x
        ld      a,l             ; pattern # = SAT offset
        out     (#98),a
        xor     a
        out     (#98),a         ; byte3 unused in mode 2
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_sp_create - A=id, HL=asset, B=mode(unused), C=x, D=y, E=bank(unused)
; asset: defb w,h,nframes,colour, 32-byte frames
; ----------------------------------------------------------------------------
rbt_sp_create:
        push    hl
        push    bc
        push    af              ; id
        call    rbt_slot
        pop     af
        add     a,a
        add     a,a             ; SAT offset = id*4
        ld      (ix+12),a
        pop     bc
        pop     hl
        ld      (ix+0),1        ; active
        ld      (ix+1),c        ; x
        ld      (ix+2),d        ; y
        ld      a,(hl)          ; w (pixels) -> +13 for COLLIDETILE's bbox
        ld      (ix+13),a
        inc     hl
        ld      a,(hl)          ; h (pixels) -> +14
        ld      (ix+14),a
        inc     hl
        ld      a,(hl)          ; nframes
        ld      (ix+4),a
        inc     hl
        ld      a,(hl)          ; colour nibble
        ld      (ix+7),a
        inc     hl
        ld      (ix+5),l
        ld      (ix+6),h        ; frame data ptr
        xor     a
        ld      (ix+3),a        ; frame 0
        ld      (ix+8),a
        ld      (ix+9),a
        ld      (ix+10),a       ; anim off
        call    rbt_sp_spt
        call    rbt_sp_sct      ; mode-2 colour table (no-op on SC2/MSX1)
        jp      rbt_sp_sat

; ----------------------------------------------------------------------------
; rbt_sp_move - A=id, B=dx, C=dy (signed). Wraps at edges; hardware clips.
; ----------------------------------------------------------------------------
rbt_sp_move:
        call    rbt_slot
        ld      a,(ix+1)
        add     a,b
        ld      (ix+1),a
        ld      a,(ix+2)
        add     a,c
        ld      (ix+2),a
        jp      rbt_sp_sat

; ----------------------------------------------------------------------------
; rbt_sp_place - A=id, B=x, C=y (absolute)
; ----------------------------------------------------------------------------
rbt_sp_place:
        call    rbt_slot
        ld      (ix+1),b
        ld      (ix+2),c
        jp      rbt_sp_sat

; ----------------------------------------------------------------------------
; rbt_sp_frame - A=id, B=frame
; ----------------------------------------------------------------------------
rbt_sp_frame:
        call    rbt_slot
        ld      a,(ix+4)
        or      a
        ret     z
        ld      a,b
        cp      (ix+4)
        jr      c,_ok
        xor     a               ; clamp wraps to 0
_ok     ld      (ix+3),a
        jp      rbt_sp_spt

; ----------------------------------------------------------------------------
; rbt_sp_anim - A=id, B=first, C=last, D=pingpong. Marks animating; the
; frame advance happens in rbt_sp_update.
; ----------------------------------------------------------------------------
rbt_sp_anim:
        call    rbt_slot
        ld      (ix+8),b
        ld      (ix+9),c
        ld      (ix+3),b        ; current = first
        ld      a,d
        and     1
        or      2               ; pingpong flag | animating
        ld      (ix+10),a
        ld      (ix+11),1       ; dir +
        jp      rbt_sp_spt

; ----------------------------------------------------------------------------
; rbt_sp_kill / rbt_sp_hide / rbt_sp_show / rbt_sp_draw - A=id
; ----------------------------------------------------------------------------
rbt_sp_kill:
        call    rbt_slot
        ld      (ix+0),0        ; inactive
        jp      rbt_sp_sat      ; writes y=209

rbt_sp_hide:
        call    rbt_slot
        set     1,(ix+0)
        jp      rbt_sp_sat

rbt_sp_show:
        call    rbt_slot
        res     1,(ix+0)
        jp      rbt_sp_sat

rbt_sp_draw:
        call    rbt_slot
        bit     0,(ix+0)
        ret     z
        call    rbt_sp_spt
        jp      rbt_sp_sat

; ----------------------------------------------------------------------------
; rbt_sp_attr - A=id, B=ZX attr (ink|paper<<3|bright<<6). Only the ink
; half maps — MSX sprites are single-colour.
; ----------------------------------------------------------------------------
rbt_sp_attr:
        call    rbt_slot
        ld      a,b
        and     7
        ld      c,a
        ld      a,b
        and     #40
        rrca
        rrca
        rrca
        or      c
        ld      hl,rbt_zx2msx
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        ld      (ix+7),a
        call    rbt_sp_sct      ; mode-2 colour table (no-op on SC2/MSX1)
        jp      rbt_sp_sat

; ----------------------------------------------------------------------------
; rbt_sp_update - tick animations and refresh every active sprite
; ----------------------------------------------------------------------------
rbt_sp_update:
        ld      b,RBT_NSLOTS
        ld      c,0             ; id
_up     push    bc
        ld      a,c
        call    rbt_slot
        bit     0,(ix+0)
        jr      z,_next
        bit     1,(ix+10)       ; animating?
        jr      z,_noanim
        ld      a,(ix+3)
        add     a,(ix+11)       ; frame += dir
        ld      d,a
        ld      a,(ix+11)
        or      a
        jp      p,_fwd
        ld      a,d             ; dir - : below first?
        ld      e,(ix+8)
        cp      e
        jr      nc,_set
        bit     0,(ix+10)       ; pingpong?
        jr      nz,_pp1
        ld      a,(ix+9)        ; wrap to last
        ld      d,a
        jr      _set
_pp1    ld      (ix+11),1       ; bounce up
        ld      d,(ix+8)
        jr      _set
_fwd    ld      a,d             ; dir + : above last?
        ld      e,(ix+9)
        cp      e
        jr      c,_set
        jr      z,_set
        bit     0,(ix+10)
        jr      nz,_pp2
        ld      d,(ix+8)        ; wrap to first
        jr      _set
_pp2    ld      (ix+11),#ff     ; bounce down
        ld      d,(ix+9)
_set    ld      (ix+3),d
        call    rbt_sp_spt
_noanim call    rbt_sp_sat
_next   pop     bc
        inc     c
        djnz    _up
        ret

; ----------------------------------------------------------------------------
; rbt_sp_drawall - refresh every active sprite (SAT + pattern)
; ----------------------------------------------------------------------------
rbt_sp_drawall:
        ld      b,RBT_NSLOTS
        ld      c,0
_da     push    bc
        ld      a,c
        call    rbt_slot
        bit     0,(ix+0)
        jr      z,_dnext
        call    rbt_sp_spt
        call    rbt_sp_sat
_dnext  pop     bc
        inc     c
        djnz    _da
        ret

; ----------------------------------------------------------------------------
; rbt_spx / rbt_spy - A=id -> HL = stored x / y (screen coords)
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
; rbt_spcoll - A = id1, B = id2 -> A = 1 when the 16x16 boxes overlap.
; Lives here (not in spcoll.asm) because SPRITECOLLIDE only pulls the
; sprite module — same split as the ZX/CPC runtimes.
; ----------------------------------------------------------------------------
rbt_spcoll:
        call    rbt_slot
        bit     0,(ix+0)        ; active?
        jr      z,_no
        ld      a,(ix+1)
        ld      (rbt_sc_x1),a
        ld      a,(ix+2)
        ld      (rbt_sc_y1),a
        ld      a,b
        call    rbt_slot
        bit     0,(ix+0)
        jr      z,_no
        ; |x1-x2| < 16 && |y1-y2| < 16
        ld      a,(rbt_sc_x1)
        sub     (ix+1)
        jr      nc,_dx
        neg
_dx     cp      16
        jr      nc,_no
        ld      a,(rbt_sc_y1)
        sub     (ix+2)
        jr      nc,_dy
        neg
_dy     cp      16
        jr      nc,_no
        ld      a,1
        ret
_no     xor     a
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_sp_remode - sprite-table refresh after a MODE switch (called via
; rbt_hook_mode): hide every SAT entry for the new mode's table, then
; re-upload pattern/colour/attribute for each active sprite.
; ----------------------------------------------------------------------------
rbt_sp_remode:
        ld      a,(rbt_smode)
        or      a
        jr      nz,_m5
        ; back to Screen 2: hide all 32 (y=209), refresh actives
        ld      a,209
        ld      hl,#1b00
        ld      bc,128
        call    rbt_vfill
        jp      rbt_sp_drawall
_m5     ; Screen 5: hide all 32 (y=216), clear SCT, refresh actives
        ld      a,216
        ld      hl,#7600
        ld      bc,128
        call    rbt_vfill5
        xor     a
        ld      hl,#7400
        ld      bc,512
        call    rbt_vfill5
        ld      b,RBT_NSLOTS
        ld      c,0             ; id
_up     push    bc
        ld      a,c
        call    rbt_slot
        bit     0,(ix+0)
        jr      z,_next
        call    rbt_sp_spt5
        call    rbt_sp_sct
        call    rbt_sp_sat5
_next   pop     bc
        inc     c
        djnz    _up
        ret
        endif

rbt_sc_x1       defb 0
rbt_sc_y1       defb 0
