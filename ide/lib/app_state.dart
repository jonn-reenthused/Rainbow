import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:rainbow_compiler/rainbow_compiler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An open document (source or asset) in an editor tab.
class EditorDoc {
  EditorDoc(this.relPath, this.text);

  /// Path relative to the project root, e.g. `src/main.rbw`.
  final String relPath;
  String text;
  bool dirty = false;

  String get name => relPath.split('/').last;
}

/// IDE state: open project, documents, diagnostics, build log.
class IdeState extends ChangeNotifier {
  String? projectDir;
  String projectName = '';
  List<String> sourceFiles = [];
  List<String> assetFiles = [];

  final List<EditorDoc> docs = [];
  int activeDoc = -1;
  final List<String> log = [];
  List<Diagnostic> diagnostics = [];
  ProgramInfo? lastInfo;
  bool building = false;
  String? lastTap;
  int? lastTapTarget;

  Timer? _debounce;
  static const _oldDefaultEmulatorCmdCbm =
      'mame c64p -flop {file} -autoboot_delay 3 '
      '-autoboot_command "LOAD\\"*\\",8,1\\nRUN\\n"';
  static const _oldDefaultEmulatorCmd =
      '/Applications/Fuse.app/Contents/MacOS/Fuse --machine 48 --tape {tap}';
  /// Default emulator commands are host-OS specific: macOS launches the
  /// installed apps directly; Windows/Linux invoke binaries on PATH
  /// (Fuse has ports on both, Retro Virtual Machine ships as a single
  /// exe on all three). Everything is editable in Settings.
  String emulatorCmd = Platform.isMacOS
      ? '/Applications/Fuse.app/Contents/MacOS/Fuse --machine {machine} '
          '--tape {tap}'
      : 'fuse --machine {machine} --tape {tap}';

  /// ZX disk command — used when the built artifact is a `.dsk`
  /// (zxplus3), since emulators take a different switch for disks
  /// (Fuse: `--disk`, Arnold-style `-drivea` on CPC).
  String emulatorCmdDsk = Platform.isMacOS
      ? '/Applications/Fuse.app/Contents/MacOS/Fuse --machine {machine} '
          '--disk {file}'
      : 'fuse --machine {machine} --disk {file}';
  String emulatorCmdCpc = Platform.isMacOS
      ? 'open -a "Retro Virtual Machine 2.1" {file}'
      : 'RetroVirtualMachine {file}';

  /// CPC disk command — used when the built artifact is a `.dsk`
  /// (cpc6128) instead of a tape image, since e.g. Arnold needs
  /// `-drivea` for disks but `-tape` for cassettes.
  String emulatorCmdCpcDsk = Platform.isMacOS
      ? 'open -a "Retro Virtual Machine 2.1" {file}'
      : 'RetroVirtualMachine {file}';

  /// CBM command — c64 builds emit `.prg`, `.tap` and `.d64`, c128
  /// adds `.d71`; `{file}` resolves to the `.d71`/`.d64` when it
  /// primary medium — it loads far faster than tape), otherwise the
  /// `.tap`, otherwise the `.prg`. For MAME use `-flop` with disks
  /// plus an autoboot command, `-cass` with tapes or `-quik` with
  /// programs.
  String emulatorCmdCbm =
      'mame {machine} -flop {file} -autoboot_delay 3 '
      '-autoboot_command "LOAD\\"*\\",8,1\\nRUN\\n"';

  /// CBM tape / cartridge / program commands — `emulatorCmdCbm`
  /// covers disks (.d64/.d71 via MAME `-flop`); these cover the other
  /// media a cbm build emits (`-cass` tapes, `-cart` cartridges,
  /// `-quik` programs).
  String emulatorCmdCbmTape =
      'mame {machine} -cass {file} -autoboot_delay 3 '
      '-autoboot_command "LOAD\\nRUN\\n"';
  String emulatorCmdCbmCart = 'mame {machine} -cart {file}';
  String emulatorCmdCbmPrg = 'mame {machine} -quik {file}';

