; ============================================================================
; rbt_sprite - VIC-II hardware sprite engine + Y-sorted raster-IRQ
; multiplexer (Commodore 64, ca65)
;
; TODO(revisit): the mux is much better but still not perfect — >8-sprite
; games (invaders) can still show occasional flicker when a rebind lands
; late. Next steps worth trying: tighter staging, a smaller lead time on
; the early arm, or double-buffering the pending stages so mid-frame
; applies never wait on sched output.
;
; 16 virtual slots drive the 8 hardware sprites. A raster IRQ at the
; frame-reset line (300, bottom border) does the once-per-frame commit —
; step animations, sort the live slots by Y, stage each slot's hw
; register image and bind the first 8 to the hardware — so every bind
; lands inside the border, before any sprite's top line. Mid-frame raster
; IRQs then rebind each hardware sprite to the next pending slot as the
; beam reaches its bottom, armed early enough that the rebind lands
; before the pending sprite's top. SPRITES UPDATE/DRAWALL/DRAW only
; ensure the mux is installed; the frame IRQ owns the schedule.
; SPRITECOLLIDE is a bounding-box test like the ZX engine (the VIC's
; $D01E/$D01F latches only cover currently-bound hardware pairs, so
; software bbox is the portable semantic).
;
; Logical coords match the ZX model: x 0-255, y 0-191 inside the text area.
; Hardware coords add the C64 border offsets: hwX = x+24 ($D010 bit for
; x>231), hwY = y+50.
;
; Sprite data is normally addressed in place: .rbs frames are padded
; to 64B and emitted in the SPDATA segment (linked on a 64B boundary),
; so each frame lands on a SPRPTR-addressable boundary in the active VIC
; bank and binding a slot is just a pointer write. A fallback pool of
; 8 x 64B buffers still serves frames that aren't directly addressable —
; runtime-loaded (COPYBANK) or linked outside the active bank. The pool
; sits inside the custom-charset window's unused codes 64-127 — text
; uses 0-63, tiles 128+ (C64: $CA00 in the bank-3 charset at $C800;
; C128: $3A00 in the bank-0 charset at $3800; the live base is in core's
; rbt_sppool/rbt_spptrb).
;
; .rbs (cbm encode): defb w,h,nframes,colour padded to 64 bytes; then
; frames of 63 bytes + pad (21 rows x 3 bytes, MSB-left), source
; clipped/padded to 24x21.
;
; Slot record (16 bytes, mirrors the ZX layout):
;   +0  flags: bit0 live, bit1 hidden
;   +1  x +2 y (logical pixels)
;   +3  w +4 h (source pixels; collision bbox)
;   +5  frame +6,7 asset ptr
;   +8  colour +9 mode (stored; hardware sprites have no blend mode)
;   +10 animFirst +11 animLast
;   +12 animFlags: bit0 pingpong, bit1 animating
;   +13 animDir (1 / $ff)
;   +14 asset bank ($ff - unused, no banked RAM)
;   +15 unused (was hw binding; the mux tracks binding in rbt_sp_bind)
; ============================================================================

