#!/usr/bin/env node
// Reproducible signature-level diff & config generator for Wave M1.1 (AFK-surf/monoid).
// Compares libs/ui/src/controls (254 prod files) + libs/ui/src/*/pkg.generated.mbti
// against AFK-surf/invar `pionc doc --json` output.
//
// Usage:
//   node pion/tools/mbt2pion-monoid/audit_signatures.mjs \
//     --invar-doc /path/to/invar_doc.json \
//     --invar-sha <40-char-sha> \
//     [--pionc-sha <sha>] [--moon-sha <sha>]
//   (or pass --invar /path/to/invar-repo to invoke `pionc doc --json` directly)

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';

const SCRIPT_DIR = path.dirname(new URL(import.meta.url).pathname);
const REPO_ROOT = path.resolve(SCRIPT_DIR, '../../..');
const CONTROLS_DIR = path.join(REPO_ROOT, 'libs/ui/src/controls');
const UI_SRC_DIR = path.join(REPO_ROOT, 'libs/ui/src');

function parseArgs(argv) {
  const args = {};
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--') && i + 1 < argv.length) {
      args[a.slice(2)] = argv[++i];
    }
  }
  return args;
}

const args = parseArgs(process.argv);
const INVAR_SHA = args['invar-sha'] || '339c271e0bd4ea9e2680f13adcec8075d6da9cf3';
const MONOID_SHA = execFileSync('git', ['-C', REPO_ROOT, 'log', '-n', '1', '--format=%H', '--', 'libs/ui/src/controls'], { encoding: 'utf8' }).trim();