  /// ZX cartridge command — Interface 2 `.rom` images.
  String emulatorCmdCart = Platform.isMacOS
      ? '/Applications/Fuse.app/Contents/MacOS/Fuse --machine {machine} '
          '--interface2 {file}'
      : 'fuse --machine {machine} --interface2 {file}';

  /// CPC cartridge command — CPC+/GX4000 `.cpr` images. Defaults to
  /// cpc6128p rather than gx4000: the GX4000 is 64K-only, so its MMR
  /// RAM banking is a no-op and banked carts can't load their pages.
  String emulatorCmdCpcCpr = 'mame cpc6128p -cart {file}';

  String pasmoPath = 'pasmo';

  /// `targets` map keys of the loaded project (empty for flat manifests);
  /// [runTarget] picks which one `run()` builds and launches.
  List<String> targetKeys = [];
  String? runTarget;

  /// What the run/build picker offers: `targets` keys for a multi-target
  /// manifest, otherwise every supported platform so the same source can
  /// be tried on ZX or CPC without editing the manifest.
  List<String> get runChoices =>
      targetKeys.isNotEmpty ? targetKeys : kTargetNames.values.toList();

  /// Preferred run medium: 'auto' keeps the per-family default (disk
  /// on cbm, the primary artifact elsewhere); the other values pick a
  /// sibling file of the same basename when the build produced it.
  String runMedia = 'auto';

  /// Media the run target can emit. Every platform can carry all
  /// three media in principle; the list is what the builders write
  /// today — zx48/128 produce no disk, cpc464 has no drive, cbm adds
  /// a bare .prg alongside its tape/disk/cart images.
  List<String> get runMediaChoices {
    final id = resolveTargetId(runTarget);
    if (id == null) return const ['auto', 'tape'];
    return switch (platformOf(id)) {
      TargetFamily.cbm =>
        const ['auto', 'disk', 'tape', 'cartridge', 'program'],
      TargetFamily.cpc => id == 464
          ? const ['auto', 'tape', 'cartridge']
          : const ['auto', 'tape', 'disk', 'cartridge'],
      TargetFamily.zx => id == 3
          ? const ['auto', 'tape', 'disk', 'cartridge']
          : const ['auto', 'tape', 'cartridge'],
    };
  }

  void selectRunTarget(String? key) {
    runTarget = key;
    if (!runMediaChoices.contains(runMedia)) runMedia = 'auto';
    notifyListeners();
  }

  void selectRunMedia(String? m) {
    runMedia = m ?? 'auto';
    notifyListeners();
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    emulatorCmd = prefs.getString('emulatorCmd') ?? emulatorCmd;
    emulatorCmdDsk = prefs.getString('emulatorCmdDsk') ?? emulatorCmdDsk;
    emulatorCmdCpc = prefs.getString('emulatorCmdCpc') ?? emulatorCmdCpc;
    emulatorCmdCpcDsk =
        prefs.getString('emulatorCmdCpcDsk') ?? emulatorCmdCpcDsk;
    emulatorCmdCbm = prefs.getString('emulatorCmdCbm') ?? emulatorCmdCbm;
    emulatorCmdCbmTape =
        prefs.getString('emulatorCmdCbmTape') ?? emulatorCmdCbmTape;
    emulatorCmdCbmCart =
        prefs.getString('emulatorCmdCbmCart') ?? emulatorCmdCbmCart;
    emulatorCmdCbmPrg =
        prefs.getString('emulatorCmdCbmPrg') ?? emulatorCmdCbmPrg;
    emulatorCmdCart =
        prefs.getString('emulatorCmdCart') ?? emulatorCmdCart;
    emulatorCmdCpcCpr =
        prefs.getString('emulatorCmdCpcCpr') ?? emulatorCmdCpcCpr;
    runMedia = prefs.getString('runMedia') ?? runMedia;
    // migrate the old hardcoded 48K default so 128K projects get the
    // right machine; custom commands are left untouched
    if (emulatorCmd == _oldDefaultEmulatorCmd) {
      emulatorCmd =
          '/Applications/Fuse.app/Contents/MacOS/Fuse --machine {machine} '
          '--tape {tap}';
    }
    // migrate the old hardcoded c64p default so c128 projects get the
    // right machine; custom commands are left untouched
    if (emulatorCmdCbm == _oldDefaultEmulatorCmdCbm) {
      emulatorCmdCbm =
          'mame {machine} -flop {file} -autoboot_delay 3 '
          '-autoboot_command "LOAD\\"*\\",8,1\\nRUN\\n"';
    }
    pasmoPath = prefs.getString('pasmoPath') ?? pasmoPath;
    final last = prefs.getString('lastProject');
    if (last != null && File('$last/project.rbw.json').existsSync()) {
      _loadProject(last);
    }
  }

