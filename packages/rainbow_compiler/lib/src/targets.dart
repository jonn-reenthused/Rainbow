/// Canonical target names shared by the manifest, the `TARGET` decl and
/// the CLI. ZX ids are the memory size in K; other backends map their
/// own names (e.g. `cpc464`, `c64`) to ids — the memory number alone is
/// ambiguous across machines.

/// Canonical target name -> internal id.
const kTargetIds = <String, int>{
  'zx48': 48,
  'zx128': 128,
  'zxplus3': 3,
  'plus3': 3,
  'cpc464': 464,
  'cpc6128': 6128,
  'c64': 64,
  'c128': 1280,
  '48': 48, // legacy aliases
  '128': 128,
};

/// Internal id -> canonical name (for diagnostics).
const kTargetNames = <int, String>{
  48: 'zx48',
  128: 'zx128',
  3: 'zxplus3',
  464: 'cpc464',
  6128: 'cpc6128',
  64: 'c64',
  1280: 'c128',
};

/// Display name for an id, falling back to the raw number.
String targetNameOf(int id) => kTargetNames[id] ?? '${id}K';

/// Which machine family a target id belongs to — drives the runtime
/// module set, asset encoders, packaging format and emulator launch.
/// (Named `TargetFamily`, not `TargetPlatform`, to avoid colliding with
/// Flutter's own enum in the IDE.)
enum TargetFamily { zx, cpc, cbm }

/// Explicit id -> family map. ZX ids are the memory size in K (48/128)
/// or 3 for the +3; CPC ids are model numbers; cbm ids are 64 for the
/// C64 and 1280 for the C128 (plain 128 collides with zx128).
const _familyOf = <int, TargetFamily>{
  48: TargetFamily.zx,
  128: TargetFamily.zx,
  3: TargetFamily.zx,
  464: TargetFamily.cpc,
  6128: TargetFamily.cpc,
  64: TargetFamily.cbm,
  1280: TargetFamily.cbm,
};

TargetFamily platformOf(int id) => _familyOf[id] ?? TargetFamily.zx;

String platformNameOf(int id) => platformOf(id).name;

/// Runtime modules each platform provides (beyond `core`/`math`/`input`/
/// `charset`, which every platform has under the same names). Statements
/// needing anything else get a polite "not supported on <target>" error.
const kPlatformModules = <TargetFamily, Set<String>>{
  TargetFamily.zx: {
    'pixel',
    'sprite',
    'tmdata',
    'tilemap',
    'spcoll',
    'ant',
    'sfx',
    'bank',
    'ay',
  },
  TargetFamily.cpc: {
    'pixel',
    'sprite',
    'tmdata',
    'tilemap',
    'spcoll',
    'sfx',
    'bank',
    'ay',
  },
  // C64 (6502): tilemap = text-cell tiles (a tile is a screen code —
  // TILESET patches charset RAM at codes 128+). `bank` is deliberately
  // absent: a stock C64 has no spare RAM to page, its ROM overlay
  // "banking" isn't the banked-asset model.
  TargetFamily.cbm: {
    'pixel',
    'tmdata',
    'tilemap',
    'sprite',
    'spcoll',
    'sfx',
    'sid',
    'diskload',
  },
};

/// Modules all platforms provide (names are the same across runtimes).
const kSharedModules = {'core', 'math', 'input', 'charset'};

/// Whether [target] has banked memory to page (zx128 RAM banks at
/// #C000; zxplus3 the same minus bank 7 — that's +3DOS's workspace;
/// cpc6128 secondary RAM banks 4-7 at #4000-#7FFF — the screen stays
/// at #C000 since c4-c7 never remap that window). cpc464/zx48/c64
/// don't. The C128 does (MMU banks 0/1) but its semantics — whole-map
/// remapping rather than a fixed window — aren't modelled yet.
bool bankCapableOf(int target) =>
    target == 128 || target == 6128 || target == 3;

/// Whether [module] is available for [target].
bool targetSupportsModule(int target, String module) =>
    kSharedModules.contains(module) ||
    ((kPlatformModules[platformOf(target)] ?? const {}).contains(module) &&
        (module != 'bank' || bankCapableOf(target)));

/// Default code org per platform (ZX: 0x8000; cpc464: 0x4000 below the
/// screen; cpc6128: 0x8000 — the bank window pages secondary RAM into
/// 0x4000-0x7FFF so resident code can't live there; cbm: 0x0801 on the
/// C64, 0x1C01 on the C128 — the respective BASIC program starts — the
/// emitted image carries a `10 SYS` stub).
int defaultOrgOf(int id) => switch (platformOf(id)) {
      TargetFamily.cpc => (id == 6128 ? 0x8000 : 0x4000),
      TargetFamily.cbm => (id == 1280 ? 0x1C01 : 0x0801),
      TargetFamily.zx => 0x8000,
    };

/// Resolves a manifest `target` value — an int (48/128, legacy) or a
/// canonical name string ('zx48', 'zx128', 'cpc464'). Null = unsupported.
int? resolveTargetId(Object? v) {
  if (v is int) return kTargetNames.containsKey(v) ? v : null;
  if (v is String) return kTargetIds[v.toLowerCase()];
  return null;
}
