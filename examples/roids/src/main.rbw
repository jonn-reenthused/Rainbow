PROGRAM "ROIDS"
TARGET ZX48

' Asteroids-style. No tilemap: MASK sprites composite over a blank
' background, so SPRITES UPDATE gives a clean flicker-free frame.
' Slots: 0 ship / 1-4 shots / 5-9 big rocks / 10-15 small rocks.
' Ship has 8 rotation frames; dir tables tdx/tdy drive both thrust
' and shot velocity.

TYPE Rock
  x AS INT
  y AS INT
  vx AS INT
  vy AS INT
  on AS BYTE
END TYPE

TYPE Shot
  x AS INT
  y AS INT
  vx AS INT
  vy AS INT
  life AS BYTE
END TYPE

DIM bigs(5) AS Rock
DIM sml(6) AS Rock
DIM shots(4) AS Shot
DIM tdx(8) AS INT
DIM tdy(8) AS INT
DIM sx AS INT
DIM sy AS INT
DIM svx AS INT
DIM svy AS INT
DIM sdir AS BYTE
DIM lives AS BYTE
DIM sc AS UINT
DIM wave AS BYTE
DIM iv AS BYTE
DIM fc AS BYTE
DIM i AS BYTE
DIM j AS BYTE
DIM nbig AS BYTE
DIM dead AS BYTE
DIM k AS BYTE

SUB spawnbig(n AS INT)
  bigs(n).on = 1
  bigs(n).x = 8 + RND(220)
  bigs(n).y = 16 + RND(140)
  bigs(n).vx = RND(3) - 1
  bigs(n).vy = RND(3) - 1
  IF bigs(n).vx = 0 THEN
    IF bigs(n).vy = 0 THEN bigs(n).vx = 1
  ENDIF
  SPRITE SHOW 5 + n
  SPRITE PLACE 5 + n, bigs(n).x, bigs(n).y
END SUB

SUB split(n AS INT)
  ' two small rocks where the big one died
  k = 0
  FOR j = 0 TO 5
    IF sml(j).on = 0 THEN
      IF k < 2 THEN
        sml(j).on = 1
        sml(j).x = bigs(n).x + 4
        sml(j).y = bigs(n).y + 4
        sml(j).vx = RND(5) - 2
        sml(j).vy = RND(5) - 2
        IF sml(j).vx = 0 THEN
          IF sml(j).vy = 0 THEN sml(j).vx = 2
        ENDIF
        SPRITE SHOW 10 + j
        SPRITE PLACE 10 + j, sml(j).x, sml(j).y
        k = k + 1
      ENDIF
    ENDIF
  NEXT
END SUB

SUB wave_up()
  wave = wave + 1
  nbig = wave + 2
  IF nbig > 5 THEN nbig = 5
  FOR i = 0 TO 4
    IF i < nbig THEN CALL spawnbig(i)
  NEXT
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  BRIGHT 1
  CLS
  PRINTAT 9, 11, "R O I D S"
  PRINTAT 11, 5, "o/p rotate - q thrust - space fire"
  WAITKEY
  CLS
  SPRITE CREATE 0, "ship", 120, 88, MASK
  FOR i = 0 TO 3
    SPRITE CREATE 1 + i, "shot", 0, 0, MASK
    SPRITE HIDE 1 + i
  NEXT
  FOR i = 0 TO 4
    SPRITE CREATE 5 + i, "rold", 0, 0, MASK
    SPRITE HIDE 5 + i
  NEXT
  FOR i = 0 TO 5
    SPRITE CREATE 10 + i, "rolds", 0, 0, MASK
    SPRITE HIDE 10 + i
  NEXT
  ' dir tables: 0=N 1=NE 2=E 3=SE 4=S 5=SW 6=W 7=NW
  tdx(0) = 0
  tdx(1) = 1
  tdx(2) = 1
  tdx(3) = 1
  tdx(4) = 0
  tdx(5) = -1
  tdx(6) = -1
  tdx(7) = -1
  tdy(0) = -1
  tdy(1) = -1
  tdy(2) = 0
  tdy(3) = 1
  tdy(4) = 1
  tdy(5) = 1
  tdy(6) = 0
  tdy(7) = -1
  sx = 120
  sy = 88
  svx = 0
  svy = 0
  sdir = 0
  sc = 0
  lives = 3
  wave = 0
  iv = 80
  fc = 0
  FOR i = 0 TO 4
    bigs(i).on = 0
  NEXT
  FOR i = 0 TO 5
    sml(i).on = 0
  NEXT
  FOR i = 0 TO 3
    shots(i).life = 0
  NEXT
  CALL wave_up
