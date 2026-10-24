import 'dart:convert';
import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:rainbow_assets/rainbow_assets.dart';
import 'package:rainbow_compiler/rainbow_compiler.dart';

import '../app_state.dart';
import '../spectrum.dart';
import 'code_editor.dart';
import 'font_editor.dart';
import 'music_editor.dart';
import 'screen_editor.dart';
import 'sprite_editor.dart';
import 'tilemap_editor.dart';
import 'tileset_editor.dart';

/// Main IDE window: sidebar, tabbed editors, bottom log/problems panel.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.state});

  final IdeState state;

  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _bottomTab = 0; // 0 = log, 1 = problems

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    // Command-key shortcuts on macOS, Control elsewhere (SingleActivator
    // requires modifiers not listed to be up, so this must be exact).
    final mac = Platform.isMacOS;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) => Shortcuts(
        shortcuts: {
          SingleActivator(LogicalKeyboardKey.keyS,
              meta: mac, control: !mac): _SaveIntent(),
          SingleActivator(LogicalKeyboardKey.keyB,
              meta: mac, control: !mac): _BuildIntent(),
          SingleActivator(LogicalKeyboardKey.keyR,
              meta: mac, control: !mac): _RunIntent(),
          SingleActivator(LogicalKeyboardKey.keyO,
              meta: mac, control: !mac): _OpenIntent(),
          SingleActivator(LogicalKeyboardKey.keyP,
              meta: mac, control: !mac): _QuickOpenIntent(),
          SingleActivator(LogicalKeyboardKey.keyN,
              meta: mac, control: !mac, shift: true): _NewProjectIntent(),
        },
        child: Actions(
          actions: {
            _SaveIntent: CallbackAction<_SaveIntent>(
              onInvoke: (_) => s.saveAll(),
            ),
            _BuildIntent: CallbackAction<_BuildIntent>(
              onInvoke: (_) => s.build(),
            ),
            _RunIntent: CallbackAction<_RunIntent>(onInvoke: (_) => s.run()),
            _OpenIntent: CallbackAction<_OpenIntent>(
              onInvoke: (_) => s.openProjectDialog(),
            ),
            _QuickOpenIntent: CallbackAction<_QuickOpenIntent>(
              onInvoke: (_) => _quickOpen(s),
            ),
            _NewProjectIntent: CallbackAction<_NewProjectIntent>(
              onInvoke: (_) => _newProjectDialog(s),
            ),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: const Color(0xFF16161E),
              body: Column(
                children: [
                  _titleBar(s),
                  Expanded(
                    child: Row(
                      children: [
                        _sidebar(s),
                        const VerticalDivider(
                          width: 1,
                          color: Color(0xFF2A2A38),
                        ),
                        Expanded(child: _editorArea(s)),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF2A2A38)),
                  _bottomPanel(s),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _titleBar(IdeState s) {
    return Container(
      height: 38,
      color: const Color(0xFF1B1B24),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          const Text(
            'RAINBOW',
            style: TextStyle(
              color: Color(0xFFE0AF68),
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 16),
          TextButton.icon(
            icon: const Icon(Icons.add, size: 16),
            label: const Text('New'),
            onPressed: () => _newProjectDialog(s),
          ),
          TextButton.icon(
            icon: const Icon(Icons.folder_open, size: 16),
            label: Text(s.projectDir == null ? 'Open project…' : s.projectName),
            onPressed: s.openProjectDialog,
          ),
          const Spacer(),
          if (s.building)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          TextButton.icon(
            icon: const Icon(Icons.build, size: 16),
            label: const Text('Build'),
            onPressed: s.projectDir == null || s.building ? null : s.build,
          ),
          TextButton.icon(
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('Run'),
            onPressed: s.projectDir == null || s.building ? null : s.run,
          ),
          if (s.projectDir != null && s.runChoices.length > 1)
            Tooltip(
              message: 'target to build and run',
              child: DropdownButton<String>(
                value: s.runTarget,
                isDense: true,
                underline: const SizedBox(),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12),
                dropdownColor: const Color(0xFF1B1B24),
                items: s.runChoices
                    .map((k) =>
                        DropdownMenuItem(value: k, child: Text(k)))
                    .toList(),
                onChanged: s.selectRunTarget,
              ),
            ),
          if (s.projectDir != null && s.runMediaChoices.length > 1)
            Tooltip(
              message: 'media to run',
              child: DropdownButton<String>(
                value: s.runMediaChoices.contains(s.runMedia)
                    ? s.runMedia
                    : 'auto',
                isDense: true,
                underline: const SizedBox(),
                style: const TextStyle(
                    color: Colors.white70, fontSize: 12),
                dropdownColor: const Color(0xFF1B1B24),
                items: s.runMediaChoices
                    .map((m) =>
                        DropdownMenuItem(value: m, child: Text(m)))
                    .toList(),
                onChanged: s.selectRunMedia,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.settings, size: 16, color: Colors.white54),
            tooltip: 'Settings',
            onPressed: () => _settingsDialog(s),
          ),
        ],
      ),
    );
  }

  Widget _sidebar(IdeState s) {
    if (s.projectDir == null) {
      return const SizedBox(
        width: 200,
        child: Center(
          child: Text('No project', style: TextStyle(color: Colors.grey)),
        ),
      );
    }
    return SizedBox(
      width: 200,
      child: ListView(
        padding: const EdgeInsets.all(8),
        children: [
          _group('SOURCES', s.sourceFiles, s, 'source'),
          const SizedBox(height: 12),
          _group('ASSETS', s.assetFiles, s, 'sprite'),
        ],
      ),
    );
  }

  /// Pageable banks for the run target — +3 reserves bank 1 (+3DOS
  /// cache) and bank 7 (workspace); cpc6128 has its own bank set.
  /// cbm has no pageable RAM but `bank0` still means "stream this
  /// asset off the .d64"; zx48 hides the picker (dirs are ignored).
  static Set<int> _banksFor(IdeState s) {
    final id = resolveTargetId(s.runTarget) ?? 48;
    return switch (id) {
      6128 => kCpcPageableBanks,
      3 => kPlus3PageableBanks,
      _ when platformOf(id) == TargetFamily.cbm => {0},
      _ when bankCapableOf(id) => kPageableBanks,
      _ => {},
    };
  }

  /// File kinds offered by the new-file dialog: label, subdir, extension.
  static const _kinds = <String, (String, String)>{
    'Source (.rbw)': ('src', '.rbw'),
    'Sprite (.rbs)': ('assets/sprites', '.rbs'),
    'Tileset (.rbt)': ('assets/tilesets', '.rbt'),
    'Tilemap (.rbm)': ('assets/tilemaps', '.rbm'),
    'Font (.rbf)': ('assets/fonts', '.rbf'),
    'Screen (.rbc)': ('assets/screens', '.rbc'),
    'Music 48K (.rnt)': ('assets/music', '.rnt'),
    'Music 128K (.ray)': ('assets/music', '.ray'),
    'SFX (.rsf)': ('assets/sfx', '.rsf'),
    'Import .mod → .ray': ('assets/music', '.ray'),
    'Import .mus → .ray': ('assets/music', '.ray'),
  };

  /// Font system for new .rbf assets, from the run target's platform.
  String _fontSystem() {
    final id = resolveTargetId(widget.state.runTarget);
    return switch (platformOf(id ?? 48)) {
      TargetFamily.cpc => 'cpc',
      TargetFamily.cbm => 'c64',
      _ => 'zx',
    };
  }

  String _template(String ext, String name) {
    switch (ext) {
      case '.rbw':
        final prog = name.toUpperCase();
        return 'PROGRAM "$prog"\n\nMAIN:\n  BORDER 0\n  PAPER 0\n  INK 7\n  CLS\n\ndone:\n  GOTO done\n';
      case '.rbs':
        return const JsonEncoder.withIndent('  ').convert({
          'w': 16,
          'h': 16,
          'attr': 0x47,
          'frames': [List.filled(16, '................')],
        });
      case '.rbt':
        return const JsonEncoder.withIndent('  ').convert({
          'tiles': [List.filled(8, '........')],
          'attrs': [0x38],
          'flags': [0],
        });
      case '.rbm':
        return const JsonEncoder.withIndent('  ')
            .convert({'w': 32, 'h': 20, 'map': List.filled(640, 0)});
      case '.rbf':
        final sys = _fontSystem();
        return const JsonEncoder.withIndent('  ').convert({
          'name': name,
          'system': sys,
          if (sys == 'cpc') 'mode': 1,
          'w': 8,
          'chars': <String, dynamic>{},
        });
      case '.rbc':
        return const JsonEncoder.withIndent('  ')
            .convert({'bitmap': '00' * 6144, 'attrs': '38' * 768});
      case '.rnt':
        return const JsonEncoder.withIndent('  ').convert({
          'type': 'rnt',
          'speed': 6,
          'loop': -1,
          'rows': List.filled(16, {
            'spd': 0,
            'n1': 0,
            'd1': 0,
            'n2': 0,
            'd2': 0,
            'dr': 0,
          }),
        });
      case '.ray':
        return const JsonEncoder.withIndent('  ').convert({
          'type': 'ray',
          'loop': -1,
          'rows': [
            {
              'dur': 6,
              'a': [0, 0],
              'mixer': 62,
            },
          ],
        });
      case '.rsf':
        return const JsonEncoder.withIndent('  ').convert({
          'type': 'rsf',
          'steps': [
            {'per': 60, 'len': 40, 'slide': -1},
          ],
        });
      default:
        return '';
    }
  }

  Future<void> _newFileDialog(IdeState s, String defaultKind) async {
    final kinds = _kinds.keys.toList();
    var kind = kinds.firstWhere(
      (k) => k.toLowerCase().startsWith(defaultKind),
      orElse: () => kinds.first,
    );
    final nameCtl = TextEditingController(
      text: kind.startsWith('Screen') ? 'loading' : '',
    );
    var bank = -1; // -1 = resident
    final banks = _banksFor(s);
    var ch4 = ModCh4Mode.drop; // .mod import: channel-4 strategy
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final name = nameCtl.text.trim().toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9_-]'),
            '',
          );
          final (dir, ext) = _kinds[kind]!;
          final isAsset = dir.startsWith('assets/');
          final path = name.isEmpty
              ? ''
              : bank < 0
              ? '$dir/$name$ext'
              : 'assets/bank$bank/${dir.substring(7)}/$name$ext';
          return AlertDialog(
            title: const Text('New file', style: TextStyle(fontSize: 15)),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButton<String>(
                  isExpanded: true,
                  value: kind,
                  items: [
                    for (final k in kinds)
                      DropdownMenuItem(value: k, child: Text(k)),
                  ],
                  onChanged: (v) => setDlg(() {
                    kind = v!;
                    if (kind.startsWith('Screen') &&
                        nameCtl.text.trim().isEmpty) {
                      nameCtl.text = 'loading';
                    }
                  }),
                ),
                if (kind == 'Import .mod → .ray')
                  DropdownButton<ModCh4Mode>(
                    isExpanded: true,
                    value: ch4,
                    items: const [
                      DropdownMenuItem(
                        value: ModCh4Mode.drop,
                        child: Text('channel 4: drop'),
                      ),
                      DropdownMenuItem(
                        value: ModCh4Mode.merge,
                        child: Text('channel 4: merge into C'),
                      ),
                    ],
                    onChanged: (v) => setDlg(() => ch4 = v ?? ModCh4Mode.drop),
                  ),
                if (isAsset)
                  DropdownButton<int>(
                    isExpanded: true,
                    value: bank,
                    items: [
                      const DropdownMenuItem(
                        value: -1,
                        child: Text('resident'),
                      ),
                      for (final b in banks)
                        DropdownMenuItem(value: b, child: Text('bank $b')),
                    ],
                    onChanged: (v) => setDlg(() => bank = v!),
                  ),
                TextField(
                  controller: nameCtl,
                  autofocus: true,
                  onChanged: (_) => setDlg(() {}),
                  decoration: const InputDecoration(labelText: 'name'),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    path.isEmpty ? '' : '→ $path',
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: name.isEmpty ? null : () => Navigator.pop(ctx, path),
                child: const Text('Create'),
              ),
            ],
          );
        },
      ),
    );
    if (ok == null) return;
    if (kind == 'Import .mod → .ray') {
      if (!mounted) return;
      await _importMod(s, ok, ch4);
      return;
    }
    if (kind == 'Import .mus → .ray') {
      if (!mounted) return;
      await _importMus(s, ok);
      return;
    }
    final ext = ok.substring(ok.lastIndexOf('.'));
    final name = ok.substring(ok.lastIndexOf('/') + 1, ok.lastIndexOf('.'));
    final err = s.createFile(ok, _template(ext, name));
    if (err != null) s.log.add('new file: $err');
  }

  /// Pick a ProTracker .mod, convert to .ray and write it at [dest].
  Future<void> _importMod(IdeState s, String dest, ModCh4Mode ch4) async {
    const type = XTypeGroup(label: 'ProTracker module', extensions: ['mod']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f == null) return;
    try {
      final bytes = await f.readAsBytes();
      final r = modToRay(bytes, ch4: ch4);
      final err = s.createFile(
        dest,
        const JsonEncoder.withIndent('  ').convert(r.json),
      );
      for (final line in r.report) {
        s.log.add('mod import: $line');
      }
      if (err != null) s.log.add('mod import: $err');
    } catch (e) {
      s.log.add('mod import failed: $e');
    }
  }

  /// Pick a Sidplayer .mus, convert to .ray and write it at [dest].
  Future<void> _importMus(IdeState s, String dest) async {
    const type = XTypeGroup(label: 'Sidplayer song', extensions: ['mus']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f == null) return;
    try {
      final bytes = await f.readAsBytes();
      final r = musToRay(bytes);
      final err = s.createFile(
        dest,
        const JsonEncoder.withIndent('  ').convert(r.json),
      );
      for (final line in r.report) {
        s.log.add('mus import: $line');
      }
      if (err != null) s.log.add('mus import: $err');
    } catch (e) {
      s.log.add('mus import failed: $e');
    }
  }

  /// Cmd+P quick-open: fuzzy-filtered file list, Enter/click opens.
  Future<void> _quickOpen(IdeState s) async {
    if (s.projectDir == null) return;
    final files = [...s.sourceFiles, ...s.assetFiles];
    final filter = TextEditingController();
    var sel = 0;
    final pick = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          final q = filter.text.toLowerCase();
          final shown = files
              .where((f) => f.toLowerCase().contains(q))
              .take(12)
              .toList();
          if (sel >= shown.length) sel = shown.isEmpty ? 0 : shown.length - 1;
          return AlertDialog(
            contentPadding: EdgeInsets.zero,
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Focus(
                      onKeyEvent: (node, e) {
                        if (e is! KeyDownEvent) return KeyEventResult.ignored;
                        if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
                          setDlg(
                            () => sel = shown.isEmpty
                                ? 0
                                : (sel + 1) % shown.length,
                          );
                          return KeyEventResult.handled;
                        }
                        if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
                          setDlg(
                            () => sel = shown.isEmpty
                                ? 0
                                : (sel - 1 + shown.length) % shown.length,
                          );
                          return KeyEventResult.handled;
                        }
                        if (e.logicalKey == LogicalKeyboardKey.enter &&
                            shown.isNotEmpty) {
                          Navigator.pop(ctx, shown[sel]);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: filter,
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: 'file name…',
                          isDense: true,
                          prefixIcon: Icon(Icons.search, size: 16),
                        ),
                        onChanged: (_) => setDlg(() => sel = 0),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: shown.length,
                      itemBuilder: (_, i) => ListTile(
                        dense: true,
                        selected: i == sel,
                        leading: Icon(_iconFor(shown[i]), size: 14),
                        title: Text(
                          shown[i],
                          style: const TextStyle(fontSize: 12),
                        ),
                        onTap: () => Navigator.pop(ctx, shown[i]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    if (pick != null) s.openDoc(pick);
  }

  Future<void> _settingsDialog(IdeState s) async {
    final emuCtl = TextEditingController(text: s.emulatorCmd);
    final emuZxDskCtl = TextEditingController(text: s.emulatorCmdDsk);
    final emuZxCartCtl = TextEditingController(text: s.emulatorCmdCart);
    final emuCpcCtl = TextEditingController(text: s.emulatorCmdCpc);
    final emuCpcDskCtl = TextEditingController(text: s.emulatorCmdCpcDsk);
    final emuCpcCprCtl = TextEditingController(text: s.emulatorCmdCpcCpr);
    final emuCbmCtl = TextEditingController(text: s.emulatorCmdCbm);
    final emuCbmTapeCtl = TextEditingController(text: s.emulatorCmdCbmTape);
    final emuCbmCartCtl = TextEditingController(text: s.emulatorCmdCbmCart);
    final emuCbmPrgCtl = TextEditingController(text: s.emulatorCmdCbmPrg);
    final pasmoCtl = TextEditingController(text: s.pasmoPath);
    final save = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Settings', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: pasmoCtl,
                decoration: const InputDecoration(
                  labelText: 'pasmo path',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCtl,
                decoration: const InputDecoration(
                  labelText: 'ZX emulator command — tape '
                      '({file} = artifact, {machine} = 48/128)',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuZxDskCtl,
                decoration: const InputDecoration(
                  labelText: 'ZX emulator command — disk .dsk',
                  hintText: 'Fuse --machine {machine} --disk {file} '
                      '({machine} = plus3)',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuZxCartCtl,
                decoration: const InputDecoration(
                  labelText: 'ZX emulator command — cartridge .rom '
                      '(Interface 2)',
                  hintText: 'Fuse --machine {machine} --interface2 {file}',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCpcCtl,
                decoration: const InputDecoration(
                  labelText: 'CPC emulator command — tape .cdt '
                      '({file} = artifact, {cpctype} = Arnold model)',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCpcDskCtl,
                decoration: const InputDecoration(
                  labelText: 'CPC emulator command — disk .dsk',
                  hintText: 'arnold -cpctype {cpctype} -drivea {file}',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCpcCprCtl,
                decoration: const InputDecoration(
                  labelText: 'CPC emulator command — cartridge .cpr '
                      '(CPC+/GX4000)',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCbmCtl,
                decoration: const InputDecoration(
                  labelText: 'CBM emulator command — disk .d64/.d71 '
                      '({file} = artifact)',
                  hintText: 'mame {machine} -flop {file} '
                      '-autoboot_command "LOAD\\"*\\",8,1\\nRUN\\n"',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCbmTapeCtl,
                decoration: const InputDecoration(
                  labelText: 'CBM emulator command — tape .tap',
                  hintText: 'mame {machine} -cass {file}',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCbmCartCtl,
                decoration: const InputDecoration(
                  labelText: 'CBM emulator command — cartridge .crt',
                  hintText: 'mame {machine} -cart {file}',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: emuCbmPrgCtl,
                decoration: const InputDecoration(
                  labelText: 'CBM emulator command — program .prg',
                  hintText: 'mame {machine} -quik {file}',
                  isDense: true,
                ),
                style: const TextStyle(fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback, fontSize: 12),
              ),
            ],
          ),
        ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (save != true) return;
    s.emulatorCmd = emuCtl.text.trim();
    s.emulatorCmdDsk = emuZxDskCtl.text.trim();
    s.emulatorCmdCart = emuZxCartCtl.text.trim();
    s.emulatorCmdCpc = emuCpcCtl.text.trim();
    s.emulatorCmdCpcDsk = emuCpcDskCtl.text.trim();
    s.emulatorCmdCpcCpr = emuCpcCprCtl.text.trim();
    s.emulatorCmdCbm = emuCbmCtl.text.trim();
    s.emulatorCmdCbmTape = emuCbmTapeCtl.text.trim();
    s.emulatorCmdCbmCart = emuCbmCartCtl.text.trim();
    s.emulatorCmdCbmPrg = emuCbmPrgCtl.text.trim();
    s.pasmoPath = pasmoCtl.text.trim();
    await s.saveSettings();
  }

  Future<void> _newProjectDialog(IdeState s) async {
    final parent = await getDirectoryPath(
      confirmButtonText: 'Choose folder for new project',
    );
    if (parent == null || !mounted) return;
    final nameCtl = TextEditingController();
    var target = 48;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('New project', style: TextStyle(fontSize: 15)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'in: $parent',
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                ),
                TextField(
                  controller: nameCtl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'project name',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('target:', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 12),
                    for (final t in [48, 128])
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(
                            '${t}K',
                            style: const TextStyle(fontSize: 11),
                          ),
                          selected: target == t,
                          onSelected: (_) => setDlg(() => target = t),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final err = s.createProject(parent, nameCtl.text, target);
    if (err != null) s.log.add('new project: $err');
  }

  Widget _group(String title, List<String> files, IdeState s, String kind) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            GestureDetector(
              onTap: () => _newFileDialog(s, kind),
              child: const Icon(Icons.add, size: 14, color: Colors.white54),
            ),
          ],
        ),
        const SizedBox(height: 4),
        for (final f in files)
          InkWell(
            onTap: () => s.openDoc(f),
            onSecondaryTapUp: (d) => _fileMenu(s, f, d.globalPosition),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 6),
              child: Row(
                children: [
                  Icon(_iconFor(f), size: 14, color: Colors.white54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      f.split('/').last,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  // per-target overlay tag: assets-<key>/…
                  if (RegExp(r'^assets-([^/]+)/').firstMatch(f)
                      case final m?)
                    Text(
                      m.group(1)!,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white24,
                      ),
                    ),
                  if (RegExp(r'/bank(\d+)/').firstMatch(f) case final m?)
                    Text(
                      ' b${m.group(1)}',
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white38,
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Right-click menu on a sidebar file — bank move (assets) + delete.
  Future<void> _fileMenu(IdeState s, String f, Offset pos) async {
    final isAsset = IdeState.isAssetPath(f);
    // root = 'assets/' or 'assets-<key>/' — bank moves stay inside it
    final root = isAsset
        ? RegExp(r'^assets(-[^/]+)?/').firstMatch(f)!.group(0)!
        : '';
    final bm = RegExp(r'^bank(\d+)/').firstMatch(f.substring(root.length));
    final curBank = bm != null ? int.parse(bm.group(1)!) : -1;
    final items = <PopupMenuEntry<String>>[
      if (isAsset) ...[
        for (final b in [-1, ..._banksFor(s)])
          if (b != curBank)
            PopupMenuItem(
              value: 'bank:$b',
              child: Text(
                b < 0 ? 'Move to resident' : 'Move to bank $b',
                style: const TextStyle(fontSize: 12),
              ),
            ),
        const PopupMenuDivider(),
      ],
      PopupMenuItem(
        value: 'delete',
        child: Text(
          'Delete ${f.split('/').last}',
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ];
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      items: items,
    );
    if (choice == null || !mounted) return;
    if (choice.startsWith('bank:')) {
      final bank = int.parse(choice.substring(5));
      // <root>[bankN/]<rest> -> <root>bankN/<rest> or <root><rest>
      var rest = f.substring(root.length);
      final sm = RegExp(r'^bank\d+/').firstMatch(rest);
      if (sm != null) rest = rest.substring(sm.end);
      final dest = bank < 0 ? '$root$rest' : '${root}bank$bank/$rest';
      final err = s.moveFile(f, dest);
      if (err != null) s.log.add('move: $err');
      return;
    }
    if (choice != 'delete') return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete file', style: TextStyle(fontSize: 15)),
        content: Text(
          'Delete $f? This cannot be undone.',
          style: const TextStyle(fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final err = s.deleteFile(f);
    if (err != null) s.log.add('delete: $err');
  }

  IconData _iconFor(String f) {
    if (f.endsWith('.rbw')) return Icons.code;
    if (f.endsWith('.rbs')) return Icons.person;
    if (f.endsWith('.rbt')) return Icons.grid_on;
    if (f.endsWith('.rbm')) return Icons.map;
    if (f.endsWith('.rbf')) return Icons.font_download;
    if (f.endsWith('.rbc')) return Icons.image;
    if (f.endsWith('.rnt') || f.endsWith('.ray')) return Icons.music_note;
    if (f.endsWith('.rsf')) return Icons.graphic_eq;
    if (f.endsWith('.scr')) return Icons.image;
    return Icons.insert_drive_file;
  }

  Widget _editorArea(IdeState s) {
    final doc = s.currentDoc;
    return Column(
      children: [
        if (s.docs.isNotEmpty)
          SizedBox(
            height: 32,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: s.docs.length,
              itemBuilder: (context, i) {
                final d = s.docs[i];
                final active = i == s.activeDoc;
                return InkWell(
                  onTap: () => s.selectDoc(i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF24243A)
                          : Colors.transparent,
                      border: const Border(
                        right: BorderSide(color: Color(0xFF2A2A38)),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          d.dirty ? '● ${d.name}' : d.name,
                          style: TextStyle(
                            fontSize: 12,
                            color: active ? Colors.white : Colors.white54,
                          ),
                        ),
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: () => s.closeDoc(i),
                          child: const Icon(
                            Icons.close,
                            size: 12,
                            color: Colors.white38,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        Expanded(
          child: doc == null
              ? const Center(
                  child: Text(
                    'Open a project and select a file',
                    style: TextStyle(color: Colors.white38),
                  ),
                )
              : _editorFor(s, doc),
        ),
      ],
    );
  }

  Widget _editorFor(IdeState s, EditorDoc doc) {
    final path = doc.relPath;
    // key on project+path: two projects share rel paths like
    // src/main.rbw, and a bare ValueKey(path) would reuse the old
    // editor state (showing the previous project's text)
    final k = ValueKey('${s.projectDir}:$path');
    final diags = s.diagnostics.where((d) => _matchesDoc(d, path)).toList();
    void onChanged(String t) => s.editDoc(doc, t);
    if (path.endsWith('.rbs')) {
      return SpriteEditor(
        key: k,
        text: doc.text,
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rbt')) {
      return TilesetEditor(
        key: k,
        text: doc.text,
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rbm')) {
      return TilemapEditor(
        key: k,
        text: doc.text,
        projectDir: s.projectDir!,
        relPath: doc.relPath,
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rbf')) {
      return FontEditor(
        key: k,
        text: doc.text,
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rbc')) {
      return ScreenEditor(
        key: k,
        text: doc.text,
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rnt') || path.endsWith('.ray')) {
      return MusicEditor(
        key: k,
        text: doc.text,
        isAy: path.endsWith('.ray'),
        onChanged: onChanged,
      );
    }
    if (path.endsWith('.rsf')) {
      return SfxEditor(
        key: k,
        text: doc.text,
        onChanged: onChanged,
      );
    }
    return CodeEditor(
      key: k,
      doc: doc,
      diags: diags,
      onChanged: onChanged,
      symbols: s.completions,
    );
  }

  bool _matchesDoc(Diagnostic d, String relPath) =>
      d.file == relPath ||
      d.file.endsWith('/$relPath') ||
      relPath.endsWith(d.file);

  Widget _bottomPanel(IdeState s) {
    return SizedBox(
      height: 160,
      child: Column(
        children: [
          Container(
            height: 28,
            color: const Color(0xFF1B1B24),
            child: Row(
              children: [
                _panelTab(0, 'BUILD LOG'),
                _panelTab(
                  1,
                  'PROBLEMS (${s.diagnostics.where((d) => !d.isWarning).length})',
                ),
                const Spacer(),
              ],
            ),
          ),
          Expanded(child: _bottomTab == 0 ? _logView(s) : _problemsView(s)),
        ],
      ),
    );
  }

  Widget _panelTab(int i, String label) {
    final active = _bottomTab == i;
    return InkWell(
      onTap: () => setState(() => _bottomTab = i),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? const Color(0xFFE0AF68) : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: active ? Colors.white : Colors.white38,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _logView(IdeState s) {
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: s.log.length,
      itemBuilder: (context, i) => Text(
        s.log[i],
        style: const TextStyle(
          fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback,
          fontSize: 11,
          color: Colors.white70,
        ),
      ),
    );
  }

  Widget _problemsView(IdeState s) {
    if (s.diagnostics.isEmpty) {
      return const Center(
        child: Text(
          'No problems',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: s.diagnostics.length,
      itemBuilder: (context, i) {
        final d = s.diagnostics[i];
        return InkWell(
          onTap: () => s.openDoc(d.file),
          child: Row(
            children: [
              Icon(
                d.isWarning ? Icons.warning_amber : Icons.error,
                size: 14,
                color: d.isWarning
                    ? const Color(0xFFCCA700)
                    : const Color(0xFFF44747),
              ),
              const SizedBox(width: 8),
              Text(
                '${d.file}:${d.line}:${d.col}',
                style: const TextStyle(
                  fontFamily: 'Menlo', fontFamilyFallback: monoFontFallback,
                  fontSize: 11,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  d.message,
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _BuildIntent extends Intent {
  const _BuildIntent();
}

class _RunIntent extends Intent {
  const _RunIntent();
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}

class _QuickOpenIntent extends Intent {
  const _QuickOpenIntent();
}

class _NewProjectIntent extends Intent {
  const _NewProjectIntent();
}
