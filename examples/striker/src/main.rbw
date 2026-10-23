PROGRAM "STRIKER"

' Scramble-style horizontal shooter over a scrolling tilemap.
' TILEMAP SCROLL RIGHT advances the camera (view content shifts left),
' so every sprite on screen slides -8px. The frame order is: scroll,
' erase each live sprite at its SHIFTED position (XOR), run logic,
' then draw each at its new position. Sprites are XORed directly to the
' screen — a slot is only "on screen" between the draw phase and the
' next frame's erase phase, so spawn just records the position (the
' draw phase picks it up) and mid-frame despawn only clears its flag.
' Kills in the collision phase happen after drawing, so they re-place
' the slot and REDRAW to erase its pixels.
' Slots: 0 ship / 1 shot / 2..4 enemies.  KEY() codes are the ZX matrix
' codes on every platform — the CPC/C64 runtimes translate them.

DIM ex(3) AS INT            ' enemy positions
DIM ey(3) AS INT
DIM eon(3) AS BYTE
DIM sy AS INT               ' ship y (x is fixed at 24)
DIM bx AS INT               ' shot position
DIM by AS INT
DIM bon AS BYTE
DIM sc AS UINT
DIM dist AS BYTE
DIM i AS BYTE
DIM st AS BYTE              ' spawn timer
DIM alive AS BYTE
DIM fc AS BYTE

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 8, 10, "S T R I K E R"
  PRINTAT 11, 5, "q/a steer - space to fire"
  WAITKEY
  CLS
  TILESET "terrain"
  TILEMAP "canyon"
  TILEMAP VIEW 0, 0, 32, 18
  TILEMAP CAMERA 0, 0
  TILEMAP DRAW
  SPRITE CREATE 0, "ship", 24, 88, XOR
  SPRITE CREATE 1, "shot", 0, 0, XOR
  FOR i = 0 TO 2
    SPRITE CREATE 2 + i, "enemy", 0, 0, XOR
  NEXT
  sy = 88
  bon = 0
  sc = 0
  dist = 0
  st = 0
  fc = 0
  alive = 1
  SPRITE REDRAW 0
  PRINTAT 19, 1, "score"
game:
  HALT
  ' --- scroll: every sprite's pixels move left one cell ---
  IF dist = 32 THEN
    TILEMAP CAMERA 0, 0
    TILEMAP DRAW
    dist = 0
    ' the repaint wiped every sprite pixel — despawn without erasing
    FOR i = 0 TO 2
      eon(i) = 0
    NEXT
    bon = 0
    GOTO steer
  ENDIF
  TILEMAP SCROLL RIGHT 1
  dist = dist + 1
  sc = sc + 1
  ' erase each live sprite where the scroll left it (x-8)
  SPRITE PLACE 0, 16, sy
  SPRITE REDRAW 0
  IF bon = 1 THEN
    SPRITE PLACE 1, bx - 8, by
    SPRITE REDRAW 1
    bx = bx - 8
  ENDIF
  FOR i = 0 TO 2
    IF eon(i) = 1 THEN
      SPRITE PLACE 2 + i, ex(i) - 8, ey(i)
      SPRITE REDRAW 2 + i
      ex(i) = ex(i) - 8
    ENDIF
  NEXT
steer:
  ' --- ship vertical steer ---
  IF KEY(16) THEN sy = sy - 3
  IF KEY(8) THEN sy = sy + 3
  IF sy < 8 THEN sy = 8
  IF sy > 136 THEN sy = 136
  ' --- fire ---
  IF bon = 0 THEN
    IF KEY(56) THEN
      bon = 1
      bx = 40
      by = sy + 4
      SFX "laser"
    ENDIF
  ENDIF
  ' --- shot flight: +12 vs the -8 scroll shift = +4/frame on screen ---
  IF bon = 1 THEN
    bx = bx + 12
    IF bx > 240 THEN
      bon = 0
    ELSE
      SPRITE PLACE 1, bx, by
      IF COLLIDETILE(1) = 1 THEN bon = 0
    ENDIF
  ENDIF
  ' --- enemies drift left on their own power too ---
  fc = fc + 1
  IF fc MOD 2 = 0 THEN
    FOR i = 0 TO 2
      IF eon(i) = 1 THEN
        ex(i) = ex(i) - 2
        IF ex(i) < 8 THEN eon(i) = 0
      ENDIF
    NEXT
  ENDIF
  ' --- spawn ---
  st = st + 1
  IF st > 30 THEN
    st = 0
    FOR i = 0 TO 2
      IF eon(i) = 0 THEN
        ex(i) = 240
        ey(i) = 24 + RND(110)
        eon(i) = 1
        i = 3
      ENDIF
    NEXT
  ENDIF
  ' --- commit positions & draw ---
  SPRITE PLACE 0, 24, sy
  SPRITE REDRAW 0
  IF bon = 1 THEN
    SPRITE PLACE 1, bx, by
    SPRITE REDRAW 1
  ENDIF
  FOR i = 0 TO 2
    IF eon(i) = 1 THEN
      SPRITE PLACE 2 + i, ex(i), ey(i)
      SPRITE REDRAW 2 + i
    ENDIF
  NEXT
  ' --- collisions ---
  IF COLLIDETILE(0) = 1 THEN GOTO crashed
  FOR i = 0 TO 2
    IF eon(i) = 1 THEN
      IF SPRITECOLLIDE(0, 2 + i) THEN GOTO crashed
      IF bon = 1 THEN
        IF SPRITECOLLIDE(1, 2 + i) THEN
          ' both were drawn this frame — erase them where they stand
          SPRITE PLACE 2 + i, ex(i), ey(i)
          SPRITE REDRAW 2 + i
          eon(i) = 0
          SPRITE PLACE 1, bx, by
          SPRITE REDRAW 1
          bon = 0
          sc = sc + 25
          SFX "thud"
        ENDIF
      ENDIF
    ENDIF
  NEXT
  PRINTAT 20, 1, sc, "      "
  GOTO game
crashed:
  SFX "thud"
  BORDER 2
  PRINTAT 10, 10, "  G A M E   O V E R  "
  PRINTAT 12, 10, "  score ", sc, "  "
endless:
  GOTO endless
