; rbt_diskload - stream an asset file off disk into RAM via the kernal.
; COPYBANK "name", dest lowers to this on cbm: the 1541 file's first two
; bytes (its stored load address) are skipped because the secondary
; address is 0, so the payload lands at the caller's dest.
;
; in:  rbt_hl = ptr to a length-prefixed PETSCII filename
;      rbt_de = load address
; out: carry clear = ok, carry set = kernal/device error
; clobbers a,x,y (and anything the kernal uses)

rbt_diskload:
        sei                     ; c128: an IRQ mid-LOAD can land in the
                                ; monitor under the kernal's transient
                                ; MMU configs — hold interrupts off for
                                ; the whole kernal call
        .if RBT_C128
        lda     #$00
        sta     $ff00           ; kernal needs its all-ROM + I/O map; our
                                ; $0F mainline map hides I/O entirely
        .endif
        lda     #1              ; logical file number
        ldx     #8              ; device 8
        ldy     #0              ; secondary 0: LOAD uses the X/Y address
        jsr     $ffba           ; SETLFS
        ldy     #0
        lda     (rbt_hl),y      ; name length
        ldx     rbt_hl          ; name ptr = rbt_hl + 1
        inx
        bne     @hi
        ldy     rbt_hl+1
        iny
        jmp     @setnam
@hi:    ldy     rbt_hl+1
@setnam:
        jsr     $ffbd           ; SETNAM (a=len, x/y=name ptr)
        lda     #0              ; LOAD (not VERIFY)
        ldx     rbt_de
        ldy     rbt_de+1
        jsr     $ffd5           ; kernal LOAD
        .if RBT_C128
        lda     #$0f
        sta     $ff00           ; back to the mainline map
        .endif
        cli
        rts
