# Rainbow asset formats

Assets are JSON files under `assets/` (or `assets/bank<N>/` for 128K
banked data), encoded at build time into compact runtime binaries by
`rainbow_assets`. Only assets *referenced by code* are emitted into
the binary — unused files cost nothing.

## `.rbs` — sprite

```json
{"w":16, "h":16, "attr":"none",
 "frames":[["................", "...#.##...", ...], ...]}
```

- `w` multiple of 8 (≤248), `h` 1..192.
- `frames`: list of frames; each frame is `h` strings of `w` chars
  (`#` = set pixel, anything else clear).
- `attr`: attribute byte for all cells, or `"none"`/`0xFF` to skip
  attribute writes (transparent sprites over existing attrs).
- Frame chars: `#`/`1`/`*` = opaque ink, `o` = opaque paper (erases
  the background), `.`/`0`/` ` = transparent.
- Encoded: `wb, h, nframes, attr`, then a `nframes*8` u16 offset
  table (phase-major: `offs[phase*nframes + frame]`, absolute from
  asset start), then per frame a mask plane (`wb*h` bytes, 1 = keep
  screen pixel) + bitmap plane (`wb*h` bytes) — used by the immediate
  `SPRITE DRAW` path — then pre-shifted blocks: for each of the 8
  pixel phases × each frame, `h` rows × `wb+1` `(mask,bmp)` pairs
  (the `(prev<<8|cur)>>shift` compositor result precomputed), used by
  the `SPRITES UPDATE` compositor.
- CPC-encoded (mode 1): `wpx, h, nframes, attr`, then a `nframes*4`
  u16 offset table, then per pixel phase p in 0..3 × each frame,
  `h` rows × `wpx/4+1` columns of `(mask,bmp)` pen1/pen0 bytes —
  mask bits keep the screen (`0x88>>k` per pixel), bmp bits draw
  pen 1 (`0x08>>k`).

## `.rbt` — tileset

```json
{"tiles":[["........","..####..",...8 rows], ...],
 "attrs":[56, ...], "flags":[1, ...], "attr":56}
```

- Any number of 8×8 tiles (row strings like sprites).
- `attrs` per-tile attribute byte (default `attr` = 0x38);
  `flags` per-tile flags — **bit 0 = solid** (used by `COLLIDETILE`).
- Encoded: `ntiles` + `n×8` bitmap bytes + `n` attrs + `n` flags.

## `.rbm` — tilemap

```json
{"w":64, "h":24, "map":[0,0,1, ...]}
```

- `w`,`h` in cells (1..255); `map` = `w*h` tile indices, row-major.
- Encoded: `w, h` + `w*h` bytes.

## `.rbf` — font

```json
{"name":"main", "system":"zx", "w":8,
 "chars":{"65":["00111100","01000010",...8 rows]}}
```

- `system`: `"zx"` (default, also the v1 format), `"cpc"` or `"c64"` —
  selects the geometry, pixel depth and stock font the editor offers.
- `w`: glyph cell width in pixels, `4` or `8` (default 8). Narrow
  glyphs pack left; CPC mode-0 fonts often use 4 for 40-column text.
- `mode` (CPC only): screen mode 0/1/2 → glyph pixel depth 4/2/1 bpp.
  Multibpp rows use a hex digit per pixel (`'0'`..max; `'#'` aliases
  the max). Encoded with the CPC hardware interleave — mode 0 packs
  2 px/byte (16 pens), mode 1 packs 4 px/byte (4 pens).
- `multi` (C64 only): multicolour text — `w` is forced to 4, each
  pixel is a 2-bit pair packed 4/byte. Pair values: `0`=background,
  `1`=multi1, `2`=multi2, `3`=colour-RAM foreground.
- `chars` maps ASCII code (string) → 8 row strings of `w` chars.
  Glyphs not present **inherit the system ROM font** (Spectrum, CPC
  firmware or C64 chargen per `system`) — a font file only needs its
  deltas. `"base":"blank"` opts out (unset = blank).
- Encoded: 96 glyphs × `ceil(w*bpp/8)` bytes/row × 8 rows, glyph
  index = ascii − 32. ZX/CPC-m2/C64-hires are 8 bytes/glyph 1bpp.

**Note:** multicolour/width-variant fonts encode correctly but the
runtimes currently render 8×8 1bpp fonts only — full per-mode font
rendering is a planned runtime change.

## `.rbc` — screen

```json
{"bitmap":"<6144 bytes hex>", "attrs":"<768 bytes hex>"}
```

- Full 6912-byte screen in Spectrum display order (thirds → char
  rows → pixel lines; attrs 32×24 row-major), ready to LDIR to 0x4000.
