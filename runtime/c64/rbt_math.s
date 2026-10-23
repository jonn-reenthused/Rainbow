; ============================================================================
; rbt_math - arithmetic helpers for 8/16-bit ops (Commodore 64, ca65)
; Same contracts as the shared Z80 module, on the virtual registers.
; ============================================================================

        .code

; ----------------------------------------------------------------------------
; rbt_mul8 - rbt_hl = rbt_d * rbt_e (unsigned, low 16 bits)
; ----------------------------------------------------------------------------
rbt_mul8:
        lda     #0
        sta     rbt_hl
        sta     rbt_hl+1
        ldx     #8
@ml:    asl     rbt_hl          ; hl <<= 1
        rol     rbt_hl+1
        asl     rbt_d           ; multiplier bit -> C
        bcc     @m0
        clc
        lda     rbt_hl
        adc     rbt_e
        sta     rbt_hl
        bcc     @m0
        inc     rbt_hl+1
@m0:    dex
        bne     @ml
        rts

; ----------------------------------------------------------------------------
; rbt_divmod8 - in: A = dividend, rbt_b = divisor.
; out: A = quotient, rbt_b = remainder
; ----------------------------------------------------------------------------
rbt_divmod8:
        sta     rbt_t0          ; dividend
        lda     rbt_b
        beq     @dz             ; divisor 0: return q=0, r=0
        lda     #0
        sta     rbt_t1          ; quotient
        lda     rbt_t0
@dl:    cmp     rbt_b
        bcc     @done
        sbc     rbt_b           ; carry known set here
        inc     rbt_t1
        jmp     @dl
@done:  sta     rbt_b           ; remainder
        lda     rbt_t1          ; quotient
        rts
@dz:    lda     #0
        sta     rbt_b
        rts                     ; A = 0

; ----------------------------------------------------------------------------
; rbt_mul16 - rbt_hl = rbt_de * rbt_hl (low 16 bits; signed-safe)
; ----------------------------------------------------------------------------
rbt_mul16:
        lda     rbt_hl
        sta     rbt_bc
        lda     rbt_hl+1
        sta     rbt_bc+1        ; rbt_bc = multiplier
        lda     #0
        sta     rbt_hl
        sta     rbt_hl+1
        ldx     #16
@ml:    asl     rbt_hl
        rol     rbt_hl+1        ; product <<= 1
        asl     rbt_bc
        rol     rbt_bc+1        ; multiplier top bit -> C
        bcc     @m0
        clc
        lda     rbt_hl
        adc     rbt_de
        sta     rbt_hl
        lda     rbt_hl+1
        adc     rbt_de+1
        sta     rbt_hl+1
@m0:    dex
        bne     @ml
        rts

; ----------------------------------------------------------------------------
; rbt_divmod16 - unsigned: rbt_bc / rbt_de -> rbt_bc = quotient,
; rbt_hl = remainder
; ----------------------------------------------------------------------------
rbt_divmod16:
        lda     rbt_de
        ora     rbt_de+1
        bne     @go
        lda     #0              ; divisor 0: q=0, r=0
        sta     rbt_bc
        sta     rbt_bc+1
        sta     rbt_hl
        sta     rbt_hl+1
        rts
@go:    lda     #0
        sta     rbt_hl          ; remainder
        sta     rbt_hl+1
        ldx     #16
@dl:    asl     rbt_bc          ; dividend <<= 1, top bit -> C
        rol     rbt_bc+1
        rol     rbt_hl          ; rem <<= 1 + C
        rol     rbt_hl+1
        ; rem >= divisor? (compare rbt_hl vs rbt_de)
        lda     rbt_hl+1
        cmp     rbt_de+1
        bne     @cmp
        lda     rbt_hl
        cmp     rbt_de
@cmp:   bcc     @nxt            ; rem < de -> quotient bit 0
        sec
        lda     rbt_hl
        sbc     rbt_de
        sta     rbt_hl
        lda     rbt_hl+1
        sbc     rbt_de+1
        sta     rbt_hl+1
        inc     rbt_bc          ; quotient bit 1 (bit0 was just shifted 0)
@nxt:   dex
        bne     @dl
        rts

; ----------------------------------------------------------------------------
; rbt_sdivmod16 - signed: rbt_bc / rbt_de -> rbt_bc = quotient,
; rbt_hl = remainder. Quotient truncates toward zero; remainder takes
; the dividend's sign (same as the Z80 version).
; ----------------------------------------------------------------------------
rbt_sdivmod16:
        lda     #0
        sta     rbt_divsign     ; bit0: result negative
        bit     rbt_bc+1
        bpl     @nnum
        jsr     rbt_negbc
        lda     rbt_divsign
        eor     #1
        sta     rbt_divsign
@nnum:  bit     rbt_de+1
        bpl     @ndiv
        jsr     rbt_negde
        lda     rbt_divsign
        eor     #1
        sta     rbt_divsign
@ndiv:  jsr     rbt_divmod16
        lda     rbt_divsign
        beq     @done
        jsr     rbt_negbc       ; negate quotient
@done:  rts

rbt_divsign:     .byte 0

rbt_negbc:
        sec
        lda     #0
        sbc     rbt_bc
        sta     rbt_bc
        lda     #0
        sbc     rbt_bc+1
        sta     rbt_bc+1
        rts

rbt_negde:
        sec
        lda     #0
        sbc     rbt_de
        sta     rbt_de
        lda     #0
        sbc     rbt_de+1
        sta     rbt_de+1
        rts

; ----------------------------------------------------------------------------
; rbt_neg16 - rbt_hl = -rbt_hl (two's complement)
; ----------------------------------------------------------------------------
rbt_neg16:
        sec
        lda     #0
        sbc     rbt_hl
        sta     rbt_hl
        lda     #0
        sbc     rbt_hl+1
        sta     rbt_hl+1
        rts

; ----------------------------------------------------------------------------
; rbt_abs16 - rbt_hl = |rbt_hl|
; ----------------------------------------------------------------------------
rbt_abs16:
        bit     rbt_hl+1
        bpl     @pos
        jmp     rbt_neg16
@pos:   rts
