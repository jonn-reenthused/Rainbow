PROGRAM "MUNCHER"
TARGET ZX48

' Pac-Man style maze game. The maze is a 32x22 tilemap; dots are map
' tiles eaten by rewriting the cell with TILEATSET — SPRITES UPDATE
' then rebuilds that cell (the player sprite sits on it) from the new
' map data, so the dot vanishes under the sprite as it's eaten.
' Ghosts 1-3 are struct-array sprites moving 1px/frame; they re-pick
' a direction at every cell boundary, chasing the player 3 times in 4
' and wandering randomly otherwise.

TYPE Ghost
  x AS INT
  y AS INT
  dir AS BYTE
END TYPE

DIM ghosts(4) AS Ghost      ' slots 1..3 (index 0 unused)
DIM ddx(4) AS INT           ' dir deltas: 0=left 1=right 2=up 3=down
DIM ddy(4) AS INT
DIM px AS INT
DIM py AS INT
DIM pdir AS BYTE
DIM pwant AS BYTE
DIM dots AS UINT
DIM sc AS UINT
DIM lives AS BYTE
DIM cx AS BYTE
DIM cy AS BYTE
DIM t AS BYTE
DIM i AS BYTE
DIM nd AS BYTE
DIM tryn AS BYTE
DIM tx AS INT
DIM ty AS INT
DIM rx AS BYTE
DIM ry AS BYTE

' Pick a direction for ghost g: mostly head toward the player,
' sometimes random; if the candidate is walled, re-roll until free.
SUB pickdir(g AS INT)
  IF RND(4) = 0 THEN
    nd = RND(4)
  ELSE
    nd = ghosts(g).dir
    IF px < ghosts(g).x THEN nd = 0
    IF px > ghosts(g).x THEN nd = 1
    IF px = ghosts(g).x THEN
      IF py < ghosts(g).y THEN
        nd = 2
      ELSE
        nd = 3
      ENDIF
    ENDIF
  ENDIF
  tryn = 0
  WHILE tryn < 8
    SPRITE PLACE g, ghosts(g).x + ddx(nd), ghosts(g).y + ddy(nd)
    IF COLLIDETILE(g) = 0 THEN
      ghosts(g).dir = nd
      tryn = 8
    ELSE
      nd = RND(4)
      tryn = tryn + 1
    ENDIF
  WEND
  SPRITE PLACE g, ghosts(g).x, ghosts(g).y
END SUB

' Back to start positions after a catch.
SUB respawn()
  px = 120
  py = 160
  pdir = 1
  pwant = 1
  ghosts(1).x = 88
  ghosts(1).y = 104
  ghosts(1).dir = 2
  ghosts(2).x = 120
  ghosts(2).y = 104
  ghosts(2).dir = 2
  ghosts(3).x = 152
  ghosts(3).y = 104
  ghosts(3).dir = 2
  SPRITE PLACE 0, px, py
  FOR i = 1 TO 3
    SPRITE PLACE i, ghosts(i).x, ghosts(i).y
  NEXT
END SUB

SUB hud()
  PRINTAT 22, 1, "score"
  PRINTAT 23, 1, sc, "    "
  PRINTAT 22, 22, "lives"
  PRINTAT 23, 22, lives
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  CHARSET "test"
  PRINTAT 8, 11, "M U N C H E R"
  PRINTAT 11, 3, "o/p q/a to steer the muncher"
  PRINTAT 13, 3, "clear the maze of 226 dots"
  WAITKEY
  CLS
  TILESET "walls"
  TILEMAP "maze"
  TILEMAP VIEW 0, 0, 32, 22
  TILEMAP CAMERA 0, 0
  TILEMAP DRAW
  ' count the dots on the map so any maze edit keeps working
  dots = 0
  FOR ry = 0 TO 21
    FOR rx = 0 TO 31
      t = TILEAT(rx, ry)
      IF t = 2 THEN dots = dots + 1
      IF t = 3 THEN dots = dots + 1
    NEXT
  NEXT
  SPRITE CREATE 0, "munch", 120, 160, MASK
  SPRITE ANIMATE 0, 0, 1
  FOR i = 1 TO 3
    SPRITE CREATE i, "ghost", 0, 0, MASK
    SPRITE ANIMATE i, 0, 1
  NEXT
  SPRITE ATTR 1, 2, 0, 1     ' red ghost
  SPRITE ATTR 2, 3, 0, 1     ' magenta ghost
  SPRITE ATTR 3, 5, 0, 1     ' cyan ghost
  ddx(0) = -1
  ddx(1) = 1
  ddx(2) = 0
  ddx(3) = 0
  ddy(0) = 0
  ddy(1) = 0
  ddy(2) = -1
  ddy(3) = 1
  sc = 0
  lives = 3
  CALL respawn
  CALL hud
game:
  HALT
  ' --- player steering: remember the wanted dir, take it at the next
  '     cell boundary if it isn't walled ---
  IF KEY(41) THEN pwant = 0
  IF KEY(40) THEN pwant = 1
  IF KEY(16) THEN pwant = 2
  IF KEY(8) THEN pwant = 3
  IF px MOD 8 = 0 THEN
    IF py MOD 8 = 0 THEN
      cx = px / 8
      cy = py / 8
      t = TILEAT(cx, cy)
      IF t = 2 THEN
        TILEATSET cx, cy, 0
        sc = sc + 10
        dots = dots - 1
        SFX "coin"
      ENDIF
      IF t = 3 THEN
        TILEATSET cx, cy, 0
        sc = sc + 50
        dots = dots - 1
        SFX "coin"
      ENDIF
      SPRITE PLACE 0, px + ddx(pwant) * 2, py + ddy(pwant) * 2
      IF COLLIDETILE(0) = 0 THEN pdir = pwant
    ENDIF
  ENDIF
  ' --- move 2px along current dir, revert if walled ---
  SPRITE PLACE 0, px + ddx(pdir) * 2, py + ddy(pdir) * 2
  IF COLLIDETILE(0) = 1 THEN SPRITE PLACE 0, px, py
  px = SPRITEX(0)
  py = SPRITEY(0)
  ' --- ghosts: 1px/frame, re-plan at each cell boundary ---
  FOR i = 1 TO 3
    IF ghosts(i).x MOD 8 = 0 THEN
      IF ghosts(i).y MOD 8 = 0 THEN CALL pickdir(i)
    ENDIF
    SPRITE PLACE i, ghosts(i).x + ddx(ghosts(i).dir), ghosts(i).y + ddy(ghosts(i).dir)
    IF COLLIDETILE(i) = 1 THEN
      SPRITE PLACE i, ghosts(i).x, ghosts(i).y
      CALL pickdir(i)
    ENDIF
    ghosts(i).x = SPRITEX(i)
    ghosts(i).y = SPRITEY(i)
  NEXT
  ' --- commit the frame, then slow work ---
  SPRITES UPDATE
  CALL hud
  FOR i = 1 TO 3
    IF SPRITECOLLIDE(0, i) THEN GOTO caught
  NEXT
  IF dots = 0 THEN GOTO cleared
  GOTO game
caught:
  SFX "thud"
  lives = lives - 1
  PAUSE 60
  IF lives = 0 THEN GOTO gameover
  CALL respawn
  GOTO game
cleared:
  PRINTAT 10, 11, "  CLEARED!  "
  PRINTAT 12, 9, "  final score ", sc, "  "
endwin:
  GOTO endwin
gameover:
  BORDER 2
  PRINTAT 10, 10, "  G A M E   O V E R  "
  PRINTAT 12, 10, "  score ", sc, "  "
endless:
  GOTO endless
