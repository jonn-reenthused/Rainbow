; ============================================================================
; rbt_math_asm - arithmetic helpers for 8/16-bit ops
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_mul8 - HL = D * E (unsigned, low 16 bits)
; ----------------------------------------------------------------------------
rbt_mul8:
        ld      hl,0
        ld      b,8
_ml     add     hl,hl
        sla     d
        jr      nc,_m0
        ld      a,l
        add     a,e
        ld      l,a
        jr      nc,_m0
        inc     h
_m0     djnz    _ml
        ret

; ----------------------------------------------------------------------------
; rbt_divmod8 - in: A = dividend, B = divisor. out: A = quotient, B = remainder
; ----------------------------------------------------------------------------
rbt_divmod8:
        ld      c,a
        xor     a
        ld      e,a             ; quotient
        ld      a,b
        or      a
        jr      z,_dz           ; divisor 0: return q=0, r=0
        ld      a,c
_dl     cp      b
        jr      c,_done
        sub     b
        inc     e
        jr      _dl
_done   ld      b,a             ; remainder
        ld      a,e             ; quotient
_dz     ret                     ; (a==0 here on the _dz path)

; ----------------------------------------------------------------------------
; rbt_mul16 - HL = DE * HL (low 16 bits; works for signed too)
; ----------------------------------------------------------------------------
rbt_mul16:
        ld      b,h
        ld      c,l
        ld      hl,0
        ld      a,16
_ml     add     hl,hl
        sla     c
        rl      b
        jr      nc,_m0
        add     hl,de
_m0     dec     a
        jr      nz,_ml
        ret

; ----------------------------------------------------------------------------
; rbt_divmod16 - unsigned: BC / DE -> BC = quotient, HL = remainder
; ----------------------------------------------------------------------------
rbt_divmod16:
        ld      hl,0            ; remainder
        ld      a,d
        or      e
        jr      z,_dz           ; divisor 0: return q=0, r=0
        ld      a,16
_dl     sla     c               ; num <<= 1, bit15 -> CY
        rl      b
        rl      l               ; rem <<= 1 + CY
        rl      h
        sbc     hl,de
        jr      nc,_q1
        add     hl,de           ; restore (CY=0 -> quotient bit 0)
        jr      _nxt
_q1     inc     c               ; quotient bit 1
_nxt    dec     a
        jr      nz,_dl
        ret
_dz     ld      b,h             ; quotient BC=0, remainder HL=0
        ld      c,l
        ret

; ----------------------------------------------------------------------------
; rbt_sdivmod16 - signed: BC / DE -> BC = quotient, HL = remainder
; quotient truncates toward zero; remainder takes dividend's sign.
; ----------------------------------------------------------------------------
rbt_sdivmod16:
        xor     a
        ld      (rbt_divsign),a ; bit0: result negative
        bit     7,b
        jr      z,_nnum
        ; negate BC
        ld      a,c
        cpl
        ld      c,a
        ld      a,b
        cpl
        ld      b,a
        inc     bc
        ld      a,(rbt_divsign)
        xor     1
        ld      (rbt_divsign),a
_nnum   bit     7,d
        jr      z,_ndiv
        ; negate DE
        ld      a,e
        cpl
        ld      e,a
        ld      a,d
        cpl
        ld      d,a
        inc     de
        ld      a,(rbt_divsign)
        xor     1
        ld      (rbt_divsign),a
_ndiv   call    rbt_divmod16
        ld      a,(rbt_divsign)
        or      a
        ret     z
        ; negate quotient BC
        ld      a,c
        cpl
        ld      c,a
        ld      a,b
        cpl
        ld      b,a
        inc     bc
        ret

rbt_divsign     defb 0

; ----------------------------------------------------------------------------
; rbt_neg16 - HL = -HL (two's complement)
; ----------------------------------------------------------------------------
rbt_neg16:
        xor     a
        sub     l
        ld      l,a
        sbc     a,a
        sub     h
        ld      h,a
        ret

; ----------------------------------------------------------------------------
; rbt_abs16 - HL = |HL|
; ----------------------------------------------------------------------------
rbt_abs16:
        bit     7,h
        ret     z
        jr      rbt_neg16
