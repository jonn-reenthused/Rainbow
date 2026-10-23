# Rainbow BASIC — language reference

Rainbow BASIC is a structured, compiled BASIC-like language for ZX
Spectrum games. Sources are `.rbw` files compiled by
`rainbow_compiler` to Pasmo Z80 assembly, linked with the `rbt_*`
runtime and packed into a `.tap` image.

Statements are written one per line; `:` separates multiple
statements on one line (and is used inside `IF ... THEN`). `'` starts
a comment (also `REM`). Keywords are case-insensitive. `#ff` /
`$ff` / `0x` style hex is written `#FF` or `0xFF` in code.

## Program structure

```basic
PROGRAM "MYGAME"          ' program name (TAP filename)
TARGET ZX128              ' optional: ZX48 (default), ZX128 or CPC464.
                          ' When the build target comes from
                          ' project.rbw.json a conflicting decl warns
                          ' and is ignored.
INCLUDE "lib/util.rbw"    ' pull another source file into the build
                          ' (relative to the including file; may nest)

CONST SPEED = 2           ' compile-time constants
DIM x AS BYTE             ' global byte variable
DIM score AS UINT = 0     ' global 16-bit unsigned
GLOBAL DIM y AS BYTE      ' explicit global (top-level DIM already is)

MAIN:                     ' required entry label
  BORDER 0
loop:
  HALT
  GOTO loop

SUB moveIt(a, b)          ' subs take params, called with CALL or bare name
  ...
END SUB

FUNCTION twice(n)         ' functions return a value via RETURN expr
  RETURN n * 2
END FUNCTION
```

Execution starts at the `MAIN:` label. `DATA`/`READ`/`RESTORE` give
BASIC-style inline data: `DATA 1,2,"hi"` … `READ a, b, s$` …
`RESTORE` resets the pointer. `ASM "..."`/`ASM` blocks embed raw Z80
mnemonics (Pasmo syntax) inline.

## Types and variables

| Type     | Size   | Range            |
|----------|--------|------------------|
| `BYTE`   | 8 bit  | 0..255           |
| `UINT`   | 16 bit | 0..65535         |
| `INT`    | 16 bit | -32768..32767    |
| `STRING` | —      | string literals  |

