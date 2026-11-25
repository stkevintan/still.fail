// The faces a device's pages are set in (sf/faces.mbt): three places, each its own choice (`prefs.set {fonts: {…}}`):
// ui, the app's own words; text, what people and agents wrote (messages, the composer); code. None chosen: the app's
// own face (text: as ui). Beside each, a face for its CJK characters alone (`uiCjk`, `textCjk`, `codeCjk`): none, the
// place's own face sets them; text's, none chosen, is ui's, and `none` keeps it to text's own face. Beside the system's: the faces still.fail keeps in the releases bucket (scripts/fonts.py makes
// them, fonts/<id>/<version>/), and on a computer one installed there (`local:<family>`, the page lists them).
import { current } from "./i18n.ts";

export const PLACES = ["ui", "text", "code"] as const;
/// What is kept (`fonts`): each place's face, then each place's face for CJK characters.
export const FONT_SLOTS = ["ui", "text", "code", "uiCjk", "textCjk", "codeCjk"] as const;
export type Slot = (typeof FONT_SLOTS)[number];
/// `textCjk`'s: text's CJK characters in text's own face, not ui's CJK face.
const NONE = "none";
// Not util.ts's isObject: the web reads this file itself (its demo, its stories), under its stricter settings.
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
export type Place = (typeof PLACES)[number];

/// A face's file for the Android app: a weight (0: one variable file for all), gzipped, its size so and the hash of it
/// unzipped.
type File = { weight: number; file: string; bytes: number; sha256: string };
/// `hasCjk`: it has the CJK characters (a face for a place's CJK characters, or one that sets them as well).
type Entry = { id: string; version: string; zh: string; en: string; mono: boolean; hasCjk: boolean; family: string; files: File[]; preview?: string };

/// What scripts/fonts.py made and put (its output, as printed).
const FACES: Entry[] = [
  { id: "inter", version: "4.001", zh: "Inter", en: "Inter", mono: false, hasCjk: false, family: "SF Inter", preview: "preview-194fa287.ttf", files: [
    { weight: 0, file: "var.ttf.gz", bytes: 457818, sha256: "29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031" },
  ] },
  { id: "noto-sans-sc", version: "2.004", zh: "思源黑体", en: "Noto Sans SC", mono: false, hasCjk: true, family: "SF Noto Sans SC", preview: "preview-f0494178.ttf", files: [
    { weight: 0, file: "var.ttf.gz", bytes: 11276563, sha256: "a3041811a78c361b1de50f953c805e0244951c21c5bd412f7232ef0d899af0da" },
  ] },
  { id: "noto-serif-sc", version: "2.003", zh: "思源宋体", en: "Noto Serif SC", mono: false, hasCjk: true, family: "SF Noto Serif SC", preview: "preview-001bbedf.ttf", files: [
    { weight: 0, file: "var.ttf.gz", bytes: 15454579, sha256: "050080d9255a86808f2945bffac582b31ef32bc36411ce29563b4961670c66f9" },
  ] },
  { id: "lxgw-wenkai", version: "1.530", zh: "霞鹜文楷", en: "LXGW WenKai", mono: false, hasCjk: true, family: "SF LXGW WenKai", preview: "preview-d3505af4.ttf", files: [
    { weight: 400, file: "400.ttf.gz", bytes: 12904482, sha256: "2d73eea94ad808999d90c0000c239a84a33b09d4bc6ab6c5b8bbf1eda8a7fc8b" },
    { weight: 500, file: "500.ttf.gz", bytes: 13272430, sha256: "f4b8a34d1f838fe411540cb7c97b1c384ac9738a876c4104500bc42508b2312a" },
  ] },
  { id: "jetbrains-mono", version: "2.211", zh: "JetBrains Mono", en: "JetBrains Mono", mono: true, hasCjk: false, family: "SF JetBrains Mono", preview: "preview-ee73078f.ttf", files: [
    { weight: 0, file: "var.ttf.gz", bytes: 90579, sha256: "48715a42ec242c21e9f02692891e147d022299a52e48d5e413e1a942193ffeda" },
  ] },
  { id: "fira-code", version: "5.002", zh: "Fira Code", en: "Fira Code", mono: true, hasCjk: false, family: "SF Fira Code", preview: "preview-555be27a.ttf", files: [
    { weight: 0, file: "var.ttf.gz", bytes: 137151, sha256: "9335b082b3c7850d98a64b584f3417f65355f3471278bb5eeb8c6c0e8657aeeb" },
  ] },
  { id: "maple-mono", version: "7.9", zh: "Maple Mono", en: "Maple Mono", mono: true, hasCjk: true, family: "SF Maple Mono CN", preview: "preview-cffdf246.ttf", files: [
    { weight: 400, file: "400.ttf.gz", bytes: 8352545, sha256: "0fcc5139bfd5ab14ff989bb7dfd5236d0cafc10e60b9828569e6883613ab4085" },
    { weight: 600, file: "600.ttf.gz", bytes: 8438132, sha256: "96ed7ae26ee7c50b02b2d2b2bc0f1a0cbabe45ae5d6e6abf6678e2177c415677" },
  ] },
];

