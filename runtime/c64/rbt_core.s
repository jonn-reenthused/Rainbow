; ============================================================================
; rbt_core - Rainbow runtime core (Commodore 64, ca65)
; Entry point, frame sync, pause, border, cls, RNG, waitkey, 16-bit helpers.
;
; Virtual-register convention (zero page): rbt_hl/rbt_de/rbt_bc are the
; 16-bit pairs the Z80 runtime uses HL/DE/BC for; rbt_b..rbt_e are the byte
; argument registers. BYTE expressions evaluate into A, UINT/INT into rbt_hl.
; The kernal IRQ stays enabled (keyboard scan + jiffy clock); nothing below
; may install its own IRQ yet — the SID/multiplexer modules will take it over.
; ============================================================================
;
; Text-mode VIC layout. C64: bank 3 ($C000-$CFFF) — plain RAM for both CPU
; and VIC with no chargen-ROM window and no BASIC-ROM shadow, so it works
; for every media type (PRG, tape, disk and a 16K cart at $8000) and can
; never collide with a program image at $0801+: screen $C400, SPRPTR $C7F8,
; charset $C800 (tile glyphs $CC00+), sprite pool $CA00. Bank 3 has no
; chargen window so rbt_start seeds charset RAM from the ROM at $D000.
; C128 keeps bank 0 — its programs link at $4000+ so $0400/$3800/$3A00
; can never collide, and BASIC-hi lives in bank 3's window.
.if RBT_C128
RBT_SCRN        = $0400         ; screen matrix base
RBT_CSET        = $3800         ; charset RAM base
RBT_SPPT        = $07f8         ; sprite-pointer table (screen + $3f8)
RBT_D018T       = $1e           ; $D018: screen $0400 + charset $3800
RBT_D018I       = $14           ; boot value: charset = ROM chargen $1000
RBT_POOLH       = $3a           ; sprite pool page (inside charset tail)
RBT_POOLP       = $e8           ; its SPRPTR value
RBT_BANK        = $03           ; $DD00 bits: VIC bank 0
.else
RBT_SCRN        = $c400
RBT_CSET        = $c800
RBT_SPPT        = $c7f8
RBT_D018T       = $12           ; $D018: screen $C400 + charset $C800
RBT_D018I       = $12           ; bank 3 has no chargen window — same value
RBT_POOLH       = $ca
RBT_POOLP       = $28           ; $CA00>>6
RBT_BANK        = $00           ; VIC bank 3
.endif
RBT_CDELTA      = $d800-RBT_SCRN ; screen -> colour RAM offset

        .zeropage

rbt_hl:         .res 2          ; virtual HL (16-bit exprs / pointers)
rbt_de:         .res 2          ; virtual DE
rbt_bc:         .res 2          ; virtual BC (div args, IN/OUT addresses)
rbt_b:          .res 1          ; byte arg/scratch regs (Z80 B,C,D,E roles)
rbt_c:          .res 1
rbt_d:          .res 1
rbt_e:          .res 1
rbt_t0:         .res 1          ; scratch temps
rbt_t1:         .res 1
rbt_t2:         .res 2          ; scratch word (putchar/fillattr row math —
                                ;  must NOT alias pstart/slen: print_u16
                                ;  and print_str hold those across calls)
rbt_ptr:        .res 2          ; scratch pointer
rbt_pstart:     .res 1          ; print leading-zero flag
rbt_slen:       .res 1          ; string length temp
rbt_sidx:       .res 1          ; string index temp

        .code

; ----------------------------------------------------------------------------
; c128 MMU windows. The C128 can't map I/O and RAM at $4000+ together:
;   $0F = RAM $4000-$BFFF + kernal (mainline map; no I/O)
;   $0E = I/O + kernal (ROM at $4000; the $FF17 IRQ trampoline stays
;        mapped, so these windows need no SEI)
;   $3E = I/O + RAM $4000+ but no kernal (IRQ vector trampoline is gone —
;        only safe inside SEI or the IRQ handler itself)
;   $00 = all ROM + I/O (kernal service calls)
; ----------------------------------------------------------------------------
rbt_mapio:
        .if RBT_C128
        pha
        lda     #$0e
        sta     $ff00
        pla
        .endif
        rts

rbt_maprun:
        .if RBT_C128
        pha
        lda     #$0f
        sta     $ff00
        pla
        .endif
        rts

