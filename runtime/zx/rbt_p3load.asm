; ============================================================================
; rbt_p3load - Rainbow runtime: +3DOS bank loader (zxplus3 only)
;
; Emitted first so RANDOMIZE USR <org> lands here. Each bank file is
; loaded through +3DOS: DOS_READ takes the destination bank in C and
; pages it in at #C000 itself. +3DOS keeps its workspace in bank 7 and
; its sector cache/RAMdisc in pages 1,3,4,6 — DOS_SET_1346 confines it
; to bank 1, freeing banks 0/3/4/6 for assets.
;
; A DOS entry requires ROM 2 (the +3DOS ROM — it carries the jump block
; at #0100) at #0000, bank 7 at #C000, a stack inside #4000-#BFE0 and
; interrupts enabled. ROM number = 7FFD.bit4 | 1FFD.bit2<<1, so ROM2 is
; res 4 on the BANKM mirror once 1FFD bit2 is set (forced here via
; BANK678). Every DOS call corrupts BC DE HL IX — the table pointer
; rides the stack across each call.
;
; File table rbt_bankfiles is emitted by the compiler:
;   defb bank / defm "BANKn.BIN" / defb #FF  ... defb #FF
; ============================================================================

RBT_P3_DOS_OPEN   equ #0106
RBT_P3_DOS_CLOSE  equ #0109
RBT_P3_DOS_READ   equ #0112
RBT_P3_GET_EOF    equ #0139
RBT_P3_S1346      equ #013F
RBT_P3_SETMSG     equ #014E
RBT_P3_DD_MOT_OFF equ #019C
RBT_P3_BANKM      equ #5B5C
RBT_P3_BANK678    equ #5B67

rbt_p3load:
        di
        ld      sp,RBT_STACK    ; #7ffe: inside the #4000-#BFE0 DOS
                                ; stack window, in always-mapped bank 5
        call    rbt_p3_dosram   ; bank7 + ROM2, ei
        xor     a
        call    RBT_P3_SETMSG   ; disable ALERT dialogs — errors just
                                ; return carry clear
        ld      de,#001C        ; cache = buffers 0-27, RAMdisc = 28-31:
        ld      hl,#1C04        ; page 1 only — 0/3/4/6 free for assets
        call    RBT_P3_S1346
        jr      nc,_fail
        ld      ix,rbt_bankfiles
_next:
        ld      a,(ix)          ; bank number, #FF = end
        cp      #ff
        jr      z,_done
        ld      bc,#0005        ; B = file 0, C = shared-read
        ld      de,#0001        ; open existing + read header; error if
                                ; absent
        push    ix
        pop     hl
        inc     hl              ; -> "BANKn.BIN",#FF
        push    ix              ; DOS corrupts IX
        call    RBT_P3_DOS_OPEN
        pop     ix
        jr      nc,_fail
        ld      b,0
        push    ix
        call    RBT_P3_GET_EOF  ; E:HL = file size incl. 128-byte
        pop     ix              ; PLUS3DOS header
        jr      nc,_fail
        ld      a,e
        or      a
        jr      nz,_fail        ; >64K file — impossible for a bank
        ld      e,l
        ld      d,h             ; DE = EOF
        ld      hl,-128
        add     hl,de           ; HL = data length past the header
        ex      de,hl           ; DE = length for DOS_READ
        ld      a,d
        or      e
        jr      z,_fail         ; DE=0 would read 64K and hit EOF
        ld      b,0             ; file 0
        ld      c,(ix)          ; C = destination page at #C000
        ld      hl,#C000
        push    ix
        call    RBT_P3_DOS_READ
        pop     ix
        jr      nc,_fail
        ld      b,0
        push    ix
        call    RBT_P3_DOS_CLOSE
        pop     ix
        jr      nc,_fail
        ld      de,11           ; entry = bank + "BANKn.BIN"(9) + #FF
        add     ix,de
        jr      _next
_done:
        ld      b,0
        call    RBT_P3_DOS_CLOSE
        call    RBT_P3_DD_MOT_OFF
        call    rbt_p3_useram   ; bank0 + ROM3 (48K BASIC) for the game
        jp      rbt_start
_fail:
        call    rbt_p3_useram
        ld      a,#07           ; white border flash — the game cannot
_h:     halt                    ; run without its banks
        xor     #07
        out     (#FE),a
        jr      _h

; page RAM bank 7 (DOS workspace) at #C000 and the DOS ROM (ROM2) at
; #0000: res 4 on BANKM with 1FFD bit2 forced through BANK678
rbt_p3_dosram:
        ld      a,(RBT_P3_BANK678)
        or      #04             ; 1FFD bit2 = ROM select high bit
        ld      (RBT_P3_BANK678),a
        ld      bc,#1FFD
        out     (c),a
        ld      a,(RBT_P3_BANKM)
        res     4,a             ; ROM2
        or      #07             ; bank 7
        ld      (RBT_P3_BANKM),a
        ld      bc,#7FFD
        out     (c),a
        ei                      ; DOS wants interrupts enabled
        ret

; resting state for the game: bank 0 + ROM3 (48K BASIC) — the same
; configuration rbt_bank maintains through RBT_BANKROM
rbt_p3_useram:
        di
        ld      a,(RBT_P3_BANKM)
        and     #F8             ; bank 0
        set     4,a             ; ROM3
        ld      (RBT_P3_BANKM),a
        ld      bc,#7FFD
        out     (c),a
        ei
        ret
