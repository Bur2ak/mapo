import Graph from "graphology";
import forceAtlas2 from "graphology-layout-forceatlas2";
import noverlap from "graphology-layout-noverlap";
import Sigma from "sigma";
import { createNodeBorderProgram } from "@sigma/node-border";
import type { NodeDisplayData, PartialButFor } from "sigma/types";
import type { Settings } from "sigma/settings";

import { DARK, LIGHT, mix, neutralColor, spreadColor, type Theme } from "./palette";
import { convexHull, drawRegions, type Bundle, type Territory } from "./regions";
import { Kind, Rel, type ColorMode, type Detail, type GroupInfo, type Outgoing, type Payload } from "./types";

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
// State

interface NodeAttrs {
  x: number;
  y: number;
  size: number;
  label: string;
  kind: Kind;
  community: number;
  folder: number;
  sub: number;
  test: boolean;
  noise: boolean;
  baseColor: string;
  color: string;
}

interface EdgeAttrs {
  rel: Rel;
  weight: number;
}

const container = document.getElementById("map")!;
const regionCanvas = document.getElementById("regions") as HTMLCanvasElement;
const labelLayer = document.getElementById("labels")!;
const status = document.getElementById("status")!;

const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const motionQuery = matchMedia("(prefers-reduced-motion: reduce)");

let theme: Theme = darkQuery.matches ? DARK : LIGHT;
let graph = new Graph<NodeAttrs, EdgeAttrs>({ type: "directed", multi: true, allowSelfLoops: false });
let renderer: Sigma<NodeAttrs, EdgeAttrs> | null = null;
/** Bumped to cancel a running layout (new load / relayout). */
let layoutRun = 0;
let payload: Payload | null = null;
/** graphify found more than one community (its cluster step ran). */
let hasCommunities = false;

let detail: Detail = 0;
let colorMode: ColorMode = "folder";
let hideTests = false;
let showNoise = false;

let hovered: string | null = null;
let selected: string | null = null;
/** Path / impact highlight: nodes + edges drawn in accent, the rest dimmed. */
let highlight: { nodes: Set<string>; edges: Set<string> } | null = null;
/** Neighbourhood of hovered/selected. */
let focusSet: Set<string> | null = null;

/** Group id → colour, for the active colour mode. Absent = neutral. */
let groupColors = new Map<number, string>();
let groupNames: string[] = [];

/** Maps this small name every node and keep individual edges. */
const SMALL_MAP = 150;
let visibleCount = 0;
let cameraRatio = 1;
/** Bumped whenever node positions change (layout, refine). */
let positionsVersion = 0;
/** Territory disc radius in graph units (from node spacing). */
let territoryRadius = 10;

const duration = () => (motionQuery.matches ? 0 : 450);
const isSmall = () => visibleCount <= SMALL_MAP;

// ---------------------------------------------------------------------------
// Loading

