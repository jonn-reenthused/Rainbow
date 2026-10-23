; ============================================================================
; rbt_sid - Rainbow SID music player (Commodore 64)
;
; rbt_sid_start - rbt_hl = song data; starts playback (non-blocking).
; rbt_sid_tick  - advance one frame (auto-called from rbt_rwait callers
;                 via rbt_hook_frame, or explicitly with MUSIC TICK).
; rbt_sid_stop  - stop playback and silence all voices.
;
; Row format (produced by encodeRayCbm / encodeRntCbm — AY rows are
; converted to SID regs at build time):
;   defb dur
;   voice 1: defw freq, defb ctrl
;   voice 2: defw freq, defb ctrl
;   voice 3: defw freq, defb ctrl
;   defw pw                ; shared pulse width (12-bit), written to all
;                          ; three voices — pulse only sounds on those
;                          ; whose ctrl selects the pulse wave
;   defb vol               ; master volume written to $D418
; end marker: defb 0, defw loop-offset-in-rows ($ffff = stop + silence)
; ctrl carries gate+waveform: gate | $10 tri / $20 saw / $40 pulse /
; $80 noise, $00 voice off — auto-mapped from the AY mixer unless the
; .ray row supplies a "wave" name per voice.
; ============================================================================

        .code

; ----------------------------------------------------------------------------
; rbt_sid_start - rbt_hl = song data
; ----------------------------------------------------------------------------
rbt_sid_start:
        lda     rbt_hl
        sta     rbt_sid_base
        sta     z:rbt_sid_pos
        lda     rbt_hl+1
        sta     rbt_sid_base+1
        sta     z:rbt_sid_pos+1
        ; voice setup: 50% pulse width ($800), fast attack / full sustain
        ; PW hi registers are 4-bit, so $800 needs #$08 not #$80
        jsr     rbt_mapio               ; SID regs live in the I/O window
        lda     #$08
        sta     $d403                   ; PW hi voice 1
        sta     $d40a                   ; voice 2
        sta     $d411                   ; voice 3
        lda     #$09                    ; A=0, D=9
        sta     $d405
        sta     $d40c
        sta     $d413
        lda     #$f0                    ; S=15, R=0
        sta     $d406
        sta     $d40d
        sta     $d414
        jsr     rbt_maprun
        lda     #0
        sta     rbt_sid_dur             ; force row load on next tick
        lda     #1
        sta     rbt_sid_on
        rts

; ----------------------------------------------------------------------------
; rbt_sid_stop - stop playback and silence all voices
; ----------------------------------------------------------------------------
rbt_sid_stop:
        lda     #0
        sta     rbt_sid_on
        jsr     rbt_mapio
        sta     $d404                   ; gates off
        sta     $d40b
        sta     $d412
        sta     $d418                   ; master vol
        jmp     rbt_maprun              ; tail: restore map + rts

; ----------------------------------------------------------------------------
; rbt_sid_tick - advance one frame. Called from rbt_hook_frame inside the
; frame-wait loops, which hold live counters in X — preserve all regs.
; ----------------------------------------------------------------------------
rbt_sid_tick:
        pha
        txa
        pha
        tya
        pha
        jsr     rbt_mapio               ; SID regs live in the I/O window
        lda     rbt_sid_on
        bne     @go
        jmp     @ret
@go:
        lda     rbt_sid_dur
        beq     @row
        dec     rbt_sid_dur
        bne     @ret
@row:
        ldy     #0
        lda     (rbt_sid_pos),y         ; dur byte
        beq     @end
        sta     rbt_sid_dur
        iny
        ldx     #0                      ; voice reg offset: 0, 7, 14
@voice:
        lda     (rbt_sid_pos),y         ; freq lo
        sta     $d400,x
        iny
        lda     (rbt_sid_pos),y         ; freq hi
        sta     $d401,x
        iny
        lda     (rbt_sid_pos),y         ; ctrl
        sta     $d404,x
        iny
        txa
        clc
        adc     #7
        tax
        cmp     #21
        bcc     @voice
        lda     (rbt_sid_pos),y         ; pulse width lo (y = 10)
        sta     $d402
        sta     $d409
        sta     $d410
        iny
        lda     (rbt_sid_pos),y         ; pulse width hi (12-bit)
        sta     $d403
        sta     $d40a
        sta     $d411
        iny
        lda     (rbt_sid_pos),y         ; master volume (y = 12)
        sta     $d418
        clc
        lda     z:rbt_sid_pos
        adc     #13
        sta     z:rbt_sid_pos
        bcc     @ret
        inc     z:rbt_sid_pos+1
@ret:
        jsr     rbt_maprun
        pla
        tay
        pla
        tax
        pla
        rts
@end:
        ldy     #1
        lda     (rbt_sid_pos),y         ; loop offset lo -> X
        tax
        iny
        lda     (rbt_sid_pos),y         ; loop offset hi -> Y
        tay
        cpy     #$ff                    ; $ffff -> stop + silence
        bne     @loop
        cpx     #$ff
        beq     @stop
@loop:
        ; pos = base + offset (Y=hi, X=lo)
        txa
        clc
        adc     rbt_sid_base
        sta     z:rbt_sid_pos
        tya
        adc     rbt_sid_base+1
        sta     z:rbt_sid_pos+1
        jmp     @ret
@stop:
        jsr     rbt_sid_stop
        jmp     @ret

        .zeropage
rbt_sid_pos:    .res    2               ; current row pointer (indirect)

        .code
rbt_sid_base:   .res    2               ; song data base
rbt_sid_dur:    .res    1               ; frames left on current row
rbt_sid_on:     .res    1               ; playback active flag
