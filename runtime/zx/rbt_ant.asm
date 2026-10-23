; ============================================================================
; rbt_ant_asm - Rainbow beeper music engine (AntEater port)
;
; AntEater - ZX Spectrum beeper engine by utz 08'2014 (1tracker version by
; Shiru 12'2017). Ported to the Rainbow runtime; music data uses OFFSETS
; from the asset base (rbt_ant_base) so songs are position independent.
;
; Entry: rbt_ant - HL = .rnt music data. Blocking; plays to song end or loop.
; (upstream AntEater aborted on keypress — removed: games trigger MUSIC
; from key input, which would kill the song instantly)
; (skips to the loop section) or when a non-looping song reaches its end.
; Uses EXX/BC'/DE'/HL'; restores HL'=#2758 for the ROM on exit.
; ============================================================================

; rbt_ant - play AntEater song, HL = music data
rbt_ant:
        di
        ld      (rbt_ant_base),hl
rbt_ant_loop:
        ld      (rbt_ant_order),hl
        call    rbt_ant_readorder
        ld      e,(hl)                  ; order end: read loop-slot offset
        inc     hl
        ld      d,(hl)
        ld      a,d
        or      e
        jr      z,rbt_ant_done          ; loop word 0 -> song finished
        ld      hl,(rbt_ant_base)
        add     hl,de                   ; resume at loop order slot
        jr      rbt_ant_loop
