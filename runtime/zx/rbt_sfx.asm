; ============================================================================
; rbt_sfx_asm - Rainbow beeper sound effects
;
; SFX queues an effect instead of playing it inline: the pending pointer is
; drained at the next idle point (rbt_vsync / rbt_pause / rbt_waitkey /
; rbt_end / rbt_sp_update entry), so the effect plays during dead frame time
; instead of stalling the game loop. If a second SFX arrives while one is
; still pending, the pending one plays immediately so ordering is preserved.
;
; rbt_sfx       - queue an effect: HL = step data, A = bank (#ff = resident)
; rbt_sfx_drain - play the pending effect now if one is queued (called by
;                 the frame-wait routines; stubbed to ret when sfx unused)
; rbt_sfx_play  - blocking player: HL = step data (di during playback)
;
; Step format (3 bytes): len, period, slide
;   len    = number of speaker toggles (1..255; 0 = end of effect)
;   period = delay between toggles (~13*T per unit, 1..255)
;   slide  = signed byte added to period each toggle (pitch bend)
; ============================================================================

rbt_sfx:
        push    hl
        push    af
        call    rbt_sfx_drain         ; flush a queued effect first (ordering)
        pop     af
        pop     hl
        ld      (rbt_sfx_pbank),a
        ld      (rbt_sfx_pending),hl
        ret

rbt_sfx_drain:
        ld      hl,(rbt_sfx_pending)
        ld      a,h
        or      l
        ret     z
        push    hl                    ; step ptr
        xor     a
        ld      (rbt_sfx_pending),a
        ld      (rbt_sfx_pending+1),a
        ld      a,(rbt_sfx_pbank)
        ld      hl,rbt_sfx_pprev
        call    rbt_pg_in             ; pages only when pbank <> #ff
        pop     hl
        call    rbt_sfx_play
        ld      hl,rbt_sfx_pprev
        jp      rbt_pg_out            ; restore bank (no-op when resident)

rbt_sfx_play:
        di
        ld      c,#10                   ; speaker output level
_step   ld      a,(hl)                  ; len
        or      a
        jr      z,_done
        inc     hl
        ld      d,(hl)                  ; period
        inc     hl
        ld      e,(hl)                  ; slide
        inc     hl
        push    hl
        ld      b,a
_toggle ld      a,c
        out     (#fe),a                 ; write speaker level
        xor     #10
        ld      c,a
        ld      a,d                     ; delay: ~13T * period
        or      a
        jr      nz,_wait
        inc     a                       ; period 0 -> 1 (avoid hang)
_wait   dec     a
        jr      nz,_wait
        ld      a,d                     ; period += slide
        add     a,e
        ld      d,a
        nop                             ; pad loop timing
        nop
        djnz    _toggle
        pop     hl
        jr      _step
_done   xor     a
        out     (#fe),a
        ei
        ret

rbt_sfx_pending defw    0               ; queued effect step ptr (0 = none)
rbt_sfx_pbank   defb    #ff             ; bank of the queued effect
rbt_sfx_pprev   defb    0               ; bank save byte for the drain guard
