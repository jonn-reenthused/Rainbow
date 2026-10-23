PROGRAM "SCROLLER"
TARGET ZX48

DIM y AS INT
DIM py AS INT
DIM sc AS UINT
DIM dist AS BYTE
DIM alive AS BYTE

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 8, 6, "C A V E R N   F L Y E R"
  PRINTAT 11, 4, "q/a to steer - survive the cavern"
  WAITKEY
  CLS
  TILESET "tiles"
  TILEMAP "level"
  TILEMAP VIEW 0, 0, 32, 20
  TILEMAP CAMERA 0, 0
  TILEMAP DRAW
  SPRITE CREATE 0, "ship", 32, 88, XOR
  SPRITE REDRAW 0             ' ship drawn once at (32,88)
  y = 88
  py = 88
  sc = 0
  dist = 0
  alive = 1
' Loop invariant entering "game": ship is on screen at x=32, y=py.
' TILEMAP SCROLL shifts everything one cell, ship image included, so it
' lands at x=24 - erase it there (XOR) then draw at the new position.
' This keeps the ship on screen during the scroll instead of blanking it.
game:
  HALT
  IF dist = 47 THEN GOTO wrap
  TILEMAP SCROLL RIGHT 1
  dist = dist + 1
  SPRITE PLACE 0, 24, py      ' where the shifted ship image is
  SPRITE REDRAW 0             ' erase it
  GOTO steer
wrap:
  TILEMAP CAMERA 0, 0         ' camera jump, not a shift: repaint all
  TILEMAP DRAW
  dist = 0
  SFX "beep"
steer:
  IF KEY(16) THEN y = y - 3
  IF KEY(8) THEN y = y + 3
  IF y < 16 THEN y = 16
  IF y > 152 THEN y = 152
  SPRITE PLACE 0, 32, y
  IF COLLIDETILE(0) THEN GOTO crashed
  SPRITE REDRAW 0             ' draw ship at new pos
  py = y
  sc = sc + 1
  PRINTAT 0, 1, "score"
  PRINTAT 1, 1, sc, "   "
  GOTO game
crashed:
  SFX "crash"
  BORDER 2
  alive = 0
  PRINTAT 10, 10, "  G A M E   O V E R  "
  PRINTAT 12, 10, "  score ", sc, "  "
gameover:
  GOTO gameover
