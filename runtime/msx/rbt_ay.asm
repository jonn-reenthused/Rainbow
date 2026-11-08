; ============================================================================
; rbt_ay_asm - PSG music player (MSX1)
;
; Port of the ZX AY player. The PSG is an AY-3-8910: register select on
; port #A0, data write on #A1. Song format is the shared .ray stream:
; rows of dur + 14 register bytes (r13 = #ff means keep previous shape),
; ended by dur 0 + loop-offset word (#ffff = stop).
;
; rbt_ay_start  - HL = song data, A = bank (#ff = resident, always on MSX)
; rbt_ay_stop   - halt playback + silence
; rbt_ay_silence- volumes 0, mixer off
; rbt_ay_tick   - advance one frame (called from rbt_hook_frame)
;
; The bank re-page dance from the ZX player is kept — rbt_bank is a stub
; when the bank module isn't linked, so it costs nothing.
; ============================================================================

rbt_ay_regport  equ #a0
rbt_ay_dataport equ #a1

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
        ld      e,7                     ; mixer: all off (#3f)
        ld      a,e
        out     (#a0),a
        ld      a,#3f
        out     (#a1),a
        ld      e,8                     ; regs 8,9,10 = channel volumes -> 0
_v      ld      a,e
        out     (#a0),a
        xor     a
        out     (#a1),a
        inc     e
        ld      a,e
        cp      11
        jr      c,_v
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
        di                              ; BIOS ISR also writes the PSG
_wr     ld      a,e
        out     (#a0),a
        ld      a,(hl)
        out     (#a1),a
        ld      d,a
        ld      a,e
        cp      7                       ; mixer reg -> keep a shadow for
        jr      nz,_wrn                 ; the sfx player's merge logic
        ld      a,d
        ld      (rbt_ay_r7),a
_wrn    inc     hl
        inc     e
        ld      a,e
        cp      13
        jr      c,_wr
        ei
        ld      a,(hl)                  ; r13 env shape: #ff = skip
        inc     hl
        cp      #ff
        jr      z,_next
        ld      d,a
        ld      a,e
        out     (#a0),a
        ld      a,d
        out     (#a1),a
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
rbt_ay_r7       db 0                    ; last mixer byte (sfx merge)
rbt_ay_dur      db 0                    ; frames left on current row
rbt_ay_on       db 0                    ; playback active flag
rbt_ay_bank     db 0                    ; bank the song data lives in
