PROGRAM "JUKEBOX"
TARGET ZX128

DIM bx AS INT
DIM by AS INT
DIM vx AS INT
DIM vy AS INT
DIM tune AS BYTE

SUB status()
  PRINTAT 15, 14, "tune: ", tune, "  "
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 1, 9, "A Y   J U K E B O X   ( 1 2 8 K )"
  PRINTAT 4, 5, "1  drive    2  drift    3  march    0  stop"
  PRINTAT 5, 5, "s  laser    d  jump  (beeper sfx)"
  PRINTAT 8, 5, "ay music is non-blocking - the ball"
  PRINTAT 9, 5, "keeps flying while the tune plays"
  SPRITE CREATE 0, "note", 120, 120, XOR
  SPRITE REDRAW 0
  bx = 120
  by = 120
  vx = 3
  vy = 2
  tune = 0
  CALL status
game:
  HALT
  IF KEY(24) AND tune <> 1 THEN MUSIC "drive" : tune = 1 : CALL status
  IF KEY(25) AND tune <> 2 THEN MUSIC "drift" : tune = 2 : CALL status
  IF KEY(26) AND tune <> 3 THEN MUSIC "march" : tune = 3 : CALL status
  IF KEY(32) AND tune <> 0 THEN MUSIC STOP : tune = 0 : CALL status
  IF KEY(9) THEN SFX "laser"
  IF KEY(10) THEN SFX "jump"
  bx = bx + vx
  by = by + vy
  IF bx < 8 THEN bx = 8 : vx = -vx
  IF bx > 240 THEN bx = 240 : vx = -vx
  IF by < 80 THEN by = 80 : vy = -vy
  IF by > 176 THEN by = 176 : vy = -vy
  SPRITE REDRAW 0
  SPRITE PLACE 0, bx, by
  SPRITE REDRAW 0
  GOTO game
