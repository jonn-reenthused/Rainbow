import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:rainbow_assets/rainbow_assets.dart';

import 'ccpr.dart';
import 'ccrt.dart';
import 'cd64.dart';
import 'codegen.dart';
import 'compiler.dart';
import 'ctap.dart';
import 'dsk.dart';
import 'plus3loader.dart';
import 'targets.dart';

/// Cartridge preamble size — payload always starts at ROM offset $0080.
const int _cartPreambleLen = 0x80;

/// Payload bytes that fit in cart page 0 after the preamble.
const int _cartPage0Room = 0x4000 - _cartPreambleLen;

/// Size of the staged page-walk routine the preamble installs in RAM.
const int _cartStage2Len = 0x25;

/// Cart ROM preamble: the Z80 reset vector copies the payload
/// (stored at $0080 on page 0, then solid on pages 1+) into RAM and
/// jumps in, so the relocated program is indistinguishable from a
/// tape/disk build — variables stay writable, which a pure-ROM image
/// couldn't offer.
///
/// Multi-page payloads need a page-select loop, but cart pages map
/// into the $0000 lower-ROM window — the very window the preamble
/// executes from — so the stub at $0000 relocates a second stage into
/// RAM one byte past the payload's destination (the copy can never
/// reach it) and jumps there. Stage 2 copies page 0's chunk, then
/// walks pages 1..N-1 via the $DF00 ROM-select port, restoring page 0
/// before jumping to org. $0038 keeps an ei/ret IM1 safety net: on
/// both the Interface 2 and CPC+ carts this slot is ours, and stray
/// EIs in the runtime's PSG/keyboard guards land there. [sp] is $7FFE
/// on ZX, $C000 on CPC.
Uint8List _cartPreamble(
    {required int org, required int payloadLen, required int sp,
    bool im1 = false, int npages = 1}) {
  final b = Uint8List(_cartPreambleLen);
  var i = 0;
  void op(List<int> bytes) {
    for (final v in bytes) {
      b[i++] = v;
    }
  }

  // Stage 2 lives just past the payload's destination: cart pages map
  // at $0000, so anywhere lower is shadowed by ROM and anything inside
  // the destination range gets overwritten mid-copy.
  final stg = org + _cartPage0Room + (npages - 1) * 0x4000;
  final len0 =
      payloadLen < _cartPage0Room ? payloadLen : _cartPage0Room;
  const s2src = _cartPreambleLen ~/ 2; // stage-2 image at $0040
  const s2len = _cartStage2Len;

  op([0xF3]);                                   // di
  op([0x31, sp & 0xFF, sp >> 8]);               // ld sp,NN
  if (im1) op([0xED, 0x56]);                    // im 1
  op([0x21, s2src, 0x00]);                      // ld hl,stage2
  op([0x11, stg & 0xFF, stg >> 8]);             // ld de,stg
  op([0x01, s2len, 0x00]);                      // ld bc,s2len
  op([0xED, 0xB0]);                             // ldir
  op([0x11, org & 0xFF, org >> 8]);             // ld de,org
  op([0x21, _cartPreambleLen, 0x00]);           // ld hl,payload
  op([0xC3, stg & 0xFF, stg >> 8]);             // jp stg
  // --- stage 2 (runs at stg; A holds the cart page, ldir preserves it)
  while (i < s2src) {
    b[i++] = 0;
  }
  op([0x01, len0 & 0xFF, len0 >> 8]);           // ld bc,len0
  op([0xED, 0xB0]);                             // ldir — page 0's chunk
  op([0x3E, 0x81]);                             // ld a,page1
  final lp = i;
  op([0xFE, 0x80 + npages]);                    // cp #80+npages
  final zj = i;
  op([0x28, 0x00]);                             // jr z,done (patched)
  op([0x01, 0x00, 0xDF]);                       // ld bc,#DF00
  op([0xED, 0x79]);                             // out (c),a — page at $0000
  op([0x21, 0x00, 0x00]);                       // ld hl,0 — page base
  op([0x01, 0x00, 0x40]);                       // ld bc,#4000
  op([0xED, 0xB0]);                             // ldir
  op([0x3C]);                                   // inc a
  op([0x18, (lp - i - 2) & 0xFF]);              // jr lp
  b[zj + 1] = (i - zj - 2) & 0xFF;              // patch jr z -> done
  op([0x01, 0x00, 0xDF]);                       // ld bc,#DF00
  op([0x3E, 0x80]);                             // ld a,page0
  op([0xED, 0x79]);                             // out (c),a
  op([0xC3, org & 0xFF, org >> 8]);             // done: jp org
  b[0x38] = 0xFB;                               // ei
  b[0x39] = 0xC9;                               // ret
  return b;
}

/// Result of a full project build: diagnostics, log lines and (on
/// success) the paths of the generated artifacts.
class BuildResult {
  BuildResult({required this.ok, required this.log, this.tapPath,
      this.tapTarget, this.artifacts = const {}});

  final bool ok;
  final List<String> log;
  final String? tapPath;

  /// Resolved target id (48/128/...) of the tap at [tapPath], so callers
  /// can pick a matching emulator machine.
  final int? tapTarget;

  /// Every produced artifact, keyed by `targets` map key ('' for flat
  /// manifests): `key -> (path, resolved target id)`. `.tap` on ZX,
  /// `.cdt` on CPC.
  final Map<String, ({String path, int target})> artifacts;
}

/// Encoded project assets, split into resident (always in the 48K
/// address space) and banked (loaded into a 128K RAM bank and paged
/// into 0xC000 on demand).
class AssetScan {
  AssetScan(this.resident, this.banked, this.bankBlobs, this.bankFiles);

  /// name -> encoded bytes, emitted into the resident binary.
  final Map<String, Uint8List> resident;

