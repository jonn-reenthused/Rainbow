; ============================================================================
; rbt_input_asm - keyboard matrix + joystick input
; Key code encoding: code = row*8 + bit.
;   row 0 (#FEFE): 0=SHIFT 1=Z 2=X 3=C 4=V
;   row 1 (#FDFE): 0=A 1=S 2=D 3=F 4=G
;   row 2 (#FBFE): 0=Q 1=W 2=E 3=R 4=T
;   row 3 (#F7FE): 0=1 1=2 2=3 3=4 4=5
;   row 4 (#EFFE): 0=0 1=9 2=8 3=7 4=6
;   row 5 (#DFFE): 0=P 1=O 2=I 3=U 4=Y
;   row 6 (#BFFE): 0=ENTER 1=L 2=K 3=J 4=H
;   row 7 (#7FFE): 0=SPACE 1=SYM 2=M 3=N 4=B
; ============================================================================

rbt_rowtbl      defb #fe,#fd,#fb,#f7,#ef,#df,#bf,#7f

; code -> ASCII map (0 = no ascii). Index = row*8+bit.
rbt_keymap:
        defb    0,'z','x','c','v',0,0,0          ; row 0
        defb    'a','s','d','f','g',0,0,0        ; row 1
        defb    'q','w','e','r','t',0,0,0        ; row 2
        defb    '1','2','3','4','5',0,0,0        ; row 3
        defb    '0','9','8','7','6',0,0,0        ; row 4
        defb    'p','o','i','u','y',0,0,0        ; row 5
        defb    13,'l','k','j','h',0,0,0         ; row 6
        defb    ' ',0,'m','n','b',0,0,0          ; row 7

; ----------------------------------------------------------------------------
; rbt_key - test one key. In: A = code (row<<3 | bit). Out: A=1 pressed, 0 not.
; ----------------------------------------------------------------------------
rbt_key:
        ld      e,a             ; E = code
        and     7
        ld      c,a             ; C = bit index
        ld      a,e
        rrca
        rrca
        rrca
        and     7               ; A = row
        ld      hl,rbt_rowtbl
        ld      d,0
        ld      e,a
        add     hl,de
        ld      a,(hl)          ; port high byte
        ld      e,c             ; E = bit index
        ld      b,a
        ld      c,#fe
        in      a,(c)           ; A = row bits (0 = pressed)
        ; shift bit E into carry
        ld      b,e
        inc     b
_sh     rra
        djnz    _sh
        ld      a,0
        ret     c               ; bit was 1 -> not pressed
        inc     a
        ret

; ----------------------------------------------------------------------------
; rbt_anykey - A = 1 if any key pressed
; ----------------------------------------------------------------------------
rbt_anykey:
        xor     a
        in      a,(#fe)
        cpl
        and     #1f
        ret     z
        ld      a,1
        ret

; ----------------------------------------------------------------------------
; rbt_inkey - scan matrix, return ASCII of first pressed key (or 0)
; ----------------------------------------------------------------------------
rbt_inkey:
        ld      b,64
        ld      c,0             ; C = code
_scan   ld      a,c
        push    bc
        call    rbt_key
        pop     bc
        or      a
        jr      nz,_found
        inc     c
        djnz    _scan
        xor     a
        ret
_found  ld      hl,rbt_keymap
        ld      d,0
        ld      e,c
        add     hl,de
        ld      a,(hl)
        ret

; ----------------------------------------------------------------------------
; rbt_joy - read joystick port.
;   rbt_joymode: 0 = none, 1 = Kempston (port 31), 2 = Sinclair1 (5678),
;                3 = Sinclair2 (1234), 4 = Cursor (890;)
; Out: A = bitmask %000FUDLR (fire,up,down,left,right)
; ----------------------------------------------------------------------------
rbt_joymode     defb 0

rbt_joy:
        ld      a,(rbt_joymode)
        or      a
        ret     z               ; A = 0: no joystick
        cp      1
        jr      z,_kempston
        ; Sinclair variants read the keyboard matrix:
        ;   SINCLAIR1 = keys 6,7,8,9,0 -> row 4 (#EFFE): 0=fire... map:
        ;   port #EFFE bits: 0='0' 1='9' 2='8' 3='7' 4='6'
        ;   sinclair1: right=6,left=7,down=8,up=9,fire=0
        ;   sinclair2: right=1? standard: SINCLAIR2 = keys 1-5 row #F7FE
        cp      3
        jr      z,_sin2
_sin1   ld      b,#ef           ; row 4: 6 7 8 9 0
        ld      c,#fe
        in      a,(c)
        ; bits: 4=right('6') 3=left('7') 2=down('8') 1=up('9') 0=fire('0')
        ; build %000FUDLR
        ld      b,a
        and     1               ; fire (bit0) -> bit4
        add     a,a
        add     a,a
        add     a,a
        add     a,a
        ld      e,a
        ld      a,b
        and     2               ; up -> bit3
        add     a,a
        add     a,a
        or      e
        ld      e,a
        ld      a,b
        and     4               ; down -> bit2
        or      e
        ld      e,a
        ld      a,b
        and     8               ; left -> bit1
        rra
        or      e
        ld      e,a
        ld      a,b
        and     16              ; right -> bit0
        rra
        rra
        rra
        rra
        or      e
        cpl
        and     #1f             ; pressed bits are 0 -> invert
        ret
_sin2   ld      b,#f7           ; row 3: 1 2 3 4 5
        ld      c,#fe
        in      a,(c)
        ; sinclair2: left='1'(bit0)... fire='5'(bit4)
        ; bits: 0=left 1=right? convention: 1=left 2=right 3=down 4=up 5=fire
        ld      b,a
        and     1               ; left -> bit1
        add     a,a
        ld      e,a
        ld      a,b
        and     2               ; right -> bit0
        rra
        or      e
        ld      e,a
        ld      a,b
        and     4               ; down -> bit2
        or      e
        ld      e,a
        ld      a,b
        and     8               ; up -> bit3
        or      e
        ld      e,a
        ld      a,b
        and     16              ; fire -> bit4
        or      e
        cpl
        and     #1f
        ret
_kempston:
        ld      bc,#001f        ; port 31
        in      a,(c)
        and     #1f             ; already %000FUDLR
        ret