- CPC-encoded: the bitmap expands to mode-1 pen1/pen0 bytes in
  y-linear order (192 lines × 64 bytes); attrs are ignored (pen inks
  are set via `INK`/`PAPER`).
- C64-encoded: 8000-byte linear hires bitmap (`char_row*320 +
  char_col*8 + line`, ZX's 256x192 in the top-left of the 320x200
  frame) + 1000-byte colour matrix (`ink|bright << 4 | paper|bright`
  per cell, ZX `FLASH` swapping the nibbles).
- `assets/screens/loading.rbc` (or a raw `loading.scr`) becomes the
  TAP loading screen automatically — it only costs game RAM if code
  also `SHOWPIC`s it.
- The screen editor imports PNG/GIF/JPG/BMP (`imageToScreen` in
  `rainbow_assets`: per-8×8-block ink/paper quantise, bright-aware,
  bilinear letterbox/crop fit).

## `.rnt` — beeper music (AntEater, 48K)

```json
{"type":"rnt", "speed":6, "loop":-1,
 "rows":[{"spd":0,"n1":30,"d1":1,"n2":0,"d2":0,"dr":0}, ...]}
```

Per row: `spd` row speed (0 = keep last), `n1`/`n2` note indices for
the two tone channels (0/1 = rest, 2 = C2, +12 per octave —
`antPeriodTable` is 1tracker-compatible), `d1`/`d2` ornament/detune,
`dr` drum 0..4 (1=noise A, 2=noise B, 3=noise C, 4=thud).
`loop` = row index the order loops at; -1 = play once and stop.
Blocking on 48K (`MUSIC "name"` plays to the end before returning).
Every other target converts `.rnt` to `.ray` rows at build time —
AntEater counter × 92·clk/56 = AY period (clk = 1 MHz on CPC,
1.7734 MHz on ZX128/+3), speed × 0.6755 = frame count, drums → noise
on channel C — so the same file plays on the AY engine. On C64 it
goes rnt → CPC AY rows → SID rows (see `.ray` below).

## `.rsf` — beeper SFX

```json
{"type":"rsf", "steps":[{"per":60,"len":40,"slide":-1}, ...]}
```

Each step toggles the speaker `len` times with period `per`, adding
`slide` (signed) to the period each iteration. `len` 0 ends.
Blocking; works on both targets. On CPC the step encodes as
`{len, dur, q8 period, q8 slide}` for the AY channel-C player —
period/slide convert the ZX toggle cost (16T/unit + overhead) to AY
units ((32*per+152)/56 in eighths), `dur` matches the step's wall time.
On C64 the step encodes as `{len, dur, freq, slide16.8}` for the SID
voice-3 player — `freq` is the SID frequency register
(3.5e6/(32*per+152) Hz × 2^24/985248), `slide` a signed 16.8 per-step
delta linearised at the step's initial period.

## `.ray` — music (all targets)

The canonical cross-target song format. Row semantics are machine-
agnostic — *three melodic channels × {period, volume} + shared noise
period + channel mixer + hardware envelope* — expressed as AY
register snapshots for authoring convenience: each row writes all
14 AY regs once per frame-tick for `dur` frames. Every chip's
encoder converts from this common row model.

**Reference clock**: periods are authored for the ZX AY clock,
1.7734 MHz (`f = 1773400 / 16·period`). Each target rescales.

```json
{"type":"ray", "loop":-1,
 "rows":[ {"dur":6, "a":[428,15], "b":[0,0], "c":[0,0],
           "noise":4, "mixer":62, "env":[0,9], "eshape":255},
          [6, r0, r1, ..., r13], ...]}
```