game:
  HALT
  fc = fc + 1
  dead = 0
  ' --- ship: rotate (throttled), thrust, inertia, wrap ---
  IF fc MOD 3 = 0 THEN
    IF KEY(41) THEN
      IF sdir = 0 THEN
        sdir = 7
      ELSE
        sdir = sdir - 1
      ENDIF
    ENDIF
    IF KEY(40) THEN
      IF sdir = 7 THEN
        sdir = 0
      ELSE
        sdir = sdir + 1
      ENDIF
    ENDIF
  ENDIF
  IF KEY(16) THEN
    svx = svx + tdx(sdir)
    svy = svy + tdy(sdir)
  ENDIF
  IF svx > 4 THEN svx = 4
  IF svx < -4 THEN svx = -4
  IF svy > 4 THEN svy = 4
  IF svy < -4 THEN svy = -4
  sx = sx + svx
  sy = sy + svy
  IF sx < 0 THEN sx = 240
  IF sx > 240 THEN sx = 0
  IF sy < 0 THEN sy = 176
  IF sy > 176 THEN sy = 0
  SPRITE PLACE 0, sx, sy
  SPRITE FRAME 0, sdir
  ' --- fire ---
  IF KEY(56) THEN
    i = 0
    WHILE i < 4
      IF shots(i).life = 0 THEN
        shots(i).life = 30
        shots(i).vx = tdx(sdir) * 5 + svx
        shots(i).vy = tdy(sdir) * 5 + svy
        shots(i).x = sx + 4
        shots(i).y = sy + 4
        SPRITE SHOW 1 + i
        SFX "laser"
        i = 4
      ENDIF
      i = i + 1
    WEND
  ENDIF
  ' --- move shots ---
  FOR i = 0 TO 3
    IF shots(i).life > 0 THEN
      shots(i).life = shots(i).life - 1
      shots(i).x = shots(i).x + shots(i).vx
      shots(i).y = shots(i).y + shots(i).vy
      IF shots(i).x < 0 THEN shots(i).x = 248
      IF shots(i).x > 248 THEN shots(i).x = 0
      IF shots(i).y < 0 THEN shots(i).y = 184
      IF shots(i).y > 184 THEN shots(i).y = 0
      IF shots(i).life = 0 THEN
        SPRITE HIDE 1 + i
      ELSE
        SPRITE PLACE 1 + i, shots(i).x, shots(i).y
      ENDIF
    ENDIF
  NEXT
  ' --- move rocks ---
  FOR i = 0 TO 4
    IF bigs(i).on = 1 THEN
      bigs(i).x = bigs(i).x + bigs(i).vx
      bigs(i).y = bigs(i).y + bigs(i).vy
      IF bigs(i).x < 0 THEN bigs(i).x = 240
      IF bigs(i).x > 240 THEN bigs(i).x = 0
      IF bigs(i).y < 0 THEN bigs(i).y = 176
      IF bigs(i).y > 176 THEN bigs(i).y = 0
      SPRITE PLACE 5 + i, bigs(i).x, bigs(i).y
    ENDIF
  NEXT
  FOR i = 0 TO 5
    IF sml(i).on = 1 THEN
      sml(i).x = sml(i).x + sml(i).vx
      sml(i).y = sml(i).y + sml(i).vy
      IF sml(i).x < 0 THEN sml(i).x = 248
      IF sml(i).x > 248 THEN sml(i).x = 0
      IF sml(i).y < 0 THEN sml(i).y = 184
      IF sml(i).y > 184 THEN sml(i).y = 0
      SPRITE PLACE 10 + i, sml(i).x, sml(i).y
    ENDIF
  NEXT
  ' --- shot vs rock ---
  FOR i = 0 TO 4
    IF bigs(i).on = 1 THEN
      FOR j = 0 TO 3
        IF shots(j).life > 0 THEN
          IF SPRITECOLLIDE(1 + j, 5 + i) THEN
            bigs(i).on = 0
            SPRITE HIDE 5 + i
            shots(j).life = 0
            SPRITE HIDE 1 + j
            sc = sc + 20
            SFX "thud"
            CALL split(i)
          ENDIF
        ENDIF
      NEXT
    ENDIF
  NEXT
  FOR i = 0 TO 5
    IF sml(i).on = 1 THEN
      FOR j = 0 TO 3
        IF shots(j).life > 0 THEN
          IF SPRITECOLLIDE(1 + j, 10 + i) THEN
            sml(i).on = 0
            SPRITE HIDE 10 + i
            shots(j).life = 0
            SPRITE HIDE 1 + j
            sc = sc + 50
            SFX "thud"
          ENDIF
        ENDIF
      NEXT
    ENDIF
  NEXT
  ' --- ship vs rock ---
  IF iv > 0 THEN iv = iv - 1
  IF iv = 0 THEN
    FOR i = 0 TO 4
      IF bigs(i).on = 1 THEN
        IF SPRITECOLLIDE(0, 5 + i) THEN dead = 1
      ENDIF
    NEXT
    FOR i = 0 TO 5
      IF sml(i).on = 1 THEN
        IF SPRITECOLLIDE(0, 10 + i) THEN dead = 1
      ENDIF
    NEXT
  ENDIF
  SPRITES UPDATE
  PRINTAT 0, 1, "score ", sc, "    lives ", lives
  IF dead = 1 THEN
    lives = lives - 1
    sx = 120
    sy = 88
    svx = 0
    svy = 0
    iv = 80
    SPRITE PLACE 0, sx, sy
    SFX "thud"
    IF lives = 0 THEN GOTO gameover
  ENDIF
  ' --- wave cleared? ---
  nbig = 0
  FOR i = 0 TO 4
    nbig = nbig + bigs(i).on
  NEXT
  FOR i = 0 TO 5
    nbig = nbig + sml(i).on
  NEXT
  IF nbig = 0 THEN CALL wave_up
  GOTO game

gameover:
  BORDER 2
  PRINTAT 10, 10, "  G A M E   O V E R  "
  PRINTAT 12, 10, "  score ", sc, "  "
endless:
  GOTO endless
