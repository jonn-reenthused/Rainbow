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
        ldx     #$ff            ; port A all-output (columns can be driven)
        stx     $dc02
        ldx     #$00            ; port B all-input (rows readable)
        stx     $dc03
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
        sei
        jsr     rbt_mapio
        lda     #$ff            ; port A output (column select)
        sta     $dc02
        lda     #$00            ; port B input (row read)
        sta     $dc03
        ldy     #0              ; col 0-7
        lda     #$fe            ; ~(1<<col) mask, rotates left
        sta     rbt_t0
@col:   lda     rbt_t0
        sta     $dc00           ; ground this column
        lda     $dc01           ; row bits (0 = pressed)
        cmp     #$ff
        bne     @got            ; something held in this column
        sec
        rol     rbt_t0          ; next column mask
        iny
        cpy     #8
        bcc     @col
        lda     $dc00           ; restore idle column state
        jsr     rbt_maprun
        cli
        lda     #0
        rts
@got:   sta     rbt_t1          ; column bits
        lda     $dc00
        jsr     rbt_maprun
        cli
        ; key index = col*8 + first clear bit
        ldx     #0
@bit:   lsr     rbt_t1
        bcc     @map
        inx
        jmp     @bit
@map:   tya                     ; col
        asl     a
        asl     a
        asl     a               ; col*8
        sta     rbt_t0
        txa                     ; rowbit
        clc
        adc     rbt_t0          ; matrix index 0-63
        tax
        lda     rbt_cbmkeymap,x ; c64 matrix -> ASCII
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

; ----------------------------------------------------------------------------
; rbt_input - line editor. rbt_hl = dest buffer, A = max length (size-1).
; Echoes via rbt_putchar; 8/127/20 delete, 13 ends and NUL-terminates.
; No auto-repeat: each accepted char waits for key release. All state is
; kept in vars because rbt_inkey/rbt_putchar clobber registers.
; ----------------------------------------------------------------------------
rbt_input:
        sta     rbt_in_max
        lda     rbt_hl
        sta     rbt_in_ptr
        lda     rbt_hl+1
        sta     rbt_in_ptr+1
        lda     #0
        sta     rbt_in_len
@iw:    jsr     rbt_inkey       ; A = ascii or 0
        beq     @iw             ; wait for a press
        cmp     #13
        beq     @idone
        cmp     #8
        beq     @ibs
        cmp     #127
        beq     @ibs
        cmp     #20             ; c64 DEL
        beq     @ibs
        cmp     #32
        bcc     @irel           ; ignore other control codes
        ; append if len < maxlen
        ldy     rbt_in_len
        cpy     rbt_in_max
        bcs     @irel           ; buffer full
        ; copy the write ptr into zp rbt_hl for (zp),y addressing
        ldx     rbt_in_ptr
        stx     rbt_hl
        ldx     rbt_in_ptr+1
        stx     rbt_hl+1
        ldy     #0
        sta     (rbt_hl),y      ; A still holds the char
        inc     rbt_in_ptr
        bne     @nhi
        inc     rbt_in_ptr+1
@nhi:   inc     rbt_in_len
        jsr     rbt_putchar     ; echo
        jmp     @irel
@ibs:   lda     rbt_in_len      ; backspace
        beq     @irel
        dec     rbt_in_len
        lda     rbt_in_ptr
        bne     @plo
        dec     rbt_in_ptr+1
@plo:   dec     rbt_in_ptr
        jsr     _ibsch          ; erase the last printed char
        jmp     @irel
@irel:  jsr     rbt_inkey       ; wait for release before next press
        bne     @irel
        jmp     @iw
@idone: lda     rbt_in_ptr
        sta     rbt_hl
        lda     rbt_in_ptr+1
        sta     rbt_hl+1
        ldy     #0
        lda     #0
        sta     (rbt_hl),y      ; NUL terminate
@idrel: jsr     rbt_inkey       ; a held ENTER must release first, or the
        bne     @idrel          ; next INPUT sees it again
        rts

; erase one char: cursor back (wrapping up a row at col 0), space, back again
_ibsch:
        lda     rbt_col
        bne     @bl
        dec     rbt_row         ; col 0: up a row to col 39
        lda     #39
        jmp     @bc
@bl:    sec
        sbc     #1
@bc:    sta     rbt_col
        lda     #' '
        jsr     rbt_putchar     ; prints space, advances cursor
        lda     rbt_col
        bne     @b2
        dec     rbt_row
        lda     #39
        jmp     @b3
@b2:    sec
        sbc     #1
@b3:    sta     rbt_col
        rts

; ----------------------------------------------------------------------------
; rbt_match - rbt_hl = NUL-terminated buffer, rbt_de = length-prefixed
;   literal (.byte len,"text"). Out: A = 1 on exact match else 0.
; ----------------------------------------------------------------------------
rbt_match:
        ldy     #0
        lda     (rbt_de),y      ; literal length
        tax                     ; X = bytes remaining
        inc     rbt_de          ; DE -> first text byte
        bne     @ml
        inc     rbt_de+1
@ml:    txa
        beq     @mend
        lda     (rbt_hl),y
        cmp     (rbt_de),y
        bne     @mno
        iny
        dex
        jmp     @ml
@mend:  lda     (rbt_hl),y      ; buffer must end here too
        bne     @mno
        lda     #1
        rts
@mno:   lda     #0
        rts

rbt_in_ptr:     .word   0
rbt_in_len:     .byte   0
rbt_in_max:     .byte   0

; c64 matrix (col*8+rowbit) -> ASCII. Only real text keys mapped; shifts,
; cursors, function keys and control keys return 0.
rbt_cbmkeymap:
        .byte   20,13,0,0,0,0,0,0          ; col 0: DEL RETURN _ F7 F1 F3 F5 _
        .byte   '3','w','a','4','z','s','e',0  ; col 1: 3 W A 4 Z S E LSHIFT
        .byte   '5','r','d','6','c','f','t','x'  ; col 2: 5 R D 6 C F T X
        .byte   '7','y','g','8','b','h','u','v'  ; col 3: 7 Y G 8 B H U V
        .byte   '9','i','j','0','m','k','o','n'  ; col 4: 9 I J 0 M K O N
        .byte   '+','p','l','-','.',':','@',','  ; col 5: + P L - . : @ ,
        .byte   0,'*',';',0,0,'=','^','/'        ; col 6: _ * ; HOME _ = ^ /
        .byte   '1',0,0,'2',' ',0,'q',0          ; col 7: 1 <- CTRL 2 SPC C= Q STOP