- Map form: `a`/`b`/`c` = `[period, vol]`, `noise` (r6), `mixer` (r7,
  default 0x38 = all tones on), `env` = r11/12, `eshape` = r13
  (255 = don't touch the shape register).
- List form: raw `[dur, r0..r13]` — this is what the `.mod` importer
  emits; the music editor accepts and normalises both.
- `loop` = row index to jump back to (row 0 works — the on-disk
  sentinel is `0xFFFF`), -1 = stop and silence the chip.
- Non-blocking on AY/SID targets: `MUSIC "name"` returns immediately
  and each `HALT`/`PAUSE`/frame-sync ticks the player via
  `rbt_hook_frame`. Blocking on 48K.

Per-target conversions:

| Target | Encoding | Lossy bits |
|---|---|---|
| zx128/+3 | native 15-byte AY rows | none |
| zx48 | AntEater `.rnt` binary | 2 most-active channels → 2 voices (3rd dropped); vol → on/off; noise → drum 1 (map-form `"drum":0..4` overrides); env ignored; `dur` frames → 92 Hz speed units (×1.48), long rows split at 63 |
| cpc464/6128 | AY rows, periods ×0.564 (1 MHz clock) | none (native AY) |
| c64 | 13-byte SID rows: `dur` + per voice `{defw freq, defb ctrl}` + shared `defw pw` + master vol | AY tone → pulse ($41), noise-only → noise ($81); env ignored; voice on iff vol non-zero and mixer enables it |

Extension keys (map-form rows only; encoders that don't understand a
key ignore it, so one file still plays everywhere):

- `"wave":["pulse","tri","noise"]` — per-voice waveform select for the
  SID (`tri`/`triangle`, `saw`/`sawtooth`, `pulse`/`square`, `noise`,
  `off`). An int entry (0–255, high nibble used) sets raw SID waveform
  bits for combined waveforms — the `.mus` importer emits these.
  Missing/unknown entries keep the auto mapping.
- `"pw":2048` — shared 12-bit SID pulse width, written to all three
  voices each row (only voices playing `pulse` are affected).
- `"vol":15` — SID master volume ($D418), written each row.
- `"drum":0..4` — AntEater drum voice for the beeper encoder
  (overrides the noise-channel heuristic).

## `.mod` import

`modToRay` (IDE `+` → *Import .mod → .ray*, or
`rainbow import-mod file.mod out.ray`) converts 4-channel ProTracker
`.mod` to `.ray`: Amiga period ÷32 → AY period, channel 4 dropped,
`Fxx` speed / `Cxx` volume / `Bxx`,`Dxx` flow handled; unconverted
effects are listed in the report output.

## `.mus` import

`musToRay` (IDE `+` → *Import .mus → .ray*, or
`rainbow import-mus file.mus out.ray`) converts Compute! Sidplayer
`.mus` songs (type B / Enhanced, e.g. the CGSC collection in
`docs/CGSC`) to `.ray`: the three voice streams — two-byte note and
command pairs — are decoded into a shared 50 Hz frame grid and
quantised to `.ray` rows.

- Notes decode per the spec: duration bits 4–2 as 64ths of a whole
  note, dot/triplet modifiers, octave = 7 − bits 5–3, accidentals
  (incl. double sharp/flat). Tempo comes from `TEM`
  (quarters/min = 14400 ÷ value) — a global setting shared by voices
  without their own.
- `CAL n` calls measure `n` (`MS#` markers); calls are expanded inline
  with a recursion guard. `WAV` → `"wave"` (raw SID bits incl.
  combined waveforms), `P-W` → `"pw"` (first pulse-playing voice wins —
  the SID row shares one pw), `VOL` → `"vol"` master volume,
  `TPS` transposes following notes, rests silence the channel.
- Sidplayer features with no `.ray` home — ADSR (`ATK`/`DCY`/`SUS`/
  `RLS`), vibrato (`VRT`/`VDP`/`PVD`/`PVR`/`AUT`), filters (`F-M`,
  `FLT`/`F-X` flags), portamento, detune, repeats and flow commands —
  are skipped and counted in the report output. Stereo `.str` second-
  voice files and `.wds` lyrics are not imported.
- Result plays on every target; it is most faithful on c64 where the
  `wave`/`pw`/`vol` keys take effect — remaining differences vs the
  original are the fixed A0 D9 S15 R0 envelope and dropped fx.

## 128K banked assets

Any asset file under `assets/bank<N>/` (nested subdirs allowed) is
packed into that bank's 16K image instead of the resident binary.
N is 0,1,3,4,6,7 on zx128, 0,3,4,6 on zxplus3 (bank 7 is +3DOS's
workspace, bank 1 its sector cache) and 4,5,6,7 on cpc6128 (each
platform's pageable set — the other banks hold the screen and
resident code).
Bank blobs load into the platform's bank window (`0xC000` on ZX,
`0x4000` on CPC): on zx128 via the generated loader stub's
`0x7FFD` writes, on zxplus3 via `rbt_p3load` — a machine-code stub at
the top of the resident binary that calls +3DOS's `DOS_READ` per
`BANKn.BIN` file (the routine pages the target bank itself) — and on
CPC via `rbt_bankload`, which runs before `MAIN:`,
pages each bank with the gate array (`out #7Fxx`, configs `#C4`-`#C7`
map the bank at `0x4000-0x7FFF`)
and `CAS IN DIRECT`s its `BANKn.BIN` file off the `.dsk` straight
into the paged window.
Asset statements auto-page around every access. `build/map.txt`
reports resident size and per-bank usage/free.

The `.dsk` itself is a standard CPCEMU disk image (40 tracks, 9 x
512B sectors, data format): `NAME.BIN` (org `0x4000`, or `0x8000`
when bank files keep the `0x4000` window reserved) plus one
`BANKn.BIN` per used bank, all with AMSDOS headers.
