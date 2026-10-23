PROGRAM "SFXTEST"
TARGET ZX48

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  PRINTAT 3, 5, "SFX TEST - single shots"
  PRINTAT 5, 5, "laser.. jump.. coin.."
  PRINTAT 6, 5, "hiss.. thud.. repeat"
  SFX "laser"
  PAUSE 30
  SFX "jump"
  PAUSE 30
  SFX "coin"
  PAUSE 30
  SFX "hiss"
  PAUSE 30
  SFX "thud"
  PAUSE 60
loop:
  GOTO loop
