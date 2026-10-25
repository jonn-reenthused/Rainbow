PROGRAM "HELLO"
' exercises a representative slice of codegen
DIM score AS UINT
DIM x AS BYTE
DIM i AS BYTE

SUB bump(n AS UINT)
  score = score + n
END SUB

MAIN:
  BORDER 0 : PAPER 0 : INK 7 : CLS
  PRINTAT 5, 9, "HELLO"
  score = 100
  FOR i = 1 TO 10
    bump(2)
    x = x + 1
  NEXT
  WAITKEY
END
