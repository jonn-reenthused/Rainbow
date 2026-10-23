; ============================================================================
; rbt_sfx_asm - Rainbow sound effects via the AY (Amstrad CPC)
;
; Same queue/drain model as the ZX beeper engine: SFX queues an effect,
; the next idle point (vsync/pause/waitkey/end/sprite update) drains and
; plays it blocking — effects land in dead frame time. Instead of toggling
; a speaker the CPC player drives AY channel C: it "steals" the music
; channel's voice (the next .ray row reasserts the channel), or programs
; the mixer itself when no music is running.
;
; rbt_sfx       - queue an effect: HL = step data, A ignored (no banks)
; rbt_sfx_drain - play the pending effect now if one is queued
; rbt_sfx_play  - blocking player: HL = step data
;
; CPC-encoded .rsf step format (6 bytes):
;   defb len          ; update iterations (0 = end of effect)
;   defb dur          ; delay units between updates (~13T each)
;   defw period       ; AY tone period for channel C
;   defw slide        ; signed delta added to period each iteration
; ============================================================================

rbt_sfx:
        push    hl
        push    af
        call    rbt_sfx_drain         ; flush a queued effect first (ordering)
        pop     af
        pop     hl
        ld      (rbt_sfx_pbank),a     ; bank the effect data lives in (#ff = resident)
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
        call    rbt_pg_in             ; no-op when resident (#ff) or no bank module
        pop     hl
        call    rbt_sfx_play
        ld      hl,rbt_sfx_pprev
        jp      rbt_pg_out            ; restore mapping (ret)

rbt_sfx_play:
        ld      e,10                  ; channel C volume
        ld      d,12
        call    rbt_psg
        ld      a,(rbt_ay_on)
        or      a
        jr      z,_mix0
        ; music owns the mixer: steal its C voice - force tone C on and
        ; noise C off, keeping the music's A/B channel bits (songs that
        ; use C for drums/noise would otherwise gate noise instead of
        ; the swept tone).
        ld      a,(rbt_ay_r7)
        and     #fb                   ; bit2 = 0: tone C enabled
        or      #20                   ; bit5 = 1: noise C disabled
        ld      d,a
        ld      e,7
        call    rbt_psg
        jr      _step
_mix0   ld      e,7                   ; no music: tone C on, rest off
        ld      d,#3b                 ; bits 0,1,3,4,5 set: C tone only
        call    rbt_psg
_step   ld      a,(hl)                ; len
        or      a
        jp      z,_done
        ld      (rbt_sfx_len),a
        inc     hl
        ld      a,(hl)                ; dur units
        inc     hl
        ld      (rbt_sfx_dur),a
        ld      a,(hl)                ; period lo
        inc     hl
        ld      (rbt_sfx_per),a
        ld      a,(hl)                ; period hi
        inc     hl
        ld      (rbt_sfx_per+1),a
        ld      a,(hl)                ; slide lo
        inc     hl
        ld      (rbt_sfx_sl),a
        ld      a,(hl)                ; slide hi
        inc     hl
        ld      (rbt_sfx_sl+1),a
        push    hl                    ; next-step pointer (HL = step+6)
_iter   ; write channel C period (regs 4,5); data is q8 -> shift >>3
        ld      a,(rbt_sfx_per)
        ld      l,a
        ld      a,(rbt_sfx_per+1)
        ld      h,a
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l               ; HL = period
        ld      d,l
        ld      e,4
        call    rbt_psg
        ld      a,(rbt_sfx_per)
        ld      l,a
        ld      a,(rbt_sfx_per+1)
        ld      h,a
        srl     h
        rr      l
        srl     h
        rr      l
        srl     h
        rr      l
        ld      a,h
        and     #0f
        ld      d,a
        ld      e,5
        call    rbt_psg
        ; delay: dur x ~13T loop (encoder scales units for 4 MHz)
        ld      a,(rbt_sfx_dur)
        or      a
        jr      nz,_w
        inc     a
_w      ld      b,a
_wi     djnz    _wi
        ; period += slide (clamp at 0)
        ld      a,(rbt_sfx_per)
        ld      e,a
        ld      a,(rbt_sfx_per+1)
        ld      d,a
        ld      a,(rbt_sfx_sl)
        ld      l,a
        ld      a,(rbt_sfx_sl+1)
        ld      h,a
        add     hl,de
        bit     7,h
        jr      z,_pc
        ld      hl,0
_pc     ld      a,l
        ld      (rbt_sfx_per),a
        ld      a,h
        ld      (rbt_sfx_per+1),a
        ld      a,(rbt_sfx_len)
        dec     a
        ld      (rbt_sfx_len),a
        jr      nz,_iter
        pop     hl
        jp      _step
_done   ld      e,10                  ; channel C silent
        ld      d,0
        call    rbt_psg
        ret

rbt_sfx_pending defw    0             ; queued effect step ptr (0 = none)
rbt_sfx_pbank   defb    #ff           ; bank of the queued effect
rbt_sfx_pprev   defb    0             ; mapping save byte for the drain guard
rbt_sfx_len     defb    0
rbt_sfx_dur     defb    0
rbt_sfx_per     defw    0
rbt_sfx_sl      defw    0