  /// name -> (bank, absolute address in the 0xC000 window).
  final Map<String, ({int bank, int addr})> banked;

  /// name -> payload size (subset of [banked]).
  Map<String, int> get bankedSize =>
      {for (final e in banked.entries) e.key: _bankedBytes[e.key]!.length};

  /// bank number -> blob to load at 0xC000 while that bank is paged.
  final Map<int, Uint8List> bankBlobs;

  /// bank -> ordered (name, addr, size) entries, for map.txt.
  final Map<int, List<(String, int, int)>> bankFiles;

  final Map<String, Uint8List> _bankedBytes = {};

  /// Empty scan result.
  static AssetScan empty() => AssetScan({}, {}, {}, {});
}

/// RAM banks pageable into 0xC000 on a ZX 128 (2 and 5 are the
/// permanently-mapped resident/screen banks).
const kPageableBanks = {0, 1, 3, 4, 6, 7};

/// Physical RAM banks pageable on a CPC 6128 — the gate array's
/// #C4-#C7 configs map the selected bank at #4000-#7FFF. Banks 0-3
/// are the base 64K.
const kCpcPageableBanks = {4, 5, 6, 7};

/// Pageable banks on a +3 — like a 128 but bank 7 is +3DOS's
/// workspace (disk buffers/scratchpads), so assets can't live there
/// while the disk loader runs.
const kPlus3PageableBanks = {0, 3, 4, 6}; // bank1 = +3DOS cache
                                        // bank7 = +3DOS workspace

const kBankWindow = 0xC000;
const kCpcBankWindow = 0x4000;
const kBankSize = 0x4000;
const kLoaderOrg = 0x6000;

/// Scan `<projectDir>/assets` for known asset files and encode them via
/// [gfxEncoders]. Files under `assets/bank<N>/` (N a pageable 128K RAM
/// bank) are packed into that bank's image instead of the resident
/// binary. When [overlayKey] is given, `<projectDir>/assets-<overlayKey>`
/// is scanned afterwards and same-named files override the shared
/// assets — how a project ships a higher-colour `cpc464` sprite while
/// keeping the ZX original under `assets/`. Returns `null` if any asset
/// fails to parse or a bank overflows (errors reported through
/// [onError]).
AssetScan? scanAssets(String projectDir,
    {String? overlayKey,
    void Function(String)? onError,
    Map<String, GfxEncoder> encoders = gfxEncoders,
    Set<int> pageableBanks = kPageableBanks,
    int bankWindow = kBankWindow}) {
  final scan = AssetScan.empty();
  final packed = <int, List<(String, Uint8List)>>{};
  for (final dirName
      in ['assets', if (overlayKey != null) 'assets-$overlayKey']) {
    final overlay = dirName != 'assets';
    final assetsDir = Directory('$projectDir/$dirName');
    if (!assetsDir.existsSync()) continue;
    final files = assetsDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => encoders.keys.any(f.path.endsWith))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      final ext = encoders.keys.firstWhere(f.path.endsWith);
      final segs = f.uri.pathSegments;
      final base =
          segs.last.substring(0, segs.last.length - ext.length);
      final key = CodeGen.sanitizeAssetName(base);
      // assets[-<key>]/bank<N>/... -> banked asset
      int? bank;
      final ai = segs.indexOf(dirName);
      if (ai >= 0 && ai + 2 < segs.length) {
        final d = segs[ai + 1];
        if (d.startsWith('bank')) {
          bank = int.tryParse(d.substring(4));
          if (bank == null || !pageableBanks.contains(bank)) {
            onError?.call('asset ${f.path}: "$d" is not a pageable bank '
                'dir (want one of '
                '${pageableBanks.map((b) => 'bank$b').join(', ')})');
            return null;
          }
        }
      }
      Uint8List bytes;
      try {
        final json =
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        bytes = encoders[ext]!(key, json);
      } catch (e) {
        onError?.call('asset ${f.path}: $e');
        return null;
      }
      if (!overlay &&
          (scan.resident.containsKey(key) ||
              scan._bankedBytes.containsKey(key))) {
        onError?.call('asset ${f.path}: duplicate asset name "$key"');
        return null;
      }
      if (bank != null) {
        // an overlay file may move a shared asset into a bank (or back)
        scan.resident.remove(key);
        scan._bankedBytes[key] = bytes;
        for (final l in packed.values) {
          l.removeWhere((e) => e.$1 == key);
        }
        (packed[bank] ??= []).add((key, bytes));
      } else {
        scan._bankedBytes.remove(key);
        for (final l in packed.values) {
          l.removeWhere((e) => e.$1 == key);
        }
        scan.resident[key] = bytes;
      }
    }
  }
  // lay out each bank sequentially from the bank window
  for (final b in packed.keys.toList()..sort()) {
    var off = 0;
    final blob = <int>[];
    for (final (key, bytes) in packed[b]!) {
      if (off + bytes.length > kBankSize) {
        onError?.call(
            'bank $b overflows 16K packing asset "$key" '
            '(${bytes.length} bytes at +0x${off.toRadixString(16)})');
        return null;
      }
      scan.banked[key] = (bank: b, addr: bankWindow + off);
      (scan.bankFiles[b] ??= []).add((key, bankWindow + off, bytes.length));
      blob.addAll(bytes);
      off += bytes.length;
    }
    scan.bankBlobs[b] = Uint8List.fromList(blob);
  }
  return scan;
}

