' ROBOTRON — Phase 1 demo: masked sprite, key control,
' tilemap scroll and solid-tile collision.
' Q/A = up/down  O/P = left/right  7/6 = scroll left/right

PROGRAM "ROBOTRON"

DIM dx AS BYTE, dy AS BYTE, hit AS BYTE, ox AS BYTE, oy AS BYTE

MAIN:
  BORDER 0
  PAPER 0: INK 7: CLS
  TILESET "tiles"
  TILEMAP "level"
  TILEMAP VIEW 0, 0, 32, 20
  TILEMAP CAMERA 0, 0
  TILEMAP DRAW
  SPRITE CREATE 0, "ship", 40, 72
  SPRITE ANIMATE 0, 0, 1
loop:
  dx = 0: dy = 0
  IF KEY(16) THEN dy = -8
  IF KEY(8) THEN dy = 8
  IF KEY(41) THEN dx = -8
  IF KEY(40) THEN dx = 8
  IF dx <> 0 OR dy <> 0 THEN
    ox = SPRITEX(0): oy = SPRITEY(0)
    SPRITE MOVE 0, dx, dy
    hit = COLLIDETILE(0)
    IF hit THEN
      SPRITE MOVE 0, -dx, -dy
    ELSE
      ' move succeeded: erase the old footprint
      TILEMAP REDRAW ox/8, oy/8, 3, 3
    ENDIF
  ENDIF
  IF KEY(35) THEN TILEMAP SCROLL LEFT 1
  IF KEY(36) THEN TILEMAP SCROLL RIGHT 1
  SPRITES DRAWALL
  HALT
  GOTO loop
