PROGRAM "PONG"

TYPE Ball
  x AS INT
  y AS INT
  vx AS INT
  vy AS INT
END TYPE

TYPE Player
  y AS INT
  score AS UINT
END TYPE

DIM b AS Ball
DIM p(2) AS Player     ' p(0)=human, p(1)=cpu
DIM hit AS BYTE

SUB serve(dir AS INT)
  b.x = 124
  b.y = 88
  b.vx = dir * 2
  b.vy = 1
END SUB

SUB scoreline()
  PRINTAT 0, 12, "    "
  PRINTAT 0, 12, p(0).score
  PRINTAT 0, 19, "    "
  PRINTAT 0, 19, p(1).score
END SUB

MAIN:
  BORDER 1
  PAPER 0
  INK 7
  CLS
  PRINTAT 9, 9, "P O N G"
  PRINTAT 11, 6, "rainbow showcase"
  MUSIC "intro"
  WAITKEY
  CLS
  FILLATTR 0, 0, 32, 24
  ' Composited sprites: SPRITES UPDATE diffs each sprite's old and new
  ' cell rectangles and rebuilds only the dirty cells in RAM before
  ' writing them to the screen once — the screen never holds a "sprite
  ' erased" state, so there is nothing to flicker. No manual erase.
  SPRITE CREATE 0, "paddle", 8, 80, MASK
  SPRITE CREATE 1, "paddle", 240, 80, MASK
  SPRITE CREATE 2, "ball", 124, 88, MASK
  p(0).y = 80
  p(1).y = 80
  p(0).score = 0
  p(1).score = 0
  CALL serve(1)
' Loop shape: do ALL logic first (no screen access), PLACE the sprites
' at their final positions, then one SPRITES UPDATE commits the frame.
' SFX (blocking beeper) and score printing run after the update.
game:
  HALT
  hit = 0
  ' player paddle: Q (16) up, A (8) down
  IF KEY(16) THEN p(0).y = p(0).y - 3
  IF KEY(8) THEN p(0).y = p(0).y + 3
  IF p(0).y < 8 THEN p(0).y = 8
  IF p(0).y > 160 THEN p(0).y = 160
  ' cpu paddle tracks the ball
  IF p(1).y + 12 < b.y THEN p(1).y = p(1).y + 2
  IF p(1).y + 12 > b.y THEN p(1).y = p(1).y - 2
  IF p(1).y < 8 THEN p(1).y = 8
  IF p(1).y > 160 THEN p(1).y = 160
  ' ball physics (screen untouched yet)
  b.x = b.x + b.vx
  b.y = b.y + b.vy
  IF b.y < 8 THEN b.y = 8 : b.vy = -b.vy : hit = 1
  IF b.y > 176 THEN b.y = 176 : b.vy = -b.vy : hit = 1
  ' --- commit positions, test collisions against them, then update ---
  SPRITE PLACE 0, 8, p(0).y
  SPRITE PLACE 1, 240, p(1).y
  SPRITE PLACE 2, b.x, b.y
  IF SPRITECOLLIDE(2, 0) THEN b.vx = ABS(b.vx) : b.x = b.x + 4 : hit = 1 : SPRITE PLACE 2, b.x, b.y
  IF SPRITECOLLIDE(2, 1) THEN b.vx = -ABS(b.vx) : b.x = b.x - 4 : hit = 1 : SPRITE PLACE 2, b.x, b.y
  IF b.x < 0 THEN p(1).score = p(1).score + 1 : hit = 2 : CALL serve(-1) : SPRITE PLACE 2, b.x, b.y
  IF b.x > 248 THEN p(0).score = p(0).score + 1 : hit = 2 : CALL serve(1) : SPRITE PLACE 2, b.x, b.y
  SPRITES UPDATE
  ' --- slow work, the finished frame is already on screen ---
  IF hit = 1 THEN SFX "blip"
  IF hit = 2 THEN CALL scoreline : SFX "blip"
  GOTO game
