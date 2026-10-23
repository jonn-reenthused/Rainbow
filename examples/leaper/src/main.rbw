PROGRAM "LEAPER"
TARGET ZX48

' Endless upward jumper. Platforms are sprites, so the "camera" is
' just: while the player is above SCRLINE and rising, shift every
' platform down instead of moving the player. Landing is only valid
' while falling AND the feet crossed the platform top this frame.
' The player wraps around the screen edges horizontally.
' Slots: 0 player / 1..7 platforms.

TYPE Plat
  x AS INT
  y AS INT
END TYPE

DIM plats(8) AS Plat        ' slots 1..7 (index 0 unused)
DIM px AS INT
DIM py AS INT
DIM ppy AS INT
DIM vy AS INT
DIM sc AS UINT
DIM i AS BYTE
DIM sh AS INT

CONST SCRLINE = 80

SUB seed_plats()
  ' first platform always sits under the spawn point — guaranteed hop
  plats(1).x = 116
  plats(1).y = 176
  SPRITE PLACE 1, plats(1).x, plats(1).y
  FOR i = 2 TO 7
    plats(i).x = RND(230)
    plats(i).y = 202 - i * 26
    SPRITE PLACE i, plats(i).x, plats(i).y
  NEXT
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 8, 11, "L E A P E R"
  PRINTAT 11, 6, "o/p steer - keep climbing!"
  WAITKEY
  CLS
  SPRITE CREATE 0, "jumper", 120, 160, MASK
  SPRITE ANIMATE 0, 0, 1
  FOR i = 1 TO 7
    SPRITE CREATE i, "plat", 0, 0, MASK
  NEXT
  px = 120
  py = 160
  vy = 0
  sc = 0
  CALL seed_plats
  PRINTAT 0, 1, "height"
game:
  HALT
  ' --- steer + horizontal wrap ---
  IF KEY(41) THEN px = px - 3
  IF KEY(40) THEN px = px + 3
  IF px < 0 THEN px = 248
  IF px > 248 THEN px = 0
  ' --- gravity; scroll the world while rising above SCRLINE ---
  ppy = py
  vy = vy + 1
  IF vy > 6 THEN vy = 6
  IF vy < 0 THEN
    IF py + vy < SCRLINE THEN
      sh = SCRLINE - py - vy
      py = SCRLINE
      sc = sc + sh
      FOR i = 1 TO 7
        plats(i).y = plats(i).y + sh
        ' recycle platforms that fell off the bottom to above the top
        IF plats(i).y > 184 THEN
          plats(i).y = 0
          plats(i).x = RND(230)
        ENDIF
        SPRITE PLACE i, plats(i).x, plats(i).y
      NEXT
    ELSE
      py = py + vy
    ENDIF
  ELSE
    py = py + vy
  ENDIF
  SPRITE PLACE 0, px, py
  ' --- land: only while falling with feet at/above the platform top ---
  IF vy > 0 THEN
    FOR i = 1 TO 7
      IF ppy + 16 <= plats(i).y + 4 THEN
        IF SPRITECOLLIDE(0, i) THEN
          py = plats(i).y - 16
          vy = -15
          SPRITE PLACE 0, px, py
          SFX "jump"
        ENDIF
      ENDIF
    NEXT
  ENDIF
  SPRITES UPDATE
  PRINTAT 1, 1, sc / 8, "   "
  IF py > 184 THEN GOTO gameover
  GOTO game
gameover:
  SFX "thud"
  BORDER 2
  PRINTAT 10, 10, "  G A M E   O V E R  "
  PRINTAT 12, 10, "  height ", sc / 8, "  "
endless:
  GOTO endless