/// Z80 loader stub paged in at [kLoaderOrg] by the BASIC loader. It
/// loads each bank blob into the right RAM bank at 0xC000, then the
/// resident code at [org], and jumps to the game entry.
///
/// Every `out` also sets bit 4 (#10): the LD-BYTES routine at #0556
/// lives in the 48K ROM — with the 128K editor ROM paged (bit4=0) that
/// call lands in the wrong routine and loads nothing.
String buildBankLoader(
    Map<int, Uint8List> banks, int org, int codeLen) {
  final b = StringBuffer()
    ..writeln('\torg\t#${kLoaderOrg.toRadixString(16)}')
    ..writeln('\tld\tsp,#${kLoaderOrg.toRadixString(16)}');
  void loadBlock(int bank, int dest, int len) {
    b
      ..writeln('\tld\tbc,#7ffd')
      ..writeln('\tld\ta,${bank | 0x10}')
      ..writeln('\tout\t(c),a')
      ..writeln('\tpush\tix')
      ..writeln('\tld\ta,#ff')
      ..writeln('\tscf')
      ..writeln('\tld\tix,#${dest.toRadixString(16)}')
      ..writeln('\tld\tde,$len')
      ..writeln('\tcall\t#0556')
      ..writeln('\tpop\tix');
  }

  for (final bank in banks.keys.toList()..sort()) {
    loadBlock(bank, kBankWindow, banks[bank]!.length);
  }
  loadBlock(0, org, codeLen); // main code, bank 0 paged in
  b.writeln('\tjp\t#${org.toRadixString(16)}');
  return b.toString();
}

/// Render a human-readable memory-map report.
String buildMapReport(String name, int org, int codeLen, AssetScan scan,
    {int bankWindow = kBankWindow}) {
  final b = StringBuffer()
    ..writeln('memory map — $name')
    ..writeln('resident code+assets: $codeLen bytes '
        '@ 0x${org.toRadixString(16)}'
        '..0x${(org + codeLen - 1).toRadixString(16)}');
  for (final bank in scan.bankFiles.keys.toList()..sort()) {
    var used = 0;
    b.writeln('bank $bank '
        '(pages to 0x${bankWindow.toRadixString(16)}):');
    for (final (key, addr, size) in scan.bankFiles[bank]!) {
      b.writeln('  0x${addr.toRadixString(16)}  $key  $size bytes');
      used += size;
    }
    b.writeln('  free: ${kBankSize - used} / $kBankSize bytes');
  }
  return b.toString();
}

/// Build a Rainbow project directory to a .tap image.
///
/// Matches an `INCLUDE "path"` statement at the start of a line —
/// comment lines (`'`/`REM`) can't reach it.
final _includeRe = RegExp(r'^\s*INCLUDE\s+"([^"]+)"',
    multiLine: true, caseSensitive: false);

/// Joins [inc] onto the directory of [from] and normalizes `.`/`..`
/// path segments (INCLUDE paths are relative to the including file).
String relJoin(String from, String inc) {
  final dir =
      from.contains('/') ? from.substring(0, from.lastIndexOf('/')) : '';
  final segs = <String>[];
  for (final p in (dir.isEmpty ? inc : '$dir/$inc').split('/')) {
    if (p.isEmpty || p == '.') continue;
    if (p == '..') {
      if (segs.isNotEmpty) segs.removeLast();
    } else {
      segs.add(p);
    }
  }
  return segs.join('/');
}

/// Reads [srcNames] — plus any files they pull in via `INCLUDE "path"`,
/// resolved relative to the including file and expanded recursively —
/// into a filename -> source map. Entries in [overrides] (e.g. dirty
/// editor buffers) win over disk. Returns null (and appends to [log])
/// when a referenced file is missing.
Map<String, String>? gatherSources(
  String projectDir,
  List<String> srcNames, {
  Map<String, String>? overrides,
  List<String>? log,
}) {
  final srcs = <String, String>{};
  final seen = <String>{};
  final queue = List.of(srcNames);
  while (queue.isNotEmpty) {
    final s = queue.removeAt(0);
    if (!seen.add(s)) continue;
    var content = overrides?[s];
    if (content == null) {
      final f = File('$projectDir/$s');
      if (f.existsSync()) content = f.readAsStringSync();
    }
    if (content == null) {
      log?.add('missing source: $s');
      return null;
    }
    srcs[s] = content;
    for (final m in _includeRe.allMatches(content)) {
      queue.add(relJoin(s, m[1]!));
    }
  }
  return srcs;
}

/// One build target resolved from the manifest's `targets` map (or the
/// single implicit target of a flat manifest).
class _BuildEntry {
  _BuildEntry(this.key, this.target, this.sources, this.org);

  /// `targets` map key ('' for flat manifests).
  final String key;

  /// ZX target 48/128; null means the manifest didn't pin one, so a
  /// `TARGET` decl in source (or the 48K default) applies.
  final int? target;
  final List<String> sources;

  /// Code org; null picks the platform default once the target is
  /// resolved ([defaultOrgOf]).
  final int? org;
}

/// Normalizes the manifest's target selection into build entries.
/// Flat manifests (`"target"`, `"sources"`, `"org"` at top level) yield
/// a single entry; `"targets": {"zx48": {...}, "cpc": {...}}` yields one
/// per key — entries inherit `sources`/`org` from the top level when
/// they don't override them.
List<_BuildEntry>? _targetEntries(
    Map<String, dynamic> manifest, List<String> log) {
  final defSources =
      (manifest['sources'] as List?)?.cast<String>() ?? ['src/main.rbw'];
  final defOrg = manifest['org'] as int?;
  final raw = manifest['targets'];
  if (raw is Map) {
    if (raw.isEmpty) {
      log.add('manifest "targets" is empty');
      return null;
    }
    final out = <_BuildEntry>[];
    for (final e in raw.entries) {
      final v = (e.value as Map).cast<String, dynamic>();
      final t = v['target'];
      final ti = resolveTargetId(t);
      if (t != null && ti == null) {
        log.add('target "${e.key}": unsupported target "$t" '
            '(want ${kTargetNames.values.join(', ')})');
        return null;
      }
      out.add(_BuildEntry(
          e.key,
          ti,
          (v['sources'] as List?)?.cast<String>() ?? defSources,
          v['org'] as int? ?? defOrg));
    }
    return out;
  }
  final flat = manifest['target'];
  if (flat != null && resolveTargetId(flat) == null) {
    log.add('unsupported target "$flat" '
        '(want ${kTargetNames.values.join(', ')})');
    return null;
  }
  return [
    _BuildEntry('', resolveTargetId(flat), defSources, defOrg)
  ];
}

