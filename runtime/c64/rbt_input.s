; ============================================================================
; rbt_input - CIA1 keyboard matrix + joystick (Commodore 64, ca65)
;
; KEY(n)/INKEY codes are ZX-layout codes (row*8 + bit, same numbers the
; Spectrum runtime uses) so sources port unchanged — rbt_key maps them
; onto the C64 matrix via rbt_zx2cbm. Matrix: driving ~(1<<col) onto
; $DC00 (port A) grounds that column; $DC01 (port B) reads the 8 row
; lines active-low:
;   col 0: DEL RETURN CUR-RL F7 F1 F3 F5 CUR-UD
;   col 1: 3 W A 4 Z S E LSHIFT
;   col 2: 5 R D 6 C F T X
;   col 3: 7 Y G 8 B H U V
;   col 4: 9 I J 0 M K O N
;   col 5: + P L - . : @ ,
;   col 6: £ * ; HOME RSHIFT = ^ /
;   col 7: 1 <- CTRL 2 SPACE C= Q STOP
;
; Port pokes are SEI-guarded: the kernal IRQ drives $DC00 for its own scan.
; ============================================================================

        .code

rbt_joymode:     .byte 0         ; kept for source compat; C64 JOY always
                                ; reads port 2 ($DC00) regardless of mode

; ----------------------------------------------------------------------------
; rbt_anykey - A = 1 if any matrix key is pressed
; ----------------------------------------------------------------------------
rbt_anykey:
        sei
        jsr     rbt_mapio
        lda     #0
        sta     $dc00           ; all columns selected
        lda     $dc01
        jsr     rbt_maprun
        cli
        eor     #$ff
        beq     @no
        lda     #1
@no:    rts

; ----------------------------------------------------------------------------
; rbt_key - test one key. In: A = ZX code (row<<3 | bit). Out: A = 1/0.
; ----------------------------------------------------------------------------
rbt_key:
        tax
        lda     rbt_zx2cbm,x
        bmi     @no             ; no C64 equivalent -> never pressed
        sta     rbt_t0          ; C64 matrix code (col<<3 | rowbit)
        and     #7
        sta     rbt_t1          ; row bit index
        lda     rbt_t0
        lsr     a
        lsr     a
        lsr     a               ; column 0-7
        tax
        lda     #1
@m:     dex
        bmi     @sel
        asl     a
        jmp     @m
@sel:   eor     #$ff            ; active-low column mask
        sei
        jsr     rbt_mapio
        sta     $dc00
        lda     $dc01
        jsr     rbt_maprun
        cli
        ; shift bit (row index) into carry
        ldx     rbt_t1
        inx
@sh:    lsr     a
        dex
        bne     @sh
        lda     #0
        bcs     @np             ; bit was 1 -> not pressed
        lda     #1
@np:    rts
@no:    lda     #0
        rts

; ----------------------------------------------------------------------------
; rbt_inkey - scan matrix, return ASCII of first pressed key (or 0)
; ----------------------------------------------------------------------------
rbt_inkey:
        lda     #0
        sta     rbt_t1          ; code
@scan:  lda     rbt_t1
        jsr     rbt_key
        bne     @found
        inc     rbt_t1
        lda     rbt_t1
        cmp     #64
        bcc     @scan
        lda     #0
        rts
@found: ldx     rbt_t1
        lda     rbt_keymap,x
        rts

; ----------------------------------------------------------------------------
; rbt_joy - read joystick port 2 ($DC00). Port A is normally an output for
; the keyboard scan, so DDRA is switched to input, read, restored.
; Out: A = bitmask %000FUDLR (fire,up,down,left,right)
; ----------------------------------------------------------------------------
rbt_joy:
        sei
        jsr     rbt_mapio
        lda     $dc02           ; DDRA
        pha
        lda     #0
        sta     $dc02           ; port A -> input
        lda     $dc00           ; bits: 0=up 1=down 2=left 3=right 4=fire
        tax                     ; stash in X via stack
        pla
        sta     $dc02
        jsr     rbt_maprun
        cli
        txa
        eor     #$ff
        and     #$1f            ; raw: %000FRLDU (active bits now 1)
        ; rearrange to %000FUDLR: up bit0->3, down bit1->2 (stays),
        ; left bit2->1, right bit3->0, fire bit4 stays
        sta     rbt_t0
        and     #$10            ; fire already in place
        sta     rbt_t1
        lda     rbt_t0
        and     #1              ; up -> bit3
        asl     a
        asl     a
        asl     a
        ora     rbt_t1
        sta     rbt_t1
        lda     rbt_t0
        and     #2              ; down -> bit2 (already right)
        ora     rbt_t1
        sta     rbt_t1
        lda     rbt_t0
        and     #4              ; left -> bit1
        lsr     a
        ora     rbt_t1
        sta     rbt_t1
        lda     rbt_t0
        and     #8              ; right -> bit0
        lsr     a
        lsr     a
        lsr     a
        ora     rbt_t1
        rts

; ----------------------------------------------------------------------------
; ZX code -> C64 matrix code (col*8 + rowbit; $ff = no such key).
; ZX codes are row*8+bit over the Spectrum layout: row0 SHIFT-ZXCV,
; row1 A-G, row2 Q-T, row3 1-5, row4 0/9/8/7/6, row5 P-O-I-U-Y,
; row6 ENTER-L-K-J-H, row7 SPACE-SYM-M-N-B. ZX SYMBOL SHIFT maps to C=.
; ----------------------------------------------------------------------------
rbt_zx2cbm:
        .byte   15,12,23,20,31,$ff,$ff,$ff    ; row 0: SHIFT Z X C V
        .byte   10,13,18,21,26,$ff,$ff,$ff    ; row 1: A S D F G
        .byte   62,9,14,17,22,$ff,$ff,$ff     ; row 2: Q W E R T
        .byte   56,59,8,11,16,$ff,$ff,$ff     ; row 3: 1 2 3 4 5
        .byte   35,32,27,24,19,$ff,$ff,$ff    ; row 4: 0 9 8 7 6
        .byte   41,38,33,30,25,$ff,$ff,$ff    ; row 5: P O I U Y
        .byte   1,42,37,34,29,$ff,$ff,$ff     ; row 6: ENTER L K J H
        .byte   60,61,36,39,28,$ff,$ff,$ff    ; row 7: SPACE SYM M N B

; ----------------------------------------------------------------------------
; ZX code -> ASCII map (0 = no ascii) — same layout as the ZX runtime's
; so INKEY returns identical values on every platform.
; ----------------------------------------------------------------------------
rbt_keymap:
        .byte   0,'z','x','c','v',0,0,0       ; row 0
        .byte   'a','s','d','f','g',0,0,0     ; row 1
        .byte   'q','w','e','r','t',0,0,0     ; row 2
        .byte   '1','2','3','4','5',0,0,0     ; row 3
        .byte   '0','9','8','7','6',0,0,0     ; row 4
        .byte   'p','o','i','u','y',0,0,0     ; row 5
        .byte   13,'l','k','j','h',0,0,0      ; row 6
        .byte   ' ',0,'m','n','b',0,0,0       ; row 7
