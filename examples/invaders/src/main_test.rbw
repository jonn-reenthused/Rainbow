PROGRAM "INVADERS"
TARGET ZX48

' The fleet is an array of structs: one DIM replaces parallel x/y/alive
' arrays. Slot ids equal array indices (foes(0..11) -> slots 0..11).
TYPE Foe
  x AS INT
  y AS INT
  alive AS BYTE
END TYPE

DIM foes(12) AS Foe
DIM sx AS INT          ' player ship x
DIM bx AS INT          ' bullet position
DIM by AS INT
DIM bact AS BYTE       ' bullet in flight
DIM dir AS INT         ' fleet step per frame (+2/-2)
DIM edge AS BYTE
DIM i AS BYTE
DIM remain AS BYTE
DIM sc AS UINT

SUB wave()
  FOR i = 0 TO 11
    foes(i).x = 48 + (i MOD 6) * 24
    foes(i).y = 40 + (i / 6) * 24
    foes(i).alive = 1
    SPRITE SHOW i
    SPRITE PLACE i, foes(i).x, foes(i).y
  NEXT
  dir = 2
  remain = 12
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 9, 10, "I N V A D E R S"
  PRINTAT 11, 7, "o/p move - space fire"
  PAUSE 1
  CLS
  FOR i = 0 TO 11
    SPRITE CREATE i, "invader", 0, 0, MASK
    SPRITE ANIMATE i, 0, 1
  NEXT
  SPRITE CREATE 12, "ship", 120, 176, MASK
  SPRITE CREATE 13, "bolt", 0, 0, MASK
  SPRITE HIDE 13
  sx = 120
  bact = 0
  sc = 0
  CALL wave
' Frame order: all logic first, commit every slot, test collisions on
' the committed positions, then one SPRITES UPDATE draws the frame.
game:
  HALT
  ' --- player ---
  IF KEY(41) THEN sx = sx - 3
  IF KEY(40) THEN sx = sx + 3
  IF sx < 8 THEN sx = 8
  IF sx > 232 THEN sx = 232
  ' --- fire / bullet flight ---
  IF bact = 0 THEN
    IF 1 THEN
      bact = 1
      bx = sx + 4
      by = 168
      SPRITE SHOW 13
      SFX "shot"
    ENDIF
  ENDIF
  IF bact = 1 THEN
    by = by - 6
    IF by < 8 THEN bact = 0 : SPRITE HIDE 13
  ENDIF
  ' --- fleet: predict an edge hit, then move or drop ---
  edge = 0
  FOR i = 0 TO 11
    IF foes(i).alive = 1 THEN
      IF foes(i).x + dir < 8 THEN edge = 1
      IF foes(i).x + dir > 228 THEN edge = 1
    ENDIF
  NEXT
  IF edge = 1 THEN
    dir = -dir
    FOR i = 0 TO 11
      IF foes(i).alive = 1 THEN foes(i).y = foes(i).y + 8
    NEXT
  ELSE
    FOR i = 0 TO 11
      IF foes(i).alive = 1 THEN foes(i).x = foes(i).x + dir
    NEXT
  ENDIF
  ' --- commit slot positions ---
  SPRITE PLACE 12, sx, 176
  IF bact = 1 THEN SPRITE PLACE 13, bx, by
  FOR i = 0 TO 11
    IF foes(i).alive = 1 THEN SPRITE PLACE i, foes(i).x, foes(i).y
  NEXT
  ' --- bullet vs fleet, landing check ---
  FOR i = 0 TO 11
    IF foes(i).alive = 1 THEN
      IF foes(i).y > 152 THEN GOTO gameover
      IF bact = 1 THEN
        IF SPRITECOLLIDE(13, i) THEN
          foes(i).alive = 0
          SPRITE HIDE i
          bact = 0
          SPRITE HIDE 13
          remain = remain - 1
          sc = sc + 10
          SFX "boom"
        ENDIF
      ENDIF
    ENDIF
  NEXT
  SPRITES UPDATE
  PRINTAT 23, 1, "score ", sc, "   "
  IF remain = 0 THEN
    PRINTAT 12, 10, "WAVE CLEARED"
    PAUSE 50
    PRINTAT 12, 10, "            "
    CALL wave
  ENDIF
  GOTO game
gameover:
  BORDER 2
  PRINTAT 10, 9, "  T H E Y   L A N D E D  "
  PRINTAT 12, 9, "  score ", sc, "  "
endless:
  GOTO endless
