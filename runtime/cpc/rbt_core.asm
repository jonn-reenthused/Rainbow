; ============================================================================
; rbt_core_asm - Rainbow runtime core (Amstrad CPC)
; Entry point, frame sync, pause, border, cls, mode, RNG, waitkey.
;
; Firmware-backed: runs inside the firmware environment created by the CDT
; BASIC loader (pasmo --cdtbas -> CALL <org>). IM1 + EI are kept so the ROM
; ISR at &0038 keeps scanning the keyboard and driving the sound queue.
; The stack is inherited from the firmware - do NOT relocate it (system
; variables live above &A700).
; ============================================================================

FW_TXT_OUTPUT   equ #bb5a       ; TXT OUTPUT        A = char
FW_TXT_SET_COL  equ #bb6f       ; TXT SET COLUMN    A = column (1-based)
FW_TXT_SET_ROW  equ #bb72       ; TXT SET ROW       A = row (1-based)
FW_TXT_SET_PEN  equ #bb90       ; TXT SET PEN       A = pen number
FW_TXT_SET_PAP  equ #bb96       ; TXT SET PAPER     A = pen number
FW_KM_WAIT_CHAR equ #bb18       ; KM WAIT CHAR      -> A = char
FW_KM_READ_CHAR equ #bb09       ; KM READ CHAR      -> carry? A = char
FW_SCR_SET_OFF  equ #bc05       ; SCR SET OFFSET    HL = scroll offset
FW_SCR_SET_BASE equ #bc08       ; SCR SET BASE      A = base page (#c0 -> #c000)
FW_SCR_SET_MODE equ #bc0e       ; SCR SET MODE      A = mode 0-2
FW_SCR_CLEAR    equ #bc14       ; SCR CLEAR
FW_SCR_SET_INK  equ #bc32       ; SCR SET INK       A=pen B=ink1 C=ink2
FW_SCR_SET_BORD equ #bc38       ; SCR SET BORDER    B=C = ink
FW_MC_WAIT_FLY  equ #bd19       ; MC WAIT FLYBACK   preserves all regs
FW_KL_FAST_TK   equ #bce0       ; KL NEW FAST TICKER HL=blk B=cls C=rom DE=rtn

; ----------------------------------------------------------------------------
; ZX colour index (0-7) -> CPC hardware ink. Keeps BORDER/INK/PAPER values
; portable: INK 7 gives white text on both machines.
; ----------------------------------------------------------------------------
rbt_zx2cpc:     defb 0,1,3,4,9,10,12,13

rbt_start:
        if      RBT_CART
        ; cart boot (CPC+/GX4000): no firmware at all — the preamble set
        ; the stack and disabled interrupts; banks come off cart pages
        ; and the screen needs an explicit mode+clear
        call    rbt_crtc_init   ; GX4000 boots with a dead CRTC — program
                                ; the standard firmware video setup or
                                ; port B never sees a vsync
        call    rbt_ink_init    ; GA pens also start indeterminate — apply
                                ; the firmware default ink table
        call    rbt_bankload    ; cart pages -> RAM banks (stub if unbanked)
        call    rbt_scr_home
        ld      a,1
        call    rbt_scrmode     ; mode 1, the BASIC loader's default
        call    rbt_cls
        else
        ei                      ; firmware ISR is already IM1 at &0038
        call    rbt_bankload    ; cpc6128: pull BANKn.BIN files into RAM
                                ; banks (stubbed to ret on unbanked builds)
        call    rbt_scr_home    ; undo any firmware text scroll (loader msgs)
        endif
        call    rb_main         ; user program entry (MAIN:)
rbt_end:
        if      RBT_CART
        call    rbt_sfx_drain   ; no BASIC to return to — idle loop that
        call    rbt_wfly        ; keeps the 50Hz frame hooks ticking
        call    rbt_hook_frame
        jr      rbt_end
        else
        ret                     ; back to the BASIC loader / prompt
        endif

; ----------------------------------------------------------------------------
; rbt_vsync - wait for frame flyback (50 Hz), then run the frame hooks
; ----------------------------------------------------------------------------
        if      RBT_CART