function loadInvarDoc() {
  if (args['invar-doc']) {
    return JSON.parse(fs.readFileSync(args['invar-doc'], 'utf8'));
  }
  if (!args['invar']) {
    throw new Error('Provide either --invar-doc <json> or --invar <invar_repo_dir>');
  }
  const pkgs = [
    'pixels', 'paint', 'codec', 'ui', 'signals', 'hostapi', 'player',
    'headless', 'headless_core', 'view', 'motion', 'dmath', 'zip',
    'text', 'lg', 'halt', 'shape', 'flex', 'svg', 'skia', 'code_field',
    'kit', 'effect', 'icons',
  ];
  const out = {};
  for (const p of pkgs) {
    const dir = path.join(args['invar'], 'packages', p);
    if (!fs.existsSync(dir)) continue;
    const stdout = execFileSync('pionc', ['doc', '--json', dir], { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
    const data = JSON.parse(stdout);
    for (const pkg of data.packages || []) {
      out[pkg.name] = pkg.items;
    }
  }
  return out;
}

// Strip // comments, #| raw strings, and string/char literals while preserving line count
function stripCommentsAndStrings(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const c = src[i];
    if (c === '/' && src[i + 1] === '/') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '#' && src[i + 1] === '|') {
      while (i < n && src[i] !== '\n') i++;
      continue;
    }
    if (c === '"' || (c === 'b' && src[i + 1] === '"')) {
      if (c === 'b') i++;
      i++;
      while (i < n) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === '"') { i++; break; }
        if (src[i] === '\n') out += '\n';
        i++;
      }
      out += '""';
      continue;
    }
    if (c === '\'') {
      i++;
      while (i < n) {
        if (src[i] === '\\') { i += 2; continue; }
        if (src[i] === '\'') { i++; break; }
        i++;
      }
      out += "''";
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

// Parse a MoonBit pkg.generated.mbti into structured declarations
function parseMbti(mbtiText) {
  const decls = new Map();
  const lines = mbtiText.split('\n');
  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trim();
    // pub fn Name(...) -> Ret [raise ...] or pub fn[T] Type::method(...) -> Ret
    const fnHead = line.match(/^pub fn(?:\[[^\]]*\])?\s+([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)\s*\(/);
    if (fnHead) {
      const openIdx = line.indexOf('(', fnHead[0].length - 1);
      let depth = 0;
      let closeIdx = -1;
      for (let k = openIdx; k < line.length; k++) {
        if (line[k] === '(') depth++;
        else if (line[k] === ')') {
          depth--;
          if (depth === 0) { closeIdx = k; break; }
        }
      }
      if (closeIdx > openIdx && /^\s*->/.test(line.slice(closeIdx + 1))) {
        decls.set(fnHead[1], { kind: 'fn', name: fnHead[1], sig: line });
        i++;
        continue;
      }
    }
    // pub let name : Type
    let m = line.match(/^pub let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/);
    if (m) {
      decls.set(m[1], { kind: 'const', name: m[1], sig: line });
      i++;
      continue;
    }
    // pub(all) struct Name { ... } or pub struct Name { ... }
    m = line.match(/^pub(?:\(all\)|\(open\))?\s+struct\s+([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\s*\{/);
    if (m) {
      const name = m[1];
      const fields = [];
      let sigLines = [line];
      if (!line.includes('}')) {
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('}')) {
          const fl = lines[i].trim();
          sigLines.push(fl);
          const fm = fl.match(/^(?:mut\s+)?([a-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/);
          if (fm) fields.push({ name: fm[1], type: fm[2].trim() });
          i++;
        }
        if (i < lines.length) sigLines.push(lines[i].trim());
      }
      decls.set(name, { kind: 'struct', name, sig: sigLines.join(' '), fields });
      i++;
      continue;
    }
    // pub(all) enum Name { ... } or pub enum Name { ... }
    m = line.match(/^pub(?:\(all\)|\(open\))?\s+enum\s+([A-Za-z_][A-Za-z0-9_]*)(?:\[[^\]]*\])?\s*\{/);
    if (m) {
      const name = m[1];
      const variants = [];
      let sigLines = [line];
      if (!line.includes('}')) {
        i++;
        while (i < lines.length && !lines[i].trim().startsWith('}')) {
          const vl = lines[i].trim();
          sigLines.push(vl);
          const vm = vl.match(/^([A-Z][A-Za-z0-9_]*)(?:\((.*)\))?$/);
          if (vm) variants.push({ name: vm[1], payload: vm[2] ? vm[2].trim() : '' });
          i++;
        }
        if (i < lines.length) sigLines.push(lines[i].trim());
      }
      decls.set(name, { kind: 'enum', name, sig: sigLines.join(' '), variants });
      for (const v of variants) {
        decls.set(`${name}::${v.name}`, {
          kind: 'enum_variant',
          name: `${name}::${v.name}`,
          parent: name,
          sig: v.payload ? `${name}::${v.name}(${v.payload})` : `${name}::${v.name}`,
        });
      }
      i++;
      continue;
    }
    // pub type Name
    m = line.match(/^pub(?:\(all\))?\s+type\s+([A-Za-z_][A-Za-z0-9_]*)/);
    if (m) {
      decls.set(m[1], { kind: 'type', name: m[1], sig: line });
      i++;
      continue;
    }
    // pub(open) trait Name
    m = line.match(/^pub(?:\(open\))?\s+trait\s+([A-Za-z_][A-Za-z0-9_]*)/);
    if (m) {
      decls.set(m[1], { kind: 'trait', name: m[1], sig: line });
      i++;
      continue;
    }
    i++;
  }
  return decls;
}

// Parse Pion struct fields & enum variants from pionc doc --json sig
function parsePionStructFields(sig) {
  const m = sig.match(/\{(.*)\}/);
  if (!m) return [];
  return m[1]
    .split(';')
    .map(s => s.trim())
    .filter(Boolean)
    .map(part => {
      const fm = part.match(/^(?:pub\s+)?(?:mut\s+)?([a-z_][A-Za-z0-9_]*)\s*:\s*(.+)$/);
      return fm ? { name: fm[1], type: fm[2].trim() } : null;
    })
    .filter(Boolean);
}

function parsePionEnumVariants(sig) {
  const m = sig.match(/\{(.*)\}/);
  if (!m) return [];
  return m[1]
    .split(';')
    .map(s => s.trim())
    .filter(Boolean)
    .map(part => {
      const vm = part.match(/^([A-Z][A-Za-z0-9_]*)(?:\((.*)\))?$/);
      return vm ? { name: vm[1], payload: vm[2] ? vm[2].trim() : '' } : null;
    })
    .filter(Boolean);
}

// Parse top-level comma-separated parameters from fn(...)
function splitTopLevel(str, sep = ',') {
  const parts = [];
  let depth = 0;
  let cur = '';
  for (let i = 0; i < str.length; i++) {
    const c = str[i];
    if (c === '(' || c === '[' || c === '{') depth++;
    else if (c === ')' || c === ']' || c === '}') depth--;
    if (c === sep && depth === 0) {
      if (cur.trim()) parts.push(cur.trim());
      cur = '';
    } else {
      cur += c;
    }
  }
  if (cur.trim()) parts.push(cur.trim());
  return parts;
}

function parseFnSig(sig) {
  const openIdx = sig.indexOf('(');
  if (openIdx < 0) return null;
  let depth = 0;
  let closeIdx = -1;
  for (let i = openIdx; i < sig.length; i++) {
    if (sig[i] === '(') depth++;
    else if (sig[i] === ')') {
      depth--;
      if (depth === 0) { closeIdx = i; break; }
    }
  }
  if (closeIdx < 0) return null;
  const paramsRaw = sig.slice(openIdx + 1, closeIdx);
  const rest = sig.slice(closeIdx + 1).trim();
  const retMatch = rest.match(/^->\s*(.+)$/);
  const ret = retMatch ? retMatch[1].trim() : 'Unit';
  const params = splitTopLevel(paramsRaw).map((p, idx) => {
    // Handle `label~ : Type = default`, `label? : Type`, `name: Type`, or positional `Type`
    const m = p.match(/^([a-z_][A-Za-z0-9_]*)([~?])?\s*:\s*([^=]+?)(?:\s*=\s*(.+))?$/);
    if (m) {
      return {
        index: idx,
        name: m[1],
        modifier: m[2] || '',
        type: m[3].trim(),
        has_default: Boolean(m[4]),
      };
    }
    return { index: idx, name: `arg${idx}`, modifier: '', type: p.trim(), has_default: false };
  });
  return { params, ret };
}

// Normalize a MoonBit or Pion type string for position-by-position comparison.
function normalizeTypeForCompare(raw) {
  let s = String(raw || '').trim();
  // Strip optional `raise ...` suffix on return types
  s = s.replace(/\s+raise\b.*$/, '');
  // Strip package qualifiers (`@pkg.` and `pkg::`)
  s = s.replace(/@[A-Za-z0-9_\/]+\./g, '');
  s = s.replace(/\b[a-z_][a-z0-9_]*::/g, '');
  // Strip parameter names inside function types like `(a : Int, b : Int) -> Bool`
  s = s.replace(/\b[a-z_][A-Za-z0-9_]*[~?]?\s*:\s*/g, '');
  // Collapse whitespace
  s = s.replace(/\s+/g, ' ').replace(/\s*,\s*/g, ',').replace(/\s*->\s*/g, '->').replace(/\(\s+/g, '(').replace(/\s+\)/g, ')').replace(/\[\s+/g, '[').replace(/\s+\]/g, ']');
  // Iteratively rewrite postfix `T?` into `Option[T]`
  for (let pass = 0; pass < 6; pass++) {
    const next = s
      .replace(/\(([^()]+)\)\?/g, 'Option[($1)]')
      .replace(/([A-Za-z_][A-Za-z0-9_]*(?:\[[^\[\]]*\])?)\?/g, 'Option[$1]');
    if (next === s) break;
    s = next;
  }
  return s;
}

function typesCompatible(mType, pType, paramName, isAutofillLoc) {
  const mNorm = normalizeTypeForCompare(mType);
  const pNorm = normalizeTypeForCompare(pType);
  if (mNorm === pNorm) return true;
  if (isAutofillLoc && paramName === 'loc' && mNorm === 'SourceLoc' && pNorm === 'String') {
    return true;
  }
  return false;
}

// String-offset / length Int unit classifier
const STRING_OFFSET_NAMES = new Set([
  'start', 'end', 'offset', 'pos', 'caret', 'cursor', 'anchor', 'focus',
  'from', 'to', 'at', 'idx', 'index', 'byte_offset', 'byte_start', 'byte_end',
  'utf8_offset', 'utf16_offset', 'char_index', 'len', 'length', 'max_len',
  'max_chars', 'limit', 'col', 'column', 'sel_start', 'sel_end',
]);

function isStringRelatedApi(pkg, sym, sig) {
  const s = `${pkg}::${sym} ${sig}`.toLowerCase();
  return (
    s.includes('string') ||
    s.includes('text') ||
    s.includes('word') ||
    s.includes('field') ||
    s.includes('caret') ||
    s.includes('cursor') ||
    s.includes('sel') ||
    s.includes('span') ||
    s.includes('link') ||
    s.includes('glyph') ||
    s.includes('run') ||
    s.includes('line')
  );
}

function classifyIntUnit(pkg, sym, paramName, sig, role) {
  const n = (paramName || '').toLowerCase();
  const full = `${pkg}::${sym}`;
  // Explicit known string-index APIs in mbui/invar:
  // MoonBit String APIs use UTF-16 code units; Pion / Invar String APIs use UTF-8 byte offsets.
  const utf8InvarApis = new Set([
    'ui::LinkSpan', 'ui::Field::set_text', 'ui::Field::select', 'ui::Field::set_selection',
    'ui::Field::caret', 'ui::Field::selection', 'ui::Field::insert', 'ui::Field::replace',
    'ui::words_hit_box', 'ui::words_shaped', 'ui::runs_piece', 'ui::runs_links',
    'ui::runs_link_piece', 'text::measure', 'text::shape', 'text::hit_test',
    'view::View::words', 'view::View::rich',
  ]);
  if (utf8InvarApis.has(full) && (STRING_OFFSET_NAMES.has(n) || role === 'return')) {
    return { source_unit: 'utf16', target_unit: 'utf8', convert: 'utf16_to_utf8' };
  }
  if (isStringRelatedApi(pkg, sym, sig) && STRING_OFFSET_NAMES.has(n)) {
    // Disambiguate non-string Int params like line_limit, max_lines, font weight, color
    if (n === 'limit' && /line|row|item|count/i.test(sym)) {
      return { source_unit: 'none', target_unit: 'none', convert: 'none' };
    }
    return { source_unit: 'utf16', target_unit: 'utf8', convert: 'utf16_to_utf8' };
  }
  return { source_unit: 'none', target_unit: 'none', convert: 'none' };
}

function isOffsetLikeName(name) {
  const s = (name || '').toLowerCase();
  return (
    s === 'offset' ||
    s === 'byte_offset' ||
    s === 'char_offset' ||
    s === 'utf8_offset' ||
    s === 'utf16_offset' ||
    s === 'index' ||
    s === 'idx' ||
    s === 'pos' ||
    s === 'start' ||
    s === 'end' ||
    s === 'len' ||
    s === 'length' ||
    s === 'cursor' ||
    s === 'caret' ||
    s === 'selection_start' ||
    s === 'selection_end' ||
    s.endsWith('_offset') ||
    s.endsWith('_idx') ||
    s.endsWith('_index') ||
    s.endsWith('_len') ||
    s.endsWith('_length') ||
    s.endsWith('_pos')
  );
}

function buildEngineParamsAndReturn(pkg, sym, mbtiDecl, pionItem) {
  const sig = (pionItem && pionItem.sig) || (mbtiDecl && mbtiDecl.sig) || '';
  const parsed =
    (pionItem && pionItem.kind === 'fn' && parseFnSig(pionItem.sig)) ||
    (mbtiDecl && mbtiDecl.kind === 'fn' && parseFnSig(mbtiDecl.sig)) ||
    null;

  const params = [];
  let retTy = '';
  let retUnit = 'none';
  let retMapBoundary = 'none';
  let autofillLoc = false;
  let externalTildeDefault = false;
  let intUnitCount = 0;
  let orderedMapBoundary = /\bMap\[/.test(sig) || (mbtiDecl && /\bMap\[/.test(mbtiDecl.sig));

  if (parsed) {
    // Identify first String-like param name for str_param linkage
    const strParamCandidate =
      (parsed.params.find(p => /\bString\b/.test(p.type)) || {}).name || '';

    for (const p of parsed.params) {
      if (p.name === 'loc' && p.modifier === '~') autofillLoc = true;
      if (p.modifier === '~' && p.has_default) externalTildeDefault = true;
      const isInt = /\bInt\b/.test(p.type);
      let unit = 'none';
      let strParam = '';
      if (isInt) {
        const u = classifyIntUnit(pkg, sym, p.name, sig, 'param');
        unit = u.target_unit;
        if (unit === 'utf8' || unit === 'scalar') {
          strParam = strParamCandidate;
        }
        intUnitCount++;
      } else if (isOffsetLikeName(p.name)) {
        unit = 'none';
      }
      const mapBoundary = /\bMap\[/.test(p.type) ? 'ordered_to_map' : 'none';
      if (mapBoundary !== 'none') orderedMapBoundary = true;
      params.push({
        name: p.name,
        ty: p.type,
        unit,
        str_param: strParam,
        map_boundary: mapBoundary,
        is_optional: p.modifier === '?',
        has_default: Boolean(p.has_default),
      });
    }
    retTy = parsed.ret;
    if (/\bInt\b/.test(retTy)) {
      const u = classifyIntUnit(pkg, sym, 'return', sig, 'return');
      retUnit = u.target_unit;
      intUnitCount++;
    }
    if (/\bMap\[/.test(retTy)) {
      retMapBoundary = 'map_to_ordered';
      orderedMapBoundary = true;
    }
  } else if (pionItem && pionItem.kind === 'struct') {
    const fields = parsePionStructFields(pionItem.sig);
    const strFieldCandidate =
      (fields.find(f => /\bString\b/.test(f.type)) || {}).name || '';
    for (const f of fields) {
      if (/\bInt\b/.test(f.type)) {
        const u = classifyIntUnit(pkg, sym, f.name, pionItem.sig, 'field');
        const unit = u.target_unit;
        params.push({
          name: f.name,
          ty: f.type,
          unit,
          str_param: unit === 'utf8' || unit === 'scalar' ? strFieldCandidate : '',
          map_boundary: /\bMap\[/.test(f.type) ? 'ordered_to_map' : 'none',
          is_optional: false,
          has_default: false,
        });
        intUnitCount++;
      }
    }
  }

  return {
    params,
    ret_ty: retTy,
    ret_unit: retUnit,
    ret_map_boundary: retMapBoundary,
    autofill_loc: autofillLoc,
    external_tilde_default: externalTildeDefault,
    intUnitCount,
    orderedMapBoundary,
  };
}

// Curated explicit mapping overrides & anti-examples (per Wave M1 Design Spec v3 §4)
const EXPLICIT_OVERRIDES = {
  // Valid cross-package relocations in invar
  '@ui.arc': { target_pkg: 'paint', target_sym: 'arc', note: 'Moved from @ui to paint::arc in invar' },
  '@ui.line': { target_pkg: 'paint', target_sym: 'line', note: 'Moved from @ui to paint::line in invar' },
  '@ui.vector_shapes': { target_pkg: 'paint', target_sym: 'vector_shapes', note: 'Moved from @ui to paint::vector_shapes in invar' },
  '@ui.dashed_outlines': { target_pkg: 'paint', target_sym: 'dashed_outlines', note: 'Moved from @ui to paint::dashed_outlines in invar' },
  '@ui.InlineDrawing': { target_pkg: 'text', target_sym: 'InlineDrawing', note: 'Moved from @ui to text::InlineDrawing in invar' },
  '@ui.window_act': { target_pkg: 'hostapi', target_sym: 'window_act', note: 'Moved from @ui to hostapi::window_act in invar' },
  '@ui.window_snap': { target_pkg: 'hostapi', target_sym: 'window_snap', note: 'Moved from @ui to hostapi::window_snap in invar' },
  '@signals.signal': {
    target_pkg: 'signals',
    target_sym: 'signal',
    alt_target: 'signals::signal_by',
    note: '@signals.signal(init) -> signals::signal(init); @signals.signal(init, same=f) -> signals::signal_by(init, f) via recipes.toml',
  },
  // Anti-examples explicitly forbidden from false mapping:
  '@ui.style_words': {
    forbidden_target: 'hostapi::style_words',
    status: 'missing_layer2_pure_logic',
    note: 'NEVER map to hostapi::style_words (const Int bitflag); @ui.style_words is a Style builder fn',
  },
  '@ui.style_tabular': {
    forbidden_target: 'hostapi::style_tabular',
    status: 'missing_layer2_pure_logic',
    note: 'NEVER map to hostapi::style_tabular (const Int bitflag); @ui.style_tabular is a Style builder fn',
  },
  '@ui.span': {
    forbidden_target: 'text::span',
    status: 'missing_layer2_pure_logic',
    note: 'NEVER map to non-existent text::span; @ui.span is a RichText span builder',
  },
  '@ui.window_zoomed': {
    forbidden_target: 'hostapi::window_zoomed',
    target_pkg: 'ui',
    target_sym: 'host_said',
    status: 'missing_layer2_strict',
    note: 'Must map to reactive signal/ui::host_said (non-reactive ui::window_zoomed_now / hostapi::window_zoomed does not subscribe)',
  },
  '@ui.window_snap_state': {
    forbidden_target: 'hostapi::window_snap_state',
    target_pkg: 'ui',
    target_sym: 'host_said',
    status: 'missing_layer2_strict',
    note: 'Must map to reactive signal/ui::host_said (non-reactive ui::window_snap_state_now / hostapi::window_snap_state does not subscribe)',
  },
  '@ui.code_field_node': {
    forbidden_target: 'code_field::code_field_node',
    status: 'm2_plus_deferred',
    note: 'OTP segmented verification code input; NEVER map to invar code_field (syntax-highlighted code editor)',
  },
};

// Classify missing Layer 2 symbols into strict invar blockers (require invar internal state/draw/event wiring)
// vs pure-logic escape-hatch candidates (can be temporarily overlaid with 100% real logic if upstream PR is in flight)
const STRICT_INVAR_BLOCKERS = new Set([
  // Glass / LG internal Lent & surface decorators
  '@glass.in_liquid_pill',
  '@glass.bind_pill_press_by',
  '@glass.liquid_pill_hover_ink',
  '@glass.liquid_pill_trigger_lent',
  '@glass.liquid_loupe_node',
  '@glass.liquid_knob_glass',
  '@glass.liquid_scroll_edge_fill_decorate',
  '@glass.liquid_tab_bar_surface_decorate',
  '@glass.liquid_tab_lens_surface_decorate',
  '@glass.liquid_toast_surface_decorate',
  '@glass.PillDirection',
  // UI runtime / host / draw / event wiring
  '@ui.over_scrim_floor',
  '@ui.words_shaped',
  '@ui.words_hit_box',
  '@ui.WordsShape::Cell',
  '@ui.WordsShape::Code',
  '@ui.WordsShape::Heading',
  '@ui.WordsShape::Item',
  '@ui.WordsShape::Quote',
  '@ui.field_menu_now',
  '@ui.field_menu_on',
  '@ui.field_edit_now',
  '@ui.field_backdrop',
  '@ui.FieldMenuNow',
  '@ui.keeps_field_menu',
  '@ui.focused_editor_in_node',
  '@ui.holds_ime_leaving',
  '@ui.image_natural',
  '@ui.image_any_ready',
  '@ui.has_image',
  '@ui.take_picture',
  '@ui.clipboard_secret',
  '@ui.window_zoomed',
  '@ui.window_snap_state',
  '@ui.window_kept_array',
  '@ui.window_kept_map',
  '@ui.window_kept_ref',
  '@ui.window_kept_set',
  '@ui.window_corner_at',
  '@ui.window_keys_left_now',
  '@ui.window_keys_own',
  '@ui.window_keys_own_now',
  '@ui.full_screen',
  '@ui.finger_reads',
  '@ui.keyboard',
  '@ui.more_contrast',
  '@ui.native_pointing',
  '@ui.system_tabletop',
  '@ui.web_lines_on',
  '@ui.stands_alone',
  '@ui.text_advance',
  '@ui.wheel_mod_cmd',
  '@ui.wheel_mod_ctrl',
  '@ui.wheel_mod_shift',
  '@ui.current',
  '@ui.Ctx',
  '@ui.log',
  '@view.ByNode',
  // Player MediaStatus/MediaTrack/Media parity
  '@player.media_grab_wait_ms',
  '@player.media_sleep_ms',
  '@player.media_wake_ms',
]);

// Pre-frozen M1.3 interactive test matrix (per Wave M1 Design Spec v3 §6 #12b)
const FROZEN_M13_TESTS = {
  tokens: ['contrast_theme_wbtest.mbt', 'style_defaults_wbtest.mbt', 'style_node_wbtest.mbt', 'styled_words_wbtest.mbt'],
  layout: ['card_foot_wbtest.mbt', 'segment_rule_node_wbtest.mbt'],
  avatar: ['avatar_wbtest.mbt', 'avatar_stack_node_wbtest.mbt'],
  options_card: ['choices_node_wbtest.mbt', 'choice_row_node_wbtest.mbt'],
  segmented: ['seg_wbtest.mbt', 'seg_node_wbtest.mbt', 'seg_fill_node_wbtest.mbt', 'seg_glass_lens_wbtest.mbt'],
  switch: ['switch_node_wbtest.mbt'],
  slider: ['slider_node_wbtest.mbt'],
  scroll: ['scroll_keeps_typing_wbtest.mbt'],
  focus: ['button_node_focus_wbtest.mbt', 'modal_focus_wbtest.mbt', 'panel_centred_focus_wbtest.mbt'],
  a11y: ['names_wbtest.mbt'],
  player: ['player_wbtest.mbt', 'player_node_wbtest.mbt', 'player_parity_wbtest.mbt', 'player_told_wbtest.mbt'],
  assets: ['faces_wbtest.mbt', 'math_wbtest.mbt', 'math_fixture_wbtest.mbt', 'math_text_wbtest.mbt'],
};

const APP_UNREACHABLE_PROD_FILES = new Set([
  'action_sheet_node.mbt',
  'glass_button_node.mbt',
  'row_height_node.mbt',
  'toggle_group_node.mbt',
]);

const ASSET_BYPASS_PROD_FILES = new Set([
  'font_assets.mbt',
  'font_assets_native.mbt',
  'font_assets_js.mbt',
  'math_glyphs.mbt',
  'math_glyphs_native.mbt',
  'math_glyphs_js.mbt',
  'icon_data.mbt',
  'palette_data.mbt',
]);

function main() {
  const invarDoc = loadInvarDoc();

  // Build invar index: pkg -> Map(name -> item)
  const invarIndex = new Map();
  for (const [pkg, items] of Object.entries(invarDoc)) {
    const m = new Map();
    for (const it of items) m.set(it.name, it);
    invarIndex.set(pkg, m);
  }

  // Parse all imported ui/* pkg.generated.mbti
  const uiPkgs = [
    'pixels', 'paint', 'codec', 'ui', 'signals', 'hostapi', 'player',
    'headless', 'view', 'motion', 'dmath', 'zip', 'text', 'glass', 'halt',
  ];
  const mbtiIndex = new Map();
  for (const p of uiPkgs) {
    const fp = path.join(UI_SRC_DIR, p, 'pkg.generated.mbti');
    if (fs.existsSync(fp)) {
      mbtiIndex.set(p, parseMbti(fs.readFileSync(fp, 'utf8')));
    } else {
      mbtiIndex.set(p, new Map());
    }
  }

  // Scan all files in libs/ui/src/controls/
  const allMbt = fs.readdirSync(CONTROLS_DIR).filter(f => f.endsWith('.mbt')).sort();
  const prodFiles = allMbt.filter(f => !f.endsWith('_wbtest.mbt') && !f.endsWith('_test.mbt'));
  const wbtestFiles = allMbt.filter(f => f.endsWith('_wbtest.mbt'));
  const blackboxTestFiles = allMbt.filter(f => f.endsWith('_test.mbt'));

  let totalProdLoc = 0;
  let totalTestLoc = 0;
  const prodFileMeta = [];
  const prodRefs = new Map(); // "@pkg.sym" -> [{file, line}]
  let kitCommentHits = 0;
  let treeReadOutIdCommentHits = 0;

  for (const f of prodFiles) {
    const raw = fs.readFileSync(path.join(CONTROLS_DIR, f), 'utf8');
    const loc = raw.split('\n').length - (raw.endsWith('\n') ? 1 : 0);
    totalProdLoc += loc;
    const sha256 = crypto.createHash('sha256').update(raw).digest('hex');

    // Count excluded comment hits transparently
    const rawLines = raw.split('\n');
    const clean = stripCommentsAndStrings(raw);
    const cleanLines = clean.split('\n');

    for (let li = 0; li < rawLines.length; li++) {
      const rl = rawLines[li];
      const cl = cleanLines[li] || '';
      const rawKit = (rl.match(/@kit\.[A-Za-z0-9_]+/g) || []).length;
      const cleanKit = (cl.match(/@kit\.[A-Za-z0-9_]+/g) || []).length;
      kitCommentHits += Math.max(0, rawKit - cleanKit);
      const rawTro = (rl.match(/\btree_read_out_id\b/g) || []).length;
      const cleanTro = (cl.match(/\btree_read_out_id\b/g) || []).length;
      treeReadOutIdCommentHits += Math.max(0, rawTro - cleanTro);
    }

    for (let li = 0; li < cleanLines.length; li++) {
      const line = cleanLines[li];
      const re = /@([a-z][a-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)/g;
      let m;
      while ((m = re.exec(line)) !== null) {
        const key = `@${m[1]}.${m[2]}`;
        if (!prodRefs.has(key)) prodRefs.set(key, []);
        prodRefs.get(key).push({ file: f, line: li + 1 });
      }
    }

    let disposition = 'transpile_sf';
    if (ASSET_BYPASS_PROD_FILES.has(f)) disposition = 'asset_generator_bypass';
    prodFileMeta.push({
      file: f,
      loc,
      sha256,
      app_reachable: !APP_UNREACHABLE_PROD_FILES.has(f),
      disposition,
    });
  }

  // Compare every reachable @pkg.sym against invar_doc
  const corePkgs = new Set(['cmp', 'double', 'math', 'env', 'utf8', 'json']);
  const apiEntries = [];
  const strictBlockers = [];
  const escapeHatchBlockers = [];

  let totalReachableCalls = 0;
  let exactMatchedSymbols = 0;
  let sigDiffSymbols = 0;
  let missingSourceSigSymbols = 0;
  let missingSymbols = 0;
  let totalUnitAnnotatedInts = 0;
  let totalOrderedMapBoundaries = 0;

  for (const [key, locs] of [...prodRefs.entries()].sort()) {
    const [, srcPkg, sym] = key.match(/^@([^.]+)\.(.+)$/);
    if (corePkgs.has(srcPkg)) continue;
    totalReachableCalls += locs.length;

    const override = EXPLICIT_OVERRIDES[key];
    const defaultDstPkg = srcPkg === 'glass' ? 'lg' : srcPkg;
    const dstPkg = (override && override.target_pkg) || defaultDstPkg;
    const dstSym = (override && override.target_sym) || sym;

    const mbtiMap = mbtiIndex.get(srcPkg) || new Map();
    const mbtiDecl = mbtiMap.get(sym) || null;

    const dstMap = invarIndex.get(dstPkg) || new Map();
    let pionItem = dstMap.get(dstSym) || null;
    if (!pionItem && dstSym.includes('::')) {
      const [t, member] = dstSym.split('::');
      const parentItem = dstMap.get(t);
      if (parentItem && parentItem.kind === 'enum') {
        const variants = parsePionEnumVariants(parentItem.sig);
        const v = variants.find(x => x.name === member);
        if (v) {
          pionItem = {
            kind: 'enum_variant',
            name: dstSym,
            sig: v.payload ? `${dstSym}(${v.payload})` : dstSym,
          };
        }
      }
    }

    const engineSig = buildEngineParamsAndReturn(dstPkg, dstSym, mbtiDecl, pionItem);
    totalUnitAnnotatedInts += engineSig.intUnitCount;
    if (engineSig.orderedMapBoundary) totalOrderedMapBoundaries++;

    // Determine signature match / diff details
    let status = 'missing';
    const diffs = [];

    if (override && override.status && override.status.startsWith('missing_')) {
      status = override.status;
      pionItem = null;
      missingSymbols++;
    } else if (pionItem) {
      if (!mbtiDecl) {
        status = 'missing_source_sig';
        diffs.push('source_sig_missing: symbol not found in pkg.generated.mbti');
        missingSourceSigSymbols++;
      } else {
        status = 'matched';
        if (mbtiDecl.kind !== pionItem.kind) {
          diffs.push(`kind_mismatch: mbui=${mbtiDecl.kind} vs invar=${pionItem.kind}`);
        } else if (mbtiDecl.kind === 'fn' && pionItem.kind === 'fn') {
          const mSig = parseFnSig(mbtiDecl.sig);
          const pSig = parseFnSig(pionItem.sig);
          if (mSig && pSig) {
            if (mSig.params.length !== pSig.params.length) {
              diffs.push(`param_count: mbui=${mSig.params.length} vs invar=${pSig.params.length}`);
            }
            const mLabels = mSig.params.filter(p => p.modifier).map(p => `${p.name}${p.modifier}`);
            const pLabels = pSig.params.filter(p => p.modifier).map(p => `${p.name}${p.modifier}`);
            if (mLabels.join(',') !== pLabels.join(',')) {
              diffs.push(`param_labels: mbui=[${mLabels.join(', ')}] vs invar=[${pLabels.join(', ')}]`);
            }
            const minLen = Math.min(mSig.params.length, pSig.params.length);
            for (let pi = 0; pi < minLen; pi++) {
              const mp = mSig.params[pi];
              const pp = pSig.params[pi];
              if (!typesCompatible(mp.type, pp.type, mp.name || pp.name, engineSig.autofill_loc)) {
                diffs.push(`param_type[${pi}]: mbui=${mp.type} vs invar=${pp.type}`);
              }
            }
            if (normalizeTypeForCompare(mSig.ret) !== normalizeTypeForCompare(pSig.ret)) {
              diffs.push(`return_type: mbui=${mSig.ret} vs invar=${pSig.ret}`);
            }
          }
        } else if (mbtiDecl.kind === 'struct' && pionItem.kind === 'struct') {
          const mFields = (mbtiDecl.fields || []).map(f => `${f.name}:${normalizeTypeForCompare(f.type)}`);
          const pFields = parsePionStructFields(pionItem.sig).map(f => `${f.name}:${normalizeTypeForCompare(f.type)}`);
          if (mFields.join(';') !== pFields.join(';')) {
            diffs.push(`struct_fields: mbui=[${mFields.join(', ')}] vs invar=[${pFields.join(', ')}]`);
          }
        } else if (mbtiDecl.kind === 'enum' && pionItem.kind === 'enum') {
          const mVariants = mbtiDecl.variants || [];
          const pVariants = parsePionEnumVariants(pionItem.sig);
          const mVars = mVariants.map(v => v.name);
          const pVars = pVariants.map(v => v.name);
          if (mVars.join(',') !== pVars.join(',')) {
            diffs.push(`enum_variants: mbui=[${mVars.join(', ')}] vs invar=[${pVars.join(', ')}]`);
          } else {
            for (let vi = 0; vi < mVariants.length; vi++) {
              const mv = mVariants[vi];
              const pv = pVariants[vi];
              if (normalizeTypeForCompare(mv.payload) !== normalizeTypeForCompare(pv.payload)) {
                diffs.push(`enum_variant_payload[${mv.name}]: mbui=${mv.payload || '()'} vs invar=${pv.payload || '()'}`);
              }
            }
          }
        } else if (mbtiDecl.kind === 'enum_variant' && pionItem.kind === 'enum_variant') {
          const extractPayload = s => {
            const idx = String(s || '').indexOf('(');
            const end = String(s || '').lastIndexOf(')');
            return idx >= 0 && end > idx ? String(s).slice(idx + 1, end).trim() : '';
          };
          const mPay = extractPayload(mbtiDecl.sig);
          const pPay = extractPayload(pionItem.sig);
          if (normalizeTypeForCompare(mPay) !== normalizeTypeForCompare(pPay)) {
            diffs.push(`enum_variant_payload[${mbtiDecl.name}]: mbui=${mPay || '()'} vs invar=${pPay || '()'}`);
          }
        } else if (mbtiDecl.kind === 'const' && pionItem.kind === 'const') {
          const extractConstType = s => {
            const m = String(s || '').match(/:\s*([^=]+?)(?:\s*=.*)?$/);
            return m ? m[1].trim() : '';
          };
          const mTy = extractConstType(mbtiDecl.sig);
          const pTy = extractConstType(pionItem.sig);
          if (normalizeTypeForCompare(mTy) !== normalizeTypeForCompare(pTy)) {
            diffs.push(`const_type: mbui=${mTy} vs invar=${pTy}`);
          }
        }
        if (diffs.length > 0) {
          status = 'signature_diff';
          sigDiffSymbols++;
        } else {
          exactMatchedSymbols++;
        }
      }
    } else {
      missingSymbols++;
      status = STRICT_INVAR_BLOCKERS.has(key) ? 'missing_layer2_strict' : 'missing_layer2_pure_logic';
    }

    const rawKind = (pionItem && pionItem.kind) || (mbtiDecl && mbtiDecl.kind) || 'fn';
    const engineKind = rawKind === 'enum_variant' ? 'ctor' : rawKind;
    let targetEnum = '';
    let engineTargetName = dstSym;
    if (engineKind === 'ctor' && dstSym.includes('::')) {
      const parts = dstSym.split('::');
      targetEnum = parts[0];
      engineTargetName = parts[1];
    }

    const entry = {
      src_pkg: srcPkg,
      src_name: sym,
      kind: engineKind,
      target_pkg: dstPkg,
      target_name: engineTargetName,
      target_enum: targetEnum,
      params: engineSig.params,
      ret_ty: engineSig.ret_ty,
      ret_unit: engineSig.ret_unit,
      ret_map_boundary: engineSig.ret_map_boundary,
      autofill_loc: engineSig.autofill_loc,
      external_tilde_default: engineSig.external_tilde_default,
      source: key,
      source_pkg: `ui/${srcPkg}`,
      source_sig: mbtiDecl ? mbtiDecl.sig : null,
      target: pionItem ? `${dstPkg}::${dstSym}` : (override && override.target_sym ? `${dstPkg}::${dstSym}` : null),
      target_sig: pionItem ? pionItem.sig : null,
      status,
      diffs,
      ordered_map_boundary: engineSig.orderedMapBoundary,
      call_count: locs.length,
      sample_locations: locs.slice(0, 5).map(l => `libs/ui/src/controls/${l.file}:${l.line}`),
    };
    if (override && override.forbidden_target) entry.forbidden_target = override.forbidden_target;
    if (override && override.alt_target) entry.alt_target = override.alt_target;
    if (override && override.note) entry.note = override.note;
    apiEntries.push(entry);

    if (status === 'missing_layer2_strict') {
      strictBlockers.push({
        category: 'controls_prod_missing_strict',
        source: key,
        expected_invar: `${dstPkg}::${dstSym}`,
        source_sig: mbtiDecl ? mbtiDecl.sig : null,
        call_count: locs.length,
        locations: locs.slice(0, 8).map(l => `libs/ui/src/controls/${l.file}:${l.line}`),
        note: (override && override.note) || 'Requires invar internal state, draw hook, or host/event wiring (no local workaround allowed)',
      });
    } else if (status === 'missing_layer2_pure_logic') {
      escapeHatchBlockers.push({
        category: 'controls_prod_missing_pure_logic',
        source: key,
        expected_invar: `${dstPkg}::${dstSym}`,
        source_sig: mbtiDecl ? mbtiDecl.sig : null,
        call_count: locs.length,
        locations: locs.slice(0, 8).map(l => `libs/ui/src/controls/${l.file}:${l.line}`),
        note: (override && override.note) || 'Pure-logic builder/helper; upstream to invar preferred, temporary 100%-real-logic overlay allowed if upstream PR is in flight',
      });
    }
  }

  // Explicitly add player::MediaStatus & player::MediaTrack struct-level strict blockers
  const playerMbti = mbtiIndex.get('player') || new Map();
  for (const structName of ['MediaStatus', 'MediaTrack', 'MediaNote', 'MediaPhase']) {
    const mDecl = playerMbti.get(structName);
    const pItem = (invarIndex.get('player') || new Map()).get(structName);
    if (mDecl && pItem) {
      strictBlockers.push({
        category: 'controls_prod_signature_incompatible',
        source: `@player.${structName}`,
        expected_invar: `player::${structName}`,
        source_sig: mDecl.sig,
        invar_sig: pItem.sig,
        call_count: (prodRefs.get(`@player.${structName}`) || []).length,
        locations: (prodRefs.get(`@player.${structName}`) || []).slice(0, 8).map(l => `libs/ui/src/controls/${l.file}:${l.line}`),
        note: 'Struct/enum field mismatch with invar player (tested by player_wbtest.mbt:185); align directly with Invar framework owner',
      });
    }
  }

  // Explicitly track missing ui::Align::FirstLine (`AFirstLine`) until Invar adds first-line alignment
  const invarAlign = (invarIndex.get('ui') || new Map()).get('Align');
  if (
    invarAlign &&
    !parsePionEnumVariants(invarAlign.sig).some(v => v.name === 'FirstLine' || v.name === 'AFirstLine')
  ) {
    strictBlockers.push({
      category: 'controls_prod_signature_incompatible',
      source: '@ui.Align::AFirstLine',
      expected_invar: 'ui::Align::FirstLine',
      source_sig: ((mbtiIndex.get('ui') || new Map()).get('Align') || {}).sig || null,
      invar_sig: invarAlign.sig,
      call_count: 1,
      locations: [
        'libs/ui/src/ui/style_css.mbt:415',
        'libs/ui/src/controls/style_node.mbt:411',
        'apps/mbui/src/sfpages/model_triple.mbt:3267',
      ],
      note: 'Invar ui::Align lacks FirstLine (AFirstLine: FirstLineCenter + lines_up_first_line); sf::css_read fails loudly instead of silently downgrading to Align::Start',
    });
  }

  // Scan pre-frozen M1.3 test matrix for missing ui::Tester methods
  const invarTesterMethods = new Set();
  for (const it of invarDoc.ui || []) {
    if (it.name.startsWith('Tester::')) {
      invarTesterMethods.add(it.name.slice('Tester::'.length));
    }
  }
  const uiMbti = mbtiIndex.get('ui') || new Map();
  const mbuiTesterMethods = new Map();
  for (const [k, v] of uiMbti.entries()) {
    if (k.startsWith('Tester::')) {
      mbuiTesterMethods.set(k.slice('Tester::'.length), v.sig);
    }
  }

  const frozenTestSet = new Set(Object.values(FROZEN_M13_TESTS).flat());
  const testerMethodLocs = new Map();
  for (const tf of frozenTestSet) {
    const fp = path.join(CONTROLS_DIR, tf);
    if (!fs.existsSync(fp)) continue;
    const cleanLines = stripCommentsAndStrings(fs.readFileSync(fp, 'utf8')).split('\n');
    for (let li = 0; li < cleanLines.length; li++) {
      const re = /\b(?:t|tester|t1|t2)\.([a-z_][a-z0-9_]*)\s*\(/g;
      let m;
      while ((m = re.exec(cleanLines[li])) !== null) {
        const meth = m[1];
        if (!testerMethodLocs.has(meth)) testerMethodLocs.set(meth, []);
        testerMethodLocs.get(meth).push(`libs/ui/src/controls/${tf}:${li + 1}`);
      }
    }
  }

  const testerBlockers = [];
  for (const [meth, locs] of [...testerMethodLocs.entries()].sort()) {
    if (mbuiTesterMethods.has(meth) && !invarTesterMethods.has(meth)) {
      testerBlockers.push({
        category: 'm13_frozen_tester_missing',
        source: `@ui.Tester::${meth}`,
        expected_invar: `ui::Tester::${meth}`,
        source_sig: mbuiTesterMethods.get(meth),
        call_count: locs.length,
        locations: locs.slice(0, 8),
        note: 'Required by pre-frozen M1.3 interactive test matrix',
      });
    }
  }

  // Write api_map.json (schema aligned with AFK-surf/pion/tools/mbt2pion/src/symbols.pion)
  const pkgAliases = {
    glass: 'lg',
    ui: 'ui',
    view: 'view',
    signals: 'signals',
    motion: 'motion',
    headless: 'headless',
    pixels: 'pixels',
    paint: 'paint',
    player: 'player',
    hostapi: 'hostapi',
    dmath: 'dmath',
    codec: 'codec',
    text: 'text',
    zip: 'zip',
    halt: 'halt',
  };
  // Include MoonBit stdlib Json::Number variant arity (2: Double, repr?: String?) for ctor rest expansion
  if (!apiEntries.some(e => e.src_pkg === 'json' && e.src_name === 'Number' && e.kind === 'ctor')) {
    apiEntries.push({
      src_pkg: 'json',
      src_name: 'Number',
      kind: 'ctor',
      target_pkg: 'json',
      target_enum: 'JsonValue',
      target_name: 'Number',
      arity: 2,
      params: [
        { name: 'value', ty: 'Double', unit: 'none' },
        { name: 'repr', ty: 'Option[String]', unit: 'none' },
      ],
      ret_ty: 'json::JsonValue',
      ret_unit: 'none',
      ret_map_boundary: 'none',
      autofill_loc: false,
      external_tilde_default: false,
    });
  }

  const apiMapObj = {
    schema_version: 1,
    monoid_source_commit: MONOID_SHA,
    invar_target_commit: INVAR_SHA,
    scope: `libs/ui/src/controls (${prodFiles.length} production files)`,
    pkg_aliases: pkgAliases,
    denominators: {
      production_files: prodFiles.length,
      production_loc: totalProdLoc,
      source_reachable_symbols: apiEntries.length,
      source_reachable_calls: totalReachableCalls,
      target_signature_exact_matched: exactMatchedSymbols,
      target_signature_diff: sigDiffSymbols,
      target_missing_source_sig: missingSourceSigSymbols,
      target_missing: missingSymbols,
      excluded_comment_hits: {
        '@kit.*': kitCommentHits,
        tree_read_out_id: treeReadOutIdCommentHits,
      },
      int_unit_annotations: totalUnitAnnotatedInts,
      ordered_map_boundaries: totalOrderedMapBoundaries,
    },
    forbidden_false_mappings: [
      { source: '@ui.style_words', forbidden_target: 'hostapi::style_words', reason: 'hostapi::style_words is const Int bitflag, not Style fn' },
      { source: '@ui.style_tabular', forbidden_target: 'hostapi::style_tabular', reason: 'hostapi::style_tabular is const Int bitflag, not Style fn' },
      { source: '@ui.span', forbidden_target: 'text::span', reason: 'text::span does not exist in invar' },
      { source: '@ui.code_field_node', forbidden_target: 'code_field::code_field_node', reason: 'OTP code input != syntax-highlighted code editor' },
      { source: '@ui.window_zoomed', forbidden_target: 'hostapi::window_zoomed', reason: 'Must use reactive signal / ui::host_said' },
      { source: '@ui.window_snap_state', forbidden_target: 'hostapi::window_snap_state', reason: 'Must use reactive signal / ui::host_said' },
    ],
    symbols: apiEntries,
  };
  const apiMapPath = path.join(SCRIPT_DIR, 'api_map.json');
  fs.writeFileSync(apiMapPath, JSON.stringify(apiMapObj, null, 2) + '\n');

  // Write m1_invar_blockers.json
  const blockersObj = {
    schema_version: 1,
    monoid_source_commit: MONOID_SHA,
    invar_target_commit: INVAR_SHA,
    summary: {
      strict_invar_blockers: strictBlockers.length,
      pure_logic_escape_hatch_candidates: escapeHatchBlockers.length,
      m13_frozen_tester_missing_methods: testerBlockers.length,
      m2_plus_deferred_examples: 2,
    },
    strict_invar_blockers: strictBlockers,
    pure_logic_escape_hatch_candidates: escapeHatchBlockers,
    m13_frozen_tester_missing_methods: testerBlockers,
    m2_plus_deferred: [
      {
        source: '@sf.pin_field_node / OTP code_field_node',
        used_in: 'apps/mbui/src/sfpages/lock_wait_node.mbt:128',
        wave: 'M2/M3',
        note: 'Not reachable from libs/ui/src/controls production code; never map to invar code_field editor',
      },
      {
        source: 'apps/mbui/src/{sfbase,sfpages,sfdesk,sfapp} host/app_calls',
        used_in: 'apps/mbui/src/',
        wave: 'M2/M3',
        note: 'App-layer controls deferred to Wave M2/M3',
      },
    ],
  };
  const blockersPath = path.join(SCRIPT_DIR, 'm1_invar_blockers.json');
  fs.writeFileSync(blockersPath, JSON.stringify(blockersObj, null, 2) + '\n');

  // Compute SHAs for manifest.toml
  const shaFile = p => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');
  const apiMapSha = shaFile(apiMapPath);
  const recipesPath = path.join(SCRIPT_DIR, 'recipes.toml');
  const recipesSha = fs.existsSync(recipesPath) ? shaFile(recipesPath) : 'pending';
  const blockersSha = shaFile(blockersPath);

  const pioncShaDarwin = args['pionc-sha'] || 'caa5806359f60283512aa51e1210e319ba08f5593805f451f963323b609f8d61';
  const moonShaDarwin = args['moon-sha'] || '9c6caa0cccf93865869c33310d3da104547a11327a89811dbc8296eb2ea83727';
  const toolchainLock = crypto
    .createHash('sha256')
    .update(`pionc=0.1.0\nmoon=0.1.20261117\ninvar=${INVAR_SHA}\n`)
    .digest('hex');

  // Build manifest.toml
  const lines = [];
  lines.push('# Machine-generated Wave M1 manifest for AFK-surf/monoid (`libs/ui/src/controls` -> `pion/ui/packages/sf`)');
  lines.push('# Regenerate via: node pion/tools/mbt2pion-monoid/audit_signatures.mjs');
  lines.push('');
  lines.push('[metadata]');
  lines.push(`schema_version = 1`);
  lines.push(`monoid_source_commit = "${MONOID_SHA}"`);
  lines.push(`invar_lock_sha = "${INVAR_SHA}"`);
  lines.push(`mbt2pion_commit = "6d22ff1f90bd19012a5997f7fdfdc56ee3012408"`);
  lines.push(`toolchain_lock = "${toolchainLock}"`);
  lines.push(`api_map_sha256 = "${apiMapSha}"`);
  lines.push(`recipes_sha256 = "${recipesSha}"`);
  lines.push(`blockers_sha256 = "${blockersSha}"`);
  lines.push('');
  lines.push('[toolchain.versions]');
  lines.push(`pionc = "0.1.0"`);
  lines.push(`moon = "0.1.20261117"`);
  lines.push('');
  lines.push('[toolchain.binaries.darwin-arm64]');
  lines.push(`pionc_sha256 = "${pioncShaDarwin}"`);
  lines.push(`moon_sha256 = "${moonShaDarwin}"`);
  lines.push('');
  lines.push('[toolchain.binaries.linux-x86_64]');
  lines.push(`pionc_sha256 = "verify-on-linux-ci"`);
  lines.push(`moon_sha256 = "verify-on-linux-ci"`);
  lines.push('');
  lines.push('[toolchain.binaries.linux-arm64]');
  lines.push(`pionc_sha256 = "verify-on-linux-ci"`);
  lines.push(`moon_sha256 = "verify-on-linux-ci"`);
  lines.push('');
  lines.push('[assets]');
  lines.push(`code_face_ttf_bytes = 300144`);
  lines.push(`code_face_ttf_sha256 = "3cfafa86e28b87184d592fef82846e8c10cb48653c62efcda34f082da225ec34"`);
  lines.push(`math_glyphs_gz_bytes = 293607`);
  lines.push(`math_glyphs_gz_sha256 = "7fdd1b483df973987efc5d9731fc09d348e71346905604ed2f48ffdc295814f4"`);
  lines.push(`math_json_bytes = 15052`);
  lines.push(`math_json_sha256 = "7398fa93cdd39be955d010c31728cb64979db94a89ad3f8fc8fe6ab97b11d13f"`);
  lines.push(`math_mac_textrec_bytes = 5363`);
  lines.push(`math_mac_textrec_sha256 = "eb3197183f1252d7382e30e4e1b20022f7111664f023421a3e844ae88faa2cc1"`);
  lines.push('');
  lines.push('[counts]');
  lines.push(`production_files = ${prodFiles.length}`);
  lines.push(`production_loc = ${totalProdLoc}`);
  lines.push(`app_unreachable_production_files = ${APP_UNREACHABLE_PROD_FILES.size}`);
  lines.push(`wbtest_files = ${wbtestFiles.length}`);
  lines.push(`blackbox_test_files = ${blackboxTestFiles.length}`);
  lines.push(`total_test_files = ${wbtestFiles.length + blackboxTestFiles.length}`);
  lines.push('');
  lines.push('[m1_3_frozen_test_matrix]');
  for (const [cat, list] of Object.entries(FROZEN_M13_TESTS)) {
    lines.push(`${cat} = [${list.map(x => `"${x}"`).join(', ')}]`);
  }
  lines.push('');
  lines.push('[m1_1_vertical_pilot_samples]');
  lines.push(`files = [`);
  for (const s of [
    'numbers.mbt',
    'marked.mbt',
    'tokens_data.mbt',
    'clock_read_known.mbt',
    'table_copy.mbt',
    'reader_marks.mbt',
  ]) {
    lines.push(`  "${s}",`);
  }
  lines.push(`]`);
  lines.push('');
  lines.push('[m1_2_complex_target_samples]');
  lines.push(`files = [`);
  for (const s of [
    'tokens.mbt',
    'presented_windows.mbt',
    'style_node.mbt',
    'player_parts.mbt',
    'markdown.mbt',
    'icons.mbt',
    'viewer_file.mbt',
    'gradient.mbt',
    'math.mbt',
  ]) {
    lines.push(`  "${s}",`);
  }
  lines.push(`]`);
  lines.push('');

  for (const fm of prodFileMeta) {
    lines.push('[[production_files]]');
    lines.push(`file = "${fm.file}"`);
    lines.push(`loc = ${fm.loc}`);
    lines.push(`app_reachable = ${fm.app_reachable}`);
    lines.push(`disposition = "${fm.disposition}"`);
    lines.push(`sha256 = "${fm.sha256}"`);
    lines.push('');
  }

  for (const f of wbtestFiles) {
    const raw = fs.readFileSync(path.join(CONTROLS_DIR, f), 'utf8');
    const loc = raw.split('\n').length - (raw.endsWith('\n') ? 1 : 0);
    totalTestLoc += loc;
    const isFrozen = frozenTestSet.has(f);
    let disp = isFrozen ? 'm1_3_frozen_mandatory' : 'm1_3_full_wbtest_migrate';
    if (f === 'math_env_js_wbtest.mbt') disp = 'target_wasm32_web_only';
    if (f === 'math_env_native_wbtest.mbt') disp = 'target_native_only';
    if (f === 'math_fixture_wbtest.mbt' || f === 'math_text_wbtest.mbt') disp = 'prebuild_embedded_fixture';
    lines.push('[[test_files]]');
    lines.push(`file = "${f}"`);
    lines.push(`kind = "wbtest"`);
    lines.push(`loc = ${loc}`);
    lines.push(`m1_3_frozen = ${isFrozen}`);
    lines.push(`disposition = "${disp}"`);
    lines.push('');
  }

  for (const f of blackboxTestFiles) {
    const raw = fs.readFileSync(path.join(CONTROLS_DIR, f), 'utf8');
    const loc = raw.split('\n').length - (raw.endsWith('\n') ? 1 : 0);
    totalTestLoc += loc;
    lines.push('[[test_files]]');
    lines.push(`file = "${f}"`);
    lines.push(`kind = "blackbox_test"`);
    lines.push(`loc = ${loc}`);
    lines.push(`m1_3_frozen = false`);
    lines.push(`disposition = "m1_3_blackbox_migrate"`);
    lines.push('');
  }

  const manifestPath = path.join(SCRIPT_DIR, 'manifest.toml');
  fs.writeFileSync(manifestPath, lines.join('\n') + '\n');

  console.log('=== Audit Summary ===');
  console.log(`Monoid commit: ${MONOID_SHA}`);
  console.log(`Invar commit:  ${INVAR_SHA}`);
  console.log(`Prod files:    ${prodFiles.length} (${totalProdLoc} LOC, ${APP_UNREACHABLE_PROD_FILES.size} app-unreachable)`);
  console.log(`Test files:    ${wbtestFiles.length + blackboxTestFiles.length} (${wbtestFiles.length} wbtest + ${blackboxTestFiles.length} blackbox, ${totalTestLoc} LOC)`);
  console.log(`Symbols:       ${apiEntries.length} reachable (${totalReachableCalls} calls)`);
  console.log(`  Exact match: ${exactMatchedSymbols}`);
  console.log(`  Sig diff:    ${sigDiffSymbols}`);
  console.log(`  Missing:     ${missingSymbols} (strict=${strictBlockers.length - 4}, pure-logic=${escapeHatchBlockers.length})`);
  console.log(`  Player struct blockers: 4`);
  console.log(`  M1.3 Tester blockers:   ${testerBlockers.length}`);
  console.log(`  Int unit annotations:   ${totalUnitAnnotatedInts}`);
  console.log(`  OrderedMap boundaries:  ${totalOrderedMapBoundaries}`);
  console.log(`  Excluded comment hits:  @kit.*=${kitCommentHits}, tree_read_out_id=${treeReadOutIdCommentHits}`);
}

main();
