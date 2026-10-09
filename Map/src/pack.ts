// Mapo — circle-packing map (docs/TASARIM.md, PLAN A30).
//
// The codebase is drawn as nested circles: folders contain folders contain
// files; a file's area is its lines of code; zooming into a file reveals its
// functions and types. Position means something (the folder tree) and is
// stable between runs. Dependencies are never drawn at rest: selecting a file
// or symbol shows them summarised per area, one curve per neighbouring folder.
//
// Rendering is a plain 2D canvas: a few thousand circles with culling is far
// below what the canvas can do, and it gives full control over labels.

import { hierarchy, pack, packEnclose, packSiblings, type HierarchyCircularNode } from "d3-hierarchy";

import { DARK, LIGHT, mix, neutralColor, spreadColor, type Theme } from "./palette";
import { type LinkFilter, Kind, Rel, type ColorMode, type Detail, type GroupInfo, type Outgoing, type Payload } from "./types";

// ---------------------------------------------------------------------------
// Bridge

function post(msg: Outgoing) {
  const h = (window as any).webkit?.messageHandlers?.mapo;
  if (h) h.postMessage(msg);
  else console.debug("[mapo]", msg);
}

window.addEventListener("error", (e) => post({ type: "error", message: String(e.message) }));
window.addEventListener("unhandledrejection", (e) => post({ type: "error", message: String((e as PromiseRejectionEvent).reason) }));

// ---------------------------------------------------------------------------
// Model

type CircleKind = "root" | "dir" | "file" | "sym";

interface Circle {
  /** Payload node id for files / symbols, "dir:<path>" for folders. */
  key: string;
  kind: CircleKind;
  name: string;
  /** Folder path or file path. */
  path: string;
  x: number;
  y: number;
  r: number;
  parent: Circle | null;
  /** Folders: sub-folders and files. Files: symbols (present when detail ≥ 1). */
  children: Circle[];
  depth: number;
  /** Payload index (files / symbols), -1 for folders. */
  idx: number;
  /** Area (payload.folders index) when the whole subtree is in one, else -1. */
  group: number;
}

const canvas = document.getElementById("pack") as HTMLCanvasElement;
const ctx = canvas.getContext("2d")!;
// UI language, set by the app (mapoMap.setLocale) to match its own.
const STRINGS = {
  tr: {
    loading: "Harita yükleniyor…", loadFailed: "Harita verisi alınamadı", empty: "Bu projede gösterilecek dosya yok",
    project: "Tüm proje", all: "Tümü", uses: "Kullandıkları", usedBy: "Kullananlar", noLinks: "Bağlantısı yok",
    day: "Son 24 saat", week: "Bu hafta", month: "Bu ay", older: "Daha eski",
    veryDense: "Çok yoğun", dense: "Yoğun", medium: "Orta", sparse: "Az ya da yok",
    file: "Dosya", function: "Fonksiyon", method: "Metot", type: "Tip", document: "Belge", route: "HTTP uç noktası", table: "Tablo", symbol: "Sembol",
    lines: "satır", links: "bağlantı", other: "Diğer",
    onlyCalls: "yalnız çağrılar", onlyImports: "yalnız içe aktarmalar", onlyBridges: "yalnız HTTP ve SQL",
  },
  en: {
    loading: "Loading map…", loadFailed: "Couldn't load the map data", empty: "Nothing to show in this project",
    project: "Whole project", all: "All", uses: "Uses", usedBy: "Used by", noLinks: "No links",
    day: "Last 24 hours", week: "This week", month: "This month", older: "Older",
    veryDense: "Very dense", dense: "Dense", medium: "Medium", sparse: "Little or none",
    file: "File", function: "Function", method: "Method", type: "Type", document: "Document", route: "HTTP endpoint", table: "Table", symbol: "Symbol",
    lines: "lines", links: "links", other: "Other",
    onlyCalls: "calls only", onlyImports: "imports only", onlyBridges: "HTTP and SQL only",
  },
};
type Lang = keyof typeof STRINGS;
let lang: Lang = "tr";
const t = (k: keyof (typeof STRINGS)["tr"]) => STRINGS[lang][k];
const num = (n: number) => n.toLocaleString(lang);

const tip = document.getElementById("tip")!;
const crumbs = document.getElementById("crumbs")!;
const legend = document.getElementById("legend")!;
const status = document.getElementById("status")!;

const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const motionQuery = matchMedia("(prefers-reduced-motion: reduce)");
let theme: Theme = darkQuery.matches ? DARK : LIGHT;

let payload: Payload | null = null;
let root: Circle | null = null;
const byKey = new Map<string, Circle>();
/** File names that occur more than once ("index.ts", "[id].tsx"). */
let ambiguous = new Set<string>();

/** "kulupler/[id].tsx" when the bare name would be ambiguous. */
function fileLabel(c: Circle): string {
  if (c.kind !== "file" || !ambiguous.has(c.name)) return c.name;
  const parts = c.path.split("/");
  return parts.length > 1 ? `${parts[parts.length - 2]}/${c.name}` : c.name;
}

let detail: Detail = 1;
let colorMode: ColorMode = "folder";
let hideTests = false;
let showNoise = false;

let selected: Circle | null = null;
let hovered: Circle | null = null;
/** Hovering previews a file's or function's links (selected stands in for
 *  it without telling the app); a click makes it the real selection. */
let previewing = false;
let previewTimer = 0;
/** Folder the user zoomed into (breadcrumb, Esc / background click go up). */
let zoomDir: Circle | null = null;

interface Anchor {
  circle: Circle;
  /** Symbol / file edges summarised into this anchor. */
  weight: number;
  /** Distinct files (or symbols) behind it. */
  members: Set<Circle>;
}
/** What the current selection is connected to, grouped per area. */
let focus: { uses: Anchor[]; usedBy: Anchor[]; lit: Set<Circle> } | null = null;
/** Impact / path highlight from Swift. */
let highlight: { set: Set<Circle>; chain: Circle[] | null } | null = null;

const cam = { x: 500, y: 500, k: 1 };
let camReady = false;
let W = 0, H = 0, dpr = 1;

/** A file shows its symbols once drawn at least this wide (px radius). */
const SYMBOLS_AT = 46;

const duration = () => (motionQuery.matches ? 0 : 420);

// ---------------------------------------------------------------------------
// Loading & layout