/// A family installed on the device, as the page names it.
const LOCAL = "local:";
const LOCAL_MAX = 120;

let origin = "";
let looksOrigin = "";

/// Where the faces are fetched from: the cloud's (its /releases/), set as the core starts; and the share card's looks'
/// files (shareLooksFile), the site's whose build the app is of. still.fail's own app on the test channel
/// (`testChannel`) is built from main before still.fail's site is (app.still.fail only with a release): its looks' files
/// are on the test channel's site, which every build of main deploys (2026-11-03: a beta app's new looks asked
/// app.still.fail for theirs and were given its page).
export function setOrigin(cloud: string, testChannel = false): void {
  origin = cloud.replace(/\/+$/, "");
  looksOrigin = testChannel && origin === "https://app.still.fail" ? "https://app.youdid.wtf" : origin;
}

/// Where this device keeps a face's file, by its hash, as a file the app's host reads there itself (font-files.ts):
/// set as the core starts; none before (and on the web, whose pages fetch the faces themselves).
let keptAt: (sha256: string) => string | null = () => null;

export function setKeptAt(at: (sha256: string) => string | null): void {
  keptAt = at;
}

/// A choice as kept: a face there is, or one of the device's (text's CJK face: or `none`); anything else is none.
function known(v: unknown, slot: Slot): string | null {
  if (typeof v !== "string") return null;
  if (slot === "textCjk" && v === NONE) return v;
  if (v.startsWith(LOCAL)) return v.length > LOCAL.length && v.length <= LOCAL_MAX ? v : null;
  return FACES.some((f) => f.id === v) ? v : null;
}

/// What is kept (`fonts`): each slot's face, only those known.
export function choicesOf(v: unknown): Record<Slot, string | null> {
  const r = isObject(v) ? v : {};
  const out = {} as Record<Slot, string | null>;
  for (const slot of FONT_SLOTS) out[slot] = known(r[slot], slot);
  return out;
}

/// What is kept as it goes out: the slots chosen.
export function chosen(v: unknown): Record<string, string> {
  const c = choicesOf(v);
  const out: Record<string, string> = {};
  for (const slot of FONT_SLOTS) if (c[slot] !== null) out[slot] = c[slot]!;
  return out;
}

/// A change to what is kept: what is said changes (null: back to none), the rest stays; what is not known is an error.
export function put(kept: unknown, patch: Record<string, unknown>): Record<string, string> | string {
  const now = choicesOf(kept);
  for (const [slot, v] of Object.entries(patch)) {
    if (!(FONT_SLOTS as readonly string[]).includes(slot)) return slot;
    if (v !== null && known(v, slot as Slot) === null) return slot;
    now[slot as Slot] = v === null ? null : (v as string);
  }
  return chosen(now);
}

