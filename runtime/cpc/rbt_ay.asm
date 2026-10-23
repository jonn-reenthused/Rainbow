; ============================================================================
; rbt_ay_asm - Rainbow AY-3-8912 music player (Amstrad CPC)
;
; rbt_ay_start - HL = .ray song data; starts playback (non-blocking).
; rbt_ay_tick  - call once per frame (auto-called from rbt_vsync/rbt_pause
;                via rbt_frame_hook, or explicitly with MUSIC TICK).
; rbt_ay_stop  - stop playback and silence all channels.
;
; Same .ray row format as the ZX player: defb dur, then regs r0..r13
; (r13 = #ff = don't touch); end marker defb 0, defw loop offset
; (#ffff = stop + silence). The encoder rescales AY periods for the
; CPC's 1 MHz clock (ZX AY = 1.7734 MHz) so .ray assets are portable.
; All register traffic goes through rbt_psg (PPI-mediated).
; ============================================================================

; ----------------------------------------------------------------------------
; rbt_ay_start - HL = song data
; ----------------------------------------------------------------------------
rbt_ay_start:
        ld      (rbt_ay_base),hl
        ld      (rbt_ay_pos),hl
        ld      a,(rbt_cur_bank)        ; remember the song's bank
        ld      (rbt_ay_bank),a
        xor     a
        ld      (rbt_ay_dur),a          ; force row load on next tick
        inc     a
        ld      (rbt_ay_on),a
        ret

; ----------------------------------------------------------------------------
; rbt_ay_stop - stop playback and silence all channels.
; ----------------------------------------------------------------------------
rbt_ay_stop:
        xor     a
        ld      (rbt_ay_on),a
        ; fall through: silence the chip (vols 0, tone+noise off)
rbt_ay_silence:
        ld      e,7                     ; mixer: all off (#3f)
        ld      d,#3f
        call    rbt_psg
        ld      e,8                     ; regs 8,9,10 = channel volumes -> 0
        ld      d,0
_vol    call    rbt_psg
        inc     e
        ld      a,e
        cp      11
        jr      c,_vol
        ret

; ----------------------------------------------------------------------------
; rbt_ay_tick - advance one frame (called from rbt_hook_frame / MUSIC TICK)
; ----------------------------------------------------------------------------
rbt_ay_tick:
        ld      a,(rbt_ay_on)
        or      a
        ret     z
        ; page in the song bank, restore the caller's on exit. The save
        ; byte lives in RAM, not AF' - the firmware ISR owns the alt set.
        ld      a,(rbt_ay_bank)
        ld      hl,rbt_ay_prev
        call    rbt_pg_in
        call    _work
        ld      hl,rbt_ay_prev
        jp      rbt_pg_out              ; restore previous mapping (ret)
_work:
        ld      a,(rbt_ay_dur)
        or      a
        jr      z,_row
        dec     a
        ld      (rbt_ay_dur),a
        ret     nz
_row    ld      hl,(rbt_ay_pos)
        ld      a,(hl)                  ; dur byte
        or      a
        jr      z,_end
        ld      (rbt_ay_dur),a
        inc     hl
        ; write r0..r12 unconditionally, r13 unless #ff
        ld      e,0
_wr     ld      d,(hl)
        push    hl
        call    rbt_psg
        pop     hl
        ld      a,e
        cp      7
        jr      nz,_wnr
        ld      a,d
        ld      (rbt_ay_r7),a         ; shadow mixer for the sfx channel steal
_wnr
        inc     hl
        inc     e
        ld      a,e
        cp      13
        jr      c,_wr
        ld      a,(hl)                  ; r13 env shape: #ff = skip
        inc     hl
        cp      #ff
        jr      z,_next
        ld      d,a
        call    rbt_psg
_next   ld      (rbt_ay_pos),hl
        ret
_end    inc     hl
        ld      e,(hl)                  ; loop row offset (#ffff = stop)
        inc     hl
        ld      d,(hl)
        ld      a,d
        and     e
        inc     a
        jp      z,rbt_ay_stop           ; #ffff -> stop + silence
        ld      hl,(rbt_ay_base)
        add     hl,de
        ld      (rbt_ay_pos),hl
        ret

; ----------------------------------------------------------------------------
rbt_ay_base     dw 0                    ; song data base
rbt_ay_pos      dw 0                    ; current row pointer
rbt_ay_dur      db 0                    ; frames left on current row
rbt_ay_on       db 0                    ; playback active flag
rbt_ay_r7       db 0                    ; last mixer (r7) written - sfx steal mask
rbt_ay_bank     db #c0                  ; mapping the song data lives in (#c0 = resident)
rbt_ay_prev     db 0                    ; mapping save byte for the tick guard