async function load(url: string, keepView = false, sel: string | null = null) {
  setStatus(t("loading"));
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${t("loadFailed")} (${res.status})`);
  payload = (await res.json()) as Payload;
  const view = keepView && camReady ? { ...cam } : null;
  build();
  setStatus(root && root.children.length ? null : t("empty"));
  post({ type: "loaded", nodes: payload.nodes.id.length, edges: payload.edges.s.length });
  if (view) Object.assign(cam, view);
  else fitCircle(root!, 0.94, false);
  camReady = true;
  if (sel) selectKey(sel, true);
  else requestDraw();
}

interface Tree {
  name: string;
  path: string;
  file: number;
  children: Tree[];
}

function visibleFile(i: number): boolean {
  const n = payload!.nodes;
  if (n.kind[i] !== Kind.File) return false;
  if (!(n.path?.[i])) return false;
  if (n.noise[i] && !showNoise) return false;
  if (hideTests && n.test[i]) return false;
  return true;
}

function build() {
  const p = payload!;
  const n = p.nodes;
  byKey.clear();
  selected = hovered = null;
  previewing = false;
  focus = null;
  highlight = null;
  zoomDir = null;

  // Folder tree from file paths.
  const top: Tree = { name: "", path: "", file: -1, children: [] };
  const dirs = new Map<string, Tree>([["", top]]);
  let fileCount = 0;
  for (let i = 0; i < n.id.length; i++) {
    if (!visibleFile(i)) continue;
    fileCount++;
    const parts = n.path![i].split("/");
    let parent = top, acc = "";
    for (let j = 0; j < parts.length - 1; j++) {
      acc = acc ? `${acc}/${parts[j]}` : parts[j];
      let d = dirs.get(acc);
      if (!d) {
        d = { name: parts[j], path: acc, file: -1, children: [] };
        dirs.set(acc, d);
        parent.children.push(d);
      }
      parent = d;
    }
    parent.children.push({ name: parts[parts.length - 1], path: n.path![i], file: i, children: [] });
  }
  // "a" › "b" › "c" with nothing else becomes one "a/b/c" folder.
  const collapse = (d: Tree) => {
    for (let k = 0; k < d.children.length; k++) {
      let c = d.children[k];
      while (c.file < 0 && c.children.length === 1 && c.children[0].file < 0) {
        const only = c.children[0];
        c = { name: `${c.name}/${only.name}`, path: only.path, file: -1, children: only.children };
      }
      d.children[k] = c;
      collapse(c);
    }
  };
  collapse(top);
  // A folder that holds only folders adds an empty ring and nothing else:
  // its sub-folders take its place ("apps" › "mobile" → "apps/mobile").
  const flatten = (d: Tree) => {
    d.children.forEach(flatten);
    const next: Tree[] = [];
    for (const c of d.children) {
      if (c.file < 0 && c.children.length > 0 && c.children.every((g) => g.file < 0)) {
        for (const g of c.children) next.push({ ...g, name: `${c.name}/${g.name}` });
      } else next.push(c);
    }
    d.children = next;
  };
  flatten(top);
  let start = top;
  while (start.children.length === 1 && start.children[0].file < 0) start = start.children[0];

  // Area ∝ lines; the canvas grows with the project so file circles keep a
  // similar size and padding stays proportionate.
  const size = 220 + 70 * Math.sqrt(Math.max(1, fileCount));
  const h = hierarchy<Tree>(start, (d) => (d.children.length ? d.children : null))
    .sum((d) => (d.file >= 0 ? Math.max(14, n.lines?.[d.file] ?? 40) : 0))
    .sort((a, b) => (b.value! - a.value!) || a.data.name.localeCompare(b.data.name));
  const laid = pack<Tree>()
    .size([size, size])
    // Big folders get a wider margin: a large sub-folder would otherwise
    // hug its parent's edge and their rings blur into one thick line.
    .padding((d) => (d.depth === 0 ? 10 : d.height > 1 ? 4 + Math.sqrt(d.value ?? 0) * 0.09 : 3.5))(h);

  const convert = (node: HierarchyCircularNode<Tree>, parent: Circle | null): Circle => {
    const d = node.data;
    const isFile = d.file >= 0;
    const c: Circle = {
      key: isFile ? n.id[d.file] : `dir:${d.path}`,
      kind: isFile ? "file" : parent ? "dir" : "root",
      name: d.name,
      path: d.path,
      x: node.x,
      y: node.y,
      r: node.r,
      parent,
      children: [],
      depth: node.depth,
      idx: isFile ? d.file : -1,
      group: isFile ? n.folder[d.file] : -1,
    };
    byKey.set(c.key, c);
    if (node.children) c.children = node.children.map((ch) => convert(ch, c));
    if (!isFile) {
      const groups = new Set(c.children.map((ch) => ch.group));
      c.group = groups.size === 1 ? [...groups][0] : -1;
    }
    return c;
  };
  root = convert(laid, null);
  root.name = t("project");
  const seen = new Map<string, number>();
  forEachCircle(root, (c) => c.kind === "file" && seen.set(c.name, (seen.get(c.name) ?? 0) + 1));
  ambiguous = new Set([...seen].filter(([, n]) => n > 1).map(([name]) => name));
  buildSymbols();
  assignColors();
}

/** Symbols packed inside their file (functions, methods, types; + constants at "Tümü"). */
function buildSymbols() {
  if (!payload || !root) return;
  const n = payload.nodes;
  forEachCircle(root, (c) => {
    if (c.kind === "file") {
      for (const s of c.children) byKey.delete(s.key);
      c.children = [];
    }
  });
  if (detail === 0) return;
  const byOwner = new Map<number, number[]>();
  for (let i = 0; i < n.id.length; i++) {
    const k = n.kind[i];
    const wanted = k === Kind.Function || k === Kind.Method || k === Kind.Type || k === Kind.Route || k === Kind.Table || (detail === 2 && k === Kind.Symbol);
    const owner = n.owner?.[i] ?? -1;
    if (!wanted || owner < 0) continue;
    let list = byOwner.get(owner);
    if (!list) byOwner.set(owner, (list = []));
    list.push(i);
  }
  for (const [owner, list] of byOwner) {
    const file = byKey.get(n.id[owner]);
    if (!file || file.kind !== "file") continue;
    // Bigger (more connected) symbols first: packSiblings puts early ones central.
    list.sort((a, b) => n.degree[b] - n.degree[a] || n.label[a].localeCompare(n.label[b]));
    const circles = list.map((i) => ({ x: 0, y: 0, r: 1 + Math.sqrt(n.degree[i]) * 0.55, i }));
    packSiblings(circles);
    const enc = packEnclose(circles);
    // Few symbols must not swell into a disc that looks like the file itself.
    // (Only for a handful: with many symbols one busy function would
    // otherwise shrink the whole set into a speck in an empty ring.)
    const fit = (file.r * 0.8) / Math.max(enc.r, 1e-6);
    const s = circles.length <= 4 ? Math.min(fit, (file.r * 0.22) / Math.max(...circles.map((c) => c.r))) : fit;
    for (const cc of circles) {
      const sym: Circle = {
        key: n.id[cc.i],
        kind: "sym",
        name: n.label[cc.i],
        path: n.path?.[cc.i] ?? "",
        x: file.x + (cc.x - enc.x) * s,
        y: file.y + (cc.y - enc.y) * s,
        r: Math.max(cc.r * s, file.r * 0.02),
        parent: file,
        children: [],
        depth: file.depth + 1,
        idx: cc.i,
        group: file.group,
      };
      file.children.push(sym);
      byKey.set(sym.key, sym);
    }
  }
}

function forEachCircle(c: Circle, f: (c: Circle) => void) {
  f(c);
  for (const ch of c.children) forEachCircle(ch, f);
}

// ---------------------------------------------------------------------------
// Colour

let groupColors = new Map<number, string>();
/** Per-file colour for recency / coupling modes. */
let fileColors = new Map<number, string>();
const fillCache = new Map<string, string>();

function assignColors() {
  if (!payload || !root) return;
  const n = payload.nodes;
  fillCache.clear();
  // Areas: share of visible files ≥ 3% (or heavy in dependencies), max 9.
  const counts = new Map<number, number>();
  let total = 0;
  forEachCircle(root, (c) => {
    if (c.kind !== "file") return;
    counts.set(c.group, (counts.get(c.group) ?? 0) + 1);
    total++;
  });
  const weight = fileWeights();
  const groupWeight = new Map<number, number>();
  let totalWeight = 0;
  for (const [i, w] of weight) {
    groupWeight.set(n.folder[i], (groupWeight.get(n.folder[i]) ?? 0) + w);
    totalWeight += w;
  }
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const significant = ranked
    .filter(([g, c]) => payload!.folders[g] && (c / Math.max(1, total) >= 0.03 || (groupWeight.get(g) ?? 0) / Math.max(1, totalWeight) >= 0.05))
    .slice(0, 9);
  groupColors = new Map(significant.map(([g], i) => [g, spreadColor(i, significant.length, theme.dark)]));

  fileColors = new Map();
  let groups: GroupInfo[];
  if (colorMode === "recency") {
    const buckets = [
      { id: -10, name: t("day"), color: theme.dark ? "#F2685A" : "#D9483B", max: 1, count: 0 },
      { id: -11, name: t("week"), color: theme.dark ? "#F0AE47" : "#C9821E", max: 7, count: 0 },
      { id: -12, name: t("month"), color: theme.dark ? "#4FB8A8" : "#2B8A7C", max: 30, count: 0 },
      { id: -13, name: t("older"), color: theme.dark ? "#5C6577" : "#A3AAB7", max: Infinity, count: 0 },
    ];
    forEachCircle(root, (c) => {
      if (c.kind !== "file") return;
      const age = n.age?.[c.idx] ?? -1;
      const b = age < 0 ? buckets[3] : buckets.find((bb) => age <= bb.max)!;
      b.count++;
      fileColors.set(c.idx, b.color);
    });
    groups = buckets.filter((b) => b.count > 0).map(({ id, name, color, count }) => ({ id, name, color, count }));
  } else if (colorMode === "coupling") {
    const strong = theme.dark ? "#C08BFF" : "#8E44E0";
    const neutral = neutralColor(theme.dark);
    const files: Circle[] = [];
    forEachCircle(root, (c) => c.kind === "file" && files.push(c));
    const values = files.map((f) => weight.get(f.idx) ?? 0).filter((v) => v > 0).sort((a, b) => a - b);
    const q = (t: number) => values[Math.min(values.length - 1, Math.floor(t * values.length))] ?? 0;
    const cuts = [q(0.5), q(0.8), q(0.95)];
    const buckets = [
      { id: -20, name: t("veryDense"), color: strong, count: 0 },
      { id: -21, name: t("dense"), color: mix(strong, neutral, 0.35), count: 0 },
      { id: -22, name: t("medium"), color: mix(strong, neutral, 0.65), count: 0 },
      { id: -23, name: t("sparse"), color: neutral, count: 0 },
    ];
    for (const f of files) {
      const v = weight.get(f.idx) ?? 0;
      const b = v === 0 ? buckets[3] : v >= cuts[2] ? buckets[0] : v >= cuts[1] ? buckets[1] : v >= cuts[0] ? buckets[2] : buckets[3];
      b.count++;
      fileColors.set(f.idx, b.color);
    }
    groups = buckets.filter((b) => b.count > 0).map(({ id, name, color, count }) => ({ id, name, color, count }));
  } else {
    groups = significant.map(([g, c]) => ({ id: g, name: payload!.folders[g], color: groupColors.get(g)!, count: c }));
    const rest = ranked.filter(([g]) => !groupColors.has(g)).reduce((s, [, c]) => s + c, 0);
    if (rest > 0) groups.push({ id: -1, name: "", color: neutralColor(theme.dark), count: rest });
  }
  post({ type: "groups", mode: colorMode === "community" ? "folder" : colorMode, groups });
}

/** File ↔ file connection weight (in + out), from the lifted file links. */
function fileWeights(): Map<number, number> {
  const w = new Map<number, number>();
  const fl = payload!.fileLinks;
  for (let i = 0; i < fl.s.length; i++) {
    w.set(fl.s[i], (w.get(fl.s[i]) ?? 0) + fl.w[i]);
    w.set(fl.t[i], (w.get(fl.t[i]) ?? 0) + fl.w[i]);
  }
  return w;
}

/** The colour a circle is "about". */
function base(c: Circle): string {
  if (colorMode === "recency" || colorMode === "coupling") {
    const f = c.kind === "file" ? c : c.kind === "sym" ? c.parent! : null;
    if (f) return fileColors.get(f.idx) ?? neutralColor(theme.dark);
    return neutralColor(theme.dark);
  }
  return groupColors.get(c.group) ?? neutralColor(theme.dark);
}

function tone(color: string, towardsCanvas: number): string {
  const key = `${color}|${towardsCanvas}|${theme.dark}`;
  let v = fillCache.get(key);
  if (!v) fillCache.set(key, (v = mix(color, theme.canvas, towardsCanvas)));
  return v;
}

function inkOn(fill: string): string {
  const v = parseInt(fill.slice(1), 16);
  const lum = 0.2126 * ((v >> 16) & 255) + 0.7152 * ((v >> 8) & 255) + 0.0722 * (v & 255);
  return lum > 150 ? "#11141B" : "#F4F6FA";
}

// ---------------------------------------------------------------------------
// Focus: dependencies summarised per area

/** The circle to draw `x` as, seen from `from`: itself when they share a
 * folder, otherwise the folder (sibling of `from`'s branch) containing it. */
function anchorFor(from: Circle, x: Circle): Circle {
  const ancestors = new Set<Circle>();
  for (let c: Circle | null = from; c; c = c.parent) ancestors.add(c);
  let cur = x;
  while (cur.parent && !ancestors.has(cur.parent)) cur = cur.parent;
  return cur;
}

/** Which links a selection shows (View › Links). */
let linkFilter: LinkFilter = "all";
const relPasses = (r: number) =>
  linkFilter === "all" ? r !== Rel.Contains
  : linkFilter === "calls" ? r === Rel.Call
  : linkFilter === "imports" ? r === Rel.Import
  : r === Rel.Bridge;

function computeFocus() {
  focus = null;
  if (!selected || !payload) return;
  const p = payload;
  const uses = new Map<Circle, Anchor>();
  const usedBy = new Map<Circle, Anchor>();
  const lit = new Set<Circle>([selected]);
  const add = (into: Map<Circle, Anchor>, other: Circle, w: number) => {
    if (other === selected) return;
    const a = anchorFor(selected!, other);
    let entry = into.get(a);
    if (!entry) into.set(a, (entry = { circle: a, weight: 0, members: new Set() }));
    entry.weight += w;
    entry.members.add(other);
    lit.add(other);
  };
  if (selected.kind === "file" && linkFilter !== "all") {
    // Filtered: lift only the matching symbol edges to files here.
    const n = p.nodes, e = p.edges;
    const fileOf = (i: number) => (n.kind[i] === Kind.File ? i : n.owner?.[i] ?? -1);
    for (let i = 0; i < e.s.length; i++) {
      if (!relPasses(e.r[i])) continue;
      const sf = fileOf(e.s[i]), tf = fileOf(e.t[i]);
      if (sf < 0 || tf < 0 || sf === tf) continue;
      if (sf === selected.idx) {
        const t = byKey.get(n.id[tf]);
        if (t) add(uses, t, 1);
      } else if (tf === selected.idx) {
        const s = byKey.get(n.id[sf]);
        if (s) add(usedBy, s, 1);
      }
    }
  } else if (selected.kind === "file") {
    const fl = p.fileLinks;
    for (let i = 0; i < fl.s.length; i++) {
      if (fl.s[i] === selected.idx) {
        const t = byKey.get(p.nodes.id[fl.t[i]]);
        if (t) add(uses, t, fl.w[i]);
      } else if (fl.t[i] === selected.idx) {
        const s = byKey.get(p.nodes.id[fl.s[i]]);
        if (s) add(usedBy, s, fl.w[i]);
      }
    }
  } else {
    const e = p.edges;
    // A symbol not drawn at this detail level is represented by its file.
    const resolve = (i: number): Circle | undefined => {
      const direct = byKey.get(p.nodes.id[i]);
      if (direct) return direct;
      const owner = p.nodes.owner?.[i] ?? -1;
      return owner >= 0 ? byKey.get(p.nodes.id[owner]) : undefined;
    };
    for (let i = 0; i < e.s.length; i++) {
      if (e.r[i] === Rel.Contains) continue;
      // Imports are file-level: a symbol shows them only when asked for.
      if (linkFilter === "all" ? e.r[i] === Rel.Import : !relPasses(e.r[i])) continue;
      if (e.s[i] === selected.idx) {
        const t = resolve(e.t[i]);
        if (t) add(uses, t, 1);
      } else if (e.t[i] === selected.idx) {
        const s = resolve(e.s[i]);
        if (s) add(usedBy, s, 1);
      }
    }
  }
  // A symbol's file stands for it whenever symbols are not drawn.
  for (const c of [...lit]) if (c.kind === "sym") lit.add(c.parent!);
  focus = { uses: [...uses.values()], usedBy: [...usedBy.values()], lit };
}

// ---------------------------------------------------------------------------
// Camera

const toScreenX = (x: number) => (x - cam.x) * cam.k + W / 2;
const toScreenY = (y: number) => (y - cam.y) * cam.k + H / 2;
const toWorldX = (sx: number) => (sx - W / 2) / cam.k + cam.x;
const toWorldY = (sy: number) => (sy - H / 2) / cam.k + cam.y;

function kLimits() {
  const r = root?.r ?? 500;
  return { min: (Math.min(W, H) * 0.3) / (2 * r), max: 400 };
}

let anim: number | null = null;

function animateTo(target: { x: number; y: number; k: number }, ms = duration()) {
  if (anim) cancelAnimationFrame(anim);
  const lim = kLimits();
  target.k = Math.max(lim.min, Math.min(lim.max, target.k));
  if (ms <= 0) {
    Object.assign(cam, target);
    requestDraw();
    return;
  }
  const from = { ...cam };
  const t0 = performance.now();
  const step = (t: number) => {
    const u = Math.min(1, (t - t0) / ms);
    const e = u < 0.5 ? 4 * u * u * u : 1 - Math.pow(-2 * u + 2, 3) / 2;
    cam.k = Math.exp(Math.log(from.k) + (Math.log(target.k) - Math.log(from.k)) * e);
    cam.x = from.x + (target.x - from.x) * e;
    cam.y = from.y + (target.y - from.y) * e;
    draw();
    anim = u < 1 ? requestAnimationFrame(step) : null;
  };
  anim = requestAnimationFrame(step);
}

function fitCircle(c: Circle, fill = 0.9, animate = true) {
  if (!W || !H) return;
  const target = { x: c.x, y: c.y, k: (Math.min(W, H) * fill) / (2 * c.r) };
  if (animate) animateTo(target);
  else {
    Object.assign(cam, target);
    requestDraw();
  }
}

/** Frames several circles; `focusOn` never ends up larger than ~1/3 of the view. */
function fitCircles(list: Circle[], focusOn?: Circle, minK = 0) {
  if (!list.length || !W) return;
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const c of list) {
    x0 = Math.min(x0, c.x - c.r); x1 = Math.max(x1, c.x + c.r);
    y0 = Math.min(y0, c.y - c.r); y1 = Math.max(y1, c.y + c.r);
  }
  let k = Math.min(W / (x1 - x0), H / (y1 - y0)) * 0.82;
  if (focusOn) k = Math.min(k, (Math.min(W, H) * 0.33) / (2 * focusOn.r));
  if (k < minK && focusOn) {
    // Too spread to show the symbol: keep it readable and centred instead.
    animateTo({ x: focusOn.x, y: focusOn.y, k: minK });
    return;
  }
  animateTo({ x: (x0 + x1) / 2, y: (y0 + y1) / 2, k });
}

// ---------------------------------------------------------------------------
// Drawing

let drawScheduled = false;
function requestDraw() {
  if (drawScheduled) return;
  drawScheduled = true;
  requestAnimationFrame(() => {
    drawScheduled = false;
    draw();
  });
}

function resize() {
  dpr = window.devicePixelRatio || 1;
  W = canvas.clientWidth;
  H = canvas.clientHeight;
  canvas.width = Math.round(W * dpr);
  canvas.height = Math.round(H * dpr);
  if (root && !camReady) {
    fitCircle(root, 0.94, false);
    camReady = true;
  }
  requestDraw();
}
new ResizeObserver(resize).observe(canvas);

const FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif";
const widthCache = new Map<string, number>();
function textWidth(text: string, font: string): number {
  const key = `${font}|${text}`;
  let w = widthCache.get(key);
  if (w === undefined) {
    ctx.font = font;
    widthCache.set(key, (w = ctx.measureText(text).width));
  }
  return w;
}

function isLit(c: Circle): boolean {
  if (highlight) return highlight.set.has(c) || highlight.set.has(c.parent!) || c === selected;
  if (focus) return focus.lit.has(c) || (c.kind === "sym" && focus.lit.has(c.parent!)) || (c.kind === "file" && c === selected?.parent);
  return true;
}
const dimming = () => !!(highlight || focus);

function symbolsShown(file: Circle): boolean {
  return file.children.length > 0 && file.r * cam.k >= SYMBOLS_AT;
}

function draw() {
  if (!W || !H) return;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  if (!root) return;

  drawShapes(root);
  badges = [];
  drawLinks();
  updateLegend();
  drawLabels();
  for (const b of badges) badge(b.x, b.y, b.text, b.color);
  drawRings();
  drawVeil();
  updateCrumbs();
}

/** What the two colours mean, while a selection shows its links. */
let legendKey = "";
function updateLegend() {
  const count = (as: Anchor[]) => {
    const set = new Set<Circle>();
    for (const a of as) for (const m of a.members) set.add(m);
    return set.size;
  };
  const out = focus ? count(focus.uses) : 0, inn = focus ? count(focus.usedBy) : 0;
  const key = highlight && highlightLabel ? `h|${highlightLabel}` : focus && selected ? `${out}|${inn}|${theme.dark}|${linkFilter}|${lang}` : "";
  if (key === legendKey) return;
  legendKey = key;
  legend.hidden = !key;
  if (!key) return;
  if (highlight) {
    legend.replaceChildren();
    const el = document.createElement("span");
    const dot = document.createElement("i");
    dot.style.background = theme.accent;
    dot.textContent = highlight.chain ? "→" : "!";
    const b = document.createElement("b");
    b.textContent = highlightLabel;
    el.append(dot, b);
    legend.append(el);
    return;
  }
  const inColor = theme.dark ? "#7FB2FF" : "#2F6FD6";
  legend.replaceChildren();
  const row = (color: string, text: string, n: number, arrow: string) => {
    const el = document.createElement("span");
    const dot = document.createElement("i");
    dot.style.background = color;
    dot.textContent = arrow;
    el.append(dot, `${text} `);
    const b = document.createElement("b");
    b.textContent = num(n);
    el.append(b);
    return el;
  };
  if (out) legend.append(row(theme.accent, t("uses"), out, "→"));
  if (inn) legend.append(row(inColor, t("usedBy"), inn, "←"));
  if (!out && !inn) legend.append(t("noLinks"));
  if (linkFilter !== "all") {
    const f = document.createElement("em");
    f.textContent = t(linkFilter === "calls" ? "onlyCalls" : linkFilter === "imports" ? "onlyImports" : "onlyBridges");
    legend.append(f);
  }
}

/** Inside a folder, everything around it steps back so the edges of the
 *  neighbours don't compete with what the user zoomed into. */
function drawVeil() {
  if (!zoomDir || dimming()) return;
  const sr = zoomDir.r * cam.k;
  if (sr < 40) return;
  ctx.beginPath();
  ctx.rect(0, 0, W, H);
  ctx.arc(toScreenX(zoomDir.x), toScreenY(zoomDir.y), sr + 1.5, 0, Math.PI * 2, true);
  ctx.globalAlpha = theme.dark ? 0.62 : 0.55;
  ctx.fillStyle = theme.canvas;
  ctx.fill("evenodd");
  ctx.globalAlpha = 1;
}

function onScreen(c: Circle): boolean {
  const sr = c.r * cam.k, sx = toScreenX(c.x), sy = toScreenY(c.y);
  return sr >= 0.35 && sx + sr > 0 && sx - sr < W && sy + sr > 0 && sy - sr < H;
}

function disc(c: Circle, fill: string | null, stroke: string | null, width = 1) {
  ctx.beginPath();
  ctx.arc(toScreenX(c.x), toScreenY(c.y), Math.max(0.5, c.r * cam.k), 0, Math.PI * 2);
  if (fill) {
    ctx.fillStyle = fill;
    ctx.fill();
  }
  if (stroke) {
    ctx.strokeStyle = stroke;
    ctx.lineWidth = width;
    ctx.stroke();
  }
}

function drawShapes(c: Circle) {
  if (!onScreen(c)) return;
  const dim = dimming();
  const color = base(c);
  if (c.kind === "dir") {
    const t = Math.max(0.78, 0.93 - c.depth * 0.025);
    disc(c, tone(color, t), tone(color, dim ? 0.8 : 0.55));
  } else if (c.kind === "file") {
    const lit = !dim || isLit(c);
    if (symbolsShown(c)) {
      disc(c, tone(color, lit ? 0.8 : 0.9), tone(color, lit ? 0.35 : 0.75), 1.25);
    } else {
      disc(c, tone(color, lit ? (theme.dark ? 0.12 : 0.06) : 0.82), null);
    }
  } else if (c.kind === "sym") {
    const lit = !dim || isLit(c);
    disc(c, tone(color, lit ? 0 : 0.8), null);
  }
  if (c.kind === "file" && !symbolsShown(c)) return;
  for (const ch of c.children) drawShapes(ch);
}

/** The circle actually drawn for `c` (a symbol inside a closed file is its file). */
function visual(c: Circle): Circle {
  return c.kind === "sym" && !symbolsShown(c.parent!) ? c.parent! : c;
}

/** Where a curve meets a circle: its centre if small, else its edge facing `from`. */
function port(c0: Circle, fromX: number, fromY: number) {
  const c = visual(c0);
  const sx = toScreenX(c.x), sy = toScreenY(c.y), sr = c.r * cam.k;
  if (sr < 14) return { x: sx, y: sy };
  const d = Math.hypot(fromX - sx, fromY - sy) || 1;
  return { x: sx + ((fromX - sx) / d) * sr, y: sy + ((fromY - sy) / d) * sr };
}

function drawLinks() {
  const outColor = theme.accent;
  const inColor = theme.dark ? "#7FB2FF" : "#2F6FD6";
  if (focus && selected) {
    const self = visual(selected);
    const sx = toScreenX(self.x), sy = toScreenY(self.y);
    const all = [...focus.uses.map((a) => ({ a, out: true })), ...focus.usedBy.map((a) => ({ a, out: false }))];
    // Members inside anchors get a thin ring so the exact files are visible.
    for (const { a, out } of all) {
      for (const m0 of a.members) {
        const m = visual(m0);
        if (m !== a.circle && m !== self && onScreen(m) && m.r * cam.k > 2.5) disc(m, null, out ? outColor : inColor, 1.25);
      }
    }
    // An area big on screen with few members: point at each one; otherwise
    // one bundle per area with a count.
    const links: { target: Circle; weight: number; out: boolean; count: number }[] = [];
    for (const { a, out } of all) {
      const open = (a.circle.kind === "dir" || a.circle.kind === "root") && a.circle.r * cam.k > 70 && a.members.size <= 12;
      if (open) {
        const per = new Map<Circle, number>();
        for (const m of a.members) per.set(visual(m), (per.get(visual(m)) ?? 0) + 1);
        for (const [t, w] of per) links.push({ target: t, weight: (a.weight * w) / a.members.size, out, count: 0 });
      } else {
        links.push({ target: a.circle, weight: a.weight, out, count: a.circle.kind === "dir" ? a.members.size : 0 });
      }
    }
    // Many partners in the selection's own folder: their rings say it all,
    // a fan of short curves would only hide them.
    // Counted per direction, so a few files it uses still get their arrows
    // when dozens of neighbours use it.
    const crowded = (out: boolean) => links.filter((l) => l.out === out && visual(l.target).parent === self.parent).length > 8;
    const hideOut = crowded(true), hideIn = crowded(false);
    // A neighbour right next to the selection is already marked by its ring;
    // a stubby arrow on top of it only tangles.
    const near = (l: { target: Circle }) => {
      const t = visual(l.target);
      return Math.hypot(toScreenX(t.x) - sx, toScreenY(t.y) - sy) - (t.r + self.r) * cam.k < 70;
    };
    const shown = links.filter((l) => !(visual(l.target).parent === self.parent && ((l.out ? hideOut : hideIn) || near(l))));
    const maxW = Math.max(1, ...shown.map((l) => l.weight));
    for (const l of shown) {
      if (visual(l.target) === self) continue;
      let end = port(l.target, sx, sy);
      // A big area with many members: aim into it, at where its members are,
      // instead of a stub on the edge that may sit right next to the selection.
      const t = l.target;
      if (l.count > 1 && (t.kind === "dir" || t.kind === "root") && t.r * cam.k > 70) {
        const a = [...focus.uses, ...focus.usedBy].find((x) => x.circle === t);
        let mx = 0, my = 0, k = 0;
        for (const m of a?.members ?? []) {
          const v = visual(m);
          mx += toScreenX(v.x);
          my += toScreenY(v.y);
          k++;
        }
        if (k) {
          mx /= k;
          my /= k;
          // Off screen: stop at the edge of the view, on the way there.
          const m = 28;
          const fx = mx < m ? (m - sx) / (mx - sx) : mx > W - m ? (W - m - sx) / (mx - sx) : 1;
          const fy = my < m ? (m - sy) / (my - sy) : my > H - m ? (H - m - sy) / (my - sy) : 1;
          const f = Math.max(0, Math.min(1, fx, fy));
          mx = sx + (mx - sx) * f;
          my = sy + (my - sy) * f;
          if (Math.hypot(mx - sx, my - sy) > self.r * cam.k + 60) end = { x: mx, y: my };
        }
      }
      const start = port(self, end.x, end.y);
      const width = 1.2 + 3.2 * Math.sqrt(l.weight / maxW);
      // Both directions to the same place bend apart.
      const bend = l.out ? 0.16 : -0.16;
      const from = l.out ? start : end, to = l.out ? end : start;
      curve(from, to, l.out ? outColor : inColor, width, bend);
      if (l.count > 1) {
        // On the curve, short of the arrowhead.
        const p = pointOn(from, to, bend, l.out ? 0.8 : 0.2);
        // Never on top of the selection itself.
        const minD = self.r * cam.k + 18;
        const d = Math.hypot(p.x - sx, p.y - sy);
        if (d < minD) {
          const ux = d ? (p.x - sx) / d : 0, uy = d ? (p.y - sy) / d : -1;
          p.x = sx + ux * minD;
          p.y = sy + uy * minD;
        }
        badges.push({ x: p.x, y: p.y, text: num(l.count), color: l.out ? outColor : inColor });
      }
    }
  }
  if (highlight?.chain && highlight.chain.length > 1) {
    for (let i = 0; i + 1 < highlight.chain.length; i++) {
      const a = highlight.chain[i], b = highlight.chain[i + 1];
      const pb = port(b, toScreenX(a.x), toScreenY(a.y));
      const pa = port(a, pb.x, pb.y);
      curve(pa, pb, outColor, 2.2, 0.12);
    }
  }
}

function pointOn(a: { x: number; y: number }, b: { x: number; y: number }, bend: number, t: number) {
  const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
  const cx = mx - (b.y - a.y) * bend, cy = my + (b.x - a.x) * bend;
  const u = 1 - t;
  return { x: u * u * a.x + 2 * u * t * cx + t * t * b.x, y: u * u * a.y + 2 * u * t * cy + t * t * b.y };
}

function curve(a: { x: number; y: number }, b: { x: number; y: number }, color: string, width: number, bend: number) {
  const mx = (a.x + b.x) / 2, my = (a.y + b.y) / 2;
  const dx = b.x - a.x, dy = b.y - a.y;
  const cx = mx - dy * bend, cy = my + dx * bend;
  ctx.save();
  ctx.lineCap = "round";
  ctx.strokeStyle = theme.canvas;
  ctx.globalAlpha = 0.7;
  ctx.lineWidth = width + 3;
  ctx.beginPath();
  ctx.moveTo(a.x, a.y);
  ctx.quadraticCurveTo(cx, cy, b.x, b.y);
  ctx.stroke();
  ctx.globalAlpha = 0.92;
  ctx.strokeStyle = color;
  ctx.lineWidth = width;
  ctx.stroke();
  // Arrowhead at b, along the curve's end tangent.
  const ang = Math.atan2(b.y - cy, b.x - cx);
  const L = 6 + width * 1.6;
  ctx.globalAlpha = 1;
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.moveTo(b.x, b.y);
  ctx.lineTo(b.x - L * Math.cos(ang - 0.42), b.y - L * Math.sin(ang - 0.42));
  ctx.lineTo(b.x - L * Math.cos(ang + 0.42), b.y - L * Math.sin(ang + 0.42));
  ctx.closePath();
  ctx.fill();
  ctx.restore();
}

/** Counts on bundled links, drawn after the labels so no name hides them. */
let badges: { x: number; y: number; text: string; color: string }[] = [];

function badge(x: number, y: number, text: string, color: string) {
  const font = `700 11px ${FONT}`;
  const w = textWidth(text, font) + 10, h = 17;
  ctx.save();
  ctx.fillStyle = color;
  ctx.beginPath();
  ctx.roundRect(x - w / 2, y - h / 2, w, h, h / 2);
  ctx.fill();
  ctx.fillStyle = inkOn(color);
  ctx.font = font;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillText(text, x, y + 0.5);
  ctx.restore();
}

// --- labels

interface Box { x0: number; y0: number; x1: number; y1: number }
let placed: Box[] = [];
const collides = (b: Box) => placed.some((p) => b.x0 < p.x1 && b.x1 > p.x0 && b.y0 < p.y1 && b.y1 > p.y0);

function drawLabels() {
  placed = [];
  // Overlays on the canvas claim their space first.
  const origin = canvas.getBoundingClientRect();
  for (const el of [legend, crumbs]) {
    if (el.hidden) continue;
    const r = el.getBoundingClientRect();
    placed.push({ x0: r.left - origin.left - 4, y0: r.top - origin.top - 4, x1: r.right - origin.left + 4, y1: r.bottom - origin.top + 4 });
  }
  const arcs: Circle[] = [];
  const inner: Circle[] = [];
  const syms: Circle[] = [];
  const walk = (c: Circle) => {
    if (!onScreen(c)) return;
    if (c.kind === "dir") arcs.push(c);
    else if (c.kind === "file") {
      if (symbolsShown(c)) arcs.push(c);
      else inner.push(c);
    } else if (c.kind === "sym") syms.push(c);
    if (c.kind !== "file" || symbolsShown(c)) for (const ch of c.children) walk(ch);
  };
  if (root) walk(root);
  // Big things first: they claim space.
  // An opened file whose name doesn't fit along its rim is named under it.
  const unnamed: Circle[] = [];
  for (const c of arcs.sort((a, b) => b.r - a.r)) if (!arcLabel(c) && c.kind === "file") unnamed.push(c);
  for (const c of unnamed) innerLabel(c, true);
  // The selection names itself first; then big before small.
  const sel = selected ? visual(selected) : null;
  if (sel && sel.kind === "file" && !symbolsShown(sel)) innerLabel(sel);
  for (const c of inner.sort((a, b) => b.r - a.r)) if (c !== sel) innerLabel(c);
  // Most connected first, and only as many as the file has room for: zooming
  // in reveals the rest, like towns on a map.
  symbolBudget.clear();
  symbolLabeled.clear();
  const n = payload?.nodes;
  const rank = (c: Circle) => (c === selected ? 1e9 : n ? n.degree[c.idx] : c.r);
  syms.sort((a, b) => rank(b) - rank(a) || b.r - a.r);
  // Names inside their bubble first; names beside a bubble cover neighbours.
  for (const c of syms) symbolLabel(c, true);
  for (const c of syms) symbolLabel(c, false);
}

function displayName(c: Circle): string {
  return c.kind === "dir" ? c.name.toLocaleUpperCase("en") : c.name;
}

/** Folder (or opened file) name along the top of its circle. */
function arcLabel(c: Circle): boolean {
  const sr = c.r * cam.k;
  if (sr < 42) return false;
  const isDir = c.kind === "dir";
  const fs = Math.round(Math.max(10, Math.min(isDir ? 14 : 13, sr * 0.06)));
  const font = `${isDir ? 700 : 600} ${fs}px ${FONT}`;
  const spacing = isDir ? fs * 0.08 : 0;
  const R = sr - fs * 0.55;
  // "tests/mapocoretests" on a small circle reads as just "…/mapocoretests".
  const full = displayName(c);
  const short = full.includes("/") ? `…/${full.slice(full.lastIndexOf("/") + 1)}` : full;
  let text = full, widths: number[] = [], total = 0, span = Infinity;
  for (const candidate of full === short ? [full] : [full, short]) {
    text = candidate;
    widths = [...text].map((ch) => textWidth(ch, font) + spacing);
    total = widths.reduce((a, b) => a + b, 0);
    span = total / R;
    if (span <= Math.PI * 0.6) break;
  }
  if (span > Math.PI * 0.6) return false;
  const cx = toScreenX(c.x), cy = toScreenY(c.y);
  // Along the top; a file whose folder already claims the top (a folder
  // holding just this file) takes the bottom instead, reading left to right.
  const top = { x0: cx - total / 2 - 4, y0: cy - sr - 2, x1: cx + total / 2 + 4, y1: cy - sr + fs * 1.6 };
  const bottom = { x0: top.x0, y0: cy + sr - fs * 1.6, x1: top.x1, y1: cy + sr + 2 };
  const visible = (b: Box) => b.x0 >= 2 && b.x1 <= W - 2 && b.y0 >= 2 && b.y1 <= H - 2;
  const under = collides(top) || !visible(top);
  if (under && (isDir || collides(bottom) || !visible(bottom))) return false;
  const box = under ? bottom : top;
  placed.push(box);
  const dim = dimming() && !(focus?.lit.has(c) || highlight?.set.has(c) || containsLit(c));
  ctx.save();
  ctx.font = font;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.lineJoin = "round";
  let a = under ? Math.PI / 2 + span / 2 : -Math.PI / 2 - span / 2;
  const dir = under ? -1 : 1;
  const color = isDir ? tone(base(c), theme.dark ? 0.05 : 0.15) : tone(base(c), 0);
  for (let i = 0; i < widths.length; i++) {
    const w = widths[i];
    a += (dir * w) / 2 / R;
    ctx.save();
    ctx.translate(cx + R * Math.cos(a), cy + R * Math.sin(a));
    ctx.rotate(a + (dir * Math.PI) / 2);
    ctx.globalAlpha = dim ? 0.45 : 1;
    ctx.strokeStyle = theme.canvas;
    ctx.lineWidth = 3;
    ctx.strokeText([...text][i], 0, 0);
    ctx.fillStyle = color;
    ctx.fillText([...text][i], 0, 0);
    ctx.restore();
    a += (dir * w) / 2 / R;
  }
  ctx.restore();
  return true;
}

function containsLit(c: Circle): boolean {
  const set = focus?.lit ?? highlight?.set;
  if (!set) return false;
  for (const x of set) for (let p: Circle | null = x; p; p = p.parent) if (p === c) return true;
  return false;
}

/** File name inside its circle when it fits, otherwise under it like a
 * town on a map — as long as it collides with nothing already placed. */
function innerLabel(c: Circle, belowOnly = false) {
  const sr = c.r * cam.k;
  if (sr < 4) return;
  const label = fileLabel(c);
  // While something is selected only the files that matter are named.
  if (dimming() && !isLit(c)) return;
  const dim = false;
  const x = toScreenX(c.x), y = toScreenY(c.y);
  if (sr >= 11 && !belowOnly) {
    let fs = Math.round(Math.max(9, Math.min(13, sr * 0.3)));
    let font = `600 ${fs}px ${FONT}`;
    let w = textWidth(label, font);
    while (w > sr * 1.84 && fs > 9) {
      fs--;
      font = `600 ${fs}px ${FONT}`;
      w = textWidth(label, font);
    }
    if (w <= sr * 1.84) {
      const box = { x0: x - w / 2, y0: y - fs / 2, x1: x + w / 2, y1: y + fs / 2 };
      if (collides(box)) return;
      placed.push(box);
      const fill = dim ? tone(base(c), 0.82) : tone(base(c), theme.dark ? 0.12 : 0.06);
      ctx.save();
      ctx.font = font;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = dim ? theme.labelMuted : inkOn(fill);
      ctx.fillText(label, x, y + 0.5);
      ctx.restore();
      return;
    }
    const two = splitName(label);
    if (two) {
      for (const fs2 of [12, 11, 10, 9]) {
        const font2 = `600 ${fs2}px ${FONT}`;
        const w2 = Math.max(textWidth(two[0], font2), textWidth(two[1], font2));
        const lh = fs2 * 1.15;
        if (Math.hypot(w2 / 2, lh) > sr * 0.92) continue;
        const box = { x0: x - w2 / 2, y0: y - lh, x1: x + w2 / 2, y1: y + lh };
        if (collides(box)) break;
        placed.push(box);
        const fill = tone(base(c), theme.dark ? 0.12 : 0.06);
        ctx.save();
        ctx.font = font2;
        ctx.textAlign = "center";
        ctx.textBaseline = "middle";
        ctx.fillStyle = inkOn(fill);
        ctx.fillText(two[0], x, y - lh / 2 + 0.5);
        ctx.fillText(two[1], x, y + lh / 2 + 0.5);
        ctx.restore();
        return;
      }
    }
  }
  // Below the circle: when zoomed in enough that names are the point, or
  // always for the files a selection is about.
  if (!dimming() && sr < 16 && cam.k * (root?.r ?? 1) < Math.min(W, H) * 0.9) return;
  const font = `500 11px ${FONT}`;
  const w = textWidth(label, font);
  const ty = y + sr + 8;
  const box = { x0: x - w / 2 - 2, y0: ty - 7, x1: x + w / 2 + 2, y1: ty + 7 };
  if (collides(box)) return;
  placed.push(box);
  ctx.save();
  ctx.font = font;
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.lineJoin = "round";
  ctx.strokeStyle = tone(base(c), 0.88);
  ctx.lineWidth = 3;
  ctx.strokeText(label, x, ty);
  ctx.fillStyle = dim ? theme.labelMuted : theme.label;
  ctx.fillText(label, x, ty);
  ctx.restore();
}

/** Symbol names beside their dot, only when there is room. */
const symbolBudget = new Map<Circle, number>();
const PX_PER_SYMBOL_LABEL = 15000;

const symbolLabeled = new Set<Circle>();

/** Split at the camelCase / snake_case boundary nearest the middle. */
function splitName(name: string): [string, string] | null {
  if (name.length < 9) return null;
  let best = -1;
  for (let i = 2; i < name.length - 2; i++) {
    const boundary = (/[a-zçğıöşü0-9]/.test(name[i - 1]) && /[A-ZÇĞİÖŞÜ]/.test(name[i])) || name[i - 1] === "_";
    if (boundary && (best < 0 || Math.abs(i - name.length / 2) < Math.abs(best - name.length / 2))) best = i;
  }
  return best < 0 ? null : [name.slice(0, best), name.slice(best)];
}

function symbolLabel(c: Circle, insideOnly: boolean) {
  if (symbolLabeled.has(c)) return;
  const sr = c.r * cam.k;
  const f = c.parent!, fr0 = f.r * cam.k;
  if (sr < 3.2 || fr0 < 120) return;
  if (dimming() && !isLit(c)) return;
  const must = c === selected || c === hovered || (dimming() && isLit(c));
  const used = symbolBudget.get(f) ?? 0;
  if (!must && used >= Math.max(6, Math.floor((Math.PI * fr0 * fr0) / PX_PER_SYMBOL_LABEL))) return;
  const cx0 = toScreenX(c.x), cy0 = toScreenY(c.y);
  // Inside its own bubble when the name fits: no halo over the neighbours.
  for (const fs of [12, 11, 10, 9]) {
    const font = `600 ${fs}px ${FONT}`;
    const w = textWidth(c.name, font);
    if (w > sr * 1.8 || fs > sr * 0.9) continue;
    const box = { x0: cx0 - w / 2, y0: cy0 - fs / 2, x1: cx0 + w / 2, y1: cy0 + fs / 2 };
    if (collides(box)) return;
    placed.push(box);
    symbolLabeled.add(c);
    symbolBudget.set(f, used + 1);
    ctx.save();
    ctx.font = font;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillStyle = inkOn(tone(base(c), 0));
    ctx.fillText(c.name, cx0, cy0 + 0.5);
    ctx.restore();
    return;
  }
  // A long camelCase name on two lines ("KulupUyeler / Yanit").
  const lines = splitName(c.name);
  if (lines) {
    for (const fs of [11, 10, 9]) {
      const font = `600 ${fs}px ${FONT}`;
      const w = Math.max(textWidth(lines[0], font), textWidth(lines[1], font));
      const lh = fs * 1.15;
      if (Math.hypot(w / 2, lh) > sr * 0.94) continue;
      const box = { x0: cx0 - w / 2, y0: cy0 - lh, x1: cx0 + w / 2, y1: cy0 + lh };
      if (collides(box)) break;
      placed.push(box);
      symbolLabeled.add(c);
      symbolBudget.set(f, used + 1);
      ctx.save();
      ctx.font = font;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillStyle = inkOn(tone(base(c), 0));
      ctx.fillText(lines[0], cx0, cy0 - lh / 2 + 0.5);
      ctx.fillText(lines[1], cx0, cy0 + lh / 2 + 0.5);
      ctx.restore();
      return;
    }
  }
  if (insideOnly) return;
  const font = `500 11px ${FONT}`;
  const w = textWidth(c.name, font);
  const cx = toScreenX(c.x), y = toScreenY(c.y);
  // Right of the dot, else left of it; never spilling out of its file.
  const fx = toScreenX(f.x), fy = toScreenY(f.y), fr = fr0 - 3;
  const inside = (x0: number, x1: number) =>
    [x0, x1].every((px) => [y - 7, y + 7].every((py) => Math.hypot(px - fx, py - fy) <= fr));
  let x = cx + sr + 4;
  if (!inside(x - 2, x + w + 2)) x = cx - sr - 4 - w;
  const box = { x0: x - 2, y0: y - 7, x1: x + w + 2, y1: y + 7 };
  if (!inside(box.x0, box.x1) || collides(box)) return;
  placed.push(box);
  symbolLabeled.add(c);
  symbolBudget.set(f, used + 1);
  ctx.save();
  ctx.font = font;
  ctx.textBaseline = "middle";
  ctx.lineJoin = "round";
  ctx.strokeStyle = theme.canvas;
  ctx.lineWidth = 3;
  ctx.strokeText(c.name, x, y);
  ctx.fillStyle = theme.label;
  ctx.fillText(c.name, x, y);
  ctx.restore();
}

function drawRings() {
  if (hovered && (hovered !== selected || previewing) && onScreen(hovered)) disc(hovered, null, theme.label, 1.5);
  const sel = chosen() ? visual(selected!) : null;
  if (sel && onScreen(sel)) {
    const x = toScreenX(sel.x), y = toScreenY(sel.y), r = Math.max(3, sel.r * cam.k);
    ctx.beginPath();
    ctx.arc(x, y, r + 2.5, 0, Math.PI * 2);
    ctx.strokeStyle = theme.canvas;
    ctx.lineWidth = 3;
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(x, y, r + 4, 0, Math.PI * 2);
    ctx.strokeStyle = theme.accent;
    ctx.lineWidth = 2.5;
    ctx.stroke();
  }
}

// --- breadcrumb

let crumbKey = "";
function updateCrumbs() {
  const picked = chosen();
  const at = picked?.kind === "sym" ? picked.parent : picked ?? zoomDir;
  const chain: Circle[] = [];
  for (let c = at?.kind === "file" ? at.parent : at; c; c = c.parent) chain.unshift(c);
  const key = chain.map((c) => c.key).join(">") + (picked ? `|${picked.key}` : "");
  if (key === crumbKey) return;
  crumbKey = key;
  crumbs.replaceChildren();
  if (chain.length <= 1 && !selected) {
    crumbs.hidden = true;
    return;
  }
  crumbs.hidden = false;
  chain.forEach((c, i) => {
    if (i) crumbs.append(sep());
    const b = document.createElement("button");
    b.textContent = c.kind === "root" ? t("project") : c.name;
    b.lang = "en";
    b.onclick = () => zoomInto(c);
    crumbs.append(b);
  });
  const sel = chosen();
  if (sel) {
    crumbs.append(sep());
    const s = document.createElement("span");
    s.textContent = sel.kind === "sym" ? `${sel.parent!.name} › ${sel.name}` : sel.name;
    crumbs.append(s);
  }
}
function sep() {
  const s = document.createElement("i");
  s.textContent = "›";
  return s;
}

// ---------------------------------------------------------------------------
// Interaction

/** Deepest drawn circle under a screen point. */
function hitTest(sx: number, sy: number): Circle | null {
  if (!root) return null;
  const x = toWorldX(sx), y = toWorldY(sy);
  if (Math.hypot(x - root.x, y - root.y) > root.r) return null;
  let cur = root;
  for (;;) {
    if (cur.kind === "file" && !symbolsShown(cur)) return cur;
    let next: Circle | null = null;
    for (const ch of cur.children) {
      if (ch.r * cam.k < 0.35) continue;
      // Symbols are small: give them a few pixels of grace.
      const grace = ch.kind === "sym" ? 4 / cam.k : 0;
      if (Math.hypot(x - ch.x, y - ch.y) <= ch.r + grace) {
        next = ch;
        break;
      }
    }
    if (!next) return cur;
    cur = next;
  }
}

function zoomInto(c: Circle) {
  zoomDir = c.kind === "root" ? null : c;
  fitCircle(c, 0.9);
}

function zoomOut() {
  const parent = zoomDir?.parent;
  if (!parent || parent.kind === "root") {
    zoomDir = null;
    fitCircle(root!, 0.94);
  } else zoomInto(parent);
}

/** Panning or zooming by hand away from the folder you entered leaves it. */
function releaseZoomDir() {
  if (!zoomDir) return;
  const sr = zoomDir.r * cam.k;
  const off = Math.hypot(toScreenX(zoomDir.x) - W / 2, toScreenY(zoomDir.y) - H / 2);
  if (sr < Math.min(W, H) * 0.3 || off > sr) zoomDir = null;
}

let drag: { x: number; y: number; cx: number; cy: number; moved: boolean } | null = null;

canvas.addEventListener("pointerdown", (e) => {
  canvas.setPointerCapture(e.pointerId);
  drag = { x: e.clientX, y: e.clientY, cx: cam.x, cy: cam.y, moved: false };
});

canvas.addEventListener("pointermove", (e) => {
  const r = canvas.getBoundingClientRect();
  const px = e.clientX - r.left, py = e.clientY - r.top;
  if (drag) {
    const dx = e.clientX - drag.x, dy = e.clientY - drag.y;
    if (!drag.moved && Math.hypot(dx, dy) > 3) {
      drag.moved = true;
      hideTip();
      if (anim) cancelAnimationFrame(anim);
    }
    if (drag.moved) {
      cam.x = drag.cx - dx / cam.k;
      cam.y = drag.cy - dy / cam.k;
      releaseZoomDir();
      canvas.style.cursor = "grabbing";
      requestDraw();
      return;
    }
  }
  const hit = hitTest(px, py);
  const h = hit && hit.kind !== "root" ? hit : null;
  if (h !== hovered) {
    hovered = h;
    requestDraw();
  }
  canvas.style.cursor = h ? "pointer" : "";
  schedulePreview(h);
  if (h && h.kind !== "dir") showTip(h, px, py);
  else hideTip();
});

canvas.addEventListener("pointerup", (e) => {
  const wasDrag = drag?.moved;
  drag = null;
  canvas.style.cursor = "";
  if (wasDrag) return;
  const r = canvas.getBoundingClientRect();
  const hit = hitTest(e.clientX - r.left, e.clientY - r.top);
  if (e.detail > 1) return;  // second click of a double click
  if (!hit || hit.kind === "root") {
    if (chosen() || highlight) clearSelection(true);
    else {
      endPreview();
      zoomOut();
    }
    return;
  }
  if (hit.kind === "dir") {
    if (chosen() || highlight) clearSelection(true);
    endPreview();
    zoomInto(hit);
    return;
  }
  setSelected(hit, true, false);
});

canvas.addEventListener("dblclick", (e) => {
  const r = canvas.getBoundingClientRect();
  const hit = hitTest(e.clientX - r.left, e.clientY - r.top);
  if (hit && (hit.kind === "file" || hit.kind === "sym")) post({ type: "open", id: hit.key });
});

canvas.addEventListener("pointerleave", () => {
  hovered = null;
  endPreview();
  hideTip();
  requestDraw();
});

canvas.addEventListener(
  "wheel",
  (e) => {
    e.preventDefault();
    hideTip();
    if (anim) {
      cancelAnimationFrame(anim);
      anim = null;
    }
    // Pinch arrives as ctrl+wheel; a mouse wheel moves in coarse integer
    // steps on one axis; anything else is a trackpad scroll → pan.
    const mouseWheel = e.deltaMode !== 0 || (e.deltaX === 0 && Number.isInteger(e.deltaY) && Math.abs(e.deltaY) >= 40);
    if (e.ctrlKey || mouseWheel) {
      const r = canvas.getBoundingClientRect();
      const px = e.clientX - r.left, py = e.clientY - r.top;
      const wx = toWorldX(px), wy = toWorldY(py);
      const lim = kLimits();
      const factor = Math.exp(-e.deltaY * (e.ctrlKey ? 0.012 : 0.0022));
      cam.k = Math.max(lim.min, Math.min(lim.max, cam.k * factor));
      cam.x = wx - (px - W / 2) / cam.k;
      cam.y = wy - (py - H / 2) / cam.k;
    } else {
      cam.x += e.deltaX / cam.k;
      cam.y += e.deltaY / cam.k;
    }
    releaseZoomDir();
    requestDraw();
  },
  { passive: false },
);

addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (chosen() || highlight) clearSelection(true);
  else if (previewing) endPreview();
  else zoomOut();
});

function showTip(c: Circle, x: number, y: number) {
  const n = payload!.nodes;
  const lines = c.kind === "file" ? n.lines?.[c.idx] ?? 0 : 0;
  const kindName = c.kind === "file" ? t("file") : kindLabel(n.kind[c.idx]);
  const where = c.kind === "file" ? c.path.split("/").slice(0, -1).join("/") || "/" : c.parent!.path;
  tip.replaceChildren();
  const title = document.createElement("b");
  title.textContent = c.name;
  const m = document.createElement("span");
  const links = n.degree[c.idx] ?? 0;
  m.textContent = [kindName, lines ? `${num(lines)} ${t("lines")}` : "", links ? `${num(links)} ${t("links")}` : ""]
    .filter(Boolean)
    .join(" · ");
  const p = document.createElement("small");
  p.textContent = where;
  tip.append(title, m, p);
  tip.hidden = false;
  const tw = tip.offsetWidth, th = tip.offsetHeight;
  const left = x + 16 + tw > W ? x - tw - 12 : x + 16;
  const top = y + 16 + th > H ? y - th - 12 : y + 16;
  tip.style.transform = `translate(${left}px, ${top}px)`;
}
function hideTip() {
  tip.hidden = true;
}

function kindLabel(k: Kind): string {
  switch (k) {
    case Kind.Function: return t("function");
    case Kind.Method: return t("method");
    case Kind.Type: return t("type");
    case Kind.Document: return t("document");
    case Kind.Route: return t("route");
    case Kind.Table: return t("table");
    default: return t("symbol");
  }
}

// ---------------------------------------------------------------------------
// Selection

function fileOfId(id: string): Circle | undefined {
  const n = payload?.nodes;
  if (!n) return undefined;
  const i = n.id.indexOf(id);
  const owner = i >= 0 ? n.owner?.[i] ?? -1 : -1;
  return owner >= 0 ? byKey.get(n.id[owner]) : undefined;
}

function schedulePreview(h: Circle | null) {
  clearTimeout(previewTimer);
  // A real selection, or a path / impact view, is never replaced by hovering.
  if ((selected && !previewing) || highlight) return;
  if (!h || h.kind === "dir") {
    if (previewing) previewTimer = window.setTimeout(endPreview, 80);
    return;
  }
  // A short pause, so sweeping across the map doesn't flicker.
  previewTimer = window.setTimeout(() => {
    previewing = true;
    selected = h;
    computeFocus();
    requestDraw();
  }, 120);
}

function endPreview() {
  clearTimeout(previewTimer);
  if (!previewing) return;
  previewing = false;
  selected = null;
  focus = null;
  requestDraw();
}

/** A selection the user made (not a hover preview). */
const chosen = () => (previewing ? null : selected);

function setSelected(c: Circle | null, notify: boolean, fly: boolean) {
  clearTimeout(previewTimer);
  previewing = false;
  selected = c;
  // VoiceOver: the map says what's selected.
  canvas.setAttribute("aria-label", c ? `${c.kind === "file" ? t("file") : c.kind === "sym" && payload ? kindLabel(payload.nodes.kind[c.idx]) : ""} ${c.name}`.trim() : t("project"));
  // The user moved on from a path / impact view: tell the app.
  if (highlight) post({ type: "highlight", active: false });
  highlight = null;
  computeFocus();
  if (notify) post({ type: "select", id: c?.key ?? null });
  if (c && fly) frameSelection();
  requestDraw();
}

function clearSelection(notify: boolean) {
  setSelected(null, notify, false);
}

/** The selection and the files it talks to, at a size where it reads. */
function frameSelection() {
  if (!selected || !focus) return;
  const fileOf = (c: Circle) => (c.kind === "sym" ? c.parent! : c);
  const self = fileOf(selected);
  const members = new Set<Circle>();
  for (const a of [...focus.uses, ...focus.usedBy]) for (const m of a.members) members.add(fileOf(m));
  members.delete(self);
  if (members.size === 0) {
    // Nothing to connect: open the file so the symbol itself is visible.
    const k = selected.kind === "sym" ? (SYMBOLS_AT * 2.2) / self.r : (Math.min(W, H) * 0.25) / (2 * self.r);
    animateTo({ x: self.x, y: self.y, k });
    return;
  }
  // Many partners spread over the project: frame the densest region instead
  // of everything (the bundles and the inspector cover the rest).
  const list = [self, ...members];
  fitCircles(list.length > 40 ? [self, ...nearest(self, [...members], 40)] : list, self);
}

function nearest(c: Circle, list: Circle[], n: number): Circle[] {
  return list.sort((a, b) => Math.hypot(a.x - c.x, a.y - c.y) - Math.hypot(b.x - c.x, b.y - c.y)).slice(0, n);
}

/** Selects by node id from Swift (search, inspector), revealing it if needed. */
function selectKey(id: string | null, fly: boolean) {
  if (!id) return clearSelection(false);
  if (!payload) return;
  let c = byKey.get(id);
  if (!c) {
    const i = payload.nodes.id.indexOf(id);
    if (i < 0) return;
    const k = payload.nodes.kind[i];
    const owner = k === Kind.File ? i : payload.nodes.owner?.[i] ?? -1;
    if (owner >= 0 && payload.nodes.noise[owner] && !showNoise) {
      showNoise = true;
      post({ type: "noise", value: true });
      const keep = { ...cam };
      build();
      Object.assign(cam, keep);
    }
    const need: Detail = k === Kind.File ? 0 : k === Kind.Symbol || k === Kind.Document ? 2 : 1;
    if (need > detail) {
      detail = need;
      buildSymbols();
      post({ type: "detail", value: detail });
    }
    c = byKey.get(id) ?? (owner >= 0 ? byKey.get(payload.nodes.id[owner]) : undefined);
    if (!c) return;
  }
  setSelected(c, false, fly);
}

/** What a highlight shows ("Yol · 4 adım"), in the legend strip. */
let highlightLabel = "";

function setHighlight(ids: string[], chain: boolean, label = "") {
  // Symbols the current level doesn't draw stand in as their file.
  const list = ids
    .map((id) => byKey.get(id) ?? fileOfId(id))
    .filter((c): c is Circle => !!c)
    .filter((c, i, a) => a.indexOf(c) === i);
  if (!list.length) return;
  selected = null;
  focus = null;
  highlightLabel = label;
  highlight = { set: new Set(list), chain: chain ? list : null };
  fitCircles(list);
  requestDraw();
}

// ---------------------------------------------------------------------------
// API (called from Swift: App/Map/MapController.swift)

function rebuildKeepingView() {
  if (!payload) return;
  const keep = { ...cam };
  const sel = chosen()?.key ?? null;
  build();
  Object.assign(cam, keep);
  if (sel) selectKey(sel, false);
  requestDraw();
}

const api = {
  load: (url: string, keep = false, sel: string | null = null) =>
    load(url, keep, sel).catch((e) => {
      setStatus(null);
      post({ type: "error", message: String(e?.message ?? e) });
    }),
  select: (id: string | null) => selectKey(id, true),
  focus: (id: string) => {
    const c = byKey.get(id);
    if (c) fitCircles([c]);
  },
  showPath: (ids: string[], label = "") => setHighlight(ids, true, label),
  highlightSet: (ids: string[], label = "") => setHighlight(ids, false, label),
  clearHighlight: () => {
    highlight = null;
    requestDraw();
  },
  setDetail: (d: Detail) => {
    if (d === detail) return;
    detail = d;
    const sel = selected?.key ?? null;
    buildSymbols();
    if (sel && !byKey.has(sel)) clearSelection(true);
    else if (sel) setSelected(byKey.get(sel)!, false, false);
    requestDraw();
  },
  setColorMode: (m: ColorMode) => {
    colorMode = m === "community" ? "folder" : m;
    assignColors();
    requestDraw();
  },
  setHideTests: (v: boolean) => {
    if (v === hideTests) return;
    hideTests = v;
    rebuildKeepingView();
  },
  setShowNoise: (v: boolean) => {
    if (v === showNoise) return;
    showNoise = v;
    rebuildKeepingView();
  },
  /** Legend click: fly to that area's folder. */
  focusGroup: (gid: number) => {
    if (!root || !payload) return;
    let best: Circle | null = null;
    forEachCircle(root, (c) => {
      if ((c.kind === "dir" || c.kind === "root") && c.group === gid && (!best || c.depth < best.depth)) best = c;
    });
    if (best) zoomInto(best);
  },
  /** PNG of the current view at screen resolution, on the canvas colour. */
  snapshot: (): string => {
    draw();
    const out = document.createElement("canvas");
    out.width = canvas.width;
    out.height = canvas.height;
    const o = out.getContext("2d")!;
    o.fillStyle = theme.canvas;
    o.fillRect(0, 0, out.width, out.height);
    o.drawImage(canvas, 0, 0);
    return out.toDataURL("image/png");
  },
  goUp: () => {
    const sel = chosen();
    endPreview();
    if (sel?.kind === "sym") {
      setSelected(sel.parent!, true, true);
      return;
    }
    if (sel) {
      const dir = sel.parent;
      clearSelection(true);
      if (dir && dir.kind !== "root") zoomInto(dir);
      else zoomOut();
      return;
    }
    zoomOut();
  },
  setLinkFilter: (f: LinkFilter) => {
    if (f === linkFilter) return;
    linkFilter = f;
    if (selected) {
      computeFocus();
      legendKey = "";
    }
    requestDraw();
  },
  setLocale: (l: string) => {
    const next: Lang = l.toLowerCase().startsWith("tr") ? "tr" : "en";
    if (next === lang) return;
    lang = next;
    document.documentElement.lang = lang;
    if (root) root.name = t("project");
    legendKey = "";
    if (payload && root) assignColors();
    requestDraw();
  },
  fit: () => {
    zoomDir = null;
    if (root) fitCircle(root, 0.94);
  },
  zoom: (factor: number) => animateTo({ x: cam.x, y: cam.y, k: cam.k * factor }, duration() / 2),
  relayout: () => rebuildKeepingView(),
};
(window as any).mapoMap = api;

darkQuery.addEventListener("change", (e) => {
  theme = e.matches ? DARK : LIGHT;
  document.documentElement.dataset.theme = theme.dark ? "dark" : "light";
  assignColors();
  requestDraw();
});
document.documentElement.dataset.theme = theme.dark ? "dark" : "light";

function setStatus(text: string | null) {
  status.textContent = text ?? "";
  status.hidden = !text;
}

post({ type: "ready" });