; ----------------------------------------------------------------------------
; rbt_start - entry (the BASIC SYS stub jumps here)
; ----------------------------------------------------------------------------
rbt_start:
        .if RBT_C128
        lda     #$0f
        sta     $ff00           ; mainline map: RAM $4000-$BFFF + kernal
        jsr     rbt_mapio       ; $d018 write needs the I/O window
        ; screen matrix $0400 + ROM chargen $1000 (VIC always sees the
        ; character ROM at $1000 in bank 0) — $D018 = screen<<4 | charset<<1
        lda     #$14
        sta     $d018
        sta     rbt_d018        ; keep the text-mode shadow in sync
        .else
        ; VIC bank 3 — the whole text layout lives above the program.
        ; Bank 3 has no chargen-ROM window, so seed charset RAM from the
        ; ROM at $D000 before any text is drawn. A cart boot can reach
        ; us before the kernal's IOINIT ran: force the 6510 DDR ($00)
        ; and map ($01) to the runtime's expected state first, or the
        ; I/O writes below may land in RAM instead of the chips.
        lda     $00
        ora     #$2f            ; kernal RAMTAS default: cfg+cassette out
        sta     $00
        lda     #$37            ; kernal+BASIC in, I/O mapped
        sta     $01
        lda     $dd02
        ora     #$03
        sta     $dd02
        lda     #$ff            ; CIA1 too: port A drives the keyboard
        sta     $dc02           ; columns, port B reads the rows —
        lda     #$00            ; without IOINIT both are inputs and no
        sta     $dc03           ; key ever registers.
        lda     $dd00
        and     #$fc
        ora     #RBT_BANK
        sta     $dd00
        lda     #RBT_D018T
        sta     $d018
        sta     rbt_d018        ; keep the text-mode shadow in sync
        jsr     rbt_chargen
        .endif
        ; DEN on / 25 rows / text yscroll, 40 cols / MCM off — cartridge
        ; boot can reach us before the kernal's video init ran, so the
        ; display may still be blanked.
        lda     #$1b
        sta     $d011
        lda     #$c8
        sta     $d016
        .if RBT_C128
        jsr     rbt_maprun
        .endif
        jsr     rb_main         ; user program entry (MAIN:)
rbt_end:
        jsr     rbt_sfx_drain
        jsr     rbt_rwait
        jsr     rbt_hook_frame
        jmp     rbt_end         ; program end: idle forever

.if !RBT_C128
; ----------------------------------------------------------------------------
; rbt_chargen - copy the chargen ROM ($D000-$D7FF) into charset RAM at
; RBT_CSET. Bank 3 has no chargen window, so text can't render until this
; runs — rbt_start does it once at boot.
; ----------------------------------------------------------------------------
rbt_chargen:
        sei
        lda     #$33            ; CHAREN=0 with LORAM+HIRAM held: chargen
        sta     $01             ; ROM visible at $D000 (saved $01 may be
                                ; a non-ROM map on a pre-kernal boot)
        lda     #$00
        sta     rbt_ptr
        sta     rbt_hl
        lda     #$d0
        sta     rbt_ptr+1
        lda     #>RBT_CSET
        sta     rbt_hl+1
        ldx     #8              ; 8 pages = full 256-glyph upper-case set
@pg:    ldy     #0
@cp:    lda     (rbt_ptr),y
        sta     (rbt_hl),y
        iny
        bne     @cp
        inc     rbt_ptr+1
        inc     rbt_hl+1
        dex
        bne     @pg
        lda     #$37            ; runtime map: kernal+BASIC in, I/O on
        sta     $01
        cli
        rts
.endif

; ----------------------------------------------------------------------------
; rbt_rwait - wait for raster line 250 (once per frame, edge-safe)
; ----------------------------------------------------------------------------
rbt_rwait:
        jsr     rbt_mapio       ; $d012 lives in the I/O window
@w1:    lda     $d012
        cmp     #$fa
        beq     @w1             ; already on it — wait for it to pass
@w2:    lda     $d012
        cmp     #$fa
        bne     @w2
        jmp     rbt_maprun      ; tail: restores the mainline map, rts

; ----------------------------------------------------------------------------
; rbt_vsync - wait one frame
; ----------------------------------------------------------------------------
rbt_vsync:
        jsr     rbt_sfx_drain
        jsr     rbt_rwait
        jsr     rbt_hook_frame
        rts

; ----------------------------------------------------------------------------
; rbt_pause - pause for rbt_b frames (0 waits for a keypress)
; ----------------------------------------------------------------------------
rbt_pause:
        jsr     rbt_sfx_drain
        lda     rbt_b
        beq     rbt_waitkey
        tax
@ploop: jsr     rbt_rwait
        jsr     rbt_hook_frame
        dex
        bne     @ploop
        rts

