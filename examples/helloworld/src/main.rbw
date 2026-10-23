PROGRAM "HELLO"

' Rainbow hello world - exercises the Phase 0 feature set

DIM x AS BYTE = 5, y AS BYTE = 4
DIM score AS UINT = 0
CONST SPEED = 2

SUB FlashBorder(t AS BYTE)
  BORDER t
  PAUSE t
  BORDER 0
END SUB

MAIN:
  BORDER 0
  PAPER 0
  INK 7
  CLS
  CHARSET "main"
  PRINT AT 9,5;"RAINBOW COMPILED THIS"
  PRINT AT 10,5;"HELLO WORLD"
  PRINT AT 11,2;"X=";x;"  Y=";y
  score = score + 1000 + SPEED
  PRINT AT 13,2;"SCORE=";score

loop:
  IF KEY(40) THEN CALL FlashBorder(3)  ' P key
  HALT
  GOTO loop