async function load(url: string, keepView = false, sel: string | null = null) {
  if (!keepView) setStatus("Harita yükleniyor…");
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Harita verisi alınamadı (${res.status})`);
  const view = keepView && renderer ? { bbox: renderer.getCustomBBox(), camera: renderer.getCamera().getState() } : null;
  payload = (await res.json()) as Payload;
  build(payload, view);
  if (sel && graph.hasNode(sel)) select(sel, { notify: false, fly: false });
}

type SavedView = { bbox: { x: [number, number]; y: [number, number] } | null; camera: { x: number; y: number; ratio: number; angle: number } };

function build(p: Payload, view: SavedView | null = null) {
  layoutRun++;
  renderer?.kill();
  renderer = null;
  hovered = selected = null;
  highlight = null;
  focusSet = null;

  const g = new Graph<NodeAttrs, EdgeAttrs>({ type: "directed", multi: true, allowSelfLoops: false });
  const n = p.nodes.id.length;
  hasCommunities = new Set(p.nodes.community).size > 1;

  for (let i = 0; i < n; i++) {
    const kind = p.nodes.kind[i];
    g.addNode(p.nodes.id[i], {
      x: 0,
      y: 0,
      size: nodeSize(kind, p.nodes.degree[i]),
      label: p.nodes.label[i],
      kind,
      community: p.nodes.community[i],
      folder: p.nodes.folder[i],
      sub: p.nodes.sub?.[i] ?? 0,
      test: p.nodes.test[i] === 1,
      noise: p.nodes.noise?.[i] === 1,
      baseColor: "#888",
      color: "#888",
    });
  }
  for (let i = 0; i < p.edges.s.length; i++) {
    const si = p.edges.s[i], ti = p.edges.t[i];
    if (si === ti) continue;
    const rel = p.edges.r[i];
    // Edges inside a folder pull hard and edges across folders barely pull,
    // so areas of the codebase settle into separate countries.
    const sameFolder = p.nodes.folder[si] === p.nodes.folder[ti];
    const sameCommunity = p.nodes.community[si] === p.nodes.community[ti];
    const base = rel === Rel.Contains ? 3 : rel === Rel.Call ? 1 : 0.5;
    g.addEdge(p.nodes.id[si], p.nodes.id[ti], { rel, weight: base * (sameFolder ? 4 : 0.15) * (sameCommunity ? 1.5 : 1) });
  }
  for (let i = 0; i < (p.fileLinks?.s.length ?? 0); i++) {
    const si = p.fileLinks.s[i], ti = p.fileLinks.t[i];
    if (si === ti) continue;
    const same = p.nodes.folder[si] === p.nodes.folder[ti];
    // Light in the layout (symbol edges already pull); visible at file level.
    g.addEdge(p.nodes.id[si], p.nodes.id[ti], {
      rel: Rel.FileLink,
      weight: Math.min(3, Math.log2(1 + p.fileLinks.w[i])) * (same ? 0.6 : 0.1),
    });
  }
  graph = g;
  assignColors();
  countVisible();

  const missing = placeNodes(p);
  createRenderer();
  countVisible();
  measureTerritoryRadius();
  post({ type: "loaded", nodes: g.order, edges: g.size });

  // A brand-new folder needs its own country, not a corner of a neighbour's.
  const known = new Set<number>();
  graph.forEachNode((id, a) => {
    if (p.positions?.[id]) known.add(a.folder);
  });
  let newCountry = false;
  graph.forEachNode((id, a) => {
    if (!p.positions?.[id] && !known.has(a.folder)) newCountry = true;
  });
  if (missing === g.order || (missing > 0 && newCountry)) void runLayout();
  else {
    // A few new nodes were seeded next to their neighbours; keep the map
    // the user already knows instead of re-laying it out.
    setStatus(null);
    if (view && view.bbox) {
      renderer!.setCustomBBox(view.bbox);
      renderer!.getCamera().setState(view.camera);
    } else fitVisible(false);
    if (missing > 0) {
      // New files arrived with an update: nudge everything apart so they
      // never hide under a neighbour, then remember the result.
      noverlap.assign(graph, { maxIterations: 120, settings: { margin: 3, ratio: 1, expansion: 1.05 } });
      positionsVersion++;
      hitGrid = null;
      renderer!.refresh();
      savePositions();
    }
  }
}

/** Restores cached positions; seeds the rest. Returns how many were missing. */
function placeNodes(p: Payload): number {
  const cached = p.positions ?? {};
  let missing = 0;
  // Seed by folder: the regions people recognise.
  const groups = new Map<number, number>();
  graph.forEachNode((_, a) => groups.set(a.folder, (groups.get(a.folder) ?? 0) + 1));
  const ordered = [...groups.keys()].sort((a, b) => groups.get(b)! - groups.get(a)!);
  const radius = Math.sqrt(graph.order) * 14;
  const center = new Map<number, [number, number]>();
  ordered.forEach((gid, i) => {
    const angle = (i / ordered.length) * Math.PI * 2;
    const r = ordered.length === 1 ? 0 : radius;
    center.set(gid, [Math.cos(angle) * r, Math.sin(angle) * r]);
  });

  const rand = mulberry32(42);
  graph.forEachNode((id, a) => {
    const c = cached[id];
    if (c) {
      a.x = c[0];
      a.y = c[1];
      return;
    }
    missing++;
    let placed = false;
    for (const nb of graph.neighbors(id)) {
      const pc = cached[nb];
      if (pc) {
        // Next to the neighbour, outside its dot (sizes are map units).
        const angle = rand() * Math.PI * 2;
        const d = (graph.getNodeAttribute(nb, "size") + a.size) * 1.6;
        a.x = pc[0] + Math.cos(angle) * d;
        a.y = pc[1] + Math.sin(angle) * d;
        placed = true;
        break;
      }
    }
    if (!placed) {
      const [cx, cy] = center.get(a.folder) ?? [0, 0];
      const spread = Math.sqrt(groups.get(a.folder) ?? 1) * 6;
      a.x = cx + (rand() - 0.5) * spread;
      a.y = cy + (rand() - 0.5) * spread;
    }
  });
  return missing;
}

/**
 * Two-level "mapo" layout:
 *  1. each folder is laid out on its own into a round country;
 *  2. countries are placed by the traffic between them, never overlapping.
 * A single global force layout let folders bleed into each other.
 */
async function runLayout() {
  const run = ++layoutRun;
  setStatus("Harita yerleşiyor…");
  const members = new Map<number, string[]>();
  graph.forEachNode((id, a) => {
    let m = members.get(a.folder);
    if (!m) members.set(a.folder, (m = []));
    m.push(id);
  });
  const groups = [...members.keys()];
  const yieldToUI = () => new Promise((r) => setTimeout(r, 0));

  // 1. Countries.
  const local = new Map<number, { pos: Map<string, [number, number]>; radius: number }>();
  let done = 0;
  for (const gid of groups) {
    const ids = members.get(gid)!;
    local.set(gid, await layoutCountry(ids));
    done += ids.length;
    post({ type: "layoutProgress", value: (done / graph.order) * 0.9 });
    await yieldToUI();
    if (run !== layoutRun) return;
  }

  // 2. Continent: countries placed by the traffic between them.
  const traffic = new Map<string, number>();
  graph.forEachEdge((_e, ea, _s, _t, sa, ta) => {
    if (sa.folder === ta.folder || ea.rel === Rel.Contains) return;
    const k = pairKey(String(sa.folder), String(ta.folder));
    traffic.set(k, (traffic.get(k) ?? 0) + 1);
  });
  const margin = Math.max(...[...local.values()].map((l) => l.radius)) * 0.18 + 30;
  const centres = arrange(groups.map((gid) => ({ key: String(gid), radius: local.get(gid)!.radius })), traffic, margin);

  // 3. Place every node: country centre + its local position.
  if (run !== layoutRun) return;
  const target = new Map<string, [number, number]>();
  for (const gid of groups) {
    const [cx, cy] = centres.get(String(gid))!;
    for (const [id, [x, y]] of local.get(gid)!.pos) target.set(id, [cx + x, cy + y]);
  }
  // One batched update (per-node writes each trigger a sigma refresh).
  graph.updateEachNodeAttributes((id, a) => {
    const p = target.get(id);
    if (p) { a.x = p[0]; a.y = p[1]; }
    return a;
  });
  positionsVersion++;
  hitGrid = null;
  post({ type: "layoutProgress", value: 1 });
  separateLabels();
  positionsVersion++;
  hitGrid = null;
  measureTerritoryRadius();
  setStatus(null);
  renderer?.refresh();
  fitVisible(true);
  savePositions();
}

/**
 * Places round clusters (countries, provinces) by the traffic between them:
 * force layout with sizes, then a no-overlap pass so none ever touch.
 */
function arrange(
  items: { key: string; radius: number }[],
  links: Map<string, number>,
  margin: number,
): Map<string, [number, number]> {
  const out = new Map<string, [number, number]>();
  if (items.length === 1) {
    out.set(items[0].key, [0, 0]);
    return out;
  }
  const g = new Graph({ type: "undirected" });
  const rand = mulberry32(items.length * 31);
  items.forEach((it, i) => {
    const angle = (i / items.length) * Math.PI * 2;
    g.addNode(it.key, { x: Math.cos(angle) * 100 + rand(), y: Math.sin(angle) * 100 + rand(), size: it.radius });
  });
  for (const [pair, w] of links) {
    const [a, b] = pair.split("\u0000");
    if (g.hasNode(a) && g.hasNode(b) && a !== b && !g.hasEdge(a, b)) g.addEdge(a, b, { weight: w });
  }
  forceAtlas2.assign(g, {
    iterations: 400,
    getEdgeWeight: (_e, attr) => Math.log2(1 + (attr.weight as number)),
    settings: { ...forceAtlas2.inferSettings(g), adjustSizes: true, gravity: 1.5, scalingRatio: 6, strongGravityMode: true },
  });
  noverlap.assign(g, { maxIterations: 800, settings: { margin, ratio: 1, expansion: 1.05 } });
  g.forEachNode((key, a) => out.set(key, [a.x, a.y]));
  return out;
}

function pairKey(a: string, b: string): string {
  return a < b ? `${a}\u0000${b}` : `${b}\u0000${a}`;
}

/**
 * Lays out one folder as a country:
 *  - files only: force layout with strong gravity (compact, round), then
 *    pushed apart so no two files touch;
 *  - every symbol orbits its file on rings, so the file level stays clean
 *    and the code level shows each file as its own small constellation.
 * Centred on 0,0; area grows with the number of files.
 */
async function layoutCountry(ids: string[]): Promise<{ pos: Map<string, [number, number]>; radius: number }> {
  const pos = new Map<string, [number, number]>();
  const inside = new Set(ids);

  // Owner file of each node (walk containment edges upward).
  const ownerOf = (id: string): string | null => {
    let cur = id;
    for (let hop = 0; hop < 6; hop++) {
      if (graph.getNodeAttribute(cur, "kind") === Kind.File) return cur;
      let parent: string | null = null;
      graph.forEachInEdge(cur, (_e, ea, s) => {
        if (!parent && ea.rel === Rel.Contains) parent = s;
      });
      if (!parent) return null;
      cur = parent;
    }
    return null;
  };
  const files = ids.filter((id) => graph.getNodeAttribute(id, "kind") === Kind.File);
  const orbit = new Map<string, string[]>();
  const loose: string[] = [];
  for (const id of ids) {
    if (graph.getNodeAttribute(id, "kind") === Kind.File) continue;
    const owner = ownerOf(id);
    if (owner && inside.has(owner)) {
      let list = orbit.get(owner);
      if (!list) orbit.set(owner, (list = []));
      list.push(id);
    } else loose.push(id);
  }
  // Loose symbols (no file) behave like tiny files.
  const anchors = files.length > 0 ? files.concat(loose) : ids.slice();

  // Footprint of an anchor = its own dot plus its orbit rings.
  const SPACING = 9;
  const ringsFor = (count: number) => {
    const rings: number[] = [];
    let left = count, r = 0;
    while (left > 0) {
      r += SPACING * 1.3;
      const cap = Math.max(6, Math.floor((2 * Math.PI * r) / SPACING));
      rings.push(Math.min(cap, left));
      left -= cap;
    }
    return { rings, outer: r };
  };
  const footprint = new Map<string, number>();
  for (const id of anchors) {
    const own = graph.getNodeAttribute(id, "size") * 1.2 + 3;
    footprint.set(id, Math.max(own, ringsFor(orbit.get(id)?.length ?? 0).outer + 4));
  }

  // Provinces (sub-folders): each laid out on its own, then arranged inside
  // the country so "kesfet", "sohbet"… are visibly separate areas.
  const provinces = new Map<number, string[]>();
  for (const id of anchors) {
    const p = graph.getNodeAttribute(id, "sub");
    let list = provinces.get(p);
    if (!list) provinces.set(p, (list = []));
    list.push(id);
  }
  const provinceLayouts = new Map<string, { pos: Map<string, [number, number]>; radius: number }>();
  for (const [p, list] of provinces) {
    provinceLayouts.set(String(p), layoutFiles(list, footprint));
    await new Promise((r) => setTimeout(r, 0));
  }
  const crossing = new Map<string, number>();
  for (const id of anchors) {
    const pa = String(graph.getNodeAttribute(id, "sub"));
    graph.forEachOutEdge(id, (_e, ea, _s, t) => {
      if (ea.rel === Rel.Contains || !inside.has(t)) return;
      const tOwner = graph.getNodeAttribute(t, "kind") === Kind.File ? t : null;
      if (!tOwner) return;
      const pb = String(graph.getNodeAttribute(tOwner, "sub"));
      if (pa === pb) return;
      const k = pairKey(pa, pb);
      crossing.set(k, (crossing.get(k) ?? 0) + 1);
    });
  }
  const meanFoot = [...footprint.values()].reduce((a, b) => a + b, 0) / Math.max(1, footprint.size);
  const provinceCentres = arrange(
    [...provinceLayouts.entries()].map(([key, l]) => ({ key, radius: l.radius })),
    crossing,
    meanFoot * 1.2 + 6,
  );
  for (const [key, l] of provinceLayouts) {
    const [px, py] = provinceCentres.get(key)!;
    for (const [id, [x, y]] of l.pos) pos.set(id, [px + x, py + y]);
  }
  // Re-centre the country on 0,0.
  let ccx = 0, ccy = 0;
  for (const [x, y] of pos.values()) { ccx += x; ccy += y; }
  ccx /= Math.max(1, pos.size); ccy /= Math.max(1, pos.size);
  for (const [id, [x, y]] of pos) pos.set(id, [x - ccx, y - ccy]);

  // Orbits: symbols on rings around their file, largest (most connected) first.
  for (const [file, members] of orbit) {
    const [fx, fy] = pos.get(file)!;
    members.sort((a, b) => graph.getNodeAttribute(b, "size") - graph.getNodeAttribute(a, "size"));
    const { rings } = ringsFor(members.length);
    let i = 0, r = 0;
    const phase = (hash(file) % 360) * (Math.PI / 180);
    for (const count of rings) {
      r += SPACING * 1.3;
      for (let j = 0; j < count; j++, i++) {
        const angle = phase + (j / count) * Math.PI * 2;
        pos.set(members[i], [fx + Math.cos(angle) * r, fy + Math.sin(angle) * r]);
      }
    }
  }

  let maxR = 0;
  for (const [id, [x, y]] of pos) maxR = Math.max(maxR, Math.hypot(x, y) + (footprint.get(id) ?? 0));
  return { pos, radius: Math.max(24, maxR) };
}

/** Files of one province: compact force layout, no overlaps. */
function layoutFiles(ids: string[], footprint: Map<string, number>): { pos: Map<string, [number, number]>; radius: number } {
  const pos = new Map<string, [number, number]>();
  if (ids.length === 1) {
    pos.set(ids[0], [0, 0]);
    return { pos, radius: footprint.get(ids[0])! };
  }
  const sub = new Graph({ type: "undirected", multi: true });
  const rand = mulberry32(ids.length);
  for (const id of ids) sub.addNode(id, { x: rand() * 100, y: rand() * 100, size: footprint.get(id)! });
  const set = new Set(ids);
  for (const id of ids) {
    graph.forEachOutEdge(id, (_e, ea, _s, t) => {
      if (t !== id && set.has(t) && ea.rel !== Rel.Contains) sub.addEdge(id, t, { weight: ea.weight });
    });
  }
  const n = ids.length;
  forceAtlas2.assign(sub, {
    // Work budget roughly constant in n: a flat 3k-file folder must not
    // freeze the UI for seconds.
    iterations: n < 300 ? 500 : Math.max(60, Math.round(120_000 / n)),
    getEdgeWeight: "weight",
    settings: {
      ...forceAtlas2.inferSettings(sub),
      barnesHutOptimize: n > 250,
      strongGravityMode: true,
      gravity: 0.05,
      scalingRatio: 3,
      linLogMode: false,
    },
  });
  let cx = 0, cy = 0;
  sub.forEachNode((_id, a) => { cx += a.x; cy += a.y; });
  cx /= n; cy /= n;
  const feet = ids.map((id) => footprint.get(id)!);
  const meanFoot = feet.reduce((a, b) => a + b, 0) / n;
  const area = feet.reduce((a, f) => a + Math.PI * (f + 4) ** 2, 0);
  const target = Math.sqrt(area / Math.PI) * 1.4;
  const dist = sub.mapNodes((_id, a) => Math.hypot(a.x - cx, a.y - cy)).sort((a, b) => a - b);
  const r92 = dist[Math.floor(dist.length * 0.92)] || 1;
  const k = target / r92;
  sub.forEachNode((_id, a) => {
    a.x = (a.x - cx) * k;
    a.y = (a.y - cy) * k;
    const d = Math.hypot(a.x, a.y);
    if (d > target * 1.1) { a.x *= (target * 1.1) / d; a.y *= (target * 1.1) / d; }
  });
  noverlap.assign(sub, { maxIterations: n > 1000 ? 300 : 1500, settings: { margin: Math.max(2, meanFoot * 0.2), ratio: 1, expansion: 1.1, speed: 3 } });
  let radius = 0;
  sub.forEachNode((id, a) => {
    pos.set(id, [a.x, a.y]);
    radius = Math.max(radius, Math.hypot(a.x, a.y) + footprint.get(id)!);
  });
  return { pos, radius };
}

function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
  return h >>> 0;
}

function savePositions() {
  const positions: Record<string, [number, number]> = {};
  graph.forEachNode((id, a) => (positions[id] = [round(a.x), round(a.y)]));
  post({ type: "layout", positions });
}

/**
 * Small maps label every node, so nodes are nudged apart until their label
 * boxes (dot + text to the right) stop overlapping. Big maps rely on
 * sigma's label grid instead, which hides colliding labels.
 */
function separateLabels() {
  if (!isSmall()) return;
  const ids: string[] = [];
  graph.forEachNode((id, a) => {
    if (isVisible(a)) ids.push(id);
  });
  if (ids.length < 2) return;
  // Work in a unit where the map spans ~1000 px, roughly what the user sees.
  const bb = bbox(ids);
  const span = Math.max(bb.maxX - bb.minX, bb.maxY - bb.minY, 1);
  const k = span / 900; // graph units per px
  const boxes = ids.map((id) => {
    const a = graph.getNodeAttributes(id);
    const textW = a.label.length * 7.3 + 10;
    return { a, w: (a.size * 2 + textW) * k, h: 20 * k, x0: a.size * k };
  });
  // Resolve until clean (or a generous cap): small maps are cheap.
  for (let pass = 0; pass < 600; pass++) {
    let moved = false;
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const A = boxes[i], B = boxes[j];
        const ax0 = A.a.x - A.x0, ax1 = ax0 + A.w, ay0 = A.a.y - A.h / 2, ay1 = A.a.y + A.h / 2;
        const bx0 = B.a.x - B.x0, bx1 = bx0 + B.w, by0 = B.a.y - B.h / 2, by1 = B.a.y + B.h / 2;
        const ox = Math.min(ax1, bx1) - Math.max(ax0, bx0);
        const oy = Math.min(ay1, by1) - Math.max(ay0, by0);
        if (ox <= 0 || oy <= 0) continue;
        moved = true;
        // Push along the cheaper axis; vertical is usually cheaper for text.
        if (oy < ox) {
          const d = (oy / 2 + k) * (A.a.y < B.a.y ? -1 : 1);
          A.a.y += d;
          B.a.y -= d;
        } else {
          const d = (ox / 2 + k) * (A.a.x < B.a.x ? -1 : 1);
          A.a.x += d;
          B.a.x -= d;
        }
      }
    }
    if (!moved) break;
  }
}

// ---------------------------------------------------------------------------
// Colour

/**
 * Areas big enough to matter get evenly spread hues; the long tail is
 * neutral so the map does not turn into a rainbow.
 */
function assignColors() {
  if (!payload) return;
  const useCommunity = colorMode === "community" && hasCommunities;
  groupNames = useCommunity ? payload.communities : payload.folders;
  const counts = new Map<number, number>();
  // Connection weight per group: a small folder everything depends on
  // (packages/shared) deserves a colour as much as a big one.
  const weight = new Map<number, number>();
  let totalWeight = 0;
  graph.forEachEdge((_e, ea, _s, _t, sa) => {
    if (ea.rel === Rel.Contains || ea.rel === Rel.FileLink) return;
    const gid = useCommunity ? sa.community : sa.folder;
    weight.set(gid, (weight.get(gid) ?? 0) + 1);
    totalWeight++;
  });
  graph.forEachEdge((_e, ea, _s, _t, _sa, ta) => {
    if (ea.rel === Rel.Contains || ea.rel === Rel.FileLink) return;
    const gid = useCommunity ? ta.community : ta.folder;
    weight.set(gid, (weight.get(gid) ?? 0) + 1);
  });
  let total = 0;
  graph.forEachNode((_, a) => {
    if (a.noise || a.kind === Kind.External) return;
    // Folder sizes in files; communities in all symbols.
    if (!useCommunity && a.kind !== Kind.File) return;
    const gid = useCommunity ? a.community : a.folder;
    counts.set(gid, (counts.get(gid) ?? 0) + 1);
    total++;
  });
  const ranked = [...counts.entries()].sort((a, b) => b[1] - a[1]);
  const share = (gid: number, c: number) =>
    Math.max(c / Math.max(1, total), (weight.get(gid) ?? 0) / Math.max(1, 2 * totalWeight));
  const heavy = (gid: number) => (weight.get(gid) ?? 0) / Math.max(1, 2 * totalWeight) >= 0.05;
  const significant = ranked
    .filter(([gid, c]) => (c >= 2 || heavy(gid)) && share(gid, c) >= 0.03 && groupNames[gid])
    .slice(0, 9);
  const count = Math.max(1, significant.length);
  groupColors = new Map(significant.map(([gid], i) => [gid, spreadColor(i, count, theme.dark)]));
  const neutral = neutralColor(theme.dark);
  graph.forEachNode((_, a) => {
    const gid = useCommunity ? a.community : a.folder;
    a.baseColor = groupColors.get(gid) ?? neutral;
    a.color = a.baseColor;
  });

  const groups: GroupInfo[] = significant.map(([gid, c]) => ({
    id: gid,
    name: groupNames[gid],
    color: groupColors.get(gid)!,
    count: c,
  }));
  const rest = ranked.filter(([gid]) => !groupColors.has(gid)).reduce((sum, [, c]) => sum + c, 0);
  if (rest > 0) groups.push({ id: -1, name: "", color: neutral, count: rest });
  post({ type: "groups", mode: useCommunity ? "community" : "folder", groups });
}

function groupOf(a: NodeAttrs): number {
  return colorMode === "community" && hasCommunities ? a.community : a.folder;
}

// ---------------------------------------------------------------------------
// Rendering

const BorderedProgram = createNodeBorderProgram({
  borders: [
    { size: { value: 0.28 }, color: { attribute: "borderColor" } },
    { size: { value: 0.12 }, color: { attribute: "gapColor" } },
    { size: { fill: true }, color: { attribute: "color" } },
  ],
});

function createRenderer() {
  appliedSettings.clear();
  focusKey = undefined as unknown as null;
  renderer = new Sigma(graph, container, {
    renderLabels: true,
    renderEdgeLabels: false,
    enableEdgeEvents: false,
    zIndex: true,
    labelFont: "-apple-system, BlinkMacSystemFont, sans-serif",
    labelSize: 11,
    labelWeight: "500",
    labelColor: { color: theme.label },
    labelDensity: 0.6,
    labelGridCellSize: 120,
    labelRenderedSizeThreshold: 8,
    defaultEdgeColor: theme.edge,
    defaultEdgeType: "line",
    minCameraRatio: 0.02,
    maxCameraRatio: 4,
    stagePadding: 24,
    zoomDuration: motionQuery.matches ? 0 : 250,
    doubleClickZoomingDuration: motionQuery.matches ? 0 : 250,
    // Node sizes live in map units: they grow as you zoom in (like towns on
    // a map) and the layout's spacing matches what is drawn.
    itemSizesReference: "positions",
    zoomToSizeRatioFunction: (ratio: number) => ratio,
    nodeProgramClasses: { bordered: BorderedProgram },
    defaultDrawNodeHover: drawHover,
    defaultDrawNodeLabel: drawLabel,
    nodeReducer,
    edgeReducer,
  });

  // Sticky hit-testing: zoomed out, files are a few pixels wide, so the
  // nearest visible node within HIT_PX counts as "under the cursor".
  // Never while dragging the map (nodes slide under a still cursor).
  const setHover = (id: string | null) => {
    if (id === hovered) return;
    hovered = id;
    recomputeFocus();
    container.style.cursor = id ? "pointer" : "";
  };
  let dragging = false;
  let pendingMove: { x: number; y: number } | null = null;
  renderer.on("downStage", () => (dragging = true));
  renderer.on("downNode", () => (dragging = true));
  renderer.on("upStage", () => (dragging = false));
  renderer.on("upNode", () => (dragging = false));
  renderer.on("leaveStage", () => {
    dragging = false;
    pendingMove = null;
    setHover(null);
  });
  renderer.on("enterNode", ({ node }) => !dragging && setHover(node));
  renderer.on("leaveNode", () => !dragging && setHover(null));
  renderer.on("moveBody", ({ event }) => {
    if (dragging) return;
    const first = pendingMove === null;
    pendingMove = { x: event.x, y: event.y };
    if (!first) return;
    requestAnimationFrame(() => {
      if (pendingMove && !dragging) setHover(nearestNode(pendingMove.x, pendingMove.y));
      pendingMove = null;
    });
  });
  // GPU switch / sleep can drop the WebGL context: rebuild from scratch.
  for (const canvas of container.querySelectorAll("canvas")) {
    canvas.addEventListener("webglcontextlost", (e) => {
      e.preventDefault();
      post({ type: "error", message: "WebGL context lost; reloading map" });
      location.reload();
    });
  }
  renderer.on("clickNode", ({ node }) => select(node, { notify: true, fly: false }));
  renderer.on("doubleClickNode", (e) => {
    e.preventSigmaDefault();
    post({ type: "open", id: e.node });
  });
  renderer.on("clickStage", ({ event }) => {
    const near = nearestNode(event.x, event.y);
    if (near) return select(near, { notify: true, fly: false });
    if (highlight) api.clearHighlight();
    select(null, { notify: true, fly: false });
  });
  renderer.on("doubleClickStage", (e) => {
    const near = nearestNode(e.event.x, e.event.y);
    if (!near) return;
    e.preventSigmaDefault();
    post({ type: "open", id: near });
  });
  renderer.on("beforeRender", reserveSelectedLabel);
  renderer.on("afterRender", drawOverlay);
  renderer.getCamera().on("updated", (state) => {
    const before = labelTier(cameraRatio), after = labelTier(state.ratio);
    cameraRatio = state.ratio;
    if (before !== after) renderer?.refresh({ skipIndexation: true });
  });
}

const HIT_PX = 14;

/** Visible nodes bucketed by graph position, rebuilt when visibility or
 * positions change, so hover never scans every node. */
let hitGrid: { cell: number; cells: Map<string, string[]> } | null = null;

function buildHitGrid() {
  let minX = Infinity, maxX = -Infinity;
  graph.forEachNode((_, a) => {
    if (isVisible(a)) { minX = Math.min(minX, a.x); maxX = Math.max(maxX, a.x); }
  });
  const cell = Math.max(1, (maxX - minX) / 120);
  const cells = new Map<string, string[]>();
  graph.forEachNode((id, a) => {
    if (!isVisible(a)) return;
    const k = `${Math.floor(a.x / cell)},${Math.floor(a.y / cell)}`;
    let list = cells.get(k);
    if (!list) cells.set(k, (list = []));
    list.push(id);
  });
  hitGrid = { cell, cells };
}

/** Closest visible node to a viewport point, if within HIT_PX. */
function nearestNode(x: number, y: number): string | null {
  if (!renderer) return null;
  if (!hitGrid) buildHitGrid();
  const g = renderer.viewportToGraph({ x, y });
  const edge = renderer.viewportToGraph({ x: x + HIT_PX, y });
  const reach = Math.hypot(edge.x - g.x, edge.y - g.y);
  const { cell, cells } = hitGrid!;
  const span = Math.ceil(reach / cell);
  const cx = Math.floor(g.x / cell), cy = Math.floor(g.y / cell);
  let best: string | null = null, bestD = reach * reach;
  for (let i = cx - span; i <= cx + span; i++) {
    for (let j = cy - span; j <= cy + span; j++) {
      for (const id of cells.get(`${i},${j}`) ?? []) {
        const a = graph.getNodeAttributes(id);
        const d = (a.x - g.x) ** 2 + (a.y - g.y) ** 2;
        if (d < bestD) { bestD = d; best = id; }
      }
    }
  }
  return best;
}

/** Big maps: 0 = regions only, 1 = + sub-areas, 2 = + node names. */
function labelTier(ratio: number): number {
  if (ratio > 0.55) return 0;
  if (ratio > 0.28) return 1;
  return 2;
}

function nodeReducer(id: string, a: NodeAttrs): Partial<NodeDisplayData> & Record<string, unknown> {
  const res: Partial<NodeDisplayData> & Record<string, unknown> = { ...a };
  if (!isVisible(a)) {
    res.hidden = true;
    return res;
  }
  const lit = highlight ? highlight.nodes.has(id) : focusSet ? focusSet.has(id) : true;
  // Semantic zoom on big maps: names appear once you are close enough.
  if (!isSmall() && !highlight && !focusSet && labelTier(cameraRatio) < 2) res.label = "";
  if (!lit) {
    res.color = mix(a.baseColor, theme.canvas, 0.86);
    res.size = Math.max(1.5, a.size * 0.6);
    res.label = "";
    res.zIndex = 0;
  } else {
    res.zIndex = 1;
    if (highlight || (focusSet && (id === hovered || id === selected))) res.forceLabel = true;
    // Neighbours get names through sigma's label grid (no forced pile-ups);
    // only a handful are forced.
    if (focusSet && !highlight && focusSet.size <= 24) res.forceLabel = true;
  }
  if (id === selected) {
    res.highlighted = true;
    res.type = "bordered";
    res.borderColor = theme.accent;
    res.gapColor = theme.canvas;
    res.size = a.size + 3;
    res.forceLabel = true;
    res.zIndex = 2;
  } else if (highlight?.nodes.has(id)) {
    res.type = "bordered";
    res.borderColor = theme.accent;
    res.gapColor = theme.canvas;
    res.size = a.size + 1.5;
  }
  return res;
}

function edgeReducer(id: string, a: EdgeAttrs): Record<string, unknown> {
  const res: Record<string, unknown> = { ...a, size: 0.7 };
  const [s, t] = graph.extremities(id);
  if (!isVisible(graph.getNodeAttributes(s)) || !isVisible(graph.getNodeAttributes(t))) {
    res.hidden = true;
    return res;
  }
  const levelMatch = detail === 0 ? a.rel === Rel.FileLink : a.rel !== Rel.FileLink && a.rel !== Rel.Contains;
  if (highlight) {
    if (highlight.edges.has(id) && a.rel !== Rel.Contains) {
      res.color = theme.accent;
      res.size = 2.4;
      res.zIndex = 2;
    } else res.hidden = true;
    return res;
  }
  // A deliberate selection (click, search, panel) outranks a passing cursor.
  const focus = selected ?? hovered;
  if (focus) {
    if ((s === focus || t === focus) && levelMatch) {
      res.color = theme.edgeActive;
      res.size = 1.3;
      res.zIndex = 1;
    } else res.hidden = true;
    return res;
  }
  // At rest a big map shows region ribbons (overlay) instead of thousands of
  // individual edges; a small map shows its edges.
  if (!isSmall() || !levelMatch) res.hidden = true;
  // Few edges on a small map: a touch more contrast so they read.
  res.color = mix(theme.edge, theme.edgeActive, 0.3);
  return res;
}

function isVisible(a: NodeAttrs): boolean {
  if (a.noise && !showNoise) return false;
  if (hideTests && a.test) return false;
  switch (detail) {
    case 0:
      return a.kind === Kind.File;
    case 1:
      return a.kind !== Kind.Symbol && a.kind !== Kind.External && a.kind !== Kind.Document;
    default:
      return true;
  }
}

function countVisible() {
  let n = 0;
  graph.forEachNode((_, a) => {
    if (isVisible(a)) n++;
  });
  visibleCount = n;
  overlayKey = "";
  hitGrid = null;
  applyLabelSettings();
}

/** sigma re-processes the whole graph on every setSetting: only call it on change. */
const appliedSettings = new Map<string, unknown>();
function setSetting(key: "labelRenderedSizeThreshold" | "labelDensity" | "labelGridCellSize", value: number) {
  if (!renderer || appliedSettings.get(key) === value) return;
  appliedSettings.set(key, value);
  renderer.setSetting(key, value);
}

function applyLabelSettings() {
  const focus = selected ?? hovered;
  // Small maps: every name (overlaps were resolved by separateLabels).
  // While focused, every lit node may be named; at rest big maps stay quiet.
  setSetting("labelRenderedSizeThreshold", focus || isSmall() ? 0 : 7);
  setSetting("labelDensity", isSmall() ? 100 : focus ? 2.5 : 1.6);
  setSetting("labelGridCellSize", isSmall() ? 10 : 70);
}

function recomputeFocus() {
  // A deliberate selection (click, search, panel) outranks a passing cursor.
  const focus = selected ?? hovered;
  const before = focusKey;
  focusKey = focus;
  if (before === focus) return;
  applyLabelSettings();
  if (!focus || !graph.hasNode(focus)) focusSet = null;
  else {
    focusSet = new Set<string>();
    focusSet.add(focus);
    // Only neighbours reachable through edges drawn at this level.
    graph.forEachEdge(focus, (_e, ea, s, t) => {
      const levelMatch = detail === 0 ? ea.rel === Rel.FileLink : ea.rel !== Rel.FileLink && ea.rel !== Rel.Contains;
      if (levelMatch) focusSet!.add(s === focus ? t : s);
    });
  }
  renderer?.refresh({ skipIndexation: true });
}

/**
 * The selected node's name always wins: its box is reserved before sigma
 * draws any label, so neighbours step aside instead of hiding it.
 */
function reserveSelectedLabel() {
  drawnLabels.length = 0;
  if (!renderer || !selected || !graph.hasNode(selected)) return;
  const a = graph.getNodeAttributes(selected);
  if (!isVisible(a)) return;
  const p = renderer.graphToViewport({ x: a.x, y: a.y });
  const size = renderer.getNodeDisplayData(selected)?.size ?? 4;
  const r = renderer.scaleSize(size);
  const w = a.label.length * 7 + 6;
  drawnLabels.push({ x0: p.x + r + 1, y0: p.y - 9, x1: p.x + r + 5 + w, y1: p.y + 9 });
}

/** The node focusSet was computed for (skip identical recomputes). */
let focusKey: string | null = null;

/** Label boxes drawn this frame (viewport px), for collision checks. */
const drawnLabels: { x0: number; y0: number; x1: number; y1: number }[] = [];

/**
 * Sigma's label grid limits density but lets labels overlap. Skip a label
 * that would collide with one already drawn this frame; sigma draws bigger
 * (and forced) nodes first, so the important names win.
 */
function drawLabel(
  ctx: CanvasRenderingContext2D,
  data: PartialButFor<NodeDisplayData, "x" | "y" | "size" | "label" | "color">,
  settings: Settings<NodeAttrs, EdgeAttrs>,
) {
  if (!data.label) return;
  const size = settings.labelSize;
  ctx.font = `${settings.labelWeight} ${size}px ${settings.labelFont}`;
  const w = ctx.measureText(data.label).width;
  const x = data.x + data.size + 3, y = data.y + size / 3;
  const box = { x0: x - 2, y0: data.y - size / 2 - 2, x1: x + w + 2, y1: data.y + size / 2 + 2 };
  // The selected node's own label (marked highlighted) owns the reserved box.
  if (!data.highlighted && drawnLabels.some((b) => box.x0 < b.x1 && box.x1 > b.x0 && box.y0 < b.y1 && box.y1 > b.y0)) return;
  drawnLabels.push(box);
  // Halo keeps names readable over territories and edges.
  ctx.lineWidth = 3;
  ctx.strokeStyle = theme.canvas;
  ctx.lineJoin = "round";
  ctx.strokeText(data.label, x, y);
  ctx.fillStyle = theme.label;
  ctx.fillText(data.label, x, y);
}

function drawHover(
  ctx: CanvasRenderingContext2D,
  data: PartialButFor<NodeDisplayData, "x" | "y" | "size" | "label" | "color">,
  settings: Settings<NodeAttrs, EdgeAttrs>,
) {
  if (!data.label) return;
  const size = settings.labelSize + 1;
  ctx.font = `600 ${size}px ${settings.labelFont}`;
  const w = ctx.measureText(data.label).width;
  const padX = 8, h = size + 10;
  const x = data.x + data.size + 6, y = data.y - h / 2;
  ctx.fillStyle = theme.hoverBox;
  ctx.strokeStyle = theme.hoverBorder;
  ctx.lineWidth = 1;
  ctx.beginPath();
  ctx.roundRect(x, y, w + padX * 2, h, 6);
  ctx.fill();
  ctx.stroke();
  ctx.fillStyle = theme.label;
  ctx.textBaseline = "middle";
  ctx.fillText(data.label, x + padX, data.y + 0.5);
}

// ---------------------------------------------------------------------------
// Overlay: territories, ribbons, region and sub-area names

/** Median nearest-neighbour spacing of visible nodes → territory radius. */
function measureTerritoryRadius() {
  const pts: [number, number][] = [];
  graph.forEachNode((_, a) => {
    if (isVisible(a)) pts.push([a.x, a.y]);
  });
  if (pts.length < 2) return;
  const sample = pts.length > 600 ? pts.filter((_, i) => i % Math.ceil(pts.length / 600) === 0) : pts;
  const d: number[] = [];
  for (const p of sample) {
    let best = Infinity;
    for (const q of pts) {
      if (p === q) continue;
      const dd = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2;
      if (dd > 0 && dd < best) best = dd;
    }
    if (isFinite(best)) d.push(Math.sqrt(best));
  }
  d.sort((a, b) => a - b);
  territoryRadius = (d[Math.floor(d.length / 2)] ?? 10) * 1.15;
}

interface LabelBox {
  x0: number;
  y0: number;
  x1: number;
  y1: number;
}

const labelPool: HTMLDivElement[] = [];
/** Measured label sizes; measuring every frame would force a layout per label. */
const labelSize = new Map<string, [number, number]>();

/** Camera-independent overlay geometry (graph coordinates). */
interface OverlayGeometry {
  hulls: Map<number, { x: number; y: number }[]>;
  boxes: Map<number, { x0: number; y0: number; x1: number; y1: number }>;
  subs: Map<number, { gid: number; x: number; y: number; ymin: number; ymax: number; n: number }>;
  traffic: { ga: number; gb: number; w: number }[];
}
let overlayKey = "";
let overlay: OverlayGeometry | null = null;

function overlayGeometry(): OverlayGeometry {
  const key = `${detail}|${hideTests}|${showNoise}|${colorMode}|${positionsVersion}|${[...groupColors.keys()].join(",")}`;
  if (overlay && key === overlayKey) return overlay;
  const points = new Map<number, { x: number; y: number }[]>();
  const boxes = new Map<number, { x0: number; y0: number; x1: number; y1: number }>();
  const subAcc = new Map<number, { gid: number; xs: number; ys: number; ymin: number; ymax: number; n: number }>();
  graph.forEachNode((_, a) => {
    if (!isVisible(a)) return;
    const gid = groupOf(a);
    if (!groupColors.has(gid)) return;
    let list = points.get(gid);
    if (!list) points.set(gid, (list = []));
    list.push({ x: a.x, y: a.y });
    const b = boxes.get(gid) ?? { x0: Infinity, y0: Infinity, x1: -Infinity, y1: -Infinity };
    b.x0 = Math.min(b.x0, a.x); b.x1 = Math.max(b.x1, a.x);
    b.y0 = Math.min(b.y0, a.y); b.y1 = Math.max(b.y1, a.y);
    boxes.set(gid, b);
    if (payload!.subfolders[a.sub]) {
      const s = subAcc.get(a.sub) ?? { gid, xs: 0, ys: 0, ymin: Infinity, ymax: -Infinity, n: 0 };
      s.xs += a.x; s.ys += a.y; s.n++;
      s.ymin = Math.min(s.ymin, a.y); s.ymax = Math.max(s.ymax, a.y);
      subAcc.set(a.sub, s);
    }
  });
  const hulls = new Map<number, { x: number; y: number }[]>();
  for (const [gid, pts] of points) hulls.set(gid, convexHull(pts));
  const subs = new Map<number, { gid: number; x: number; y: number; ymin: number; ymax: number; n: number }>();
  for (const [sub, a] of subAcc) subs.set(sub, { gid: a.gid, x: a.xs / a.n, y: a.ys / a.n, ymin: a.ymin, ymax: a.ymax, n: a.n });

  const pair = new Map<number, number>();
  const N = 1 << 16;
  graph.forEachEdge((_e, ea, _s, _t, sa, ta) => {
    const levelMatch = detail === 0 ? ea.rel === Rel.FileLink : ea.rel !== Rel.FileLink && ea.rel !== Rel.Contains;
    if (!levelMatch || !isVisible(sa) || !isVisible(ta)) return;
    const ga = groupOf(sa), gb = groupOf(ta);
    if (ga === gb || !groupColors.has(ga) || !groupColors.has(gb)) return;
    const key = ga < gb ? ga * N + gb : gb * N + ga;
    pair.set(key, (pair.get(key) ?? 0) + 1);
  });
  const total = [...pair.values()].reduce((a, b) => a + b, 0);
  const floor = Math.max(2, total * 0.01);
  const traffic = [...pair.entries()]
    .filter(([, w]) => w >= floor)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 18)
    .map(([k, w]) => ({ ga: Math.floor(k / N), gb: k % N, w }));

  overlay = { hulls, boxes, subs, traffic };
  overlayKey = key;
  return overlay;
}

function drawOverlay() {
  if (!renderer || !payload) return;
  const toView = (x: number, y: number) => renderer!.graphToViewport({ x, y });
  const origin = toView(0, 0), unit = toView(territoryRadius, 0);
  // Padding around a country's outermost nodes: follows zoom, within taste.
  const radiusPx = Math.max(12, Math.min(36, Math.hypot(unit.x - origin.x, unit.y - origin.y)));
  const geo = overlayGeometry();

  // Only hull corners and a few centres are projected per frame.
  const territories: Territory[] = [];
  const centres = new Map<number, { x: number; y: number }>();
  const graphBox = new Map<number, LabelBox>();
  for (const [gid, hull] of geo.hulls) {
    const pts = hull.map((p) => toView(p.x, p.y));
    territories.push({ color: groupColors.get(gid)!, points: pts });
    const b = geo.boxes.get(gid)!;
    const corners = [toView(b.x0, b.y0), toView(b.x1, b.y1), toView(b.x0, b.y1), toView(b.x1, b.y0)];
    const box = {
      x0: Math.min(...corners.map((c) => c.x)), x1: Math.max(...corners.map((c) => c.x)),
      y0: Math.min(...corners.map((c) => c.y)), y1: Math.max(...corners.map((c) => c.y)),
    };
    graphBox.set(gid, box);
    centres.set(gid, { x: (box.x0 + box.x1) / 2, y: (box.y0 + box.y1) / 2 });
  }

  // Ribbons between countries (big maps, at rest).
  const bundles: Bundle[] = [];
  if (!isSmall() && !focusSet && !highlight) {
    for (const t of geo.traffic) {
      const a = centres.get(t.ga), b = centres.get(t.gb);
      if (a && b) bundles.push({ from: a, to: b, weight: t.w });
    }
  }

  drawRegions(regionCanvas, territories, bundles, {
    dark: theme.dark,
    radius: radiusPx,
    bundleColor: theme.edgeActive,
    opacity: highlight || focusSet ? 0.45 : 1,
  });

  // Names: countries above their territory, then sub-areas at their centre.
  const labels: { text: string; x: number; y: number; color: string; cls: string }[] = [];
  const dim = highlight || focusSet;
  for (const [gid, b] of graphBox) {
    labels.push({ text: groupNames[gid], x: (b.x0 + b.x1) / 2, y: b.y0 - radiusPx - 12, color: groupColors.get(gid)!, cls: "region" });
  }
  if (!isSmall() && labelTier(cameraRatio) === 1 && !dim) {
    for (const [sub, s] of geo.subs) {
      if (s.n < 4) continue;
      // Above the province, like the country names: never on top of its files.
      const c = toView(s.x, s.y);
      const top = Math.min(toView(s.x, s.ymin).y, toView(s.x, s.ymax).y);
      labels.push({ text: payload.subfolders[sub], x: c.x, y: top - 14, color: groupColors.get(s.gid)!, cls: "area" });
    }
  }

  const placed: LabelBox[] = [];
  const w = container.clientWidth, h = container.clientHeight;
  let used = 0;
  for (const l of labels) {
    const el = labelPool[used] ?? (labelPool[used] = labelLayer.appendChild(document.createElement("div")));
    if (el.textContent !== l.text || el.className !== `label ${l.cls}`) {
      el.className = `label ${l.cls}`;
      el.textContent = l.text;
      // Folder names are code, not Turkish: "APP/VIEWS", never "APP/VİEWS".
      el.lang = "en";
    }
    el.style.color = l.color;
    const key = `${l.cls}|${l.text}`;
    let size = labelSize.get(key);
    if (!size) labelSize.set(key, (size = [el.offsetWidth, el.offsetHeight]));
    const [bw, bh] = size;
    // Keep inside the viewport, then avoid collisions (first come first served:
    // countries before sub-areas).
    // Names travel with their region; off-screen means hidden, not pinned.
    const x = l.x, y = l.y;
    if (x < -bw || x > w + bw || y < -bh || y > h + bh) {
      el.style.visibility = "hidden";
      used++;
      continue;
    }
    const box = { x0: x - bw / 2 - 4, y0: y - bh / 2 - 2, x1: x + bw / 2 + 4, y1: y + bh / 2 + 2 };
    const hit = placed.some((b) => box.x0 < b.x1 && box.x1 > b.x0 && box.y0 < b.y1 && box.y1 > b.y0);
    el.style.visibility = hit ? "hidden" : "visible";
    el.style.opacity = dim ? "0.3" : "1";
    el.style.transform = `translate(${x - bw / 2}px, ${y - bh / 2}px)`;
    if (!hit) placed.push(box);
    used++;
  }
  for (let i = used; i < labelPool.length; i++) labelPool[i].style.visibility = "hidden";
}

// ---------------------------------------------------------------------------
// Commands (called from Swift)

function select(id: string | null, opts: { notify: boolean; fly: boolean }) {
  if (id && !graph.hasNode(id)) id = null;
  if (id) {
    // Reveal first, so the focus is computed with the edges of the level
    // the node is shown at.
    const attrs = graph.getNodeAttributes(id);
    if (attrs.noise && !showNoise) setNoise(true);
    raiseDetail(requiredDetail(attrs.kind));
  }
  selected = id;
  hovered = null;
  highlight = null;
  focusKey = undefined as unknown as null;
  recomputeFocus();
  if (opts.notify) post({ type: "select", id });
  if (id && opts.fly) frameNeighbourhood(id);
}

/**
 * Brings a node and the neighbours drawn at this level into view (searching
 * `kulupSohbetiAc` should show who calls it and what it calls, not a lone
 * dot with lines leaving the screen). Very wide neighbourhoods fall back to
 * the node itself.
 */
function frameNeighbourhood(id: string) {
  if (!renderer) return;
  const attrs = graph.getNodeAttributes(id);
  if (!isVisible(attrs)) {
    if (attrs.noise && !showNoise) setNoise(true);
    raiseDetail(requiredDetail(attrs.kind));
  }
  const ids = focusSet && focusSet.size <= 60 ? [...focusSet] : [id];
  if (ids.length === 1) return fly(id, attrs.kind === Kind.File ? 0.22 : 0.07);
  fitTo(ids);
}

function fly(id: string, ratio: number) {
  if (!renderer) return;
  const attrs = graph.getNodeAttributes(id);
  if (!isVisible(attrs)) {
    // A searched node is revealed even at a coarser level / when hidden as noise.
    if (attrs.noise && !showNoise) setNoise(true);
    raiseDetail(requiredDetail(attrs.kind));
  }
  const d = renderer.getNodeDisplayData(id);
  if (!d) return;
  renderer.getCamera().animate({ x: d.x, y: d.y, ratio }, { duration: duration(), easing: "cubicInOut" });
}

function showPath(nodeIds: string[]) {
  if (!renderer) return;
  const nodes = new Set(nodeIds.filter((n) => graph.hasNode(n)));
  const edges = new Set<string>();
  for (let i = 0; i + 1 < nodeIds.length; i++) {
    const a = nodeIds[i], b = nodeIds[i + 1];
    if (!graph.hasNode(a) || !graph.hasNode(b)) continue;
    graph.edges(a, b).concat(graph.edges(b, a)).forEach((e) => edges.add(e));
  }
  applyHighlight(nodes, edges);
}

/** Highlights a set of nodes and every edge between two of them. */
function highlightSet(ids: string[]) {
  if (!renderer) return;
  const nodes = new Set(ids.filter((n) => graph.hasNode(n)));
  const edges = new Set<string>();
  for (const n of nodes)
    graph.forEachOutEdge(n, (e, _a, _s, t) => {
      if (nodes.has(t)) edges.add(e);
    });
  applyHighlight(nodes, edges);
}

function applyHighlight(nodes: Set<string>, edges: Set<string>) {
  if (nodes.size === 0) return;
  highlight = { nodes, edges };
  raiseDetail(Math.max(...[...nodes].map((n) => requiredDetail(graph.getNodeAttributes(n).kind))) as Detail);
  renderer!.refresh({ skipIndexation: true });
  fitTo([...nodes]);
}

function requiredDetail(kind: Kind): Detail {
  if (kind === Kind.File) return 0;
  if (kind === Kind.Function || kind === Kind.Method || kind === Kind.Type) return 1;
  return 2;
}

/** Shows more detail when needed, and tells Swift so the picker agrees. */
function raiseDetail(level: Detail) {
  if (level <= detail) return;
  detail = level;
  visibilityChanged();
  post({ type: "detail", value: level });
}

function setNoise(v: boolean) {
  showNoise = v;
  visibilityChanged();
  post({ type: "noise", value: v });
}

function visibilityChanged() {
  countVisible();
  measureTerritoryRadius();
  renderer?.refresh();
}

function bbox(ids: string[]) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const id of ids) {
    const a = graph.getNodeAttributes(id);
    minX = Math.min(minX, a.x); maxX = Math.max(maxX, a.x);
    minY = Math.min(minY, a.y); maxY = Math.max(maxY, a.y);
  }
  return { minX, minY, maxX, maxY };
}

/**
 * Frames the *visible* nodes (hidden symbols must not skew the view) with
 * room for labels on the right and region names on top.
 */
function fitVisible(animate: boolean) {
  if (!renderer) return;
  const ids: string[] = [];
  graph.forEachNode((id, a) => {
    if (isVisible(a)) ids.push(id);
  });
  if (ids.length === 0) return;
  const b = bbox(ids);
  // A tiny project must not be blown up to fill the screen: frame at least
  // MIN_SPAN map units around it so dots keep a sensible size.
  const MIN_SPAN = 600;
  for (const [lo, hi] of [["minX", "maxX"], ["minY", "maxY"]] as const) {
    const span = b[hi] - b[lo];
    if (span < MIN_SPAN) {
      const grow = (MIN_SPAN - span) / 2;
      b[lo] -= grow;
      b[hi] += grow;
    }
  }
  const spanX = Math.max(b.maxX - b.minX, 1), spanY = Math.max(b.maxY - b.minY, 1);
  // Labels extend ~140 px to the right on small maps; names sit above.
  const vw = Math.max(container.clientWidth, 300), vh = Math.max(container.clientHeight, 300);
  const padRight = isSmall() ? (spanX / vw) * 150 : (spanX / vw) * 30;
  const padTop = (spanY / vh) * 50;
  const padBottom = (spanY / vh) * 60; // hint strip / status pill
  renderer.setCustomBBox({ x: [b.minX - spanX * 0.04, b.maxX + padRight], y: [b.minY - padBottom, b.maxY + padTop] });
  renderer.refresh();
  const cam = renderer.getCamera();
  if (animate) cam.animatedReset({ duration: duration() });
  else cam.setState({ x: 0.5, y: 0.5, ratio: 1, angle: 0 });
}

function fitTo(ids: string[]) {
  if (!renderer || ids.length === 0) return;
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const id of ids) {
    const d = renderer.getNodeDisplayData(id);
    if (!d) continue;
    minX = Math.min(minX, d.x); maxX = Math.max(maxX, d.x);
    minY = Math.min(minY, d.y); maxY = Math.max(maxY, d.y);
  }
  if (!isFinite(minX)) return;
  const span = Math.max(maxX - minX, maxY - minY);
  renderer.getCamera().animate(
    { x: (minX + maxX) / 2, y: (minY + maxY) / 2, ratio: Math.min(1.1, Math.max(0.03, span * 1.6)) },
    { duration: duration(), easing: "cubicInOut" },
  );
}

function recolor() {
  assignColors();
  renderer?.setSetting("labelColor", { color: theme.label });
  renderer?.setSetting("defaultEdgeColor", theme.edge);
  renderer?.refresh();
}

const api = {
  load: (url: string, keep = false, sel: string | null = null) =>
    load(url, keep, sel).catch((e) => {
      // Never leave the previous project's regions and names on screen.
      setStatus(null);
      const ctx = regionCanvas.getContext("2d");
      ctx?.clearRect(0, 0, regionCanvas.width, regionCanvas.height);
      for (const el of labelPool) el.style.visibility = "hidden";
      post({ type: "error", message: String(e?.message ?? e) });
    }),
  select: (id: string | null) => select(id, { notify: false, fly: true }),
  focus: (id: string) => fly(id, 0.22),
  showPath,
  highlightSet,
  clearHighlight: () => {
    highlight = null;
    renderer?.refresh({ skipIndexation: true });
  },
  setDetail: (d: Detail) => {
    if (d === detail) return;
    detail = d;
    visibilityChanged();
    focusKey = undefined as unknown as null;
    recomputeFocus();
    fitVisible(true);
  },
  setColorMode: (m: ColorMode) => {
    colorMode = m;
    recolor();
  },
  setHideTests: (v: boolean) => {
    hideTests = v;
    visibilityChanged();
    fitVisible(true);
  },
  setShowNoise: (v: boolean) => {
    showNoise = v;
    visibilityChanged();
    fitVisible(true);
  },
  /** Fly to a coloured area (legend click). */
  focusGroup: (gid: number) => {
    const ids: string[] = [];
    graph.forEachNode((id, a) => {
      if (isVisible(a) && groupOf(a) === gid) ids.push(id);
    });
    fitTo(ids);
  },
  fit: () => fitVisible(true),
  zoom: (factor: number) => {
    const cam = renderer?.getCamera();
    if (cam) cam.animate({ ratio: cam.ratio / factor }, { duration: duration() / 2 });
  },
  relayout: () => {
    if (!payload) return;
    payload.positions = null;
    void runLayout();
  },
};
(window as any).mapoMap = api;

darkQuery.addEventListener("change", (e) => {
  theme = e.matches ? DARK : LIGHT;
  document.documentElement.dataset.theme = theme.dark ? "dark" : "light";
  recolor();
});
document.documentElement.dataset.theme = theme.dark ? "dark" : "light";

addEventListener("keydown", (e) => {
  if (e.key === "Escape") {
    if (highlight) api.clearHighlight();
    else select(null, { notify: true, fly: false });
  }
});

post({ type: "ready" });

// ---------------------------------------------------------------------------
// Helpers

/** In map units (see itemSizesReference). Files dominate; symbols orbit. */
function nodeSize(kind: Kind, degree: number): number {
  const d = Math.sqrt(Math.max(0, degree));
  switch (kind) {
    case Kind.File:
      return 7 + Math.min(16, d * 1.6);
    case Kind.Type:
      return 3.4 + Math.min(1.6, d * 0.3);
    case Kind.Function:
    case Kind.Method:
      return 2.8 + Math.min(1.6, d * 0.3);
    default:
      return 2.2 + Math.min(1, d * 0.2);
  }
}

function setStatus(text: string | null) {
  status.textContent = text ?? "";
  status.hidden = !text;
}

function round(v: number) {
  return Math.round(v * 100) / 100;
}

function mulberry32(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