; ----------------------------------------------------------------------------
; rbt_waitkey - block until any key is pressed (frame-paced so the music
; hook keeps ticking). The matrix probe is SEI-guarded because the kernal
; IRQ writes $DC00 for its own scan.
; ----------------------------------------------------------------------------
rbt_waitkey:
        jsr     rbt_sfx_drain
@wk:    jsr     rbt_rwait
        jsr     rbt_hook_frame
        sei
        jsr     rbt_mapio
        lda     #0
        sta     $dc00           ; select all columns
        lda     $dc01
        jsr     rbt_maprun
        cli
        eor     #$ff
        beq     @wk
@rel:   sei                     ; wait for release
        jsr     rbt_mapio
        lda     #0
        sta     $dc00
        lda     $dc01
        jsr     rbt_maprun
        cli
        eor     #$ff
        bne     @rel
        rts

; ----------------------------------------------------------------------------
; rbt_border - set border to A (0-15)
; ----------------------------------------------------------------------------
rbt_border:
        and     #$0f
        jsr     rbt_mapio       ; preserves A
        sta     $d020
        jmp     rbt_maprun      ; tail: restore map + rts

; ----------------------------------------------------------------------------
; rbt_scrmode - screen mode select (A = mode).
;   0 = text: VIC bank 0, matrix $0400, charset per rbt_d018
;   1 = hires bitmap: VIC bank 1 ($4000), 8KB bitmap at $4000, colour
;       matrix at $7C00 (fg<<4|bg per cell), sprite pool moves to $7800
; Lives in core so MODE works without the pixel module; the sprite mux
; picks the pool base up from rbt_sppool/rbt_spptrb and PLOT/SHOWPIC
; come with the pixel module.
; ----------------------------------------------------------------------------
rbt_scrmode:
        and     #1
        cmp     rbt_smode
        beq     @done
        sta     rbt_smode
        tax                     ; flags don't survive sta; test A via X
        bne     @bmp
        ; mode 0: text screen
        sei
        jsr     rbt_mapio
        lda     $dd00
        and     #$fc
        ora     #RBT_BANK       ; C64 %00 = bank 3, C128 %11 = bank 0
        sta     $dd00
        lda     $d011
        and     #$df            ; bitmap off
        sta     $d011
        lda     rbt_d018
        sta     $d018
        jsr     rbt_maprun
        lda     #RBT_POOLH
        sta     rbt_sppool
        lda     #RBT_POOLP
        sta     rbt_spptrb
        cli
        rts
@bmp:   ; mode 1: hires bitmap in bank 1
        sei
        jsr     rbt_mapio
        lda     $dd00
        and     #$fc
        ora     #$02            ; %10 = VIC bank 1 ($4000-$7FFF)
        sta     $dd00
        lda     $d011
        ora     #$20            ; bitmap on
        sta     $d011
        lda     #$f0            ; matrix offset $3C00 ($7C00), bitmap at
        sta     $d018           ;  bank offset 0 ($4000)
        jsr     rbt_maprun
        lda     #$78
        sta     rbt_sppool
        lda     #$e0
        sta     rbt_spptrb
        cli
@done:  rts

; ----------------------------------------------------------------------------
; rbt_cls - clear screen. Text mode: spaces + colour RAM, home cursor.
; Bitmap mode: 8000B bitmap to 0, matrix to (ink<<4)|paper.
; ----------------------------------------------------------------------------
rbt_cls:
        lda     rbt_smode
        beq     @text
        jmp     _cls_bmp
@text:  lda     #$20
        ldx     #0
@l1:    sta     RBT_SCRN,x
        sta     RBT_SCRN+$100,x
        sta     RBT_SCRN+$200,x
        inx
        bne     @l1
        ldx     #0
@l2:    sta     RBT_SCRN+$300,x ; last partial page (the sprite pointers
        inx                     ; at RBT_SPPT are left alone)
        cpx     #232
        bcc     @l2
        jsr     rbt_mapio       ; colour RAM $d800+ is in the I/O window
        lda     rbt_attr
        and     #$0f
        ldx     #0
@c1:    sta     $d800,x
        sta     $d900,x
        sta     $da00,x
        inx
        bne     @c1
        ldx     #0
@c2:    sta     $db00,x
        inx
        cpx     #232
        bcc     @c2
        jsr     rbt_maprun
        lda     #0
        sta     rbt_col
        sta     rbt_row
        rts

; _cls_bmp - bitmap-mode clear: bitmap $4000-$5F3F to 0, matrix $7C00 to
; (ink<<4)|paper, home cursor.
_cls_bmp:
        lda     #0
        ldx     #$40
        sta     rbt_ptr
        stx     rbt_ptr+1       ; ptr = $4000
        ldx     #$1f            ; 31 full pages + 64 bytes = 8000
        ldy     #0
