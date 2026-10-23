# Rainbow IDE guide

The Flutter IDE (`ide/`) is the visual half of Rainbow: project
management, code editing with live diagnostics, asset editors, and
one-button build/run.

## Projects

- **New** (title bar / ⌘⇧N): pick a parent folder, name the project,
  choose 48K or 128K. Scaffolds `project.rbw.json`, `src/main.rbw`
  and the `assets/` tree.
- **Open** (⌘O): pick a folder containing `project.rbw.json`. The
  last project reopens automatically.
- `project.rbw.json` fields the build honours: `name`, `target`
  (`"zx48"`/`"zx128"`/`"zxplus3"`/`"cpc464"`/`"cpc6128"`/`"c64"`; bare ints
  48/128 still accepted),
  `org` (code origin, defaults to the platform's: `0x8000` ZX,
  `0x4000` CPC), `sources` (list of `.rbw` paths, in
  order). `INCLUDE "file"` inside a source pulls in extra `.rbw` files
  without listing them in `sources`.
- **Multi-target projects** replace `target`/`sources`/`org` with a
  `targets` map — each entry has `target`, optional `sources` and `org`
  (inheriting the top-level values), and builds into `build/<key>/`:
  `"targets": {"zx48": {"target": "zx48", "sources": ["src/zx48.rbw"]},
  "cpc464": {"target": "cpc464", "sources": ["src/cpc464.rbw"]}}`. A
  game can ship Spectrum and Amstrad builds from one project this
  way. `rainbow build` builds all entries; `--target <key>` narrows
  to one.
- **Per-platform assets**: `assets-<key>/` beside `assets/` overrides
  same-named assets for that target only — e.g. a 16-colour
  `assets-cpc464/ship.rbs` replaces the shared `assets/ship.rbs` in
  the CPC build while `.ray` tunes stay shared. Overlay files appear
  in the ASSETS sidebar alongside shared ones, with a dim target tag
  beside the name; bank moves via right-click stay inside the same
  `assets-<key>/` root.

## Editing

- Sidebar lists **SOURCES** and **ASSETS**; `+` on a group header
  creates a file (source, sprite, tileset, tilemap, font, screen,
  beeper/AY music, SFX — or *Import .mod → .ray*). Asset kinds get a
  **bank selector**: `resident` or a 128K RAM bank (lands under
  `assets/bank<N>/`; banked files show a dim `bN` badge).
- Right-click a file → **Move to bank N** / **Delete** (confirm
  dialog; deletes from disk and the manifest).
- ⌘P quick-opens any file by name; ⌘S saves; the code editor shows
  live compiler diagnostics in the Problems tab and offers
  Ctrl+Space autocomplete (keywords + your program's symbols).

## Editors

- **Sprite**: frames, 4 draw modes context, onion-free pixel grid,
  shift/copy controls; `attr:"none"` for transparent-attr sprites.
- **Tileset**: tile picker + 8×8 canvas, per-tile attr and **solid**
  flag (drives `COLLIDETILE`).
- **Tilemap**: cell painting over a bound tileset, resize, live map.
- **Font**: 96-glyph grid — unset glyphs inherit the ROM font
  (shown dimmed); overrides only store deltas.
- **Screen**: 256×192 pixel canvas + attr-cell paint; **import
  image…** converts PNG/JPEG/etc via the SCRN-derived quantiser.
- **Music** (`.rnt` beeper / `.ray` AY): tracker grid — note columns
  (typeable note names like `C-4` / `C#4` / `---` for rest, or a raw
  index/period), speed, loop marker; AY rows additionally expose
  noise-period and envelope fields; **Preview** renders
  engine-faithful PCM to a WAV and plays it via `afplay`.
- **SFX** (`.rsf`): step-list editor with the same preview, plus
  preset starters (laser, jump, coin, hiss, thud).
- **MOD import** (`File → New → Import .mod`): converts a 4-channel
  ProTracker module to `.ray` — channel 4 can be **dropped** or
  **merged** into channel C when C has no new note; the import dialog
  shows a conversion report.

## Build & run

**Build** writes `build/game.asm` + `game.bin` + `game.sym` +
`map.txt` (memory map incl. per-bank usage) and packs
`build/<NAME>.tap` on ZX, `build/<NAME>.dsk` on zxplus3 (a +3DOS
disk image holding a `DISK` boot file, `NAME.BIN` and one
`BANKn.BIN` per paged asset bank — boot it with the +3's Loader
menu option), `build/<NAME>.cdt` on CPC 464 (via
`pasmo --cdtbas`), or `build/<NAME>.dsk` on CPC 6128 (an AMSDOS
disk image run with `RUN"NAME.BIN"`). On c64 the build writes
`build/game.s` + `game.o` + `c64.cfg` + `map.txt` and packs
`build/<NAME>.prg`, `build/<NAME>.tap` (a kernal-format cassette —
`LOAD` then `RUN` boots it), `build/<NAME>.d64` (a 1541 disk image
holding the same program — `LOAD"*",8,1` then `RUN`) and, when the
code fits 16K with no banked assets, `build/<NAME>.crt` (a cartridge
image — insert and reset). ZX 48K builds also emit
`build/<NAME>.rom` (a 16K Interface 2 cartridge) and CPC builds
`build/<NAME>.cpr` (a CPC+/GX4000 cartridge) whenever the code fits
the 16K page.
A build that overrides the manifest's `target` — a different
platform picked in the run dropdown, or `--target` on the CLI —
writes to `build/<target>/` instead, so artifacts from different
platforms can't overwrite each other's same-named files.
**Run** launches the configured emulator with
the artifact. A second dropdown picks the media when a build
produces more than one — tape, disk, cartridge (and `.prg` on
cbm); `auto` keeps the per-platform default. The settings dialog (gear icon) has one command per
platform/media: ZX tape (defaults to Fuse), ZX disk `.dsk`
(Fuse needs `--machine plus3 --disk {file}`), CPC tape `.cdt` and
CPC disk `.dsk` (both default to Retro Virtual Machine) — the disk
command is used when the build produced a `.dsk`, so e.g. Arnold can
be given `-drivea {file}` for disks and `-tape {file}` for
cassettes — and CBM (defaults to
`mame c64p -flop {file} -autoboot_delay 3
-autoboot_command "LOAD\"*\",8,1\nRUN\n"`; `{file}` is the `.d64`
sibling of the built `.prg` when one exists, otherwise the `.tap`,
otherwise the `.prg` itself).
Placeholders: `{file}`/`{tap}` = the built artifact,
`{machine}` = `48`/`128`/`plus3` (ZX) or the target name (CPC) — so
a zx128 project is always run on a 128K machine (a 48K machine has
no AY chip and MUSIC is silent) — and `{cpctype}` = Arnold's
`-cpctype` model number (`0` for cpc464, `2` for cpc6128). With a
`targets` manifest, a dropdown beside Run picks which entry to build
and launch.

Banked builds (zx128/cpc6128 target + `assets/bank<N>/` files)
automatically emit the paging loader stub and bank TAP blocks on ZX,
or `BANKn.BIN` files inside the `.dsk` on CPC — see
`docs/language.md` §Banked assets.