/// Reads `project.rbw.json` and builds every declared target.
/// Flat manifests produce `<project>/build/<NAME>.tap`; a `targets`
/// map produces `<project>/build/<key>/<NAME>.tap` per entry. `INCLUDE
/// "path"` statements in sources pull in extra files relative to the
/// including file.
///
/// [sources] may hold in-memory overrides for dirty editor buffers
/// (keyed by the same relative source paths as the manifest).
/// [targetName] selects one named target (or all matching a ZX number);
/// [target] overrides the target of a flat manifest.
///
/// When [assemble] is false only `game.asm` is produced.
Future<BuildResult> buildProject(
  String projectDir, {
  Map<String, String>? sources,
  int? target,
  String? targetName,
  bool assemble = true,
  String pasmo = 'pasmo',
  String ca65 = 'ca65',
  String ld65 = 'ld65',
  String? outDirName,
}) async {
  final log = <String>[];

  final manifestFile = File('$projectDir/project.rbw.json');
  if (!manifestFile.existsSync()) {
    log.add('no project.rbw.json in $projectDir');
    return BuildResult(ok: false, log: log);
  }
  final manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final name = (manifest['name'] as String? ?? 'game').toUpperCase();

  final entries = _targetEntries(manifest, log);
  if (entries == null) return BuildResult(ok: false, log: log);
  final multi = manifest['targets'] is Map;

  var buildList = entries;
  if (multi && targetName != null) {
    buildList = entries.where((e) => e.key == targetName).toList();
    final byId = resolveTargetId(targetName);
    if (buildList.isEmpty && byId != null) {
      buildList = entries.where((e) => e.target == byId).toList();
    }
    if (buildList.isEmpty) {
      log.add('unknown target "$targetName" '
          '(targets: ${entries.map((e) => e.key).join(', ')})');
      return BuildResult(ok: false, log: log);
    }
  } else if (!multi && target != null) {
    buildList = [
      _BuildEntry('', target, entries.first.sources, entries.first.org)
    ];
  } else if (!multi && targetName != null) {
    log.add('unknown target "$targetName" '
        '(project has a single "target" field, not a "targets" map)');
    return BuildResult(ok: false, log: log);
  }

  var ok = true;
  String? lastTap;
  int? lastTgt;
  final artifacts = <String, ({String path, int target})>{};
  for (final e in buildList) {
    if (multi) log.add('== target ${e.key} ==');
    // A flat manifest's own target keeps the flat build dir, but a
    // --target override gets a build/<target> subdir like a targets
    // map entry — same-named artifacts (.tap/.prg/.d64) from different
    // platforms would otherwise overwrite each other invisibly.
    final base = outDirName ?? '$projectDir/build';
    final outDir = multi
        ? '$base/${e.key}'
        : (target != null && target != entries.first.target)
            ? '$base/${targetNameOf(target)}'
            : base;
    final r = await _buildOne(
      projectDir,
      e,
      name: name,
      cliTarget: target,
      sources: sources,
      assemble: assemble,
      pasmo: pasmo,
      ca65: ca65,
      ld65: ld65,
      outDir: outDir,
      log: log,
    );
    ok = ok && r.ok;
    lastTap = r.artifact ?? lastTap;
    if (r.artifact != null) {
      lastTgt = r.target;
      artifacts[e.key] = (path: r.artifact!, target: r.target!);
    }
  }
  return BuildResult(
      ok: ok,
      log: log,
      tapPath: lastTap,
      tapTarget: lastTgt,
      artifacts: artifacts);
}

