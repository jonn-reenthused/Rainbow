PROGRAM "BANKED"

DIM x AS BYTE
DIM p AS BYTE

MAIN:
  BORDER 1
  CLS
  IF CBM THEN
    ' cbm has no paged RAM — COPYBANK streams each banked file off the
    ' .d64 into resident RAM. pic loads straight at the hires bitmap:
    ' its 8000 bitmap bytes land in place and the 1000-byte matrix
    ' tail spills into free RAM at $5F40.
    COPYBANK "pic", #4000
    COPYBANK "tune", #6400
    COPYBANK "crypt", #6600
    COPYBANK "cavertiles", #6800
    COPYBANK "cavern", #6C00
    COPYBANK "gem", #7400
  ELSEIF CPC THEN
    COPYBANK "tune", #3000 ' copy tune into resident RAM at 0x3000
  ELSE
    COPYBANK "tune", #7000 ' copy tune into resident RAM at 0x7000
  ENDIF
  SHOWPIC "pic"          ' banked screen
  IF CBM THEN MODE 0     ' SHOWPIC entered bitmap mode; tilemap is text
  MUSIC "tune"           ' banked AY tune
  TILESET "cavertiles"   ' banked tileset
  TILEMAP "cavern"       ' banked tilemap
  TILEMAP VIEW 0,2,32,16
  TILEMAP CAMERA 0,0
  TILEMAP DRAW
  SPRITE CREATE 0,"gem",64,64  ' banked sprite
  CHARSET "crypt"        ' banked font
  PRINTAT 19,2,"BANKED GRAPHICS"
  x = 0
loop:
  HALT                   ' AY tick re-pages the song bank each frame...
  p = x AND 127
  IF p > 63 THEN p = 127 - p
  SPRITE PLACE 0, 40 + p, 64
  SPRITES UPDATE         ' ...and the compositor re-pages the sprite bank
  x = x + 1
  GOTO loop
