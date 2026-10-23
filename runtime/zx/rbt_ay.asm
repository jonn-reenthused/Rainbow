; ============================================================================
; rbt_ay_asm - Rainbow AY-3-8912 music player (128K)
;
; rbt_ay_start - HL = .ray song data; starts playback (non-blocking).
; rbt_ay_tick  - call once per frame (auto-called from rbt_vsync/rbt_pause
;                via rbt_frame_hook, or explicitly with MUSIC TICK).
; rbt_ay_stop  - stop playback and silence all channels.
;
; .ray format: rows of 15 bytes = defb dur, then AY regs r0..r13.
;   dur = frames the row plays (1..255). r13 = #ff means "don't touch".
;   Song end: defb 0 (dur), defw loop_row_offset (#ffff = stop + silence).
; ============================================================================

rbt_ay_regport  equ #fffd
rbt_ay_dataport equ #bffd

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
rbt_ay_stop:
        xor     a
        ld      (rbt_ay_on),a
        ; fall through: silence the chip (vols 0, tone+noise off)
rbt_ay_silence:
        ld      bc,rbt_ay_regport
        ld      e,7                     ; mixer: all off (#3f)
        out     (c),e
        ld      bc,rbt_ay_dataport
        ld      d,#3f
        out     (c),d
        ld      e,8                     ; regs 8,9,10 = channel volumes -> 0
        ld      d,0
_vol    ld      bc,rbt_ay_regport
        out     (c),e
        ld      bc,rbt_ay_dataport
        out     (c),d
        inc     e
        ld      a,e
        cp      11
        jr      c,_vol
        ret

; ----------------------------------------------------------------------------
rbt_ay_tick:
        ld      a,(rbt_ay_on)
        or      a
        ret     z
        ; page in the song bank, restore the caller's on exit
        ld      a,(rbt_cur_bank)
        ex      af,af'
        ld      a,(rbt_ay_bank)
        call    rbt_bank
        call    _work
        ex      af,af'
        jp      rbt_bank                ; restore previous bank (ret)
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
_wr     ld      bc,rbt_ay_regport
        out     (c),e
        ld      bc,rbt_ay_dataport
        ld      d,(hl)
        out     (c),d
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
        ld      bc,rbt_ay_regport
        out     (c),e
        ld      bc,rbt_ay_dataport
        out     (c),d
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
rbt_ay_bank     db 0                    ; bank the song data lives in
