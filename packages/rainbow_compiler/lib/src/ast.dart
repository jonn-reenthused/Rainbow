/// AST for Rainbow BASIC.
library;

enum RType { byte, uint, int, string, voidT, structT }

RType typeFromName(String name) => switch (name) {
      'BYTE' => RType.byte,
      'UINT' => RType.uint,
      'INT' => RType.int,
      'STRING' => RType.string,
      _ => RType.byte,
    };

enum BinOp { add, sub, mul, div, mod, eq, ne, lt, gt, le, ge, and, or, xor }

enum UnaryOp { neg, not }

abstract class Node {
  Node(this.line, this.col);
  final int line;
  final int col;
}

abstract class Stmt extends Node {
  Stmt(super.line, super.col);
}

abstract class Expr extends Node {
  Expr(super.line, super.col);
}

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

class NumLit extends Expr {
  NumLit(super.line, super.col, this.value);
  final int value;
}

class StrLit extends Expr {
  StrLit(super.line, super.col, this.text);
  final String text;
}

class VarExpr extends Expr {
  VarExpr(super.line, super.col, this.name, {this.field});
  final String name;
  final String? field; // .field on a scalar struct variable
}

class ArrayExpr extends Expr {
  ArrayExpr(super.line, super.col, this.name, this.indices, {this.field});
  final String name;
  final List<Expr> indices; // one per declared dimension
  final String? field; // .field on the indexed struct element
}

class CallExpr extends Expr {
  CallExpr(super.line, super.col, this.name, this.args);
  final String name;
  final List<Expr> args;
}

class BinExpr extends Expr {
  BinExpr(super.line, super.col, this.op, this.left, this.right);
  final BinOp op;
  final Expr left;
  final Expr right;
}

class UnaryExpr extends Expr {
  UnaryExpr(super.line, super.col, this.op, this.operand);
  final UnaryOp op;
  final Expr operand;
}

// ---------------------------------------------------------------------------
// Statements / declarations
// ---------------------------------------------------------------------------

class ProgramDecl extends Stmt {
  ProgramDecl(super.line, super.col, this.name);
  final String name;
}

class TargetDecl extends Stmt {
  TargetDecl(super.line, super.col, this.target);
  final int target; // 48 or 128
}

class Param {
  Param(this.name, this.type);
  final String name;
  final RType type;
}

class ConstDecl extends Stmt {
  ConstDecl(super.line, super.col, this.name, this.value);
  final String name;
  final Expr value;
}

class DimDecl extends Stmt {
  DimDecl(super.line, super.col, this.name, this.type,
      {this.dims = const [],
      this.structType,
      this.init,
      this.isGlobal = false});
  final String name;
  final RType type;
  final List<Expr> dims; // per-dimension sizes; empty = scalar
  final String?
      structType; // user TYPE name when AS <typename> is not primitive
  final Expr? init;
  final bool isGlobal;
}

class TypeDecl extends Stmt {
  TypeDecl(super.line, super.col, this.name, this.fields);
  final String name;
  final List<Param> fields; // TYPE Name ... field AS type ... END TYPE
}

class SubDecl extends Stmt {
  SubDecl(super.line, super.col, this.name, this.params, this.body,
      {this.isFunction = false, this.retType = RType.byte});
  final String name;
  final List<Param> params;
  final List<Stmt> body;
  final bool isFunction;
  final RType retType;
}

class LabelStmt extends Stmt {
  LabelStmt(super.line, super.col, this.name);
  final String name;
}

class AssignStmt extends Stmt {
  AssignStmt(super.line, super.col, this.name, this.value,
      {this.indices = const [], this.field});
  final String name;
  final List<Expr> indices; // array subscripts; empty for scalar targets
  final String? field; // .field on the (possibly indexed) struct target
  final Expr value;
}

class CallStmt extends Stmt {
  CallStmt(super.line, super.col, this.name, this.args);
  final String name;
  final List<Expr> args;
}

class IfBranch {
  IfBranch(this.cond, this.body);
  final Expr? cond; // null = else
  final List<Stmt> body;
}

class IfStmt extends Stmt {
  IfStmt(super.line, super.col, this.branches);
  final List<IfBranch> branches;
}

class WhileStmt extends Stmt {
  WhileStmt(super.line, super.col, this.cond, this.body);
  final Expr cond;
  final List<Stmt> body;
}

class RepeatStmt extends Stmt {
  RepeatStmt(super.line, super.col, this.body, this.cond);
  final List<Stmt> body;
  final Expr cond;
}

class ForStmt extends Stmt {
  ForStmt(super.line, super.col, this.varName, this.from, this.to, this.step,
      this.body);
  final String varName;
  final Expr from;
  final Expr to;
  final Expr? step; // null = step 1
  final List<Stmt> body;
}

class ReturnStmt extends Stmt {
  ReturnStmt(super.line, super.col, this.value);
  final Expr? value;
}

class GotoStmt extends Stmt {
  GotoStmt(super.line, super.col, this.name, {this.isGosub = false});
  final String name;
  final bool isGosub;
}

/// One PRINT item: exactly one of [text]/[expr]/[at] is set.
class PrintItem {
  PrintItem.text(this.text)
      : expr = null,
        at = null;
  PrintItem.expr(this.expr)
      : text = null,
        at = null;
  PrintItem.at(this.at)
      : text = null,
        expr = null;
  final String? text;
  final Expr? expr;
  final (Expr, Expr)? at; // (row, col)
}

class PrintStmt extends Stmt {
  PrintStmt(super.line, super.col, this.items, {this.noNewline = false});
  final List<PrintItem> items;
  final bool noNewline;
}