rbt_ant_done:
        xor     a
        out     (#fe),a
        ld      hl,#2758                ; restore alternative HL to default value
        exx
        ei
        ret

;**************************************************************************************************
rbt_ant_readorder:
        ld      hl,(rbt_ant_order)      ; get order pointer
        ld      e,(hl)                  ; read pattern offset
        inc     hl
        ld      d,(hl)
        inc     hl
        ld      (rbt_ant_order),hl
        ld      a,d                     ; if offset = 0, end of song reached
        or      e
        ret     z
        ld      hl,(rbt_ant_base)       ; relocate: offset -> absolute
        add     hl,de
        ld      (rbt_ant_ptn),hl
        ;                               ; falls through into readPtn
;**************************************************************************************************
rbt_ant_readptn:
        ld      a,#10
        ld      (rbt_ant_sw1),a
        ld      (rbt_ant_sw2),a

        ld      hl,(rbt_ant_ptn)
        ld      a,(hl)                  ; check for pattern end
        cp      #ff
        jr      z,rbt_ant_readorder

        ld      a,(hl)
        and     %11111100               ; mask lowest 2 bits
        ld      b,a                     ; speed
        ld      c,b

        ld      a,(hl)
        and     %00000011
        or      a                       ; if !=0, we have drum
        call    nz,rbt_ant_drums

rbt_ant_drdata:
        inc     hl
        xor     a
        ld      d,(hl)                  ; counter ch2
        ld      e,d
        push    hl
        ld      h,#10                   ; output mask ch2
        or      d
        jr      nz,rbt_ant_rdskip1
        ld      h,a                     ; mute if note byte = 0
rbt_ant_rdskip1
        ld      l,h                     ; swap mask
        exx
        pop     hl
        inc     hl
        ld      b,(hl)                  ; counter A
        or      b
        jr      nz,rbt_ant_rdskip2
        ld      (rbt_ant_sw1),a
        ld      (rbt_ant_sw2),a
rbt_ant_rdskip2
        ld      c,b                     ; backup counter A/B
        ld      d,b                     ; counter B
        inc     hl
        ld      (rbt_ant_ptn),hl
        ld      hl,#1000                ; output mask ch1
        exx

;**************************************************************************************************
rbt_ant_playloop:
        ld      a,h                     ;4      ;load output mask ch2

        exx                             ;4
        dec     b                       ;4      ;dec counter A
        out     (#fe),a                 ;11     ;output ch2
        jr      nz,rbt_ant_wait1               ;12/7
        ld      a,h                     ;4      ;flip output mask and restore counter
rbt_ant_sw1 equ $+1                                     ;mute switch
        xor     #10                     ;7
        ld      h,a                     ;4
        ld      b,c                     ;4
rbt_ant_skip1
        dec     d                       ;4      ;dec counter B
        ld      a,l                     ;4      ;load output mask ch1
        jr      nz,rbt_ant_wait2               ;12/7
        ld      d,c                     ;4      ;restore counter
rbt_ant_sw2 equ $+1                                     ;mute switch
        xor     #10                     ;7      ;swap output mask
        ld      l,a                     ;4

        rra                             ;4      ;increment counter to create pwm effect if output mask = #10
        rra                             ;4
        rra                             ;4
        rra                             ;4
        add     a,d                     ;4
        ld      d,a                     ;4

rbt_ant_skip2
        ld      a,l                     ;4
        and     h                       ;4      ;combine output masks
        out     (#fe),a                 ;11     ;output ch1

        exx                             ;4
        dec     d                       ;4      ;decrement counter ch1
        jp      nz,rbt_ant_wait3               ;10
        ld      d,e                     ;4      ;restore counter
        ld      a,h                     ;4      ;swap output mask
        xor     l                       ;4
        ld      h,a                     ;4

rbt_ant_skip3
        dec     bc                      ;6      ;decrement speed counter
        ld      a,b                     ;4
        or      c                       ;4
        nop                             ;4      ;take care of IO contention
        jp      nz,rbt_ant_playloop     ;10
                                        ;184
        jr      rbt_ant_readptn

;**************************************************************************************************
rbt_ant_wait1
        nop                             ;4
        jp      rbt_ant_skip1                  ;10

rbt_ant_wait2
        sla     (hl)                    ;15
        sla     (hl)                    ;15
        nop                             ;4
        jr      rbt_ant_skip2                  ;12
                                        ;46

rbt_ant_wait3
        nop                             ;4
        jr      rbt_ant_skip3                  ;12

;**************************************************************************************************
rbt_ant_drums:
        push    hl

        dec     a
        ld      hl,rbt_ant_sw2
        ld      d,#fd
        jr      z,rbt_ant_drum2
        dec     a
        ld      d,#bf
        ld      hl,rbt_ant_drdata+7
        jr      z,rbt_ant_drumloop3

rbt_ant_drum1
        ld      hl,rbt_ant_drdata

        ld      a,c                     ;timing correction
        sub     #c2
        ld      c,a
        jr      nc,rbt_ant_tskip1
        dec     b
rbt_ant_tskip1
        push    bc
        ld      b,12
rbt_ant_drum1a
        ld      a,#10
        out     (#fe),a
        ld      a,(hl)
rbt_ant_drumloop1
        dec     a
        jr      nz,rbt_ant_drumloop1
        out     (#fe),a
        ld      a,(hl)
rbt_ant_drumloop2
        dec     a
        jr      nz,rbt_ant_drumloop2
        inc     hl
        djnz    rbt_ant_drum1a
        jr      rbt_ant_drumret

rbt_ant_drum2
        dec     b                       ;timing correction
        ld      a,#d9
        ld      (rbt_ant_sw3),a         ;modify end marker value
rbt_ant_drumloop3
        ld      a,c                     ;timing correction
        sub     d
        jr      nc,rbt_ant_tskip2
        dec     b
rbt_ant_tskip2
        push    bc
rbt_ant_drumloop30
        ld      a,#10
        out     (#fe),a
rbt_ant_sw3 equ $+1
        ld      a,6
        ld      b,(hl)
        xor     b
        jr      z,rbt_ant_drumret
rbt_ant_dl3a
        push    hl
        pop     hl
        djnz    rbt_ant_dl3a
        xor     a
        out     (#fe),a
        ld      b,(hl)
rbt_ant_dl3b
        push    hl
        pop     hl
        djnz    rbt_ant_dl3b
        inc     hl
        jr      rbt_ant_drumloop30
        ld      a,6
        ld      (rbt_ant_sw3),a

rbt_ant_drumret
        pop     bc

        pop     hl
        ret

;**************************************************************************************************
rbt_ant_base
        dw 0                            ; music data base (offset relocation)

rbt_ant_order
        dw 0                            ; order pointer

rbt_ant_ptn
        dw 0                            ; pattern pointer