@p:     sta     (rbt_ptr),y
        iny
        bne     @p
        inc     rbt_ptr+1
        dex
        bne     @p
        ldy     #63
@t:     sta     (rbt_ptr),y
        dey
        bpl     @t
        lda     rbt_attr        ; matrix byte = ink nibble<<4 | paper
        and     #$0f
        asl
        asl
        asl
        asl
        ora     rbt_papn
        ldx     #0
        stx     rbt_ptr
        ldx     #$7c
        stx     rbt_ptr+1       ; ptr = $7C00 matrix
        ldx     #3              ; 3 pages + 232 = 1000
        ldy     #0
@p2:    sta     (rbt_ptr),y
        iny
        bne     @p2
        inc     rbt_ptr+1
        dex
        bne     @p2
        ldy     #0
@t2:    sta     (rbt_ptr),y
        iny
        cpy     #232
        bne     @t2
        lda     #0
        sta     rbt_col
        sta     rbt_row
        rts

; ----------------------------------------------------------------------------
; rbt_rnd8 - 8-bit Galois LFSR (same tap as the ZX runtime). Out: A
; ----------------------------------------------------------------------------
rbt_rnd8:
        lda     rbt_seed
        asl     a
        bcc     @no_xor
        eor     #$1d
@no_xor:
        sta     rbt_seed
        rts

; ----------------------------------------------------------------------------
; rbt_mod8 - A = A mod rbt_b (unsigned)
; ----------------------------------------------------------------------------
rbt_mod8:
@dl:    cmp     rbt_b
        bcc     @done
        sbc     rbt_b           ; carry known set: cmp left A >= rbt_b
        jmp     @dl
@done:  rts

; ----------------------------------------------------------------------------
; 16-bit virtual-register helpers
; (rbt_hl pushes/pops are emitted inline by the compiler — a subroutine
; can't push data and RTS: the pushed bytes would sit above the return
; address and rts would pop the data as PC)
; ----------------------------------------------------------------------------

; rbt_xhlde - swap rbt_hl <-> rbt_de (the Z80 `ex de,hl` idiom)
rbt_xhlde:
        ldx     rbt_hl
        lda     rbt_de
        sta     rbt_hl
        stx     rbt_de
        ldx     rbt_hl+1
        lda     rbt_de+1
        sta     rbt_hl+1
        stx     rbt_de+1
        rts

; rbt_cmp16 - compare rbt_hl (left) vs rbt_de (right).
; Out flags: C = 1 iff hl >= de, Z = 1 iff equal — the same contract a
; Z80 `sbc hl,de` gives the conditional-jump code (with carry inverted,
; which the emitter accounts for).
; ----------------------------------------------------------------------------
rbt_cmp16:
        lda     rbt_hl+1
        cmp     rbt_de+1
        bne     @done           ; high bytes decide
        lda     rbt_hl
        cmp     rbt_de
@done:  rts

; rbt_sub16 - rbt_hl = rbt_hl - rbt_de
; ----------------------------------------------------------------------------
rbt_sub16:
        sec
        lda     rbt_hl
        sbc     rbt_de
        sta     rbt_hl
        lda     rbt_hl+1
        sbc     rbt_de+1
        sta     rbt_hl+1
        rts

; ----------------------------------------------------------------------------
; data
; ----------------------------------------------------------------------------
rbt_seed:        .word $ace1
rbt_dataptr:     .word 0         ; READ pointer (set to rbd_data by compiler)
rbt_col:         .byte 0         ; PRINT cursor column (charset)
rbt_row:         .byte 0         ; PRINT cursor row (charset)
rbt_over:        .byte 0         ; 0 = normal, 1 = reverse-video print
rbt_attr:        .byte $01       ; current colour nibble (white); bit7 = flash
                                ; (rbt_cls fills colour RAM with the nibble;
                                ;  INK/PAPER/BRIGHT/FLASH update it)
rbt_papn:        .byte $00       ; paper colour nibble (bitmap matrix /
                                ;  border colour pair for hires cells)
rbt_smode:       .byte 0         ; 0 = text, 1 = hires bitmap (rbt_scrmode)
rbt_d018:        .byte RBT_D018I ; shadow of $D018 in text mode — rbt_scrmode
                                ;  restores it on MODE 0 (fset/TILESET keep it
                                ;  in sync with their charset choice)
rbt_sppool:      .byte RBT_POOLH ; hi byte of the sprite pool in the active
                                ;  VIC bank ($CA00 text / $7800 bitmap)
rbt_spptrb:      .byte RBT_POOLP ; SPRPTR base for that pool ($28 / $1E0)
