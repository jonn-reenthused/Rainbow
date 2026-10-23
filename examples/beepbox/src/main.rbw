PROGRAM "BEEPBOX"
TARGET ZX48

DIM k AS BYTE

MAIN:
  BORDER 2
  PAPER 0
  INK 7
  CLS
  PRINTAT 2, 4, "4 8 K   B E E P   B O X"
  PRINTAT 5, 4, "anteater beeper engine"
  PRINTAT 6, 8, "2 chan + drums"
  PRINTAT 8, 4, "1  play riff"
  PRINTAT 9, 4, "2  play lullaby"
  PRINTAT 11, 3, "z  laser   x  jump   c  coin"
  PRINTAT 12, 3, "v  hiss    b  thud"
  PRINTAT 15, 5, "tunes block the cpu"
  PRINTAT 16, 7, "that is 48k life"
game:
  HALT
  IF KEY(24) THEN MUSIC "riff"
  IF KEY(25) THEN MUSIC "lull"
  IF KEY(1) THEN SFX "laser"
  IF KEY(2) THEN SFX "jump"
  IF KEY(3) THEN SFX "coin"
  IF KEY(4) THEN SFX "hiss"
  IF KEY(60) THEN SFX "thud"
  GOTO game