  // -- project --------------------------------------------------------------

  Future<void> openProjectDialog() async {
    final dir =
        await getDirectoryPath(confirmButtonText: 'Open Rainbow project');
    if (dir == null) return;
    openProject(dir);
  }

  /// Open a project dir (validates manifest). Returns an error or null.
  String? openProject(String dir) {
    if (!File('$dir/project.rbw.json').existsSync()) {
      log.add('not a Rainbow project (no project.rbw.json): $dir');
      notifyListeners();
      return 'not a Rainbow project';
    }
    _loadProject(dir);
    return null;
  }

  /// Scaffold a new project under `parentDir/name` and open it.
  /// Returns an error message or null on success.
  String? createProject(String parentDir, String name, int target) {
    final safe = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '');
    if (safe.isEmpty) return 'invalid project name';
    final dir = '$parentDir/$safe';
    if (File('$dir/project.rbw.json').existsSync()) {
      return 'project already exists: $dir';
    }
    Directory('$dir/src').createSync(recursive: true);
    Directory('$dir/assets/sprites').createSync(recursive: true);
    Directory('$dir/assets/tilesets').createSync(recursive: true);
    Directory('$dir/assets/tilemaps').createSync(recursive: true);
    Directory('$dir/assets/fonts').createSync(recursive: true);
    Directory('$dir/assets/screens').createSync(recursive: true);
    File('$dir/project.rbw.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert({
      'name': safe,
      'target': kTargetNames[target] ?? 'zx$target',
      'org': 0x8000,
      'sources': ['src/main.rbw'],
    }));
    File('$dir/src/main.rbw').writeAsStringSync(
        'PROGRAM "${safe.toUpperCase()}"\n\n'
        'MAIN:\n'
        '  BORDER 0\n'
        '  PAPER 0\n'
        '  INK 7\n'
        '  CLS\n'
        '  PRINT AT 10,4;"${safe.toUpperCase()}"\n\n'
        'done:\n'
        '  GOTO done\n');
    _loadProject(dir);
    return null;
  }

  Future<void> saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('emulatorCmd', emulatorCmd);
    await prefs.setString('emulatorCmdDsk', emulatorCmdDsk);
    await prefs.setString('emulatorCmdCpc', emulatorCmdCpc);
    await prefs.setString('emulatorCmdCpcDsk', emulatorCmdCpcDsk);
    await prefs.setString('emulatorCmdCbm', emulatorCmdCbm);
    await prefs.setString('emulatorCmdCbmTape', emulatorCmdCbmTape);
    await prefs.setString('emulatorCmdCbmCart', emulatorCmdCbmCart);
    await prefs.setString('emulatorCmdCbmPrg', emulatorCmdCbmPrg);
    await prefs.setString('emulatorCmdCart', emulatorCmdCart);
    await prefs.setString('emulatorCmdCpcCpr', emulatorCmdCpcCpr);
    await prefs.setString('runMedia', runMedia);
    await prefs.setString('pasmoPath', pasmoPath);
  }

  void _loadProject(String dir) {
    projectDir = dir;
    final m = jsonDecode(File('$dir/project.rbw.json').readAsStringSync())
        as Map<String, dynamic>;
    projectName = (m['name'] as String? ?? 'game');
    final listed = <String>{};
    listed.addAll(
        (m['sources'] as List?)?.cast<String>() ?? const ['src/main.rbw']);
    final tgts = m['targets'];
    if (tgts is Map) {
      targetKeys = tgts.keys.cast<String>().toList();
      if (runTarget == null || !targetKeys.contains(runTarget)) {
        runTarget = targetKeys.isNotEmpty ? targetKeys.first : null;
      }
      for (final v in tgts.values) {
        listed.addAll(
            ((v as Map)['sources'] as List?)?.cast<String>() ?? const []);
      }
    } else {
      targetKeys = [];
      // flat manifest: default the picker to the declared target so Run
      // behaves unchanged until the user picks another platform
      runTarget =
          targetNameOf(resolveTargetId(m['target']) ?? 48);
    }
    if (!runMediaChoices.contains(runMedia)) runMedia = 'auto';
    // INCLUDE-expanded too, so pulled-in files appear in the sidebar
    sourceFiles =
        gatherSources(dir, listed.toList())?.keys.toList() ?? listed.toList();
    assetFiles = [];
    // `assets/` is the shared set; `assets-<key>/` dirs are per-target
    // overlays (the target key from the manifest's `targets` map, or
    // the canonical target name for a flat manifest).
    for (final d in Directory(dir)
        .listSync()
        .whereType<Directory>()
        .where((d) => RegExp(r'^assets(-[^/]*)?$')
            .hasMatch(d.path.substring(dir.length + 1)))) {
      assetFiles.addAll(d
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.uri.pathSegments.last.startsWith('.'))
          .map((f) => f.path.substring(dir.length + 1)));
    }
    assetFiles.sort();
    docs.clear();
    activeDoc = -1;
    diagnostics = [];
    SharedPreferences.getInstance()
        .then((p) => p.setString('lastProject', dir));
    notifyListeners();
    if (sourceFiles.isNotEmpty) openDoc(sourceFiles.first);
    recompile();
  }

  /// True for paths under `assets/` or a per-target `assets-<key>/`
  /// overlay dir.
  static bool isAssetPath(String relPath) =>
      relPath.startsWith(RegExp(r'assets(-[^/]*)?/'));

  /// Create a new file at [relPath] with [contents]: asset files under
  /// `assets/` land in the asset tree, source files are appended to the
  /// manifest `sources` list so they compile. Returns an error message or
  /// null on success.
  String? createFile(String relPath, String contents) {
    if (projectDir == null) return 'no project open';
    final f = File('$projectDir/$relPath');
    if (f.existsSync()) return 'already exists: $relPath';
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(contents);
    if (isAssetPath(relPath)) {
      assetFiles.add(relPath);
      assetFiles.sort();
    } else {
      final mf = File('$projectDir/project.rbw.json');
      final m = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
      (m['sources'] ??= <String>[]).add(relPath);
      mf.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(m));
      sourceFiles.add(relPath);
    }
    openDoc(relPath);
    recompile();
    return null;
  }

  /// Delete the file at [relPath]: closes any open doc, removes source
  /// files from the manifest `sources` list and deletes the file from
  /// disk. Returns an error message or null on success.
  String? deleteFile(String relPath) {
    if (projectDir == null) return 'no project open';
    final f = File('$projectDir/$relPath');
    if (!f.existsSync()) return 'missing: $relPath';
    final di = docs.indexWhere((d) => d.relPath == relPath);
    if (di >= 0) closeDoc(di);
    f.deleteSync();
    if (isAssetPath(relPath)) {
      assetFiles.remove(relPath);
    } else {
      final mf = File('$projectDir/project.rbw.json');
      final m = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
      (m['sources'] as List?)?.remove(relPath);
      final dtg = m['targets'];
      if (dtg is Map) {
        for (final v in dtg.values) {
          ((v as Map)['sources'] as List?)?.remove(relPath);
        }
      }
      mf.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(m));
      sourceFiles.remove(relPath);
    }
    recompile();
    notifyListeners();
    return null;
  }

  /// Move [relPath] to [newPath] (e.g. into/out of a `assets/bank<N>/`
  /// directory). An open doc's unsaved edits are carried over.
  /// Returns an error message or null on success.
  String? moveFile(String relPath, String newPath) {
    if (projectDir == null) return 'no project open';
    if (relPath == newPath) return null;
    final src = File('$projectDir/$relPath');
    if (!src.existsSync()) return 'missing: $relPath';
    final dst = File('$projectDir/$newPath');
    if (dst.existsSync()) return 'already exists: $newPath';
    dst.parent.createSync(recursive: true);
    final di = docs.indexWhere((d) => d.relPath == relPath);
    if (di >= 0) {
      // preserve unsaved edits: write the buffer to the new path
      if (docs[di].dirty) dst.writeAsStringSync(docs[di].text);
      closeDoc(di);
    }
    if (!dst.existsSync()) {
      src.renameSync(dst.path);
    } else {
      src.deleteSync();
    }
    final ai = assetFiles.indexOf(relPath);
    if (ai >= 0) {
      assetFiles[ai] = newPath;
      assetFiles.sort();
    } else {
      final mf = File('$projectDir/project.rbw.json');
      final m = jsonDecode(mf.readAsStringSync()) as Map<String, dynamic>;
      final srcs = (m['sources'] as List?)?.cast<String>();
      final si = srcs?.indexOf(relPath) ?? -1;
      if (si >= 0) srcs![si] = newPath;
      final mtg = m['targets'];
      if (mtg is Map) {
        for (final v in mtg.values) {
          final ts = ((v as Map)['sources'] as List?);
          final ti = ts?.indexOf(relPath) ?? -1;
          if (ti >= 0) ts![ti] = newPath;
        }
      }
      mf.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(m));
      final lsi = sourceFiles.indexOf(relPath);
      if (lsi >= 0) sourceFiles[lsi] = newPath;
    }
    if (di >= 0) openDoc(newPath);
    recompile();
    notifyListeners();
    return null;
  }

  // -- documents ------------------------------------------------------------

  void openDoc(String relPath) {
    final i = docs.indexWhere((d) => d.relPath == relPath);
    if (i >= 0) {
      activeDoc = i;
      notifyListeners();
      return;
    }
    final f = File('$projectDir/$relPath');
    if (!f.existsSync()) return;
    docs.add(EditorDoc(relPath, f.readAsStringSync()));
    activeDoc = docs.length - 1;
    notifyListeners();
  }

  void closeDoc(int i) {
    docs.removeAt(i);
    if (activeDoc >= docs.length) activeDoc = docs.length - 1;
    if (i < activeDoc) activeDoc--;
    notifyListeners();
  }

  void selectDoc(int i) {
    activeDoc = i;
    notifyListeners();
  }

  EditorDoc? get currentDoc =>
      activeDoc >= 0 && activeDoc < docs.length ? docs[activeDoc] : null;

  void editDoc(EditorDoc doc, String text) {
    doc.text = text;
    doc.dirty = true;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), recompile);
  }

  void saveDoc(EditorDoc doc) {
    File('$projectDir/${doc.relPath}').writeAsStringSync(doc.text);
    doc.dirty = false;
    notifyListeners();
  }

  void saveAll() {
    for (final d in docs) {
      if (d.dirty) File('$projectDir/${d.relPath}').writeAsStringSync(d.text);
      d.dirty = false;
    }
    notifyListeners();
  }

  /// Sources merged with dirty buffers, keyed by relative path;
  /// INCLUDE'd files are pulled in too.
  Map<String, String> mergedSources() {
    final overrides = <String, String>{
      for (final d in docs.where((d) => d.dirty)) d.relPath: d.text
    };
    final g = gatherSources(projectDir!, sourceFiles,
        overrides: overrides);
    if (g != null) return g;
    final srcs = <String, String>{};
    for (final s in sourceFiles) {
      srcs[s] = overrides[s] ??
          (File('$projectDir/$s').existsSync()
              ? File('$projectDir/$s').readAsStringSync()
              : '');
    }
    return srcs;
  }

  /// Live diagnostics: compile in-memory sources only (no asm write).
  void recompile() {
    if (projectDir == null) return;
    final m = jsonDecode(
            File('$projectDir/project.rbw.json').readAsStringSync())
        as Map<String, dynamic>;
    var tgt = resolveTargetId(m['target']);
    var org = m['org'] as int?;
    String? overlayKey =
        tgt != null ? targetNameOf(tgt) : null;
    var diagSources = mergedSources();
    final tgts = m['targets'];
    if (tgts is Map && tgts.isNotEmpty) {
      // live diagnostics compile against the first declared target —
      // scoped to that entry's own sources so per-target entry files
      // don't collide (each has its own MAIN:)
      overlayKey = tgts.keys.first as String;
      final v = (tgts.values.first as Map).cast<String, dynamic>();
      tgt = resolveTargetId(v['target']) ?? tgt;
      org = v['org'] as int? ?? org;
      final srcList = ((v['sources'] as List?)?.cast<String>()) ??
          (m['sources'] as List?)?.cast<String>() ??
          const ['src/main.rbw'];
      final overrides = <String, String>{
        for (final d in docs.where((d) => d.dirty)) d.relPath: d.text
      };
      diagSources =
          gatherSources(projectDir!, srcList, overrides: overrides) ??
              diagSources;
    }
    final scan = scanAssets(projectDir!,
        overlayKey: overlayKey,
        encoders: tgt != null && platformOf(tgt) == TargetFamily.cpc
            ? cpcGfxEncoders
            : gfxEncoders);
    final r = compile(diagSources,
        org: org,
        target: tgt,
        assets: scan?.resident ?? const {},
        banked: scan?.banked ?? const {},
        bankedSize: scan?.bankedSize ?? const {});
    diagnostics = r.diag.items;
    lastInfo = r.info;
    notifyListeners();
  }

  /// Completion candidates for the code editor: language keywords plus
  /// user-declared globals/SUBs from the last compile.
  Set<String> get completions => {
        ...Lexer.keywords,
        ...(lastInfo?.globals.keys ?? const <String>{}),
        ...(lastInfo?.subs.keys ?? const <String>{}),
      };

  // -- build & run ------------------------------------------------------------

  Future<void> build() async {
    if (projectDir == null || building) return;
    saveAll();
    building = true;
    log.add('── build ${DateTime.now().toString().substring(11, 19)} ──');
    notifyListeners();
    final r = await buildProject(projectDir!,
        sources: mergedSources(),
        pasmo: pasmoPath,
        targetName: targetKeys.isNotEmpty ? runTarget : null,
        target: targetKeys.isEmpty && runTarget != null
            ? resolveTargetId(runTarget!)
            : null);
    log.addAll(r.log);
    lastTap = r.tapPath;
    lastTapTarget = r.tapTarget;
    building = false;
    recompile();
  }

  /// Build and run. [runTarget] selects the platform: a `targets` map key
  /// for multi-target manifests, or any supported target name overriding
  /// a flat manifest's declared target.
  Future<void> run() async {
    if (projectDir == null || building) return;
    saveAll();
    building = true;
    log.add('── build ${DateTime.now().toString().substring(11, 19)} ──');
    notifyListeners();
    final r = await buildProject(projectDir!,
        sources: mergedSources(),
        pasmo: pasmoPath,
        targetName: targetKeys.isNotEmpty ? runTarget : null,
        target: targetKeys.isEmpty && runTarget != null
            ? resolveTargetId(runTarget!)
            : null);
    log.addAll(r.log);
    lastTap = r.tapPath;
    lastTapTarget = r.tapTarget;
    building = false;
    recompile();
    if (lastTap == null || !File(lastTap!).existsSync()) return;
    final family = platformOf(lastTapTarget ?? 48);
    final cpc = family == TargetFamily.cpc;
    final cbm = family == TargetFamily.cbm;
    var pick = _mediaFile(lastTap!, lastTapTarget ?? 48, runMedia);
    if (pick == null && runMedia != 'auto') {
      log.add('no $runMedia image beside '
          '${lastTap!.split('/').last} — using default media');
      pick = _mediaFile(lastTap!, lastTapTarget ?? 48, 'auto');
    }
    if (pick != null) lastTap = pick;
    final ext = lastTap!.split('.').last.toLowerCase();
    final machine = cbm
        ? (lastTapTarget == 1280 ? 'c128' : 'c64p')
        : cpc
            ? targetNameOf(lastTapTarget ?? 464)
            : switch (lastTapTarget) {
                128 => '128',
                3 => 'plus3',
                _ => '48',
              };
    final cmd = (cbm
            ? switch (ext) {
                'tap' => emulatorCmdCbmTape,
                'crt' => emulatorCmdCbmCart,
                'prg' => emulatorCmdCbmPrg,
                _ => emulatorCmdCbm,
              }
            : cpc
                ? switch (ext) {
                    'dsk' => emulatorCmdCpcDsk,
                    'cpr' => emulatorCmdCpcCpr,
                    _ => emulatorCmdCpc,
                  }
                : switch (ext) {
                    'dsk' => emulatorCmdDsk,
                    'rom' || 'bin' => emulatorCmdCart,
                    _ => emulatorCmd,
                  })
        .replaceAll('{machine}', machine)
        .replaceAll('{cpctype}', _cpcTypeOf(lastTapTarget))
        .replaceAll('{tap}', '"$lastTap"')
        .replaceAll('{file}', '"$lastTap"');
    log.add('run: $cmd');
    notifyListeners();
    try {
      await (Platform.isWindows
          ? Process.start('cmd', ['/d', '/c', cmd])
          : Process.start('/bin/sh', ['-c', cmd]));
    } catch (e) {
      log.add('run failed: $e');
      notifyListeners();
    }
  }

  /// Map a run-media choice to the file the build emitted. Every
  /// medium shares the primary artifact's basename; returns null when
  /// the build didn't produce it (e.g. a `.crt` skipped for banked
  /// assets or a `.dsk` on a tape-only target) or the medium doesn't
  /// apply — 'auto' leaves the primary artifact alone outside cbm,
  /// where it means "prefer the disk, then tape, then the .prg".
  String? _mediaFile(String artifact, int target, String media) {
    final fam = platformOf(target);
    final base = artifact.replaceFirst(
        RegExp(r'\.[a-z0-9]+$', caseSensitive: false), '');
    final exts = switch (media) {
      'auto' =>
        fam == TargetFamily.cbm ? const ['.d71', '.d64', '.tap'] : const [],
      'tape' => fam == TargetFamily.cpc ? const ['.cdt'] : const ['.tap'],
      'disk' => fam == TargetFamily.cbm
          ? const ['.d71', '.d64']
          : const ['.dsk'],
      'cartridge' => switch (fam) {
          TargetFamily.cbm => const ['.crt'],
          TargetFamily.cpc => const ['.cpr'],
          _ => const ['.rom', '.bin'],
        },
      'program' =>
        fam == TargetFamily.cbm ? const ['.prg'] : const [],
      _ => const [],
    };
    for (final e in exts) {
      final p = '$base$e';
      if (File(p).existsSync()) return p;
    }
    return null;
  }

  /// Arnold's `-cpctype` value for a target id (464→0, 664→1, 6128→2).
  static String _cpcTypeOf(int? target) => switch (target) {
        464 => '0',
        664 => '1',
        _ => '2',
      };
}
