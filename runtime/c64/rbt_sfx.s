; ============================================================================
; rbt_sfx - Rainbow sound effects via the SID (Commodore 64)
;
; Same queue/drain model as the ZX/CPC engines: SFX queues an effect,
; the next idle point (vsync/pause/waitkey/end via rbt_sfx_drain) plays
; it blocking, so effects land in dead frame time. The effect drives
; SID voice 3 — the "channel steal": if music is running the next .ray
; row simply reasserts the voice's registers.
;
; rbt_sfx       - queue an effect: rbt_hl = step data
; rbt_sfx_drain - play the pending effect now if one is queued
;
; Step format (6 bytes, from encodeRsfCbm):
;   defb len    ; update iterations (0 = end of effect)
;   defb dur    ; delay units between updates (~5 cycles each @ ~1 MHz)
;   defw freq   ; SID frequency register, 16-bit
;   defw slide  ; signed per-iteration delta, 16.8 fixed point
; ============================================================================

        .code

; ----------------------------------------------------------------------------
; rbt_sfx - queue an effect (rbt_hl = step data). Drains a previously
; queued effect first so effects keep call order.
; ----------------------------------------------------------------------------
rbt_sfx:
        lda     rbt_hl
        sta     rbt_sfx_in
        lda     rbt_hl+1
        sta     rbt_sfx_in+1
        jsr     rbt_sfx_drain
        lda     rbt_sfx_in
        sta     rbt_sfx_pending
        lda     rbt_sfx_in+1
        sta     rbt_sfx_pending+1
        rts

; ----------------------------------------------------------------------------
; rbt_sfx_drain - play the queued effect now (blocking); no-op when none
; ----------------------------------------------------------------------------
rbt_sfx_drain:
        lda     rbt_sfx_pending
        ora     rbt_sfx_pending+1
        bne     @have
        jmp     @none
@have:
        ; move pending -> play pointer, clear queue
        lda     rbt_sfx_pending
        sta     z:rbt_sfx_ptr
        lda     rbt_sfx_pending+1
        sta     z:rbt_sfx_ptr+1
        lda     #0
        sta     rbt_sfx_pending
        sta     rbt_sfx_pending+1
        jsr     rbt_mapio               ; SID regs live in the I/O window
        ; voice 3 setup: 50% pulse ($800), fast attack, full sustain
        ; PW hi registers are 4-bit, so $800 needs #$08 not #$80
        lda     #$08
        sta     $d411                   ; PW hi voice 3
        lda     #$09
        sta     $d413                   ; A=0, D=9
        lda     #$f0
        sta     $d414                   ; S=15, R=0
        lda     #$0f
        sta     $d418                   ; master vol: rbt_sid_stop zeroes it
                                        ; when a tune ends — reassert or
                                        ; every effect after it is silent
        lda     #$41                    ; pulse + gate
        sta     $d412
@step:
        ldy     #0
        lda     (rbt_sfx_ptr),y         ; len (0 = end)
        bne     @more
        jmp     @done
@more:
        sta     rbt_sfx_len
        iny
        lda     (rbt_sfx_ptr),y
        sta     rbt_sfx_dur             ; dur
        iny
        lda     (rbt_sfx_ptr),y
        sta     rbt_sfx_fq              ; freq lo
        iny
        lda     (rbt_sfx_ptr),y
        sta     rbt_sfx_fq+1            ; freq hi
        iny
        lda     (rbt_sfx_ptr),y
        sta     rbt_sfx_sl              ; slide frac (16.8, signed)
        iny
        lda     (rbt_sfx_ptr),y
        sta     rbt_sfx_sl+1            ; slide int
        lda     #0
        sta     rbt_sfx_frc             ; freq frac accumulator
        ; ptr += 6
        clc
        lda     z:rbt_sfx_ptr
        adc     #6
        sta     z:rbt_sfx_ptr
        bcc     @iter
        inc     z:rbt_sfx_ptr+1
@iter:
        lda     rbt_sfx_fq              ; freq reg direct (16-bit)
        sta     $d40e                   ; voice 3 freq lo
        lda     rbt_sfx_fq+1
        sta     $d40f
        ; delay: dur x ~5 cycle loop
        ldx     rbt_sfx_dur
@wait:  dex
        bne     @wait
        ; frq:frc += slide (signed 16.8 fixed point, clamp at 0)
        clc
        lda     rbt_sfx_frc
        adc     rbt_sfx_sl
        sta     rbt_sfx_frc
        lda     rbt_sfx_fq
        adc     rbt_sfx_sl+1
        sta     rbt_sfx_fq
        lda     rbt_sfx_fq+1
        bit     rbt_sfx_sl+1
        bpl     @hi
        adc     #$ff                    ; sign-extend negative slide
        jmp     @st
@hi:    adc     #0
@st:    sta     rbt_sfx_fq+1
        bpl     @plen
        lda     #0                      ; undershot -> silence
        sta     rbt_sfx_frc
        sta     rbt_sfx_fq
        sta     rbt_sfx_fq+1
@plen:
        dec     rbt_sfx_len
        bne     @iter
        jmp     @step
@done:
        lda     #0
        sta     $d412                   ; voice 3 gate off
        jsr     rbt_maprun
@none:
        rts

        .zeropage
rbt_sfx_ptr:     .res   2               ; play pointer (indirect)

        .code
rbt_sfx_pending: .res   2               ; queued effect step ptr (0 = none)
rbt_sfx_in:      .res   2               ; incoming ptr across the drain
rbt_sfx_len:     .res   1
rbt_sfx_dur:     .res   1
rbt_sfx_fq:      .res   2               ; current freq reg
rbt_sfx_frc:     .res   1               ; freq fraction accumulator
rbt_sfx_sl:      .res   2               ; slide delta, 16.8 signed