class LocateStmt extends Stmt {
  LocateStmt(super.line, super.col, this.row, this.colExpr);
  final Expr row;
  final Expr colExpr;
}

/// Single-expression statement: INK/PAPER/BRIGHT/FLASH/BORDER/OVER/INVERSE.
class Arg1Stmt extends Stmt {
  Arg1Stmt(super.line, super.col, this.kind, this.arg);
  final String kind;
  final Expr arg;
}

class ClsStmt extends Stmt {
  ClsStmt(super.line, super.col);
}

class PokeStmt extends Stmt {
  PokeStmt(super.line, super.col, this.addr, this.value);
  final Expr addr;
  final Expr value;
}

class OutStmt extends Stmt {
  OutStmt(super.line, super.col, this.port, this.value);
  final Expr port;
  final Expr value;
}

class PauseStmt extends Stmt {
  PauseStmt(super.line, super.col, this.frames);
  final Expr frames;
}

/// Parameterless statement: HALT/WAITKEY/STOP/END/RESTORE.
class SimpleStmt extends Stmt {
  SimpleStmt(super.line, super.col, this.kind);
  final String kind;
}

class RandomizeStmt extends Stmt {
  RandomizeStmt(super.line, super.col, this.seed);
  final Expr? seed;
}

class DataStmt extends Stmt {
  DataStmt(super.line, super.col, this.values);
  final List<Expr> values; // NumLit / StrLit only
}

class ReadStmt extends Stmt {
  ReadStmt(super.line, super.col, this.targets);
  final List<AssignStmt> targets;
}

class AsmBlock extends Stmt {
  AsmBlock(super.line, super.col, this.lines);
  final List<String> lines;
}

class JoystickStmt extends Stmt {
  JoystickStmt(super.line, super.col, this.mode);
  final int mode; // 0 off, 1 kempston, 2 sinclair1, 3 sinclair2, 4 cursor
}

class FillAttrStmt extends Stmt {
  FillAttrStmt(super.line, super.col, this.x, this.y, this.w, this.h);
  final Expr x, y, w, h;
}

class PlotStmt extends Stmt {
  PlotStmt(super.line, super.col, this.x, this.y);
  final Expr x, y;
}

/// SPRITE sub-command.
///   CREATE id,"asset",x,y [,MASK|OR|XOR]   -> args [id,x,y], asset, mode
///   MOVE id,dx,dy / PLACE id,x,y / FRAME id,n
///   ANIMATE id,first,last [,PINGPONG]      -> pingpong
///   REMOVE|HIDE|SHOW|REDRAW id
///   ATTR id,ink,paper[,bright]
class SpriteStmt extends Stmt {
  SpriteStmt(super.line, super.col, this.op, this.args,
      {this.asset, this.mode = 0, this.pingpong = false});
  final String op;
  final List<Expr> args;
  final String? asset;
  final int mode; // draw mode 0=mask 1=or 2=xor
  final bool pingpong;
}

/// SPRITES group command: currently only DRAWALL.
class SpritesStmt extends Stmt {
  SpritesStmt(super.line, super.col, this.op);
  final String op;
}

/// TILESET "name" - bind a tileset asset.
class TilesetStmt extends Stmt {
  TilesetStmt(super.line, super.col, this.asset);
  final String asset;
}

/// CHARSET "name" - select a font asset for PRINT output.
class CharsetStmt extends Stmt {
  CharsetStmt(super.line, super.col, this.asset);
  final String asset;
}

/// SHOWPIC "name" - copy a screen asset to the display.
class ShowpicStmt extends Stmt {
  ShowpicStmt(super.line, super.col, this.asset);
  final String asset;
}

/// TILEMAP sub-command.
///   TILEMAP "name"            -> op BIND, asset
///   VIEW x,y,w,h / CAMERA x,y / REDRAW x,y,w,h
///   DRAW
///   SCROLL LEFT|RIGHT|UP|DOWN [,n]  -> dir, args [n] (empty = 1)
class TilemapStmt extends Stmt {
  TilemapStmt(super.line, super.col, this.op,
      {this.args = const [], this.asset, this.dir = 0});
  final String op;
  final List<Expr> args;
  final String? asset;
  final int dir; // scroll: 0=L 1=R 2=U 3=D
}

/// TILEATSET x,y,id
class TileAtSetStmt extends Stmt {
  TileAtSetStmt(super.line, super.col, this.x, this.y, this.id);
  final Expr x, y, id;
}

/// MUSIC sub-command.
///   MUSIC "name"  -> op PLAY, asset (.rnt on 48K, .ray on 128K)
///   MUSIC STOP    -> op STOP (128K AY only)
///   MUSIC TICK    -> op TICK (128K AY only; manual frame advance)
class MusicStmt extends Stmt {
  MusicStmt(super.line, super.col, this.op, {this.asset});
  final String op;
  final String? asset;
}

/// SFX "name" - queue a .rsf beeper effect; it plays at the next idle
/// drain point (frame waits or SPRITES UPDATE entry).
class SfxStmt extends Stmt {
  SfxStmt(super.line, super.col, this.asset);
  final String asset;
}

/// USEBANK n - page RAM bank n into the 0xC000 window (128K).
class UseBankStmt extends Stmt {
  UseBankStmt(super.line, super.col, this.bank);
  final Expr bank;
}

/// COPYBANK "name", dest - copy a banked asset into resident memory.
class CopyBankStmt extends Stmt {
  CopyBankStmt(super.line, super.col, this.asset, this.dest);
  final String asset;
  final Expr dest;
}

/// Whole compilation unit.
class Unit {
  Unit(this.file, this.stmts);
  final String file;
  final List<Stmt> stmts;
}
