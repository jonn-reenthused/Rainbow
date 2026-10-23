; ============================================================================
; rbt_core_asm - Rainbow runtime core
; Entry point, stack setup, frame sync, pause, border, cls, RNG, waitkey.
; Included by generated main_asm (single concatenated assembly).
; Preserves IY for the ROM interrupt (IM1) - user ASM blocks should too.
; ============================================================================

RBT_STACK       equ #7ffe       ; stack top (bank 5 free RAM, always mapped)

rbt_start:
        di
        ld      sp,RBT_STACK
        im      1
        ei
        call    rb_main         ; user program entry (MAIN:)
rbt_end:
        call    rbt_sfx_drain
        halt
        call    rbt_hook_frame
        jr      rbt_end         ; program end: idle forever

; ----------------------------------------------------------------------------
; rbt_vsync - wait for the next frame interrupt (HALT)
; ----------------------------------------------------------------------------
rbt_vsync:
        call    rbt_sfx_drain   ; play any queued effect during the idle gap
        halt
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
_ploop  halt
        call    rbt_hook_frame
        djnz    _ploop
        ret

; ----------------------------------------------------------------------------
; rbt_waitkey - block until any key is pressed (50Hz polling so the AY
; music hook keeps ticking while waiting)
; ----------------------------------------------------------------------------
rbt_waitkey:
        call    rbt_sfx_drain
_wk     halt
        call    rbt_hook_frame
        xor     a
        in      a,(#fe)         ; all half-rows
        cpl
        and     #1f
        jr      z,_wk
_rel    xor     a               ; wait for release
        in      a,(#fe)
        cpl
        and     #1f
        jr      nz,_rel
        ret

; ----------------------------------------------------------------------------
; rbt_border - set border to A (0-7)
; ----------------------------------------------------------------------------
rbt_border:
        and     7
        out     (#fe),a
        rlca                    ; BORDCR wants border in bits 3-5
        rlca
        rlca
        ld      (#5c48),a
        ret

; ----------------------------------------------------------------------------
; rbt_scrmode - select hardware screen mode (A = mode). The ZX has a single
; fixed 256x192 mode so this is a no-op; the CPC and C64 runtimes provide real
; implementations (CPC: GA/CRTC mode 0-2, C64: hires/multicolour bitmap).
; ----------------------------------------------------------------------------
rbt_scrmode:
        ret

; ----------------------------------------------------------------------------
; rbt_cls - clear bitmap, fill attributes with rbt_attr, home cursor
; ----------------------------------------------------------------------------
rbt_cls:
        ld      hl,#4000
        ld      de,#4001
        ld      bc,#17ff
        ld      (hl),0
        ldir
        ld      hl,#5800
        ld      de,#5801
        ld      bc,#02ff
        ld      a,(rbt_attr)
        ld      (hl),a
        ldir
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
; data
; ----------------------------------------------------------------------------
rbt_seed        defw #ace1
rbt_dataptr     defw 0          ; READ pointer (set to rbd_data by compiler)
rbt_col         defb 0          ; PRINT cursor column (charset)
rbt_row         defb 0          ; PRINT cursor row (charset)
rbt_over        defb 0          ; 0 = normal, 1 = invert (OVER)
rbt_attr        defb #38        ; current attr: ink|paper<<3|bright<<6|flash<<7
                                ; (rbt_cls fills the attr plane with this;
                                ;  charset's INK/PAPER/BRIGHT/FLASH update it)