RBT_SP_N        = 16            ; virtual slots
RBT_SP_SLOT     = 16            ; bytes per slot
RBT_SP_XOFF     = 24            ; logical->hardware offsets
RBT_SP_YOFF     = 50
RBT_SP_POOL     = RBT_POOLH<<8  ; 8 x 64B sprite data buffers (text-mode
                                ;  defaults — MODE 1 moves the pool to the
                                ;  bank-1 $7800 window; the live base is in
                                ;  core's rbt_sppool/rbt_spptrb)
RBT_SP_PTRBASE  = RBT_POOLP     ; SPRPTR value for the pool base
RBT_SP_FLINE    = 250           ; frame-reset raster line — past the visible
                                ; area, valid on PAL (312) and NTSC (263)
RBT_SP_H        = 21            ; hardware sprite height
RBT_SP_LEAD     = 12            ; max lines a bound sprite may be cut short

        .code

rbt_sprites:    .res 256        ; RBT_SP_N * RBT_SP_SLOT
rbt_sp_order:   .res RBT_SP_N   ; live slot ids sorted by y
rbt_sp_ordy:    .res RBT_SP_N   ; slot y parallel to order[] (fast sort)
rbt_sp_bind:    .res 8          ; order[] index bound to hw sprite n
rbt_sp_nlive:   .res 1
rbt_sp_next:    .res 1          ; next order[] index awaiting a hw sprite
rbt_sp_phase:   .res 1          ; 0 = mid-frame rebind, 1 = frame reset
rbt_sp_line:    .res 2          ; currently armed raster line
rbt_sp_inited:  .res 1
rbt_sp_j:       .res 1          ; sort inner-loop index
rbt_sp_src:     .res 16         ; per-hw pool-copy key: src lo/hi
rbt_sp_stage:   .res 128        ; 16 x 8B register images, by order idx
rbt_sp_bot:     .res 8          ; bound occupant's bottom line per hw
rbt_sp_d010:    .res 1          ; $D010/$D015 are write-only — reads return
rbt_sp_d015:    .res 1          ; open bus, so RMW goes through shadows

; Stage record (8 bytes, indexed by order position): precomputed at
; sched time so the raster-IRQ apply is just a burst of register writes.
;   +0  hw x low byte (lx + 24)
;   +1  hw y (ly + 50) — also the sprite's top line
;   +2  colour nibble
;   +3  SPRPTR value (direct path only)
;   +4  flags: bit7 = needs pool copy (unaligned/out-of-bank frame),
;       bit0 = hw x bit8 ($D010)
;   +5  bottom line (hw y + 21, clamped to 255)
;   +6,+7 frame source address (pool-copy path)

; The raster IRQ handlers only ever touch these private zero-page regs —
; the IRQ can fire anywhere in mainline code, so they must not clobber
; the rbt_hl/de/bc/t*/ptr regs the compiler emits around calls.
        .zeropage
rbt_si0:        .res 1          ; hw sprite n / loop index
rbt_si1:        .res 1          ; order idx
rbt_si2:        .res 1          ; byte temps; si2:si3 hold words
rbt_si3:        .res 1
rbt_sptr:       .res 2          ; slot pointer inside mux paths
        .code

; ----------------------------------------------------------------------------
; rbt_slot - A = sprite id -> rbt_ptr = slot. Clobbers A/X.
; ----------------------------------------------------------------------------
rbt_sp_sltab:
        .word   rbt_sprites+0,   rbt_sprites+16,  rbt_sprites+32
        .word   rbt_sprites+48,  rbt_sprites+64,  rbt_sprites+80
        .word   rbt_sprites+96,  rbt_sprites+112, rbt_sprites+128
        .word   rbt_sprites+144, rbt_sprites+160, rbt_sprites+176
        .word   rbt_sprites+192, rbt_sprites+208, rbt_sprites+224
        .word   rbt_sprites+240

rbt_slot:
        and     #RBT_SP_N-1
        asl
        tax
        lda     rbt_sp_sltab,x
        sta     rbt_ptr
        lda     rbt_sp_sltab+1,x
        sta     rbt_ptr+1
        rts

; ----------------------------------------------------------------------------
; rbt_sp_hwinit - one-time: install the raster IRQ handler, enable VIC
; raster IRQs. Non-raster IRQs (CIA1's 60Hz tick) still chain to $EA31,
; so keyboard scan and the jiffy clock keep working.
; ----------------------------------------------------------------------------
rbt_sp_hwinit:
        lda     rbt_sp_inited
        bne     @done
        sei
        lda     #<rbt_irq
        sta     $0314
        lda     #>rbt_irq
        sta     $0315
        jsr     rbt_mapio       ; VIC regs live in the I/O window on c128
        lda     #$01
        sta     $d019           ; ack any pending VIC IRQ
        sta     $d01a           ; raster IRQ enable
        lda     #0
        sta     $d010
        sta     rbt_sp_d010     ; sync the write-only-reg shadows
        sta     $d015
        sta     rbt_sp_d015
        lda     #1
        sta     rbt_sp_inited
        lda     #$ff
        ldx     #7
@clr:   sta     rbt_sp_bind,x
        sta     rbt_sp_bot,x
        dex
        bpl     @clr
        lda     #0
        ldx     #15
@cl2:   sta     rbt_sp_src,x    ; no asset lives at $0000 -> first apply copies
        dex
        bpl     @cl2
        lda     #<RBT_SP_FLINE
        sta     rbt_sp_line
        lda     #>RBT_SP_FLINE
        sta     rbt_sp_line+1
        lda     #1
        sta     rbt_sp_phase
        jsr     rbt_sp_setline
        jsr     rbt_maprun
        cli
@done:  rts

; rbt_irq - $0314 vector target. Ours iff $D019 bit0. The kernal already
; pushed A/X/Y; the mux handlers only touch their private ZP regs
; (rbt_si*/rbt_sptr), so no save/restore is needed and there is no kernal
; chain on raster IRQs — CIA1's own 60Hz IRQ still reaches $EA31 for
; keyboard scan and the jiffy clock.
rbt_irq:
        .if RBT_C128
        lda     #$3e
        sta     $ff00           ; I/O + RAM $4000+ (no kernal, but the I
                                ; flag is already set — nothing can fire)
        .endif
        lda     $d019
        and     #1
        beq     @kern
        jsr     rbt_sp_irq
        lda     #$01
        sta     $d019           ; ack raster IRQ
        .if RBT_C128
        lda     #$0f
        sta     $ff00           ; $ff33 is kernal ROM — remap it first
        jmp     $ff33           ; c128 trampoline pushed A,X,Y then CR —
                                ; its exit restores all four, then rti
        .else
        pla                     ; kernal entry pushed A,X,Y (Y on top)
        tay
        pla
        tax
        pla
        rti
        .endif
@kern:
        .if RBT_C128
        lda     #$00
        sta     $ff00           ; all-ROM map — the kernal handler calls
                                ; editor code at $4006 in ROM-lo
        .endif
        jmp     RBT_KERNAL_IRQ  ; kernal housekeeping ($EA31 c64 / $FA6B
                                ; c128 — past its raster-split manager at
                                ; $C024, which would re-arm $D012 every
                                ; tick and steal our raster IRQ)

; rbt_slot2 - A = sprite id -> rbt_sptr = slot. IRQ-side twin of
; rbt_slot; writes rbt_sptr so it can't clobber a live rbt_ptr.
; Clobbers A/X.
rbt_slot2:
        and     #RBT_SP_N-1
        asl
        tax
        lda     rbt_sp_sltab,x
        sta     rbt_sptr
        lda     rbt_sp_sltab+1,x
        sta     rbt_sptr+1
        rts

; ----------------------------------------------------------------------------
; rbt_sp_setline - arm the raster IRQ at rbt_sp_line (9-bit).
; ----------------------------------------------------------------------------
rbt_sp_setline:
        lda     rbt_sp_line
        sta     $d012
        lda     $d011
        and     #$7f
        ldx     rbt_sp_line+1
        beq     @lo
        ora     #$80
@lo:    sta     $d011
        rts

; ----------------------------------------------------------------------------
; rbt_sp_create - A=id, B=mode, C=x, D=y, E=bank, rbt_hl=asset.
; ----------------------------------------------------------------------------
rbt_sp_create:
        pha                     ; id
        lda     rbt_hl
        sta     rbt_de
        lda     rbt_hl+1
        sta     rbt_de+1        ; de = asset
        pla
        jsr     rbt_slot        ; ptr = slot
        ; header: w,h,nframes,colour at asset+0..3
        ldy     #0
        lda     (rbt_de),y
        ldy     #3
        sta     (rbt_ptr),y     ; +3 w
        ldy     #1
        lda     (rbt_de),y
        ldy     #4
        sta     (rbt_ptr),y     ; +4 h
        ldy     #2
        lda     (rbt_de),y      ; nframes
        beq     @nf
        sec
        sbc     #1              ; animLast = nframes-1
@nf:    ldy     #11
        sta     (rbt_ptr),y     ; +11 animLast
        ldy     #3
        lda     (rbt_de),y
        ldy     #8
        sta     (rbt_ptr),y     ; +8 colour
        ; identity fields
        ldy     #6
        lda     rbt_de
        sta     (rbt_ptr),y
        iny
        lda     rbt_de+1
        sta     (rbt_ptr),y     ; +6,7 asset
        ldy     #0
        lda     #1
        sta     (rbt_ptr),y     ; +0 live
        iny
        lda     rbt_c
        sta     (rbt_ptr),y     ; +1 x
        iny
        lda     rbt_d
        sta     (rbt_ptr),y     ; +2 y
        ldy     #5
        lda     #0
        sta     (rbt_ptr),y     ; +5 frame
        ldy     #9
        lda     rbt_b
        sta     (rbt_ptr),y     ; +9 mode (stored, unused by hw sprites)
        ldy     #10
        lda     #0
        sta     (rbt_ptr),y     ; +10 animFirst
        ldy     #12
        sta     (rbt_ptr),y     ; +12 animFlags = 0
        ldy     #13
        lda     #1
        sta     (rbt_ptr),y     ; +13 animDir
        ldy     #14
        lda     rbt_e
        sta     (rbt_ptr),y     ; +14 bank ($ff)
        ldy     #15
        lda     #$ff
        sta     (rbt_ptr),y     ; +15 no hw sprite yet
        jsr     rbt_sp_hwinit   ; arm the mux on first sprite use
        rts

; ----------------------------------------------------------------------------
; rbt_sp_place - A=id, B=x, C=y. rbt_sp_move - A=id, B=dx, C=dy (signed).
; ----------------------------------------------------------------------------
rbt_sp_place:
        jsr     rbt_slot
        ldy     #1
        lda     rbt_b
        sta     (rbt_ptr),y
        iny
        lda     rbt_c
        sta     (rbt_ptr),y
        rts

rbt_sp_move:
        jsr     rbt_slot
        ldy     #1
        clc
        lda     (rbt_ptr),y
        adc     rbt_b
        sta     (rbt_ptr),y
        iny
        clc
        lda     (rbt_ptr),y
        adc     rbt_c
        sta     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_sp_frame - A=id, B=frame (mod nframes via asset[2])
; ----------------------------------------------------------------------------
rbt_sp_frame:
        jsr     rbt_slot
        ldy     #5
        lda     rbt_b
        sta     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_sp_anim - A=id, B=first, C=last, D=0 loop / 1 pingpong
; ----------------------------------------------------------------------------
rbt_sp_anim:
        jsr     rbt_slot
        ldy     #10
        lda     rbt_b
        sta     (rbt_ptr),y     ; animFirst
        iny
        lda     rbt_c
        sta     (rbt_ptr),y     ; animLast
        ldy     #5
        lda     rbt_b
        sta     (rbt_ptr),y     ; start at first
        ldy     #12
        lda     #2              ; animating
        ldx     rbt_d
        beq     @np
        ora     #1              ; pingpong
@np:    sta     (rbt_ptr),y
        ldy     #13
        lda     #1
        sta     (rbt_ptr),y     ; dir forward
        rts

; ----------------------------------------------------------------------------
; rbt_sp_kill / rbt_sp_hide / rbt_sp_show - A=id
; ----------------------------------------------------------------------------
rbt_sp_kill:
        jsr     rbt_slot
        ldy     #0
        lda     #0
        sta     (rbt_ptr),y
        rts

rbt_sp_hide:
        jsr     rbt_slot
        ldy     #0
        lda     (rbt_ptr),y
        ora     #2
        sta     (rbt_ptr),y
        rts

rbt_sp_show:
        jsr     rbt_slot
        ldy     #0
        lda     (rbt_ptr),y
        and     #%11111101
        sta     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_sp_attr - A=id, B=colour nibble
; ----------------------------------------------------------------------------
rbt_sp_attr:
        jsr     rbt_slot
        ldy     #8
        lda     rbt_b
        and     #$0f
        sta     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_sp_draw - A=id. Hardware sprites need no per-sprite blit: the
; frame-reset IRQ picks up the slot state next frame.
; ----------------------------------------------------------------------------
rbt_sp_draw:
        jmp     rbt_sp_hwinit   ; commits happen at the frame-reset IRQ

; ----------------------------------------------------------------------------
; rbt_spx / rbt_spy - A=id -> A = logical x/y
; ----------------------------------------------------------------------------
rbt_spx:
        jsr     rbt_slot
        ldy     #1
        lda     (rbt_ptr),y
        rts

rbt_spy:
        jsr     rbt_slot
        ldy     #2
        lda     (rbt_ptr),y
        rts

; ----------------------------------------------------------------------------
; rbt_spcoll - A=id1, B=id2 -> A=1 when bounding boxes overlap.
; ----------------------------------------------------------------------------
rbt_spcoll:
        jsr     rbt_slot
        ldy     #0
        lda     (rbt_ptr),y
        and     #3
        cmp     #1
        beq     @a
        jmp     @no             ; slot1 not live (or hidden)
@a:     ; stash slot1 x,y,w,h in bc/de zps via t0.. — copy to rbt_de/rbt_bc
        ldy     #1
        lda     (rbt_ptr),y
        sta     rbt_t0          ; x1
        iny
        lda     (rbt_ptr),y
        sta     rbt_t1          ; y1
        ldy     #3
        lda     (rbt_ptr),y
        sta     rbt_de          ; w1
        ldy     #4
        lda     (rbt_ptr),y
        sta     rbt_de+1        ; h1
        lda     rbt_b
        jsr     rbt_slot
        ldy     #0
        lda     (rbt_ptr),y
        and     #3
        cmp     #1
        bne     @no
        ; x2 < x1+w1 ?
        ldy     #1
        lda     (rbt_ptr),y     ; x2
        sta     rbt_t2
        lda     rbt_t0
        clc
        adc     rbt_de          ; x1+w1
        bcs     @chk1           ; wrapped: x1+w1 >= 256 -> x2< that true
        cmp     rbt_t2
        beq     @no             ; x1+w1 == x2 -> no overlap
        bcc     @no             ; x1+w1 <  x2 -> no
@chk1:  ; x1 < x2+w2 ?
        ldy     #3
        lda     (rbt_ptr),y     ; w2
        ldy     #1
        clc
        adc     (rbt_ptr),y     ; x2+w2
        bcs     @chk2
        cmp     rbt_t0
        beq     @no
        bcc     @no
@chk2:  ; y2 < y1+h1 ?
        ldy     #2
        lda     (rbt_ptr),y     ; y2
        sta     rbt_t2
        lda     rbt_t1
        clc
        adc     rbt_de+1        ; y1+h1
        bcs     @chk3
        cmp     rbt_t2
        beq     @no
        bcc     @no
@chk3:  ; y1 < y2+h2 ?
        ldy     #4
        lda     (rbt_ptr),y     ; h2
        ldy     #2
        clc
        adc     (rbt_ptr),y     ; y2+h2
        bcs     @yes
        cmp     rbt_t1
        beq     @no
        bcc     @no
@yes:   lda     #1
        rts
@no:    lda     #0
        rts

; ----------------------------------------------------------------------------
; rbt_sp_update / rbt_sp_drawall - hardware sprites commit once per frame
; at the frame-reset IRQ (line 300) where ~50+ border lines are guaranteed
; before the first sprite window; the calls only ensure the mux exists.
; ----------------------------------------------------------------------------
rbt_sp_update:
rbt_sp_drawall:
        jmp     rbt_sp_hwinit

; ----------------------------------------------------------------------------
; rbt_sp_sched - step animations, rebuild the sorted order, stage
; register images, bind the first 8 hw sprites, arm the next IRQ. Runs
; once per frame at the frame-reset IRQ — never from mainline — so the
; binds always land in the border, ahead of every sprite window. Uses
; only the private rbt_si*/rbt_sptr regs so it cannot clobber the
; compiler's live ZP registers mid-instruction.
; ----------------------------------------------------------------------------
rbt_sp_sched:
        ; collect live && !hidden slot ids into order[]
        lda     #0
        sta     rbt_sp_nlive
        sta     rbt_si0         ; id
@scan:  lda     rbt_si0
        jsr     rbt_slot2
        ldy     #0
        lda     (rbt_sptr),y
        and     #1
        beq     @skip           ; not live: no anim, no draw
        jsr     _sp_anim1       ; step this slot's animation
        ldy     #0
        lda     (rbt_sptr),y
        and     #3
        cmp     #1              ; live && !hidden
        bne     @skip
        ldy     #2
        lda     (rbt_sptr),y    ; y
        cmp     #192            ; logical y off screen -> skip
        bcs     @skip
        ldx     rbt_sp_nlive
        sta     rbt_sp_ordy,x   ; sort key kept parallel — no slot
        lda     rbt_si0         ;  lookup per comparison later
        sta     rbt_sp_order,x
        inc     rbt_sp_nlive
@skip:  inc     rbt_si0
        lda     rbt_si0
        cmp     #RBT_SP_N
        bcc     @scan
        ; insertion sort order[]/ordy[] by y — pure byte compares
        lda     #1
        sta     rbt_si0         ; i
@si:    lda     rbt_si0
        cmp     rbt_sp_nlive
        bcs     @sorted
        ldx     rbt_si0
        lda     rbt_sp_order,x
        sta     rbt_si1         ; key id
        lda     rbt_sp_ordy,x
        sta     rbt_si2         ; key y
        ldx     rbt_si0
        stx     rbt_sp_j        ; j = i
@sj:    lda     rbt_sp_j
        beq     @sins
        ; ordy[j-1] > key.y ?
        ldx     rbt_sp_j
        dex
        lda     rbt_sp_ordy,x
        cmp     rbt_si2
        beq     @sins
        bcc     @sins
        ; shift both arrays at j-1 -> j
        lda     rbt_sp_order,x
        ldx     rbt_sp_j
        sta     rbt_sp_order,x
        dex
        lda     rbt_sp_ordy,x
        ldx     rbt_sp_j
        sta     rbt_sp_ordy,x
        dec     rbt_sp_j
        jmp     @sj
@sins:  ldx     rbt_sp_j
        lda     rbt_si1
        sta     rbt_sp_order,x
        lda     rbt_si2
        sta     rbt_sp_ordy,x
        inc     rbt_si0
        jmp     @si
@sorted:
        ; stage + bind the first min(8,nlive) to hw 0..7 — their tops are
        ; the earliest on screen so these applies must land before
        ; anything else. No global $d015 clear: bound sprites keep their
        ; enable bit or they vanish for any window this sched runs across.
        lda     #$ff
        ldx     #7
@cb:    sta     rbt_sp_bind,x
        sta     rbt_sp_bot,x
        dex
        bpl     @cb
        lda     #0
        sta     rbt_si0         ; order idx == hw n for this loop
@bind:  lda     rbt_si0
        cmp     #8
        bcs     @ub
        cmp     rbt_sp_nlive
        bcs     @ub
        tax
        lda     rbt_sp_order,x
        jsr     rbt_slot2       ; sptr = slot
        jsr     _sp_stage       ; stage[si0] <- slot
        ldx     rbt_si0
        txa
        sta     rbt_sp_bind,x   ; bind[hw] = order idx
        jsr     rbt_sp_apply    ; A = order idx, si0 = hw n
        inc     rbt_si0
        jmp     @bind
@ub:    ; hw sprites left unbound get disabled (dead/hidden slots must
        ; not linger); bound ones keep their enable bit
        ldx     rbt_si0
@ub2:   cpx     #8
        bcs     @pstg
        lda     rbt_sp_d015
        and     rbt_sp_mask,x
        sta     $d015
        sta     rbt_sp_d015
        inx
        jmp     @ub2
@pstg:  ; stage the pending group — mid-frame IRQs apply them from here
        lda     rbt_si0
        sta     rbt_sp_next     ; first pending = first unbound order idx
@pstg2: lda     rbt_si0
        cmp     rbt_sp_nlive
        bcs     @arm
        tax
        lda     rbt_sp_order,x
        jsr     rbt_slot2
        jsr     _sp_stage
        inc     rbt_si0
        jmp     @pstg2
@arm:   jmp     rbt_sp_arm

; ----------------------------------------------------------------------------
; _sp_anim1 - step the animation of the live slot at rbt_sptr. IRQ-side;
; uses only rbt_sptr + A/Y. Clobbers A/Y.
; ----------------------------------------------------------------------------
_sp_anim1:
        ldy     #12
        lda     (rbt_sptr),y
        and     #2
        beq     @no             ; not animating
        ldy     #13
        lda     (rbt_sptr),y
        bmi     @down
        ; dir = +1
        ldy     #5
        lda     (rbt_sptr),y    ; frame
        ldy     #11
        cmp     (rbt_sptr),y    ; animLast
        bcc     @inc
        ; at last
        ldy     #12
        lda     (rbt_sptr),y
        and     #1
        beq     @wrap           ; loop mode -> first
        ; pingpong: reverse
        ldy     #13
        lda     #$ff
        sta     (rbt_sptr),y
        ldy     #11
        lda     (rbt_sptr),y    ; last
        ldy     #10
        cmp     (rbt_sptr),y    ; last == first?
        beq     @no             ; single-frame range: stay
        sec
        sbc     #1
        jmp     @set            ; last-1
@wrap:  ldy     #10
        lda     (rbt_sptr),y    ; animFirst
        jmp     @set
@inc:   ldy     #5
        lda     (rbt_sptr),y
        clc
        adc     #1
        jmp     @set
@down:  ; dir = -1
        ldy     #5
        lda     (rbt_sptr),y    ; frame
        ldy     #10
        cmp     (rbt_sptr),y    ; animFirst
        beq     @atfirst
        bcc     @atfirst
        sec
        sbc     #1
        jmp     @set
@atfirst:
        ldy     #12
        lda     (rbt_sptr),y
        and     #1
        beq     @wraph          ; loop mode -> last
        ldy     #13
        lda     #1
        sta     (rbt_sptr),y    ; dir forward
        ldy     #10
        lda     (rbt_sptr),y    ; first
        ldy     #11
        cmp     (rbt_sptr),y
        beq     @no             ; single-frame
        clc
        adc     #1
        jmp     @set            ; first+1
@wraph: ldy     #11
        lda     (rbt_sptr),y    ; animLast
@set:   ldy     #5
        sta     (rbt_sptr),y
@no:    rts

; ----------------------------------------------------------------------------
; _sp_stage - build the hw register image for the order idx in rbt_si0
; from the slot at rbt_sptr. Clobbers A/X/Y, rbt_si2/si3.
; ----------------------------------------------------------------------------
_sp_stage:
        lda     rbt_si0
        asl
        asl
        asl
        tax                     ; X = order idx * 8
        ; src = asset + 64 + frame*64  (header is one padded 64B block)
        ldy     #5
        lda     (rbt_sptr),y    ; frame
        sta     rbt_si2
        lda     #0
        sta     rbt_si3
        asl     rbt_si2
        rol     rbt_si3
        asl     rbt_si2
        rol     rbt_si3
        asl     rbt_si2
        rol     rbt_si3
        asl     rbt_si2
        rol     rbt_si3
        asl     rbt_si2
        rol     rbt_si3
        asl     rbt_si2
        rol     rbt_si3         ; si2:si3 = frame*64
        ldy     #6
        clc
        lda     (rbt_sptr),y    ; asset lo
        adc     rbt_si2
        sta     rbt_si2
        iny
        lda     (rbt_sptr),y    ; asset hi
        adc     rbt_si3
        sta     rbt_si3
        clc
        lda     rbt_si2
        adc     #64
        sta     rbt_si2
        lda     rbt_si3
        adc     #0
        sta     rbt_si3         ; si2:si3 = frame src
        sta     rbt_sp_stage+7,x
        lda     rbt_si2
        sta     rbt_sp_stage+6,x
        ; SPRPTR: point at the frame directly when it is 64-aligned
        ; inside the pool's 16K VIC bank; flag the pool-copy fallback
        ; otherwise (runtime-loaded/unaligned data, or linked outside
        ; the bank — text mode's bank 3 never contains linked frames)
        lda     #0
        sta     rbt_si3         ; flags accumulator
        lda     rbt_sp_stage+7,x
        eor     rbt_sppool
        and     #$c0            ; same 16K bank as the sprite pool?
        bne     @cpflg
        lda     rbt_si2
        and     #$3f
        bne     @cpflg
        ; SPRPTR = src >> 6 = (hi<<2) | (lo>>6)
        lda     rbt_sp_stage+7,x
        asl
        asl
        sta     rbt_si2
        lda     rbt_sp_stage+6,x
        lsr
        lsr
        lsr
        lsr
        lsr
        lsr
        ora     rbt_si2
        jmp     @ptr
@cpflg: lda     #$80
        sta     rbt_si3         ; flag bit7: copy to pool at apply time
        lda     #0
@ptr:   sta     rbt_sp_stage+3,x
        ; x -> hw x lo + msb flag
        ldy     #1
        lda     (rbt_sptr),y    ; lx
        clc
        adc     #RBT_SP_XOFF
        sta     rbt_sp_stage+0,x
        bcc     @nomsb
        lda     rbt_si3
        ora     #1
        sta     rbt_si3         ; flag bit0: $D010 bit set
@nomsb: ; y -> hw y (top line) and bottom
        ldy     #2
        lda     (rbt_sptr),y    ; ly
        clc
        adc     #RBT_SP_YOFF
        sta     rbt_sp_stage+1,x
        clc
        adc     #RBT_SP_H
        bcc     @bot
        lda     #$ff            ; bottom >= 256 -> treat as 255
@bot:   sta     rbt_sp_stage+5,x
        ldy     #8
        lda     (rbt_sptr),y    ; colour
        and     #$0f
        sta     rbt_sp_stage+2,x
        lda     rbt_si3
        sta     rbt_sp_stage+4,x
        rts

; ----------------------------------------------------------------------------
; rbt_sp_arm - pick the next raster IRQ line and program it.
; ----------------------------------------------------------------------------
rbt_sp_arm:
        ldx     rbt_sp_next
        cpx     rbt_sp_nlive
        bcc     @mid
        ; nothing pending -> idle at the frame-reset line
        lda     #<RBT_SP_FLINE
        sta     rbt_sp_line
        lda     #>RBT_SP_FLINE
        sta     rbt_sp_line+1
        lda     #1
        sta     rbt_sp_phase
        jmp     rbt_sp_setline
@mid:   ; earliest bottom among bound hw sprites, pulled forward when the
        ; next pending sprite's window opens sooner than that — rebinding
        ; must land before the pending top or the sprite misses the frame
        ; entirely, while an occupant cut a few lines short only loses
        ; (usually empty) bottom rows
        lda     #$ff
        sta     rbt_si2         ; min bound bottom
        ldx     #0
@h:     lda     rbt_sp_bot,x
        cmp     rbt_si2
        bcs     @hn
        sta     rbt_si2
@hn:    inx
        cpx     #8
        bcc     @h
        lda     rbt_si2
        cmp     #$ff
        bne     @have
        lda     #200            ; nothing bound? fallback line
@have:  sta     rbt_si2         ; B = earliest bound bottom
        ; T = next pending's top; K = pendings sharing its band
        ; (top within one sprite height — they contend for the same gap)
        ldx     rbt_sp_next
        txa
        asl
        asl
        asl
        tay
        lda     rbt_sp_stage+1,y
        sta     rbt_si3         ; T (stage tops ascend with the order)
        lda     #0
        sta     rbt_si1         ; K
@k:     cpx     rbt_sp_nlive
        bcs     @kd
        txa
        asl
        asl
        asl
        tay
        lda     rbt_sp_stage+1,y
        sec
        sbc     rbt_si3
        cmp     #RBT_SP_H
        bcs     @kd             ; ascending tops -> out of the band
        inc     rbt_si1
        inx
        jmp     @k
@kd:    ; want the IRQ ~3K+2 lines before T (a staged apply is ~2-3
        ; lines with VIC steals); never cut a bound sprite by > LEAD
        lda     rbt_si1
        asl
        clc
        adc     rbt_si1         ; 3K
        adc     #2
        sta     rbt_si1         ; need
        lda     rbt_si3
        sec
        sbc     rbt_si1         ; cand = T - need
        bcs     @c1
        lda     #1
@c1:    sta     rbt_si1
        lda     rbt_si2
        sec
        sbc     #RBT_SP_LEAD    ; floor = B - LEAD
        bcs     @c2
        lda     #1
@c2:    cmp     rbt_si1
        bcs     @cmpb           ; floor >= cand -> fire at floor
        lda     rbt_si1         ; else cand
@cmpb:  cmp     rbt_si2
        bcs     @fireB          ; cand/floor >= B -> fire at B (no cut)
        jmp     @fire
@fireB: lda     rbt_si2
@fire:  sta     rbt_sp_line
        lda     #0
        sta     rbt_sp_line+1
        sta     rbt_sp_phase
        jmp     rbt_sp_setline

; ----------------------------------------------------------------------------
; rbt_sp_irq - raster IRQ dispatch on rbt_sp_phase.
; ----------------------------------------------------------------------------
rbt_sp_irq:
        lda     rbt_sp_phase
        bne     @frame
        jmp     _sp_irq_mid
@frame: jmp     _sp_irq_frame

; _sp_irq_frame - frame-reset line 300: run the whole schedule in the
; border, where ~50 lines are guaranteed before the first sprite window,
; so every bind lands before its occupant's top regardless of when the
; game last called UPDATE (or whether it calls it at all).
_sp_irq_frame:
        jmp     rbt_sp_sched

; _sp_irq_mid - sprite bottom(s) reached: rebind those hw sprites to
; pending slots, then rearm. A bound sprite counts as finished when its
; bottom is at most RBT_SP_LEAD lines below the armed line — the early
; arm already cut it, and grouping near-simultaneous bottoms into one IRQ
; keeps the rebind burst short.
_sp_irq_mid:
        ldx     #0
@h:     stx     rbt_si0         ; hw n
        lda     rbt_sp_bind,x
        cmp     #$ff
        beq     @next
        lda     rbt_sp_bot,x
        sec
        sbc     #RBT_SP_LEAD    ; bottom >= 71 always, never wraps
        cmp     rbt_sp_line
        beq     @fin
        bcs     @next           ; bottom-LEAD > armed line: still on screen
                                ; (recomputed per hw: apply clobbers si*)
@fin:                           ; bottom-LEAD <= line: finished
        ; this hw sprite finished
        ldx     rbt_sp_next
        cpx     rbt_sp_nlive
        bcs     @off
        txa                     ; order idx of next pending slot
        ldx     rbt_si0
        sta     rbt_sp_bind,x   ; bind[hw] = order idx
        inc     rbt_sp_next
        jsr     rbt_sp_apply    ; A = order idx, si0 = hw n
        jmp     @next
@off:   ldx     rbt_si0
        lda     #$ff
        sta     rbt_sp_bind,x
        sta     rbt_sp_bot,x
        lda     rbt_sp_d015
        and     rbt_sp_mask,x   ; (mask table below)
        sta     $d015
        sta     rbt_sp_d015
@next:  ldx     rbt_si0
        inx
        cpx     #8
        bcc     @h
        jmp     rbt_sp_arm

rbt_sp_mask:    .byte $fe,$fd,$fb,$f7,$ef,$df,$bf,$7f   ; ~bit n
rbt_sp_bits:    .byte $01,$02,$04,$08,$10,$20,$40,$80   ;  bit n

; ----------------------------------------------------------------------------
; rbt_sp_apply - program hw sprite rbt_si0 from the staged register image
; for order idx A. Just a burst of register writes — all the src/pos math
; was precomputed by _sp_stage at sched time — except on the rare pool-
; copy fallback (stage flag bit7) for frames the VIC can't address.
; Clobbers A/X/Y, rbt_si1-si3, rbt_sptr.
; ----------------------------------------------------------------------------
rbt_sp_apply:
        sta     rbt_si1         ; order idx
        asl
        asl
        asl
        tay                     ; Y = stage idx (idx*8)
        ; hw y first: a sprite that misses its top line is invisible all
        ; frame — a late ptr/x only corrupts its first rows, so trigger
        ; the window before doing anything else
        ldx     rbt_si0
        txa
        asl
        tax
        lda     rbt_sp_stage+1,y
        sta     $d001,x         ; hw y
        lda     rbt_sp_stage+4,y
        bmi     @copy           ; frame needs a pool copy
        ldx     rbt_smode
        bne     @copy           ; bitmap mode: only the bank-1 pool is
                                ;  VIC-visible
        lda     rbt_sp_stage+3,y
        ldx     rbt_si0
        sta     RBT_SPPT,x      ; SPRPTR -> frame data, no copy
        sta     $7ff8,x         ;  (both tables: the matrix moves banks
        jmp     @tail           ;   with the mode, stay in sync either way)
@copy:  ; src = stage+6,7 -> rbt_sptr;  dst = pool + hw*64 -> si2:si3
        lda     rbt_sp_stage+6,y
        sta     rbt_sptr
        lda     rbt_sp_stage+7,y
        sta     rbt_sptr+1
        lda     rbt_si0
        lsr
        lsr
        clc
        adc     rbt_sppool      ; dst hi — pool rides the active VIC bank
        sta     rbt_si3
        lda     rbt_si0
        and     #3
        asl
        asl
        asl
        asl
        asl
        asl                     ; (hw&3)<<6
        sta     rbt_si2         ; dst lo
        ; skip the 63-byte copy when this hw buffer already holds this
        ; frame: it is the bulk of apply's raster time, and running it
        ; inside the sprite's window tears it
        lda     rbt_si0
        asl
        tax                     ; hw*2
        lda     rbt_sptr
        cmp     rbt_sp_src,x
        bne     @new
        lda     rbt_sptr+1
        eor     rbt_sppool      ; key hi = src hi XOR pool bank — the cache
        cmp     rbt_sp_src+1,x  ;  self-invalidates when MODE moves the pool
        beq     @nocp
@new:   lda     rbt_sptr
        sta     rbt_sp_src,x
        lda     rbt_sptr+1
        eor     rbt_sppool
        sta     rbt_sp_src+1,x
        ldy     #62
@cp:    lda     (rbt_sptr),y
        sta     (rbt_si2),y
        dey
        bpl     @cp
        ldy     #63
        lda     #0
        sta     (rbt_si2),y     ; pad byte
@nocp:  ldx     rbt_si0
        txa
        clc
        adc     rbt_spptrb      ; pool SPRPTR base for the active VIC bank
        sta     RBT_SPPT,x      ; SPRPTR -> pool buffer
        sta     $7ff8,x         ;  (both tables — see above)
        lda     rbt_si1         ; restore stage idx
        asl
        asl
        asl
        tay
@tail:  ; colour -> $D027+n, x -> $D000+2n/$D010, bound bottom ->
        ; rbt_sp_bot[n], enable -> $D015  (hw y already written)
        ldx     rbt_si0
        lda     rbt_sp_stage+2,y
        sta     $d027,x
        txa
        asl
        tax
        lda     rbt_sp_stage+0,y
        sta     $d000,x         ; hw x lo
        lda     rbt_sp_stage+5,y
        ldx     rbt_si0
        sta     rbt_sp_bot,x    ; occupant's bottom line
        lda     rbt_sp_bits,x   ; 1<<n
        sta     rbt_si2
        lda     rbt_sp_stage+4,y
        lsr                     ; msb flag -> carry
        lda     rbt_sp_d010
        bcc     @xlo
        ora     rbt_si2
        bne     @xs             ; always
@xlo:   and     rbt_sp_mask,x
@xs:    sta     $d010
        sta     rbt_sp_d010
        lda     rbt_sp_d015
        ora     rbt_si2
        sta     $d015           ; enable hw sprite
        sta     rbt_sp_d015
        rts