/// Each place's CJK face as drawn (`""`: none, the place's own face sets them): as chosen; text's, none chosen, ui's
/// (`none`: none).
export function cjkOf(c: Record<Slot, string | null>): { uiCjk: string; textCjk: string; codeCjk: string } {
  const uiCjk = c.uiCjk ?? "";
  return { uiCjk, textCjk: c.textCjk === NONE ? "" : (c.textCjk ?? uiCjk), codeCjk: c.codeCjk ?? "" };
}

function face(e: Entry): Record<string, unknown> {
  const base = `${origin}/releases/fonts/${e.id}/${e.version}`;
  return {
    id: e.id,
    name: current() === "zh" ? e.zh : e.en,
    mono: e.mono,
    hasCjk: e.hasCjk,
    family: e.family,
    css: `${base}/font.css`,
    ...(e.preview ? { preview: `${base}/${e.preview}` } : {}),
    files: e.files.map((f) => ({ weight: f.weight, url: `${base}/${f.file}`, bytes: f.bytes, sha256: f.sha256 })),
    bytes: e.files.reduce((n, f) => n + f.bytes, 0),
  };
}

/// A file of the share card's looks that the app does not carry (`<drawing>/<name>`: web/public/share-looks/, a look's
/// picture, 1/a1-murasame-adv.webp, or their face, 1/face-400.gz), where still.fail's site keeps it; null for anything
/// else.
export function shareLooksFile(file: string): string | null {
  return /^[0-9]+\/[a-z0-9.-]+\.(gz|webp)$/.test(file) && !file.includes("..") ? `${looksOrigin}/share-looks/${file}` : null;
}

/// A face still.fail keeps, by its id, as a device fetches it: each file's address, size and hash, and its preview's.
export type FaceFiles = { files: { weight: number; url: string; bytes: number; sha256: string }[]; bytes: number; preview?: string };

/// The faces still.fail keeps, by id.
export function ids(): string[] {
  return FACES.map((f) => f.id);
}

export function faceOf(id: string): FaceFiles | null {
  const e = FACES.find((f) => f.id === id);
  if (!e) return null;
  const f = face(e);
  return { files: f.files as FaceFiles["files"], bytes: f.bytes as number, ...(typeof f.preview === "string" ? { preview: f.preview } : {}) };
}

const OWN = { id: "", name: "", mono: false, hasCjk: false, family: "", files: [], bytes: 0 };

function resolve(id: string | null, place: Place): Record<string, unknown> {
  if (id?.startsWith(LOCAL)) {
    const family = id.slice(LOCAL.length);
    return { id, name: family, mono: place === "code", hasCjk: false, family, files: [], bytes: 0 };
  }
  const e = FACES.find((f) => f.id === id);
  if (!e) return { ...OWN, mono: place === "code" };
  // a place's: each file where this device keeps it, so the app sets its pages in it as it starts, asking nothing
  const f = face(e);
  const files = (f.files as Record<string, unknown>[]).map((file) => {
    const path = keptAt(file.sha256 as string);
    return path === null ? file : { ...file, path };
  });
  return { ...f, files };
}

/// The faces as they go out (`faces`): each place's, whole (text, none chosen: as ui; each file's `path` where the
/// device keeps it), every face there is, each place's CJK face by id (`cjkOf`), and where the device keeps those
/// faces' files (`cjkPaths`, by hash: only those no place's face says already).
export function shown(kept: unknown): Record<string, unknown> {
  const c = choicesOf(kept);
  const ui = resolve(c.ui, "ui");
  const text = c.text === null ? ui : resolve(c.text, "text");
  const code = resolve(c.code, "code");
  const cjk = cjkOf(c);
  const said = new Set<string>();
  for (const place of [ui, text, code]) for (const f of place.files as { path?: string }[]) if (f.path !== undefined) said.add(f.path);
  const cjkPaths: Record<string, string> = {};
  for (const id of [cjk.uiCjk, cjk.textCjk, cjk.codeCjk]) {
    const e = FACES.find((f) => f.id === id);
    if (!e) continue;
    for (const f of e.files) {
      const path = keptAt(f.sha256);
      if (path !== null && !said.has(path)) cjkPaths[f.sha256] = path;
    }
  }
  return { ui, text, code, list: FACES.map(face), ...cjk, cjkPaths };
}
