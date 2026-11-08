; ============================================================================
; rbt_core_asm - Rainbow runtime core (MSX1 TMS9918 Screen 2 / MSX2 Screen 5)
; Entry point, VDP init + VRAM helpers, frame sync, pause, border, cls, RNG.
;
; Firmware-free: BIOS stays mapped in page 0 and services IM1 (#0038), so
; vsync/waitkey are plain ei+halt like the ZX core — the BIOS ISR consumes
; the VDP F flag, so we never poll it ourselves.
;
; On RBT_MSX2 builds MODE 1 selects Screen 5 (V9938 Graphic 4, 4bpp bitmap):
; every screen write then takes the *_5 paths, keyed off rbt_smode. The
; 1bpp pattern plane lives in rbt_shadow (the colour-matrix equivalent the
; bitmap modes lack) so POINT/FILLATTR keep exact ZX semantics.
;
; Screen 2 VRAM map (R0=#02 selects Graphic 2):
;   #0000-#17FF  pattern generator table  (768 patterns x8, 3 banks of 256)
;   #1800-#1AFF  name table               (32x24 cells -> pattern index)
;   #1B00-#1B7F  sprite attribute table   (32 entries x4)
;   #2000-#37FF  colour table             (8 colour bytes per pattern: fg<<4|bg)
;   #3800-#3FFF  sprite pattern table     (64 patterns x32, 16x16)
;
; The name table is initialised to identity (entry i = i mod 256), so the
; cell at row R, col C owns pattern R*32+C — a linear bitmap-like layout.
;
; Screen 5 VRAM map (MODE 1, RBT_MSX2 only — G4, M3+M4):
;   #0000-#69FF  bitmap                   (256x212, 2 pixels/byte)
;   #7400-#75FF  sprite colour table      (32 entries x16, one byte/line)
;   #7600-#767F  sprite attribute table   (32 entries x4)
;   #7800-#7FFF  sprite pattern table     (64 patterns x32)
; ============================================================================

RBT_STACK       equ #f380       ; below the BIOS work area (#f380+)

; ----------------------------------------------------------------------------
; rbt_start - entry: set stack + IM1, init VDP, run MAIN:
; ----------------------------------------------------------------------------
rbt_start:
        di
        ld      sp,RBT_STACK
        call    rbt_vdp_init
        call    rbt_cls
        im      1
        ei
        call    rb_main         ; user program entry (MAIN:)
rbt_end:
        call    rbt_sfx_drain
        halt
        call    rbt_hook_frame
        jr      rbt_end         ; program end: idle forever

; ----------------------------------------------------------------------------
; VDP port helpers. Port #98 = data, #99 = control (write: addr lo, addr
; hi|#40 selects write mode; reads return the status register).
; ----------------------------------------------------------------------------
; The #99 sequences are two-byte pairs — a status read between them
; resets the VDP's value latch and the second byte lands as a first.
; The BIOS ISR reads S0 every frame, so each pair brackets itself with
; di/ei (the ei sits inside its own enable delay, keeping ints off for
; the last out and back on for the next instruction).
rbt_vwaddr:                     ; HL = VRAM address to write
        di
        ld      a,l
        out     (#99),a
        ld      a,h
        and     #3f             ; A8-A13 only — A14+ lives in R#14 on
        or      #40             ; the V9938 (bit7 would mean register
        ei
        out     (#99),a         ; write, not address high bits)
        ret

rbt_vraddr:                     ; HL = VRAM address to read
        di
        ld      a,l
        out     (#99),a
        ld      a,h
        and     #3f
        ei
        out     (#99),a
        ret

rbt_vwrite:                     ; HL = VRAM dest, DE = source, BC = length
        call    rbt_vwaddr
        ex      de,hl           ; HL = source (DE = old dest, dead)
_vwl    ld      a,(hl)
        out     (#98),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,_vwl
        ret

rbt_vfill:                      ; A = fill byte, HL = VRAM dest, BC = count
        ld      d,a
        call    rbt_vwaddr
_vf     ld      a,d
        out     (#98),a
        dec     bc
        ld      a,b
        or      c
        jr      nz,_vf
        ret

rbt_vreg:                       ; A = value, E = register number
        di
        out     (#99),a
        ld      a,e
        or      #80
        ei
        out     (#99),a
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; 17-bit variants for Screen 5: VRAM addresses A14-A16 come from R#14, so
; these program it first (all SC5 tables live below #8000 -> R14 is 0/1).
; ----------------------------------------------------------------------------
rbt_vwaddr5:                    ; HL = VRAM address to write (17-bit)
        ld      a,h
        rlca
        rlca
        and     3               ; A14-A15
        push    de              ; vreg takes E = register number —
        ld      e,14            ; preserve DE for the caller
        call    rbt_vreg
        pop     de
        jp      rbt_vwaddr

rbt_vraddr5:                    ; HL = VRAM address to read (17-bit)
        ld      a,h
        rlca
        rlca
        and     3
        push    de
        ld      e,14
        call    rbt_vreg
        pop     de
        jp      rbt_vraddr

rbt_vfill5:                     ; A = fill byte, HL = 17-bit dest, BC = count
        ld      d,a
        call    rbt_vwaddr5
_vf     ld      a,d
        out     (#98),a
        dec     bc
        ld      a,b
        or      c
        jr      nz,_vf
        ret

rbt_vwrite5:                    ; HL = 17-bit dest, DE = source, BC = length
        call    rbt_vwaddr5
        ex      de,hl           ; HL = source (DE = old dest, dead)
_vwl    ld      a,(hl)
        out     (#98),a
        inc     hl
        dec     bc
        ld      a,b
        or      c
        jr      nz,_vwl
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_vdp_init - Screen 2 registers + identity name table + hidden sprites
; ----------------------------------------------------------------------------
rbt_vdp_init:
        ld      hl,rbt_vdpinit
        ld      e,0             ; register counter
_vr     ld      a,(hl)
        inc     hl
        call    rbt_vreg        ; di/ei-guarded two-byte register write
        inc     e
        ld      a,e
        cp      8
        jr      c,_vr
        ; name table #1800-#1AFF: identity so cell (r,c) -> pattern r*32+c
        ld      hl,#1800
        call    rbt_vwaddr
        ld      a,0
        ld      bc,#300         ; 768 entries
_nm     out     (#98),a
        inc     a               ; value wraps mod 256 per third — that's
                                ; exactly the in-third pattern index
        dec     bc
        push    af
        ld      a,b
        or      c
        jr      z,_nmdone
        pop     af
        jr      _nm
_nmdone pop     af
        ; sprite attribute table #1B00-#1B7F: y=#d1 hides every sprite
        ld      a,#d1
        ld      hl,#1b00
        ld      bc,128
        call    rbt_vfill
        ret

rbt_vdpinit:
        defb    #02             ; R0: Graphic 2 (screen 2)
        defb    #e2             ; R1: 16K VRAM, display on, INT on, 16x16 spr
        defb    #06             ; R2: name table #1800
        defb    #ff             ; R3: colour table #2000 — G2 quirk: low
                                ; bits are a size mask, not address; #ff
                                ; selects the full 6K (unmirrored) table
        defb    #03             ; R4: pattern table #0000 (same quirk)
        defb    #36             ; R5: sprite attr table #1B00
        defb    #07             ; R6: sprite pattern table #3800
        defb    #f1             ; R7: text col #f, border 1 (black)

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_vdp5_init - Screen 5 (V9938 Graphic 4): 256x212 4bpp bitmap at
; #0000-#69FF (LN=1 gives the real 212-line frame; Rainbow's coordinate
; model still draws in the top 192 rows), sprite mode 2 tables at
; #7400+ (SAT #7600), palette = MSX2 default so the rbt_zx2msx indices
; stay valid.
; ----------------------------------------------------------------------------
rbt_vdp5_init:
        ld      hl,rbt_vdp5regs
        ld      e,0
_vr     ld      a,(hl)
        inc     hl
        call    rbt_vreg        ; di/ei-guarded two-byte register write
        inc     e
        ld      a,e
        cp      8
        jr      c,_vr
        ; R8/R18 untouched — VRAM config and display adjust are machine
        ; BIOS settings, not mode state. R9 comes from the BIOS mirror
        ; with only LN set: keeps the machine's PAL/NTSC bit and
        ; interlace flags while pinning the display at 212 lines.
        ld      a,(#ffe8)       ; RG9SAV (R8-R23 BIOS mirrors: #ffe7+)
        or      #80             ; LN=1 -> 212-line display
        ld      e,9
        call    rbt_vreg
        xor     a
        ld      e,23
        call    rbt_vreg        ; R23: vertical scroll 0
        xor     a
        ld      e,26
        call    rbt_vreg        ; R26/R27: horizontal scroll 0 (stale
        xor     a               ; values from a previous mode/program
        ld      e,27            ; would shift the bitmap window)
        call    rbt_vreg
        ; palette: R#16 = index 0, then 16 x (0RRR0BBB, 00000GGG)
        xor     a
        ld      e,16
        call    rbt_vreg
        ld      bc,#209a        ; 32 bytes -> port #9A
        ld      hl,rbt_pal
_pal    outi
        jr      nz,_pal
        ; sprite tables: SCT clear, SAT hide (mode 2 terminator = 216)
        xor     a
        ld      hl,#7400
        ld      bc,512
        call    rbt_vfill5
        ld      a,216
        ld      hl,#7600
        ld      bc,128
        jp      rbt_vfill5

rbt_vdp5regs:
        defb    #06             ; R0: M3+M4 = Graphic 4 (screen 5)
        defb    #62             ; R1: display on, INT on, 16x16 sprites
        defb    #1f             ; R2: display base page 0 — bitmap modes
                                ; reuse the name-table reg; its unused
                                ; low bits are an address mask and must
                                ; be 1 (same quirk as SC2's R3=#ff)
        defb    #00             ; R3: unused
        defb    #00             ; R4: unused
        defb    #ec             ; R5: sprite attr table #7600 (R11=0)
        defb    #0f             ; R6: sprite pattern table #7800
        defb    #f1             ; R7: border colour (low nibble)

; MSX2 default palette — the same colours the TMS9918's fixed set uses,
; so rbt_zx2msx indices mean the same thing on both modes. Each entry
; is 0RRR0BBB then 00000GGG.
rbt_pal:
        defb    #00,#00,#00,#00,#11,#06,#33,#07
        defb    #17,#01,#27,#03,#51,#01,#27,#06
        defb    #71,#01,#73,#03,#61,#06,#63,#06
        defb    #11,#04,#55,#02,#55,#05,#77,#07
        endif

; ----------------------------------------------------------------------------
; rbt_vsync - wait for the next frame interrupt (BIOS ISR services it).
; Bumps rbt_framectr (RANDOMIZE's seed source — MSX has no ROM sysvar).
; ----------------------------------------------------------------------------
rbt_vsync:
        call    rbt_sfx_drain   ; play any queued effect during the idle gap
        ld      hl,(rbt_framectr)
        inc     hl
        ld      (rbt_framectr),hl
        in      a,(#99)         ; read VDP S0 — clears any pending INT, or a
                                ; mid-frame interrupt would return instantly
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
_ploop  in      a,(#99)         ; clear pending INT before the wait
        halt
        call    rbt_hook_frame
        djnz    _ploop
        ret

; ----------------------------------------------------------------------------
; rbt_kbd_any - PPI matrix quick scan. Out: A = #ff when nothing is held,
; the row's column byte (some bit clear) when a key is down. The #ff-for-
; none convention matches the column reads — rbt_waitkey and rbt_anykey
; both test against it.
; ----------------------------------------------------------------------------
rbt_kbd_any:
        di                      ; BIOS ISR also scans the PPI — keep the
                                ; row select ours for the whole sweep
        in      a,(#aa)
        and     #f0
        ld      d,a             ; D = port C upper bits (CAPS/cassette)
        ld      b,11            ; matrix rows 0-10
        ld      e,0
_rl     ld      a,d
        or      e
        out     (#aa),a         ; select row on port C low nibble
        in      a,(#a9)         ; columns on port B
        cp      #ff
        jr      nz,_hit
        inc     e
        djnz    _rl
        ei
        ret                     ; A = #ff: nothing held
_hit    ei
        ret                     ; A = column bits (nonzero)

; ----------------------------------------------------------------------------
; rbt_waitkey - block until any key is pressed (50/60Hz polling so the AY
; music hook keeps ticking while waiting)
; ----------------------------------------------------------------------------
rbt_waitkey:
        call    rbt_sfx_drain
_wk     halt
        call    rbt_hook_frame
        call    rbt_kbd_any
        cp      #ff
        jr      z,_wk
_rel    call    rbt_kbd_any     ; wait for release
        cp      #ff
        jr      nz,_rel
        ret

; ----------------------------------------------------------------------------
; rbt_border - set border to A (ZX colour 0-7, mapped to the MSX palette).
; VDP register 7: high nibble = text colours (unused in screen 2), low
; nibble = backdrop/border. Shadow byte keeps the high nibble stable.
; ----------------------------------------------------------------------------
rbt_border:
        and     7
        ld      e,a
        ld      d,0
        ld      hl,rbt_zx2msx
        add     hl,de
        ld      a,(hl)          ; MSX colour nibble
        ld      e,a
        ld      a,(rbt_vdp7)
        and     #f0
        or      e
        ld      (rbt_vdp7),a
        ld      e,7
        jp      rbt_vreg

; ----------------------------------------------------------------------------
; rbt_scrmode - select screen mode (A = logical mode: 0 = Screen 2,
; 1 = Screen 5). A real switch on MSX2 — the new mode's engine is then
; reinitialised, the screen cleared, and rbt_hook_mode lets the sprite
; module re-upload its tables. No-op on MSX1.
; ----------------------------------------------------------------------------
rbt_scrmode:
        if      RBT_MSX2
        and     1
        ld      hl,rbt_smode
        cp      (hl)
        ret     z               ; already in that mode
        ld      (hl),a
        or      a
        jr      nz,_m5
        call    rbt_vdp_init    ; mode 0: back to Screen 2
        jr      _sw
_m5     call    rbt_vdp5_init   ; mode 1: Screen 5
_sw     call    rbt_cls
        jp      rbt_hook_mode
        else
        ret
        endif

; ----------------------------------------------------------------------------
; rbt_colbyte - rbt_attr (ZX FBPPPIII) -> A = MSX colour byte (fg<<4|bg).
; FLASH swaps the nibbles while rbt_framectr bit5 is set (no hardware
; flash on MSX — toggling fg/bg every 32 frames is the same trick).
; ----------------------------------------------------------------------------
rbt_zx2msx:
        defb    1,4,6,13,12,7,10,14     ; ink: black blue red mag grn cyn yel gry
        defb    1,5,9,13,3,7,11,15      ; bright: ltblue ltred ltgrn ltyel wht

rbt_colbyte:
        ld      a,(rbt_attr)
        ld      e,a
        and     7               ; ink 0-2
        ld      c,a
        ld      a,e
        and     #40             ; bright bit6 -> index bit3
        rrca
        rrca
        rrca
        or      c
        ld      hl,rbt_zx2msx
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)          ; fg nibble
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        ld      c,a             ; fg<<4
        ld      a,(rbt_attr)
        rrca
        rrca
        rrca
        and     #0f             ; paper bits3-5 | bright->bit3
        ld      hl,rbt_zx2msx
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)
        or      c               ; A = fg<<4 | bg
        ld      e,a
        ld      a,(rbt_attr)
        and     #80
        jr      z,_nf
        ld      a,(rbt_framectr)
        and     #20             ; ~1.5 Hz nibble swap while FLASH set
        jr      z,_nf
        ld      a,e
        rrca
        rrca
        rrca
        rrca
        ld      e,a
_nf     ld      a,e
        ret

; ----------------------------------------------------------------------------
; rbt_cls - clear the pattern table and re-fill the colour table with the
; current attribute colour, home the cursor. (Name table stays identity.)
; ----------------------------------------------------------------------------
rbt_cls:
        if      RBT_MSX2
        ld      a,(rbt_smode)
        or      a
        jr      nz,rbt_cls5
        endif
        xor     a
        ld      hl,#0000
        ld      bc,#1800        ; 6144 pattern bytes
        call    rbt_vfill
        call    rbt_colbyte
        ld      hl,#2000
        ld      bc,#1800        ; 6144 colour bytes
        call    rbt_vfill
        xor     a
        ld      (rbt_col),a
        ld      (rbt_row),a
        ret

        if      RBT_MSX2
; ----------------------------------------------------------------------------
; rbt_cls5 - Screen 5 cls: fill the bitmap with solid paper (bg nibble in
; both pixels) and clear the shadow pattern plane.
; ----------------------------------------------------------------------------
rbt_cls5:
        call    rbt_colbyte     ; A = fg<<4|bg
        and     #0f             ; bg nibble
        ld      b,a
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        or      b               ; A = bg<<4|bg (solid paper)
        ld      hl,#0000
        ld      bc,#6a00        ; 212 rows x 128 bytes
        call    rbt_vfill5
        ld      hl,rbt_shadow   ; clear the 1bpp shadow plane
        ld      (hl),0
        ld      de,rbt_shadow+1
        ld      bc,6143
        ldir
        xor     a
        ld      (rbt_col),a
        ld      (rbt_row),a
        ret

; ----------------------------------------------------------------------------
; rbt_xpnib - expand one 1bpp pattern byte into four SC5 VRAM bytes.
; In: A = pattern byte, C = fg<<4|bg colour. Bit set -> fg nibble, bit
; clear -> bg nibble; left pixel is the high nibble. Writes to port #98
; (destination pre-addressed). Clobbers A,B,C,D,H.
; ----------------------------------------------------------------------------
rbt_xpnib:
        ld      d,a             ; D = pattern
        ld      h,c             ; H = fg<<4|bg
        ld      b,4             ; four output bytes
_xp     sla     d               ; left pixel of the pair
        ld      a,h
        jr      c,_f0
        add     a,a
        add     a,a
        add     a,a
        add     a,a             ; bg<<4
        and     #f0
        jr      _n0
_f0     and     #f0             ; fg<<4
_n0     ld      c,a
        sla     d               ; right pixel
        ld      a,h
        jr      c,_f1
        and     #0f             ; bg already sits in the low nibble
        jr      _n1
_f1     rrca
        rrca
        rrca
        rrca                    ; fg<<4|bg -> fg into the low nibble
        and     #0f
_n1     or      c
        out     (#98),a
        djnz    _xp
        ret
        endif

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
; ----------------------------------------------------------------------------
; rbt_psg - write PSG register: E = reg, D = data. Preserves all regs.
; ----------------------------------------------------------------------------
rbt_psg:
        push    af
        di                      ; BIOS ISR also touches the PSG
        ld      a,e
        out     (#a0),a
        ld      a,d
        out     (#a1),a
        ei
        pop     af
        ret

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
rbt_framectr    defw 0          ; frame counter, bumped each rbt_vsync
rbt_dataptr     defw 0          ; READ pointer (set to rbd_data by compiler)
rbt_col         defb 0          ; PRINT cursor column (charset)
rbt_row         defb 0          ; PRINT cursor row (charset)
rbt_over        defb 0          ; 0 = normal, 1 = invert (OVER)
rbt_attr        defb #38        ; current attr: ink|paper<<3|bright<<6|flash<<7
rbt_vdp7        defb #f1        ; VDP reg7 shadow (border/text colours)
        if      RBT_MSX2
rbt_smode       defb 0          ; screen mode: 0 = Screen 2, 1 = Screen 5
; 1bpp shadow of the SC5 pattern plane (cell idx*8 + line, like Screen
; 2's pattern table layout). Every SC5 draw writes it alongside VRAM;
; POINT tests bits here and FILLATTR repaints from it — the attr-cell
; semantics bitmap modes can't offer in hardware.
rbt_shadow      defs 6144
        endif