/// Builds a single target: gathers sources (INCLUDE-expanded), scans
/// assets (plus the `assets-<key>` overlay), compiles, assembles and
/// writes the tape image + map into [outDir]. The returned `artifact`
/// is a `.tap` on ZX or a `.cdt` on CPC.
Future<({bool ok, String? artifact, int? target})> _buildOne(
  String projectDir,
  _BuildEntry entry, {
  required String name,
  required int? cliTarget,
  Map<String, String>? sources,
  required bool assemble,
  required String pasmo,
  required String ca65,
  required String ld65,
  required String outDir,
  required List<String> log,
}) async {
  final tgt = cliTarget ?? entry.target;
  final org = entry.org;

  Directory(outDir).createSync(recursive: true);

  final srcs = gatherSources(projectDir, entry.sources,
      overrides: sources, log: log);
  if (srcs == null) return (ok: false, artifact: null, target: null);

  // platform-specific assets: shared assets/ plus an assets-<key>/
  // overlay (target key for multi-target manifests, canonical target
  // name for a pinned flat manifest, e.g. assets-cpc464/) encoded with
  // the platform's encoder table.
  final overlayKey = entry.key.isNotEmpty
      ? entry.key
      : (tgt != null ? targetNameOf(tgt) : null);
  Map<String, GfxEncoder> encodersFor(int? t) =>
      switch (platformOf(t ?? 48)) {
        TargetFamily.cpc => cpcGfxEncoders,
        TargetFamily.cbm => cbmGfxEncoders,
        // zx: 48K beeper-encodes .ray; 128K/+3 AY-encodes .rnt so a
        // single song asset covers every ZX target
        _ => (t ?? 48) == 48 ? zx48GfxEncoders : zx128GfxEncoders,
      };
  // cbm scans like a 128 (bank<N> dirs are accepted) — on a bankless
  // cbm target they're streamed off the .d64 via COPYBANK, on zx48
  // the !bankCapableOf check below warns and ignores them.
  Set<int> banksFor(int? t) => t == 6128
      ? kCpcPageableBanks
      : t == 3
          ? kPlus3PageableBanks
          : kPageableBanks;
  int windowFor(int? t) => t == 6128 ? kCpcBankWindow : kBankWindow;
  var scan = scanAssets(projectDir, overlayKey: overlayKey,
      onError: log.add, encoders: encodersFor(tgt),
      pageableBanks: banksFor(tgt), bankWindow: windowFor(tgt));
  if (scan == null) return (ok: false, artifact: null, target: null);

  // cpc6128's #8000 default org exists only to keep the #4000-#7FFF
  // bank window free for asset paging — a bankless program there is
  // capped at 16K before it collides with the #C000 screen, so it
  // loads at #4000 instead (matching the tape build's layout).
  int? orgFor(int? t) =>
      org ?? (t == 6128 && scan!.bankBlobs.isEmpty ? 0x4000 : null);

  var result = compile(srcs,
      org: orgFor(tgt),
      assets: scan.resident,
      target: tgt,
      banked: scan.banked,
      bankedSize: scan.bankedSize);
  for (final d in result.diag.items) {
    log.add(d.toString());
  }
  if (!result.ok) return (ok: false, artifact: null, target: null);

  // the TARGET decl can override an unspecified manifest target, so
  // banked-asset and packaging decisions use the resolved target
  final resolvedTgt = result.info?.target ?? tgt ?? 48;
  // A TARGET decl changing the encoder map (crossing platforms, or
  // 48K vs 128K within zx) re-encodes the assets and recompiles so
  // sprites/sound get the right binary format.
  if (!identical(encodersFor(resolvedTgt), encodersFor(tgt))) {
    scan = scanAssets(projectDir, overlayKey: overlayKey,
        onError: log.add, encoders: encodersFor(resolvedTgt),
        pageableBanks: banksFor(resolvedTgt),
        bankWindow: windowFor(resolvedTgt));
    if (scan == null) return (ok: false, artifact: null, target: null);
    result = compile(srcs,
        org: orgFor(resolvedTgt),
        assets: scan.resident,
        target: resolvedTgt,
        banked: scan.banked,
        bankedSize: scan.bankedSize);
    if (!result.ok) return (ok: false, artifact: null, target: null);
  }
  final resolvedOrg = orgFor(resolvedTgt) ?? defaultOrgOf(resolvedTgt);
  final cpc = platformOf(resolvedTgt) == TargetFamily.cpc;
  final cbm = platformOf(resolvedTgt) == TargetFamily.cbm;
  if (scan.bankBlobs.isNotEmpty && !bankCapableOf(resolvedTgt) && !cbm) {
    log.add('warning: assets under assets/bank<N>/ are ignored '
        '(banked memory requires zx128/zxplus3/cpc6128)');
    scan = AssetScan(scan.resident, {}, {}, {});
  }
  // cbm: banked assets aren't paged RAM — they're streamed off the
  // .d64 one file at a time via COPYBANK, so they stay in the scan.
  final bankedBuild = scan.bankBlobs.isNotEmpty;

  // Cartridge image: a second compile with the firmware-free runtime
  // paths (RBT_CART), assembled at the normal RAM org and wrapped in a
  // ROM preamble that LDIRs the payload into RAM and jumps in — keeping
  // variable cells writable. ZX emits a 16K Interface 2 .rom (48K only
  // — the IF2 doesn't fit the 128/+3 memory models); CPC emits a
  // CPC+/GX4000 .cpr whose page 0 is preamble+payload start, whose
  // following pages carry the rest of an unbanked payload (the preamble
  // page-walks them through the #DF00 select), and whose remaining
  // pages carry the bank blobs in the same sorted-bank order the
  // generated rbt_cartfiles table encodes.
  Future<void> emitCart() async {
    final sc = scan!;
    final crt = compile(srcs,
        org: resolvedOrg,
        assets: sc.resident,
        target: resolvedTgt,
        banked: sc.banked,
        bankedSize: sc.bankedSize,
        bankLens: sc.bankBlobs.map((k, v) => MapEntry(k, v.length)),
        cart: true);
    for (final d in crt.diag.items) {
      log.add('cart: $d');
    }
    if (!crt.ok) return;
    final cartAsmPath = '$outDir/cart.asm';
    final cartBinPath = '$outDir/cart.bin';
    File(cartAsmPath).writeAsStringSync(crt.asm!);
    final cr =
        await runPasmo(cartAsmPath, cartBinPath, pasmo: pasmo);
    if (cr.out.isNotEmpty) log.add('cart: ${cr.out.trimRight()}');
    if (cr.err.isNotEmpty) log.add('cart: ${cr.err.trimRight()}');
    if (cr.code != 0) {
      log.add('cart pasmo failed (${cr.code}) — see $cartAsmPath');
      return;
    }
    final cartBin = File(cartBinPath).readAsBytesSync();
    // Payload fills page 0 after the preamble, then pages 1+ solid.
    // Only unbanked CPC carts may span pages: rbt_cartfiles' baked
    // page numbers assume the bank blobs start on page 1, and the ZX
    // Interface-2 format is fixed at one 16K page.
    final payloadPages =
        (cartBin.length + _cartPreambleLen + 0x3FFF) ~/ 0x4000;
    if (payloadPages > 1 && (!cpc || sc.bankBlobs.isNotEmpty)) {
      log.add('skipped cartridge: code ${cartBin.length} bytes '
          '+ preamble exceeds the 16K page');
      return;
    }
    // The last copy writes a full page and stage 2 is staged one byte
    // past it — both must land in RAM below the #C000 screen.
    final destEnd = resolvedOrg +
        _cartPage0Room +
        (payloadPages - 1) * 0x4000 +
        _cartStage2Len;
    if (cpc && destEnd > 0xC000) {
      log.add('skipped cartridge: code ${cartBin.length} bytes needs '
          '$payloadPages pages but the RAM copy reaches 0x'
          '${destEnd.toRadixString(16)} (screen is 0xc000)');
      return;
    }
    final page0 = Uint8List(0x4000)
      ..setAll(0, _cartPreamble(
          org: resolvedOrg,
          payloadLen: cartBin.length,
          sp: cpc ? 0xC000 : 0x7FFE,
          im1: cpc,
          npages: payloadPages))
      ..setAll(_cartPreambleLen, cartBin.sublist(0,
          cartBin.length < _cartPage0Room
              ? cartBin.length
              : _cartPage0Room));
    if (cpc) {
      try {
        final pages = <Uint8List>[
          page0,
          for (var p = 1; p < payloadPages; p++)
            Uint8List(0x4000)
              ..setAll(
                  0,
                  cartBin.sublist(_cartPage0Room + (p - 1) * 0x4000,
                      _cartPage0Room + p * 0x4000 > cartBin.length
                          ? cartBin.length
                          : _cartPage0Room + p * 0x4000)),
          for (final b in sc.bankBlobs.keys.toList()..sort())
            Uint8List(0x4000)..setAll(0, sc.bankBlobs[b]!),
        ];
        final cprPath = '$outDir/$name.cpr';
        File(cprPath).writeAsBytesSync(buildCpr(pages));
        log.add('built $cprPath (${pages.length} 16K page(s))');
        if (bankedBuild) {
          log.add('note: banked cartridges need a 128K CPC+ (6128+) — '
              'the GX4000 is 64K and its MMR banking is a no-op');
        }
      } on ArgumentError catch (e) {
        log.add('skipped cartridge: $e');
      }
    } else {
      File('$outDir/$name.rom').writeAsBytesSync(page0);
      log.add('built $outDir/$name.rom (16K Interface 2 cartridge)');
    }
  }

  final asmPath = cbm ? '$outDir/game.s' : '$outDir/game.asm';
  File(asmPath).writeAsStringSync(result.asm!);
  log.add('wrote $asmPath');
  if (!assemble) return (ok: true, artifact: null, target: resolvedTgt);

  // CBM: ca65 assembles the generated .s, ld65 links it against a
  // generated cfg into a flat binary, and a 2-byte load-address prefix
  // makes it a .prg (tape/disk/cart packaging arrives in M2+).
  if (cbm) {
    final oPath = '$outDir/game.o';
    final binPath = '$outDir/game.bin';
    final ldMapPath = '$outDir/game.map';
    final cfgPath = '$outDir/c64.cfg';
    File(cfgPath).writeAsStringSync(c64LinkerCfg(resolvedOrg,
        bitmapSafe: result.usedModules?.contains('pixel') ?? false,
        // c128: the runtime maps RAM-under-ROM at $4000-$7FFF, so the
        // flat region runs to $8000 (BASIC hi stays mapped above).
        ramTop: resolvedTgt == 1280 ? 0x8000 : null));

    final ar = await runCa65(asmPath, oPath, ca65: ca65);
    if (ar.out.isNotEmpty) log.add('ca65: ${ar.out.trimRight()}');
    if (ar.err.isNotEmpty) log.add('ca65: ${ar.err.trimRight()}');
    if (ar.code != 0) {
      log.add('ca65 failed (${ar.code}) — see $asmPath');
      return (ok: false, artifact: null, target: resolvedTgt);
    }
    final lr =
        await runLd65(oPath, binPath, cfgPath, ldMapPath, ld65: ld65);
    if (lr.out.isNotEmpty) log.add('ld65: ${lr.out.trimRight()}');
    if (lr.err.isNotEmpty) log.add('ld65: ${lr.err.trimRight()}');
    if (lr.code != 0) {
      log.add('ld65 failed (${lr.code}) — see $cfgPath');
      return (ok: false, artifact: null, target: resolvedTgt);
    }
    final code = File(binPath).readAsBytesSync();
    final prgBytes = Uint8List.fromList(
        [resolvedOrg & 0xFF, (resolvedOrg >> 8) & 0xFF, ...code]);
    final prgPath = '$outDir/$name.prg';
    File(prgPath).writeAsBytesSync(prgBytes);
    final tapPath = '$outDir/$name.tap';
    File(tapPath)
        .writeAsBytesSync(buildC64Tap(code, name: name, org: resolvedOrg));
    // One .d64 holding the program plus each banked (disk-streamed)
    // asset as its own file — COPYBANK "x" kernal-LOADs file X.
    final d64Files = <D64File>[(name: name, data: prgBytes)];
    for (final e in scan.banked.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      final addr = e.value.addr;
      // Must match the rbf_ name records codegen emits for COPYBANK:
      // uppercase, '_' -> '-', 16 chars.
      final fn = e.key.toUpperCase().replaceAll('_', '-');
      final fkey = fn.length > 16 ? fn.substring(0, 16) : fn;
      d64Files.add((name: fkey, data: Uint8List.fromList(
          [addr & 0xFF, (addr >> 8) & 0xFF, ...scan._bankedBytes[e.key]!])));
    }
    final d64Path = '$outDir/$name.d64';
    try {
      File(d64Path).writeAsBytesSync(
          buildD64(diskName: name, files: d64Files));
    } on ArgumentError catch (e) {
      log.add('d64: $e');
    }
    log.add('built $d64Path'
        '${d64Files.length > 1 ? ' (${d64Files.length} files)' : ''}');
    if (resolvedTgt == 1280) {
      // the C128's native drive is the 1571 — emit the double-sided
      // image alongside the 1541-compatible .d64
      final d71Path = '$outDir/$name.d71';
      try {
        File(d71Path).writeAsBytesSync(
            buildD71(diskName: name, files: d64Files));
        log.add('built $d71Path');
      } on ArgumentError catch (e) {
        log.add('d71: $e');
      }
    }
    // .crt only suits programs under ~16K and can't carry COPYBANK'd
    // asset files — emit it when it fits, warn otherwise. c128 has no
    // native cart path yet (a C64 cart would boot it into GO64 mode).
    final crtPath = '$outDir/$name.crt';
    final crt = resolvedTgt == 1280
        ? null
        : buildC64Cart(name: name, code: code, org: resolvedOrg);
    if (crt == null) {
      if (resolvedTgt != 1280) {
        log.add('skipped $crtPath (code does not fit a 16K cart)');
      }
    } else if (d64Files.length > 1) {
      log.add('skipped $crtPath (banked assets need the .d64)');
    } else {
      File(crtPath).writeAsBytesSync(crt);
      log.add('built $crtPath');
    }
    File('$outDir/map.txt').writeAsStringSync(
        buildMapReport(name, resolvedOrg, code.length, scan));
    log.add('built $prgPath  (code ${code.length} bytes @ '
        '0x${resolvedOrg.toRadixString(16)})');
    log.add('built $tapPath');
    return (ok: true, artifact: prgPath, target: resolvedTgt);
  }

  // CPC: pasmo --cdtbas emits a CDT (BASIC loader + machine-code block
  // CALLing the `end` label) directly from the generated asm. The .bin
  // pass still runs first for the code size and .sym file.
  if (cpc) {
    final binPath = '$outDir/game.bin';
    final symPath = '$outDir/game.sym';
    final br =
        await runPasmo(asmPath, binPath, pasmo: pasmo, symPath: symPath);
    if (br.out.isNotEmpty) log.add(br.out.trimRight());
    if (br.err.isNotEmpty) log.add(br.err.trimRight());
    if (br.code != 0) {
      log.add('pasmo failed (${br.code}) — see $asmPath');
      return (ok: false, artifact: null, target: null);
    }
    final codeLen = File(binPath).lengthSync();
    if (resolvedOrg + codeLen > 0xC000) {
      log.add('warning: resident code reaches 0x'
          '${(resolvedOrg + codeLen).toRadixString(16)} — past the CPC '
          'screen at 0xc000, so display writes will corrupt it');
    }
    if (resolvedTgt == 6128) {
      // 6128: a .dsk holding the resident binary plus one BANKn.BIN per
      // paged asset bank. The runtime's rbt_bankload pages each bank at
      // #4000 and loads its file there via CAS IN DIRECT during startup.
      final dskPath = '$outDir/$name.dsk';
      // Exec must be rbt_start, not org — data (rbt_zx2cpc) can sit
      // at the binary's head. Resolve it from the .sym pasmo emitted.
      var execAddr = resolvedOrg;
      final m = RegExp(r'^rbt_start\s+EQU\s+0([0-9A-Fa-f]+)H',
              multiLine: true)
          .firstMatch(File(symPath).readAsStringSync());
      if (m != null) execAddr = int.parse(m.group(1)!, radix: 16);
      final files = <DskFile>[
        (name: '$name.BIN', bytes: [
          ...buildAmsdosHeader('$name.BIN',
              loadAddr: resolvedOrg, execAddr: execAddr,
              dataLen: codeLen),
          ...File(binPath).readAsBytesSync(),
        ]),
        for (final b in scan.bankBlobs.keys.toList()..sort())
          (name: 'BANK$b.BIN', bytes: [
            ...buildAmsdosHeader('BANK$b.BIN',
                loadAddr: kCpcBankWindow, execAddr: 0,
                dataLen: scan.bankBlobs[b]!.length),
            ...scan.bankBlobs[b]!,
          ]),
      ];
      File(dskPath).writeAsBytesSync(buildDsk(files));
      final mapPath = '$outDir/map.txt';
      File(mapPath).writeAsStringSync(buildMapReport(
          name, resolvedOrg, codeLen, scan,
          bankWindow: kCpcBankWindow));
      log.add('built $dskPath  (code $codeLen bytes @ '
          '0x${resolvedOrg.toRadixString(16)}, '
          '${scan.bankBlobs.length} bank file(s); run with RUN"$name.BIN")');
      log.add('wrote $mapPath');
      await emitCart();
      return (ok: true, artifact: dskPath, target: resolvedTgt);
    }
    final cdtPath = '$outDir/$name.cdt';
    // pasmo embeds the object filename as the tape block name — run it in
    // outDir on a bare name with no extension so the CDT block is "HELLO",
    // then rename to the real .cdt artifact.
    final asmBase = asmPath.split('/').last;
    final r = await Process.run(
        pasmo, ['--alocal', '--cdtbas', asmBase, name],
        workingDirectory: outDir);
    if (r.stdout.toString().isNotEmpty) {
      log.add(r.stdout.toString().trimRight());
    }
    if (r.stderr.toString().isNotEmpty) {
      log.add(r.stderr.toString().trimRight());
    }
    if (r.exitCode != 0) {
      log.add('pasmo failed (${r.exitCode}) — see $asmPath');
      return (ok: false, artifact: null, target: null);
    }
    File('$outDir/$name').renameSync(cdtPath);
    final mapPath = '$outDir/map.txt';
    File(mapPath).writeAsStringSync(
        buildMapReport(name, resolvedOrg, codeLen, scan));
    log.add('built $cdtPath  (code $codeLen bytes @ '
        '0x${resolvedOrg.toRadixString(16)})');
    log.add('wrote $mapPath');
    await emitCart();
    return (ok: true, artifact: cdtPath, target: resolvedTgt);
  }

  // assemble
  final binPath = '$outDir/game.bin';
  final symPath = '$outDir/game.sym';
  final r = await runPasmo(asmPath, binPath, pasmo: pasmo, symPath: symPath);
  if (r.out.isNotEmpty) log.add(r.out.trimRight());
  if (r.err.isNotEmpty) log.add(r.err.trimRight());
  if (r.code != 0) {
    log.add('pasmo failed (${r.code}) — see $asmPath');
    return (ok: false, artifact: null, target: null);
  }

  final code = File(binPath).readAsBytesSync();

  // loading screen: prefer assets/screens/loading.rbc (encoded via
  // scanAssets output), fall back to a raw loading.scr binary.
  List<int>? screen;
  if (scan.resident.containsKey('loading')) {
    screen = scan.resident['loading'];
    if (screen!.length != 6912) {
      log.add(
          'warning: loading screen asset is ${screen.length} bytes, expected 6912 — ignored');
      screen = null;
    }
  }
  if (screen == null) {
    final scrFile = File('$projectDir/assets/screens/loading.scr');
    if (scrFile.existsSync()) {
      screen = scrFile.readAsBytesSync();
      if (screen.length != 6912) {
        log.add(
            'warning: loading.scr is ${screen.length} bytes, expected 6912 — ignored');
        screen = null;
      }
    }
  }

  if (resolvedTgt == 3) {
    // +3: a +3DOS .dsk holding a DISK BASIC loader (auto-run by the
    // Loader menu option), the resident CODE file and one BANKn.BIN
    // per paged asset bank. The resident binary's rbt_p3load stub
    // calls +3DOS to fill the banks — DOS_READ pages the target bank
    // itself, so no OUT/LOAD dance is needed or possible.
    final dskPath = '$outDir/$name.dsk';
    final files = <DskFile>[
      (name: 'DISK',
          bytes: buildPlus3Loader(name,
              org: resolvedOrg, screen: screen != null)),
      if (screen != null)
        (name: 'SCREEN.BIN', bytes: [
          ...buildPlus3Header('SCREEN.BIN',
              type: 3, dataLen: screen.length,
              param1: 0x4000, param2: 0x8000),
          ...screen,
        ]),
      (name: '$name.BIN', bytes: [
        ...buildPlus3Header('$name.BIN',
            type: 3, dataLen: code.length,
            param1: resolvedOrg, param2: 0x8000),
        ...code,
      ]),
      for (final b in scan.bankBlobs.keys.toList()..sort())
        (name: 'BANK$b.BIN', bytes: [
          ...buildPlus3Header('BANK$b.BIN',
              type: 3, dataLen: scan.bankBlobs[b]!.length,
              param1: kBankWindow, param2: 0x8000),
          ...scan.bankBlobs[b]!,
        ]),
    ];
    File(dskPath).writeAsBytesSync(buildPlus3Dsk(files));
    final mapPath = '$outDir/map.txt';
    File(mapPath).writeAsStringSync(
        buildMapReport(name, resolvedOrg, code.length, scan));
    log.add('built $dskPath  (code ${code.length} bytes @ '
        '0x${resolvedOrg.toRadixString(16)}, '
        '${scan.bankBlobs.length} bank file(s); Loader runs DISK)');
    log.add('wrote $mapPath');
    return (ok: true, artifact: dskPath, target: resolvedTgt);
  }

  List<int> tap;
  if (bankedBuild) {
    // assemble the bank loader stub
    final stubAsm = buildBankLoader(scan.bankBlobs, resolvedOrg, code.length);
    final stubAsmPath = '$outDir/loader.asm';
    final stubBinPath = '$outDir/loader.bin';
    File(stubAsmPath).writeAsStringSync(stubAsm);
    final sr =
        await runPasmo(stubAsmPath, stubBinPath, pasmo: pasmo);
    if (sr.out.isNotEmpty) log.add(sr.out.trimRight());
    if (sr.err.isNotEmpty) log.add(sr.err.trimRight());
    if (sr.code != 0) {
      log.add('pasmo failed (${sr.code}) — see $stubAsmPath');
      return (ok: false, artifact: null, target: null);
    }
    final stub = File(stubBinPath).readAsBytesSync();

    final tw = TapWriter();
    tw.addProgram(
        name: name,
        program: buildGameLoader(
            clearAddr: kLoaderOrg - 1,
            entry: kLoaderOrg,
            codeBlocks: screen != null ? 2 : 1),
        autoStartLine: 10);
    if (screen != null) {
      tw.addCode(name: 'screen', org: 0x4000, data: screen);
    }
    tw.addCode(name: 'loader', org: kLoaderOrg, data: stub);
    for (final bank in scan.bankBlobs.keys.toList()..sort()) {
      tw.addBlock(0xFF, scan.bankBlobs[bank]!);
    }
    tw.addBlock(0xFF, code);
    tap = tw.bytes;
    log.add('banked build: stub @ 0x${kLoaderOrg.toRadixString(16)}, '
        '${scan.bankBlobs.length} bank block(s)');
  } else {
    final tap48 =
        buildTap48(name: name, org: resolvedOrg, code: code, screen: screen);
    tap = tap48;
    if (resolvedTgt != 48) {
      log.add('note: no banked assets — 128K target uses a plain '
          '48K-compatible tap');
    }
  }

  final tapPath = '$outDir/$name.tap';
  File(tapPath).writeAsBytesSync(tap);
  final mapPath = '$outDir/map.txt';
  File(mapPath).writeAsStringSync(
      buildMapReport(name, resolvedOrg, code.length, scan));
  log.add(
      'built $tapPath  (code ${code.length} bytes @ 0x${resolvedOrg.toRadixString(16)})');
  log.add('wrote $mapPath');
  // Interface 2 carts only suit the 48K — the IF2's 16K ROM window
  // assumes the plain bank-5 memory model
  if (resolvedTgt == 48) await emitCart();
  return (ok: true, artifact: tapPath, target: resolvedTgt);
}