; ----------------------------------------------------------------------------
; rbt_wfly - wait for frame flyback by polling the CRTC VSYNC flag on
; PPI port B bit 0 (cart builds: MC WAIT FLYBACK doesn't exist).
; ----------------------------------------------------------------------------
rbt_wfly:
        ld      bc,#f500
_wf0   in      a,(c)
        rra
        jr      c,_wf0          ; still in vsync -> wait it out
_wf1   in      a,(c)
        rra
        jr      nc,_wf1         ; wait for the next vsync
        ret

; ----------------------------------------------------------------------------
; rbt_gpen - program a gate-array pen directly (no firmware).
;   In: A = pen (0-15; 16 = border), D = ink1, E = ink2. Consecutive INKR
;   writes store the pair and the GA alternates them (hardware flash).
; ----------------------------------------------------------------------------
rbt_gpen:
        push    bc
        ld      bc,#7f00
        out     (c),a           ; PENR: select pen
        ld      a,d
        or      #40
        out     (c),a           ; INKR: ink1
        ld      a,e
        or      #40
        out     (c),a           ; INKR: ink2
        pop     bc
        ret

; ----------------------------------------------------------------------------
; rbt_kbd_any - A = 1 while any matrix key (incl. joystick line 9) is down.
; Lives in core (not input) because cart rbt_waitkey calls it even when
; the program never touches INKEY/JOYSTICK.
; ----------------------------------------------------------------------------
rbt_kbd_any:
        ld      e,0             ; E = line
_kal    ld      a,e
        push    de
        call    rbt_kbd_scan
        pop     de
        inc     a               ; #ff -> 0 = line clear
        jr      nz,_kay
        inc     e
        ld      a,e
        cp      10
        jr      c,_kal
        xor     a
        ret
_kay    ld      a,1
        ret

; ----------------------------------------------------------------------------
; rbt_crtc_init - program the CRTC with the standard firmware display
; setup (50Hz PAL, 25 text rows, screen at #C000). On a cart nothing else
; programs it: the GX4000 has no firmware and a bare CPC+ boots the cart
; before the firmware initialisation runs.
; ----------------------------------------------------------------------------
rbt_crtc_init:
        ld      e,0             ; E = register number
        ld      hl,rbt_crtc_def
_ci     ld      bc,#bc00
        out     (c),e           ; select reg E
        ld      a,(hl)
        inc     hl
        ld      bc,#bd00
        out     (c),a           ; write data
        inc     e
        ld      a,e
        cp      16
        jr      c,_ci
        ret

; CRTC regs 0-15: the values the CPC firmware uses — 63,40,46,#8E,38,0,
; 25,30,0,7 + cursor/screen-base regs (12=#30 -> display at #C000).
rbt_crtc_def:
        defb    63,40,46,#8e,38,0,25,30,0,7,0,0,#30,0,0,0

; ----------------------------------------------------------------------------
; rbt_ink_init - apply the firmware default pen table. Without firmware the
; GA colour registers hold whatever the ASIC powered up with (black on a
; GX4000), so a cart that never calls INK/PAPER/BORDER would be invisible.
; ----------------------------------------------------------------------------
rbt_ink_init:
        ld      hl,rbt_ink_def
        xor     a               ; A = pen 0..15
_ii     push    af
        ld      d,(hl)
        ld      e,d             ; same ink twice -> no hardware flash
        call    rbt_gpen
        inc     hl
        pop     af
        inc     a
        cp      16
        jr      c,_ii
        ld      a,16            ; border pen
        ld      de,#0404        ; firmware default border = ink 4 (blue)
        jp      rbt_gpen

rbt_ink_def:
        defb    4,24,20,6,26,0,2,8,10,12,14,16,18,22,1,30
        endif

rbt_vsync:
        call    rbt_sfx_drain   ; no-op stub when SFX module absent
        if      RBT_CART
        call    rbt_wfly
        else
        call    FW_MC_WAIT_FLY
        endif
        call    rbt_hook_frame
        ret

; ----------------------------------------------------------------------------
; rbt_pause - pause for B frames (B=0 waits for a keypress)
; ----------------------------------------------------------------------------
rbt_pause:
        call    rbt_sfx_drain
        ld      a,b
        or      a
        jr      z,rbt_waitkey
_ploop
        if      RBT_CART
        call    rbt_wfly
        else
        call    FW_MC_WAIT_FLY
        endif
        call    rbt_hook_frame
        djnz    _ploop
        ret

; ----------------------------------------------------------------------------
; rbt_waitkey - block until a key is pressed (firmware key manager; cart
; builds poll the matrix directly, frame-paced so the hooks still tick)
; ----------------------------------------------------------------------------
rbt_waitkey:
        call    rbt_sfx_drain
        if      RBT_CART
_wk     call    rbt_wfly
        call    rbt_hook_frame
        call    rbt_kbd_any
        or      a
        jr      z,_wk
_wkr    call    rbt_kbd_any     ; then wait for the release
        or      a
        jr      nz,_wkr
        else
        call    FW_KM_WAIT_CHAR ; needs EI: firmware ISR scans the matrix
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_border - set border to A (ZX colour 0-7, mapped to CPC ink)
; ----------------------------------------------------------------------------
rbt_border:
        and     7
        ld      hl,rbt_zx2cpc
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        if      RBT_CART
        ld      d,a             ; border = GA pen 16, ink1=ink2
        ld      e,a
        ld      a,16
        jp      rbt_gpen
        else
        ld      b,a
        ld      c,a
        call    FW_SCR_SET_BORD
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_scrmode - select CPC graphics mode (A = 0-2). Real switch on CPC;
; the ZX runtime implements this label as a no-op. Cart: the RMR byte is
; #88|mode — upper ROM off, lower ROM (our cart page) on.
; ----------------------------------------------------------------------------
rbt_scrmode:
        and     3
        if      RBT_CART
        or      #88
        ld      (rbt_rmr),a
        ld      bc,#7f00
        out     (c),a
        else
        call    FW_SCR_SET_MODE
        endif
        ret

; ----------------------------------------------------------------------------
; rbt_scr_home - reset CRTC screen base/offset to RBT_SCRB+0. Firmware text
; scrolling moves the display origin, which would shear our pixel writes.
; RBT_SCRP is the compiler-emitted base page (#c0 = screen at #C000, the
; only 16k window the 6128's c4-c7 configs never remap).
; ----------------------------------------------------------------------------
rbt_scr_home:
        xor     a
        ld      (rbt_scr_soff),a
        ld      (rbt_scr_soff+1),a      ; clear the hardware scroll offset
        if      RBT_CART
        ; CRTC regs 12/13 hold the display start in 2-byte units — #3000
        ; is the #c000 screen (RBT_SCRP is always #c0 on this runtime).
        ld      bc,#bc0c
        out     (c),c
        ld      bc,#bd30
        out     (c),c
        ld      bc,#bc0d
        out     (c),c
        ld      bc,#bd00
        out     (c),c
        ret
        else
        ld      hl,0
        call    FW_SCR_SET_OFF
        ld      a,RBT_SCRP
        jp      FW_SCR_SET_BASE
        endif

; ----------------------------------------------------------------------------
; rbt_crtc_r1213 - set the CRTC display start. HL = offset in CRTC units
; (2 bytes each, 0-1023) added to the #C000 base. No di/ei: callers bracket
; it (the split ISR already runs with interrupts masked).
; ----------------------------------------------------------------------------
rbt_crtc_r1213:
        push    bc
        ld      bc,#bc0c
        out     (c),c           ; select R12
        ld      a,h
        and     #03
        or      #30             ; page #C000 -> #30xx
        ld      bc,#bd00
        out     (c),a
        ld      bc,#bc0d
        out     (c),c           ; select R13
        ld      bc,#bd00
        out     (c),l
        pop     bc
        ret

; ----------------------------------------------------------------------------
; rbt_split_install - hang the band-split routine off the firmware fast
; ticker (fires on every GA raster interrupt). Idempotent. The cartridge
; build has no firmware events - static bands are unsupported there.
; ----------------------------------------------------------------------------
        if      RBT_CART
rbt_split_install:
        ret
        else
rbt_split_install:
        ld      a,(rbt_int_on)
        or      a
        ret     nz
        inc     a
        ld      (rbt_int_on),a
        ld      hl,rbt_evblk
        ld      b,#c1           ; class: async + express + near -> runs on
                                ; the interrupt path, central-32K routine
        xor     a
        ld      c,a             ; rom select (unused for near events)
        ld      de,rbt_split_isr
        jp      FW_KL_FAST_TK
        endif

rbt_evblk       defs 10         ; firmware event block (must sit in central RAM)

; hardware-scroll state (core: laddr/sprite code may link without tmdata)
rbt_scr_soff    defw 0          ; CRTC scroll offset in bytes (0-2047)
rbt_scr_split   defb 0          ; band split char row (0 = whole screen scrolls)
rbt_scr_son     defb 0          ; 1 = scrolled addressing active
rbt_scr_woff    defw 0          ; last scrolled laddr band offset (wrap math)
rbt_scr_wnat    defb 0          ; 1 = last laddr came out natural (band row)
rbt_split_int   defb 0          ; raster-int index that triggers the split
rbt_int_cnt     defb 0          ; int counter inside rbt_split_isr
rbt_int_on      defb 0          ; 1 = split ticker installed

; ----------------------------------------------------------------------------
; rbt_split_isr - fast-ticker routine, called on every GA raster interrupt
; (~6 per frame). The int that falls inside vertical sync re-writes the
; scrolled display start so each frame opens with the world offset; the int
; indexed by rbt_split_int (inside the char row above the band) restores the
; natural start so rows >= rbt_scr_split stay static.
; ----------------------------------------------------------------------------
rbt_split_isr:
        push    af
        push    bc
        push    hl
        ld      bc,#f500
        in      a,(c)           ; PPI port B bit 0 = vertical sync
        and     1
        jr      z,_sinv
        ; inside vsync (one int, maybe two if the counter straddles it):
        ; reset the frame counter and re-apply the scrolled display start
        ; so the next frame opens with the world offset. Idempotent.
        xor     a
        ld      (rbt_int_cnt),a
        ld      hl,(rbt_scr_soff)
        srl     h
        rr      l               ; bytes -> CRTC units
        call    rbt_crtc_r1213
        jr      _sio
_sinv   ld      a,(rbt_int_cnt)
        inc     a
        ld      (rbt_int_cnt),a
        cp      6
        jr      c,_sick
        xor     a               ; lost frame sync - clamp the counter
        ld      (rbt_int_cnt),a
        jr      _sio
_sick   ld      b,a
        ld      a,(rbt_split_int)
        or      a
        jr      z,_sio          ; no split armed
        cp      b
        jr      nz,_sio
        ld      a,(rbt_scr_split)
        or      a
        jr      z,_sio
        ld      l,a
        ld      h,0
        add     hl,hl
        add     hl,hl
        add     hl,hl           ; *8
        ld      d,h
        ld      e,l
        add     hl,hl
        add     hl,hl           ; *32
        add     hl,de           ; split row * 40 = band offset in CRTC units
        call    rbt_crtc_r1213
_sio    pop     hl
        pop     bc
        pop     af
        ret

; ----------------------------------------------------------------------------
; rbt_cls - clear screen (firmware; cart: fill the 16K screen with pen 0)
; and home our logical cursor
; ----------------------------------------------------------------------------
rbt_cls:
        call    rbt_scr_home
        if      RBT_CART
        ld      hl,#c000
        ld      de,#c001
        ld      bc,#3fff
        ld      (hl),0
        ldir
        else
        call    FW_SCR_CLEAR
        endif
        call    rbt_sp_reset    ; sprite commits are stale (stub if unused)
        xor     a
        ld      (rbt_col),a
        ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_rnd8 - 8-bit Galois LFSR. Out: A = pseudo-random byte
; ----------------------------------------------------------------------------
rbt_rnd8:
        ld      a,(rbt_seed)
        add     a,a
        jr      nc,_no_xor
        xor     #1d
_no_xor ld      (rbt_seed),a
        ret

; ----------------------------------------------------------------------------
; rbt_mod8 - A = A mod B (unsigned). Clobbers C,E.
; ----------------------------------------------------------------------------
rbt_mod8:
        ld      c,a
        xor     a
        ld      e,a             ; E = quotient
        ld      a,c
_dl     cp      b
        jr      c,_done
        sub     b
        inc     e
        jr      _dl
_done   ret                     ; A = remainder

; ----------------------------------------------------------------------------
; rbt_psg - write an AY register through the 8255 PPI.
;   In: E = register (0-15), D = data. Clobbers A,B,C.
;   DI/EI bracket the transaction so the firmware ISR cannot retarget the
;   PSG register select mid-write. Port C low nibble stays 0 (the
;   keyboard decoder line rbt_kbd_scan also leaves selected).
; ----------------------------------------------------------------------------
rbt_psg:
        di
        ld      bc,#f782        ; PPI control: port A = output. The firmware
        out     (c),c           ; keyboard scanner leaves port A in input mode
                                ; after its ISR pass, which would silently drop
                                ; every write below until something re-outputs it.
        ld      b,#f4
        out     (c),e           ; PPI port A = register number
        ld      bc,#f6c0
        out     (c),c           ; PSG op: latch register
        ld      bc,#f600
        out     (c),c           ; PSG op: inactive
        ld      b,#f4
        out     (c),d           ; PPI port A = data
        ld      bc,#f680
        out     (c),c           ; PSG op: write data
        ld      bc,#f600
        out     (c),c           ; inactive
        ei
        ret

; ----------------------------------------------------------------------------
; data
; ----------------------------------------------------------------------------
        if      RBT_CART
rbt_rmr         defb #89        ; RMR shadow: upper ROM off, lower ROM (cart
                                ; page) on, mode 1 — RMR writes must preserve
                                ; LR=0 or this code vanishes mid-execution
        endif
rbt_seed        defw #ace1
rbt_dataptr     defw 0          ; READ pointer (set to rbd_data by compiler)
rbt_col         defb 0          ; PRINT cursor column (charset)
rbt_row         defb 0          ; PRINT cursor row (charset)
rbt_over        defb 0          ; written by OVER stmt (unused on CPC yet)
rbt_attr        defb #38        ; current attr byte (charset INK/PAPER state)