`DIM x AS BYTE [= init]` declares a variable; `x = expr` assigns.
Arrays: `DIM a(10) AS BYTE`, indexed `a(i)`. `STRING` is a literal-only
type — `DIM ... AS STRING`, string parameters and string expressions are
compile errors (string literals may be passed to `SUB`/`FUNCTION`
parameters, where they arrive as the literal's address).

### Multidimensional arrays

`DIM g(3)(4) AS BYTE` declares a 3×4 array (row-major). Index with a
subscript per dimension — `g(row)(col)` — for both reads and writes:

```basic
DIM g(3)(4) AS BYTE
g(1)(2) = 42
x = g(1)(2)
```

Any number of dimensions is allowed; the row stride is the product of
the trailing dimension sizes.

### User types (structs)

`TYPE ... END TYPE` declares a struct; field types are `BYTE`, `UINT`
or `INT` (`STRING` fields and nested `TYPE` fields are not supported).
Declare variables and arrays of a type with `AS TypeName`:

```basic
TYPE Enemy
  x AS BYTE
  hp AS UINT
END TYPE

DIM e AS Enemy          ' one Enemy: x at +0, hp at +1
DIM foes(4) AS Enemy    ' array of 4, stride = sizeof(Enemy)

e.hp = 300              ' field write
foes(2).x = 9           ' array element, then field
x = foes(2).x           ' field read in an expression
```

Structs are memory-only records: you can't assign or pass a whole
struct (`e = f` is an error), and they can't appear inside other
structs or as `FUNCTION` return values. Access members with `.name`;
an unknown field name is a compile error.

Operators: `+ - * / MOD`, comparisons `= <> < > <= >=`, bitwise
`AND OR XOR NOT`, unary `-`. Division or `MOD` by a zero constant is a
compile error; a runtime zero divisor yields 0. Built-in functions: `ABS`, `MIN`,
`MAX`, `RND(n)` (0..n-1), `PEEK(addr)`, `PEEKW(addr)`, `IN(addr)`,
`POINT(x,y)`, `KEY(code)`, `INKEY`, `JOY()`, `JOYFIRE()`,
`TILEAT(x,y)`, `TILEFLAGS(id)`, `COLLIDETILE(id)`, `SPRITECOLLIDE(a,b)`,
`SPRITEX(id)`, `SPRITEY(id)`, `USR(addr)` (call machine code).

## Text, colours, screen

```basic
PRINT "score "; s;      ' ; = no newline; AT r,c positions
PRINTAT row, col, "hi"
INK 2 : PAPER 0 : BRIGHT 1 : FLASH 0
OVER 1 : INVERSE 0
BORDER 1
CLS
PLOT x, y               ' pixel (0..255, 0..191)
FILLATTR x, y, w, h     ' fill attr cells (8x8) with current INK/PAPER
CHARSET "font"          ' .rbf font asset -> PRINT uses it
SHOWPIC "title"         ' copy 6912-byte .rbc screen to the display
MODE n                  ' hardware screen mode (0-2). Real mode switch on
                        ' CPC; warns and no-ops on ZX (single fixed mode)
```

## Flow control

```basic
IF cond THEN stmts [ELSEIF cond THEN stmts] [ELSE stmts] ENDIF
IF cond THEN stmt       ' single-line form, no ENDIF needed
```

An `IF` whose condition is a constant expression is evaluated at
**compile time**: only the taken branch is compiled, so dead branches
may use target-only statements, assets or labels. Built-in target
constants make one source compile for several machines:

```basic
IF CPC THEN
  COPYBANK "tune", #3000  ' resident RAM on the 6128
ELSE
  COPYBANK "tune", #7000  ' resident RAM on the 128
ENDIF
```

`ZX` / `CPC` / `CBM` select the machine family; `ZX48`, `ZX128`,
`ZXPLUS3`, `CPC464`, `CPC6128`, `C64`, `C128` are 1 on that exact
target; `BANKED` is 1 on targets with pageable RAM (ZX128, ZXPLUS3,
CPC6128). They behave like
`CONST`s — usable in
expressions and CONST initialisers too. `TARGET` must remain an
unconditional top-level decl; pick targets per build via
`project.rbw.json` instead.

```basic
WHILE cond ... WEND
REPEAT ... UNTIL cond
FOR i = 1 TO 10 [STEP 2] ... NEXT i
GOTO label : GOSUB label
PAUSE n                 ' n frames (0 = wait key)
HALT                    ' vsync (also ticks AY music)
WAITKEY : STOP : END
RANDOMIZE [seed]
POKE addr, v : OUT port, v
```

## Keyboard & joystick

`KEY(code)` tests one matrix position; `code = row*8 + bit`:

| row | bits 0..4 keys              |
|-----|-----------------------------|
| 0   | Z X C V                     |
| 1   | A S D F G                   |
| 2   | Q W E R T                   |
| 3   | 1 2 3 4 5                   |
| 4   | 0 9 8 7 6                   |
| 5   | P O I U Y                   |
| 6   | ENTER L K J H               |
| 7   | SPACE SYM M N B             |

(e.g. `KEY(16)` = Q, `KEY(40)` = P, `KEY(56)` = SPACE.)

On CPC the same `line*8 + bit` encoding applies to the CPC's own
10×8 matrix (see the CPC key-number table); `JOY()` reads joystick 0
(matrix line 9) and `JOYFIRE()` maps fire 1 or fire 2. `JOYSTICK`
mode is accepted but ignored on CPC.

`INKEY` returns the ASCII of the first pressed key or 0.
`JOYSTICK KEMPSTON|SINCLAIR1|SINCLAIR2|CURSOR|OFF` selects a stick;
`JOY()` returns a direction bitmask, `JOYFIRE()` the fire bit.

## Sprites

```basic
SPRITE CREATE id, "sprite", x, y [, MASK|OR|XOR]   ' masked default
SPRITE MOVE id, dx, dy          ' relative pixel move
SPRITE PLACE id, x, y           ' absolute
SPRITE FRAME id, n              ' set animation frame
SPRITE ANIMATE id, first, last [, PINGPONG]
SPRITE REMOVE id
SPRITE HIDE id : SPRITE SHOW id : SPRITE REDRAW id
SPRITE ATTR id, ink, paper, bright
SPRITES DRAWALL                 ' draw every live sprite (direct to screen)
SPRITES UPDATE                  ' composited flicker-free update
x = SPRITEX(id) : y = SPRITEY(id)
hit = SPRITECOLLIDE(a, b)       ' pixel-precise masked overlap
solid = COLLIDETILE(id)         ' sprite vs map solid-flagged tiles
```

`solid = COLLIDETILE(id)` returns nonzero when the sprite overlaps a
tileset tile whose flag bit 0 is set (the tileset editor's `solid`
checkbox).

`CREATE`/`MOVE`/`PLACE` only update slot state — nothing appears until a
draw call. There are two drawing models:

### `SPRITES UPDATE` — composited, flicker-free (recommended)

Each slot remembers which character cells it last drew into. `UPDATE`
dirties the union of every sprite's old and new cell rectangle, then
rebuilds each dirty cell in a RAM buffer — background (the bound
tilemap's tile, or blank) plus every covering sprite slice — and writes
the finished cell to the screen in one burst. The screen never contains
a "sprite erased" state, so there is nothing for the raster to flicker
on. The game loop is simply:

```basic
' compute: keys, physics -> new positions
SPRITE PLACE 0, nx, ny
SPRITE PLACE 1, nx, ny
SPRITES UPDATE            ' one call commits the whole frame
' slow work (SFX, PRINT) is fine anywhere — the frame is complete
```

Notes:

- Works over a bound tilemap (cells rebuild from tile bitmaps+attrs) or
  over a blank background (bg bytes = 0). It does not know about
  hand-printed text or pixels — a sprite footprint always rewrites its
  cells, so keep HUD text out of sprite paths (or reprint it).
- Sprite attributes compose the same way: `attr` "none" keeps the
  background attr, otherwise the covering sprite's attr wins (lowest
  slot id last).
- Hiding/removing a sprite then `UPDATE` cleanly restores the
  background.
- Do not mix `UPDATE` with `DRAWALL`/`REDRAW` on the same sprite — the
  rect bookkeeping only tracks `UPDATE` draws.
- `TILEMAP SCROLL` shifts screen bytes, which moves sprite pixels too —
  the smear is not tracked by `UPDATE`'s bookkeeping. For scrollers,
  keep the erase/draw idiom (below) or re-place + update after
  scrolling.

### `SPRITES DRAWALL` / `SPRITE REDRAW` — direct erase/draw

The classic model: `REDRAW` redraws a sprite where it sits (with `XOR`
mode, redrawing erases). To animate, erase and redraw **each sprite
individually** so it is off screen only for its own draw call:

```basic
SPRITE REDRAW 0          ' erase sprite 0 (XOR erases by redrawing)
SPRITE PLACE 0, nx, ny
SPRITE REDRAW 0          ' draw at new position
```

Erase-all-then-draw-all also works, but every sprite spends the whole
gap invisible — the raster catches the erase and shows flicker. Keep
anything slow (collision code, `SFX`, `PRINT`) out of the erase/draw
window.

## Tilemaps

```basic
TILESET "tiles"                 ' bind a .rbt tileset (rebidable any time)
TILEMAP "level"                 ' bind a .rbm map (rebidable — e.g. next level)
TILEMAP VIEW x, y, w, h         ' viewport in tile cells on screen
TILEMAP CAMERA cx, cy           ' map-space top-left of the view
TILEMAP DRAW                    ' draw whole view
TILEMAP REDRAW x, y, w, h       ' redraw a view-space cell rect
TILEMAP SCROLL dir [n]          ' dir = LEFT|RIGHT|UP|DOWN, n cells
TILEATSET x, y, id              ' write a map cell
id = TILEAT(x, y)  :  f = TILEFLAGS(id)
```

`SCROLL` moves the camera one cell per step and shifts the view's
bitmap+attr bytes, redrawing only the newly exposed column/row — not
the whole view. Anything already on screen (sprites) shifts with the
map; the usual sprite-over-scroller idiom is: scroll, XOR-erase the
sprite at its shifted position, then redraw it at the new one
(see `examples/scroller`). A `CAMERA` jump is not a shift — follow it
with `TILEMAP DRAW`.

On CPC `SCROLL` is a hardware scroll: the CRTC display start moves one
cell per step — no screen bytes are copied, so it is essentially free —
and the incoming edge column/row is drawn into the circular band the
hardware exposes. Text, tiles, sprites and plots on rows above the
split are anchored to their logical positions, so they scroll with the
world exactly like the map. The static band (below) is how the HUD
stays put.

Rebinding a map clamps the camera into the new map's bounds, so
`TILEMAP "level2"` + `TILEMAP CAMERA 0,0` + `TILEMAP DRAW` is the
standard level-switch pattern.

### CPC static band

On firmware CPC builds the runtime derives a **static band** from the
tilemap view: a raster interrupt restores the natural display start
below the view, so rows at and below the split never scroll. The CPC
raster interrupts only fire at fixed positions, so the split lands on
the first valid row ≥ `view y + view h`: **5, 11, 18 or 24**. For
`TILEMAP VIEW 0,0,32,18` the split is row 18 — put the scoreline and
other static text on rows 18-23.

Constraints to know about:

- Rows between the view bottom and the split row scroll with the
  world.
- In the scrolling region, `PRINT`/`PRINTAT` only land correctly with
  a custom `CHARSET` — the firmware font draws at the natural address
  and would appear at a rotated position.
- Views that reach past row 24 get no band (the whole screen scrolls).
- On `.cpr` cartridge builds there is no firmware event chain, so the
  whole screen scrolls — keep HUD text out of scrolling games there.
- The CPC screen is 40 cells wide; the rightmost 8 columns beyond the
  32-cell logical view show the map streaming in early — that is the
  hardware exposing the incoming column, not corruption.

## Sound (Phase 3)

```basic
MUSIC "tune"    ' 48K: blocking AntEater beeper tune (.rnt or .ray —
                '   .ray converts to beeper rows at build time)
                ' 128K/+3: non-blocking AY tune (.ray or .rnt — .rnt
                '   converts to AY rows), ticked on HALT/PAUSE
MUSIC STOP      ' 128K/+3 only: silence the AY
MUSIC TICK      ' 128K/+3: advance one frame manually (rarely needed)
SFX "zap"       ' queued .rsf beeper effect (both targets) — plays at
                ' the next idle point (HALT/PAUSE/WAITKEY/SPRITES UPDATE
                ' entry) so it uses dead frame time; a second SFX while
                ' one is still queued plays the first immediately
```

`TARGET ZX128`/`TARGET ZXPLUS3` (or `"target": "zx128"`/`"zxplus3"` in
`project.rbw.json`) selects the AY path for `MUSIC`. Either song
format works on every target — `.ray` is the canonical interchange
(see `formats.md`): on 48K it encodes as AntEater rows, on 128K/+3
`.rnt` encodes as AY rows, and both play natively on their own
engine. On 48K the tune plays
to completion before returning. A zx128 TAP with no banked assets is a
plain 48K-compatible tape — it still needs to run on a **128K machine**
(Fuse: `Machine → Spectrum 128`, or `--machine 128`); on a 48K machine
the AY chip isn't present, so `MUSIC` is silent while beeper `SFX`
keep working.

## Banked assets (zx128 / zxplus3 / cpc6128)

On ZX 128, assets under `assets/bank<N>/` (N ∈ 0,1,3,4,6,7 — banks
5/2 hold the screen and resident code) are packed into 16K RAM-bank
images loaded into `0xC000` by the generated loader stub. On the +3
(`zxplus3`), N ∈ 0,3,4,6 — bank 7 is +3DOS's workspace and bank 1 is
its sector cache — and each bank image ships as `BANKn.BIN` on the
built `.dsk`; a machine-code stub at the top of the resident binary
calls +3DOS (`DOS_OPEN`/`DOS_READ` with the bank in C) to fill the
banks before `MAIN:` runs. On CPC 6128, N ∈ 4,5,6,7 (the second
64K's physical banks; 0-3 are the base 64K) and each bank image ships
as `BANKn.BIN` on the built `.dsk` — the game's startup code pages
each bank into `0x4000` and loads its file via the firmware before
`MAIN:` runs. Referencing a banked
asset in any statement (`SHOWPIC`, `MUSIC`, `TILESET`, `TILEMAP`,
`SPRITE CREATE`, `CHARSET`, `SFX`) automatically pages its bank in
first on both machines.

```basic
USEBANK 3                 ' page bank 3 at 0xC000 (zx128; use 4-7 at 0x4000 on cpc6128)
COPYBANK "tune", #7000    ' copy a banked asset into resident RAM
```

Bound banked resources are safe to keep bound: the runtime re-pages
the right bank around every access (map cells, tile bitmaps, sprite
frames during `SPRITES UPDATE`/`REDRAW`, font glyphs while printing,
the song bank on every AY frame tick). `USEBANK`/`COPYBANK` and the
AY tick save and restore the current page, so mixes like a bank-1
tilemap + bank-3 song just work. `map.txt` in the build dir lists
per-bank usage.

Banked builds only run on a banked machine: on a 48K the `0x7FFD`
page writes are ignored and every bank blob lands in the same
`0xC000` window; on cpc464 the target simply rejects banked assets
at build time. On cpc6128 the gate array's `#C4`-`#C7` configs page
each bank at `0x4000-0x7FFF` (the screen stays at `0xC000`, which
they never remap) — keep `COPYBANK` destinations and resident data
out of the `0x4000-0x7FFF` window. On c64 there is no paged RAM at
all: banked assets ship as individual files on the `.d64` and
`COPYBANK "name", dest` is a kernal `LOAD` of file `NAME` from drive
8 into `dest` (use any `bank<N>` dir — the N is ignored). `USEBANK`
is not supported.

On c64 a banked asset's *name* resolves to wherever it was
COPYBANK'd: every statement that takes an asset (`MUSIC`, `SHOWPIC`,
`TILESET`, `TILEMAP`, `CHARSET`, `SPRITE CREATE`, `SFX`) resolves the
name to the resident copy, so `COPYBANK "tune", #6400` then
`MUSIC "tune"` plays from `$6400`. The dest must be a constant
expression, identical across all COPYBANKs of the same asset
(target-guarded IF branches count once), and the copy must run
before the asset is used. Referencing a banked asset without a
COPYBANK is a compile error. Free RAM for copies is the code region
plus `$6000-$77FF` when the hires bitmap is in play — and a screen
`.rbc` can stream straight at the bitmap: `COPYBANK "pic", #4000`
lands the 8000 bitmap bytes in place (its 1000-byte matrix tail
spills harmlessly at `$5F40`), then `SHOWPIC "pic"` finishes the
blit. The `.crt` can't carry asset files, so banked builds ship the
`.d64` only.

## Platforms (cpc464 / cpc6128)

The same source can build for the Spectrum (`zx48`/`zx128`, `.tap`;
`zxplus3`, a +3DOS `.dsk` booted by the Loader menu's `DISK` file),
the Amstrad CPC 464 (`cpc464`, `.cdt` via `pasmo --cdtbas`) and the
CPC 6128 (`cpc6128`, `.dsk` — a standard AMSDOS disk image run with
`RUN"NAME.BIN"`). Select the target in `project.rbw.json` (`"target"`
or a `targets` map key) or with `TARGET CPC464`/`TARGET CPC6128`; the
CPC build defaults to org `0x4000` on the 464 and on a bankless
6128; when `assets/bank<N>/` files exist the 6128 moves to `0x8000`
so resident code stays clear of the `0x4000-0x7FFF` bank window.
No `TARGET` decl is needed when the manifest names the target.

The CPC runtime is firmware-backed: `MODE` calls `SCR_SET_MODE`
(modes 0–2), `BORDER`/`INK`/`PAPER`/`FLASH` program inks via
`SCR_SET_INK` (ZX colour indices are translated, so `INK 7` is white
text on both machines — `BRIGHT` picks the brighter ink table),
`CLS` clears via `SCR_CLEAR`, `PRINT`/`PRINTAT` go through the text
VDU, `HALT`/`PAUSE` wait on frame flyback, and `WAITKEY`/`INKEY`
use the key manager (keyboard scanning runs on the CPC hardware
matrix via the PSG, so `KEY`/`JOY` work without the firmware too).

Graphics and sound work on CPC, in mode 1 (320x200, 4 pens — the
logical screen is the top-left 256x192). `SPRITE`/`SPRITES` run a
masked software sprite engine (create/place/move/frame/anim/kill/
hide/show, MASK/OR/XOR modes, `SPRITEX`/`SPRITEY`/`SPRITECOLLIDE`),
`TILESET`/`TILEMAP`/`SCROLL`/`CAMERA`/`VIEW`/`TILEAT`/`TILEATSET`/
`TILEFLAGS`/`COLLIDETILE` run the tilemap engine, `CHARSET` switches
`PRINT`/`PRINTAT` to software-drawn `.rbf` glyphs, `PLOT`/`POINT`
plot/test mode-1 pixels, `SHOWPIC` blits a converted `.rbc`, `SFX`
plays `.rsf` effects on the AY's channel C, and `MUSIC` plays
`.ray` songs via the PPI — `.rnt` songs work too (the build
converts them to `.ray` rows on the fly; both stay shareable with
the ZX build).

Every CPC build also emits `build/<NAME>.cpr`, a CPC+/GX4000
cartridge image. Page 0 carries a small preamble that relocates the
payload into RAM at the normal org (so variables stay writable,
unlike a raw ROM image); an unbanked payload may span several 16K
pages — the preamble walks them through the `$DF00` ROM-select port —
while banked programs must still fit page 0 because their bank blobs
take the pages after it. The runtime is firmware-free: the CRTC and
GA inks are initialised directly, the keyboard matrix is scanned
without the key manager, and banked asset blobs ship as extra `cb`
pages which
`rbt_bankload` copies into RAM banks at startup. Banked cartridges
need a 128K CPC+ (a 6128+) — the GX4000 is 64K-only, so its gate
array MMR writes are no-ops and the extra cart pages can't reach
RAM. MAME: `mame cpc6128p -cart game.cpr` (gx4000 works for
unbanked carts).

CPC divergences to know about:

- `FILLATTR` recolours the **whole screen** — CPC has no attribute
  plane, so it programs the pen inks globally (warns at build time).
- `INK`/`PAPER` program pen 1/pen 0 inks globally, not per cell.
- Sprites and tiles are pen 1 on pen 0 (2 colours); the multicolour
  pens 2/3 aren't used yet. Sprite rects above ~160 bytes of
  coverage draw but can't auto-erase.
- `MUSIC` plays via the CPC AY — `.ray` period data is rescaled for
  the 1 MHz clock automatically. `SFX` steals AY channel C while
  playing.
- `USEBANK`/`COPYBANK`/`assets/bank<N>/` work on cpc6128 (banks
  4-7, disk `.dsk` output) and error politely on cpc464 — banked
  RAM is a 6128 feature. `ATTR`/`OVER`/`INVERSE` semantics
  aren't mapped yet.

A portable program written against the supported subset compiles
unchanged for both machines.

## Platforms (c64)

The Commodore 64 (`c64`) is the first non-Z80 target: the compiler
emits ca65 6502 assembly, assembled and linked by `ca65`/`ld65` into a
`.prg` (a `10 SYS 2062` BASIC stub at `0x0801` means `LOAD` + `RUN`
starts the program), a kernal-format `.tap` cassette image, a `.d64`
1541 disk image holding the same program, and — when the code fits
16K and there are no banked assets — a `.crt` cartridge image. Boot
the tape with `LOAD` then `RUN` (MAME: `mame c64p -cass game.tap`,
press PLAY), or the disk with `LOAD"*",8,1` then `RUN` (MAME: `mame
c64p -flop game.d64 -autoboot_command "LOAD\"*\",8,1\nRUN\n"
-autoboot_delay 3`). The `.crt` is a normal 16K cart (CBM80
signature): a boot stub copies the payload from ROM to `0x0801` and
jumps the program entry — insert it and reset (`x64sc -cartcrt
game.crt`, MAME `-cart`).

Currently supported on c64: the core language — `PRINT`/`PRINTAT` on
the 40x25 text screen with colour RAM, `CLS`, `BORDER`, `PAPER`,
`INK`, `BRIGHT`, `FLASH` (reverse video), `CHARSET` (an `.rbf` font is
copied to charset RAM and the VIC pointed at it), `FILLATTR`,
`HALT`/`PAUSE` (PAL raster-synced at 50 Hz), `KEY`/`INKEY`/`ANYKEY`
(CIA1 matrix scan, same `col*8+rowbit` codes), `JOY` (port 2), `RND`,
`ABS`/`SGN`, `DATA`/`READ`/`RESTORE`, `DIM`/`LET`/`IF`/`FOR`/`WHILE`/
`REPEAT`/`GOSUB`/`CALL` and friends.

Tilemaps run in text mode: `TILESET`/`TILEMAP`/`VIEW`/`CAMERA`/`DRAW`/
`REDRAW`/`SCROLL`/`TILEAT`/`TILEATSET`/`TILEFLAGS` all work. The C64
screen is already a tilemap — a tile is an 8x8 character cell, so
`TILESET` patches the `.rbt` bitmaps into charset RAM at screen codes
128+ (charset base `$3800`, tile glyphs at `$3C00`) and drawing writes
the tile index to screen RAM plus `attr & $0f` to colour RAM. Up to
128 tiles per set. `CHARSET` and `TILESET` coexist — the font owns
codes 32-127, tiles own 128+ and codes 0-31 come from the chargen ROM
— but reverse-video text (`FLASH`/`OVER` set, codes 128+) collides
with tile glyphs. `COLLIDETILE` waits on sprites.

Sprites are VIC-II hardware sprites behind a 16-slot multiplexer:
`SPRITE CREATE`/`MOVE`/`PLACE`/`FRAME`/`ANIMATE`/`REMOVE`/`HIDE`/`SHOW`/
`REDRAW`/`ATTR`, `SPRITES UPDATE`/`DRAWALL`, `SPRITEX`/`SPRITEY`,
`SPRITECOLLIDE` (bounding-box, as on ZX) and `COLLIDETILE` all work.
Logical coords match the ZX (x 0-255, y 0-191); the runtime adds the
border offsets (hw = x+24, y+50). A raster-IRQ chain rebinds the 8
hardware sprites by Y as the beam passes, so more than 8 sprites can
be on screen. `.rbs` assets are re-encoded per target: cbm frames are
24x21 1bpp (63 bytes), source pixels clipped/padded to fit; `o` paper
pixels are transparent (hardware sprites have no mask), and the sprite
colour is `attr`'s ink+bright nibble (`"none"` -> white). `MASK`/`OR`/
`XOR` modes are accepted but ignored — hardware sprites always draw
over the background.

Sound works via the SID: `MUSIC`/`MUSIC STOP`/`MUSIC TICK` are
non-blocking (the player ticks once per frame from `rbt_hook_frame`,
exactly like the AY targets) and `SFX` keeps the same queue/drain
model — an effect plays blocking at the next idle point on SID voice
3, so music reasserts that voice on its next row. `.ray` songs are
converted at build time: each row becomes three voice freq/ctrl
writes plus a shared pulse-width and master volume (AY tones map to
the pulse wave at 50% duty, noise-only channels to noise, ZX-clock
periods rescale to SID frequency registers). Map-form rows may
override the auto mapping per voice with `"wave":["tri","saw",...]`
(tri/saw/pulse/noise/off, or a raw SID waveform-bits int for combined
waveforms), set a shared 12-bit pulse width with `"pw"` and the SID
master volume with `"vol"` — all ignored on other targets. Compute!
Sidplayer `.mus` songs import to `.ray` (`Import .mus` in the IDE or
`rainbow import-mus`) keeping waveform, pulse width, volume and
transposition; envelope and effect commands are reported as skipped. `.rnt` files also work —
they go through the same AntEater→AY→SID conversion chain the CPC
uses. `.rsf` steps become 6-byte `{len,dur,freq,slide}` voice-3
sweeps.

Banked assets work differently on c64 — there's no pageable RAM, so
`assets/bank<N>/` files ship as individual PRG files on the `.d64`
and `COPYBANK "name", dest` streams one in via kernal `LOAD` from
drive 8. `USEBANK` stays unsupported. `COPYBANK` needs the game
running off the disk — the `.tap` can't carry the asset files, so
projects using it should ship the `.d64`.

`MODE 1` switches the VIC to a hires bitmap in bank 1: 320x200
pixels at `$4000-$5F3F` with a 1000-byte colour matrix at `$7C00`
(foreground/background nibble per 8x8 cell — `INK`/`PAPER` and
`FILLATTR` write it). `PLOT`/`POINT` work over it, `OVER 1` inverts
pixels, and `SHOWPIC` blits a converted `.rbc` (the ZX 256x192
bitmap lands in the left/top of the frame; `SHOWPIC` enters mode 1
itself). `MODE 0` restores the text screen and charset. The bitmap
owns all of bank 1, so programs linking the pixel module are
capped at `$4000` (about 14K of code+data); the sprite pool moves
to `$7800` with the mode and keeps working, but mid-frame mode
switches are not recommended. Text/charset/tilemap state is
preserved across mode changes via a `$D018` shadow.

`IF CBM`/`IF C64` guard the shared-source differences.

The `c128` target shares this backend and runs native C128 mode:
the image links at `$1C01`, boots with a BASIC `SYS` stub and also
ships as a double-sided `.d71` (1571) disk. At runtime the MMU
configuration is switched around I/O access — `$0F` holds flat RAM
at `$4000`-`$BFFF` for code/assets (about 40K), while VIC/SID/CIA
touches pass through an I/O-visible window. Rainbow installs its
own raster IRQ and chains to the kernal past its raster-split
manager, so `SPRITE` multiplexing, `MODE 1` bitmaps, `COPYBANK`
disk loads and `MUSIC`/`SFX` all work. `IF CBM` and `IF C128` guard
the differences.

### Per-platform assets

A directory `assets-<key>/` next to `assets/` holds target-specific
replacements (e.g. `assets-cpc464/` — `<key>` is the `targets` map
key, or the canonical target name for a flat manifest). A file with
the same logical asset name overrides the shared one for that
target only — so a 16-colour `ship.rbs` for CPC can live beside the
4-colour ZX one while `.ray` music stays shared.
