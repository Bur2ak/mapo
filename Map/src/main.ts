import Graph from "graphology";
import FA2Layout from "graphology-layout-forceatlas2/worker";
import forceAtlas2 from "graphology-layout-forceatlas2";
import Sigma from "sigma";
import { createNodeBorderProgram } from "@sigma/node-border";
import type { NodeDisplayData, PartialButFor } from "sigma/types";
import type { Settings } from "sigma/settings";

import { clusterColor, DARK, LIGHT, mix, type Theme } from "./palette";
import { Kind, Rel, type ColorMode, type Detail, type Outgoing, type Payload } from "./types";

// ---------------------------------------------------------------------------
// Bridge

function post(msg: Outgoing) {
  const h = (window as any).webkit?.messageHandlers?.atlas;
  if (h) h.postMessage(msg);
  else console.debug("[atlas]", msg);
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
  test: boolean;
  baseColor: string;
  color: string;
}

interface EdgeAttrs {
  rel: Rel;
  weight: number;
}

const container = document.getElementById("map")!;
const clusterLayer = document.getElementById("clusters")!;
const status = document.getElementById("status")!;

const darkQuery = matchMedia("(prefers-color-scheme: dark)");
const motionQuery = matchMedia("(prefers-reduced-motion: reduce)");

let theme: Theme = darkQuery.matches ? DARK : LIGHT;
let graph = new Graph<NodeAttrs, EdgeAttrs>({ type: "directed", multi: true, allowSelfLoops: false });
let renderer: Sigma<NodeAttrs, EdgeAttrs> | null = null;
let layout: FA2Layout<NodeAttrs, EdgeAttrs> | null = null;
let payload: Payload | null = null;
/** graphify found more than one community (cluster step ran). */
let hasCommunities = false;

let detail: Detail = 0;
let colorMode: ColorMode = "folder";
let hideTests = false;

let hovered: string | null = null;
let selected: string | null = null;
/** Path / impact highlight: nodes + edges drawn in accent, the rest dimmed. */
let highlight: { nodes: Set<string>; edges: Set<string> } | null = null;
/** Neighbourhood of hovered/selected, cached per focus change. */
let focusSet: Set<string> | null = null;

/** Above this camera ratio, node labels give way to cluster labels. */
const LABEL_RATIO = 0.5;
let cameraRatio = 1;

const duration = () => (motionQuery.matches ? 0 : 450);

// ---------------------------------------------------------------------------
// Loading

async function load(url: string) {
  setStatus("Harita yükleniyor…");
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Harita verisi alınamadı (${res.status})`);
  payload = (await res.json()) as Payload;
  build(payload);
}

function build(p: Payload) {
  layout?.kill();
  layout = null;
  renderer?.kill();
  renderer = null;
  hovered = selected = null;
  highlight = null;
  focusSet = null;

  const g = new Graph<NodeAttrs, EdgeAttrs>({ type: "directed", multi: true, allowSelfLoops: false });
  const n = p.nodes.id.length;
  hasCommunities = new Set(p.nodes.community).size > 1;
  const useCommunity = colorMode === "community" && hasCommunities;

  for (let i = 0; i < n; i++) {
    const kind = p.nodes.kind[i];
    const color = groupColor(useCommunity ? p.nodes.community[i] : p.nodes.folder[i], useCommunity);
    g.addNode(p.nodes.id[i], {
      x: 0,
      y: 0,
      size: nodeSize(kind, p.nodes.degree[i]),
      label: p.nodes.label[i],
      kind,
      community: p.nodes.community[i],
      folder: p.nodes.folder[i],
      test: p.nodes.test[i] === 1,
      baseColor: color,
      color,
    });
  }
  for (let i = 0; i < p.edges.s.length; i++) {
    const s = p.nodes.id[p.edges.s[i]], t = p.nodes.id[p.edges.t[i]];
    if (s === t) continue;
    const rel = p.edges.r[i];
    const si = p.edges.s[i], ti = p.edges.t[i];
    // Edges inside a folder / community pull harder, so areas of the
    // codebase settle into visible regions instead of one ball.
    const sameFolder = p.nodes.folder[si] === p.nodes.folder[ti];
    const sameCommunity = p.nodes.community[si] === p.nodes.community[ti];
    const base = rel === Rel.Contains ? 3 : rel === Rel.Call ? 1 : 0.5;
    g.addEdge(s, t, { rel, weight: base * (sameFolder ? 3 : 0.4) * (sameCommunity ? 2 : 1) });
  }
  graph = g;

  const missing = placeNodes(p);
  createRenderer();
  post({ type: "loaded", nodes: g.order, edges: g.size });

  if (missing > 0) runLayout(missing === g.order ? "full" : "refine");
  else setStatus(null);
}

/** Restores cached positions; seeds the rest. Returns how many were missing. */
function placeNodes(p: Payload): number {
  const cached = p.positions ?? {};
  let missing = 0;
  // Seed by folder: the regions people recognise.
  const groupOf = (attrs: NodeAttrs) => attrs.folder;
  const groups = new Map<number, number>();
  graph.forEachNode((_, a) => groups.set(groupOf(a), (groups.get(groupOf(a)) ?? 0) + 1));
  const ordered = [...groups.keys()].sort((a, b) => (groups.get(b)! - groups.get(a)!));
  const radius = Math.sqrt(graph.order) * 12;
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
    // New node next to an already placed neighbour if any, else its group.
    let placed = false;
    for (const nb of graph.neighbors(id)) {
      const pc = cached[nb];
      if (pc) {
        a.x = pc[0] + (rand() - 0.5) * 8;
        a.y = pc[1] + (rand() - 0.5) * 8;
        placed = true;
        break;
      }
    }
    if (!placed) {
      const [cx, cy] = center.get(groupOf(a)) ?? [0, 0];
      const spread = Math.sqrt(groups.get(groupOf(a)) ?? 1) * 6;
      a.x = cx + (rand() - 0.5) * spread;
      a.y = cy + (rand() - 0.5) * spread;
    }
  });
  return missing;
}

function runLayout(mode: "full" | "refine") {
  const n = graph.order;
  const inferred = forceAtlas2.inferSettings(graph);
  layout = new FA2Layout(graph, {
    settings: {
      ...inferred,
      barnesHutOptimize: n > 1500,
      gravity: 0.6,
      scalingRatio: 4,
      strongGravityMode: false,
      adjustSizes: false,
      linLogMode: true,
      outboundAttractionDistribution: false,
      slowDown: mode === "full" ? 2 : 6,
    },
    getEdgeWeight: "weight",
  });
  const total = mode === "full" ? Math.min(9000, 2000 + n * 1.2) : Math.min(3000, 800 + n * 0.3);
  const started = performance.now();
  setStatus("Harita yerleşiyor…");
  layout.start();

  const tick = () => {
    if (!layout) return;
    const value = Math.min(1, (performance.now() - started) / total);
    post({ type: "layoutProgress", value });
    if (value < 1) {
      // Timer, not rAF: WebKit pauses animation frames for occluded windows,
      // and the layout must still finish (and be saved) in the background.
      setTimeout(tick, 200);
      return;
    }
    layout.stop();
    layout.kill();
    layout = null;
    setStatus(null);
    updateClusterLabels(true);
    const positions: Record<string, [number, number]> = {};
    graph.forEachNode((id, a) => (positions[id] = [round(a.x), round(a.y)]));
    post({ type: "layout", positions });
  };
  setTimeout(tick, 200);
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
    maxCameraRatio: 6,
    stagePadding: 40,
    nodeProgramClasses: { bordered: BorderedProgram },
    defaultDrawNodeHover: drawHover,
    nodeReducer,
    edgeReducer,
  });

  renderer.on("enterNode", ({ node }) => {
    hovered = node;
    recomputeFocus();
    container.style.cursor = "pointer";
  });
  renderer.on("leaveNode", () => {
    hovered = null;
    recomputeFocus();
    container.style.cursor = "";
  });
  renderer.on("clickNode", ({ node }) => select(node, { notify: true, fly: false }));
  renderer.on("doubleClickNode", (e) => {
    e.preventSigmaDefault();
    post({ type: "open", id: e.node });
  });
  renderer.on("clickStage", () => select(null, { notify: true, fly: false }));
  renderer.getCamera().on("updated", (state) => {
    const crossed = (cameraRatio > LABEL_RATIO) !== (state.ratio > LABEL_RATIO);
    cameraRatio = state.ratio;
    if (crossed) renderer?.refresh({ skipIndexation: true });
    updateClusterLabels(false);
  });
  updateClusterLabels(true);
}

function nodeReducer(id: string, a: NodeAttrs): Partial<NodeDisplayData> & Record<string, unknown> {
  const res: Partial<NodeDisplayData> & Record<string, unknown> = { ...a };
  if (!isVisible(a)) {
    res.hidden = true;
    return res;
  }
  const lit = highlight ? highlight.nodes.has(id) : focusSet ? focusSet.has(id) : true;
  // Semantic zoom: far out the cluster names speak; node names appear as
  // you get closer (forced labels for focus/selection still show).
  if (!highlight && !focusSet && cameraRatio > LABEL_RATIO) res.label = "";
  if (!lit) {
    res.color = mix(a.baseColor, theme.canvas, 0.88);
    res.size = Math.max(1.5, a.size * 0.55);
    res.label = "";
    res.zIndex = 0;
  } else {
    res.zIndex = 1;
    if (highlight || (focusSet && (id === hovered || id === selected))) res.forceLabel = true;
  }
  if (id === selected) {
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
  const res: Record<string, unknown> = { ...a, size: 0.6 };
  const [s, t] = graph.extremities(id);
  if (!isVisible(graph.getNodeAttributes(s)) || !isVisible(graph.getNodeAttributes(t))) {
    res.hidden = true;
    return res;
  }
  if (highlight) {
    if (highlight.edges.has(id)) {
      res.color = theme.accent;
      res.size = 2.4;
      res.zIndex = 2;
    } else res.hidden = true;
    return res;
  }
  const focus = hovered ?? selected;
  if (focus) {
    if (s === focus || t === focus) {
      res.color = theme.edgeActive;
      res.size = 1.2;
      res.zIndex = 1;
    } else res.hidden = true;
    return res;
  }
  // Resting state: containment edges are structure, not information.
  if (a.rel === Rel.Contains) res.hidden = true;
  res.color = theme.edge;
  return res;
}

function isVisible(a: NodeAttrs): boolean {
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

function recomputeFocus() {
  const focus = hovered ?? selected;
  if (!focus || !graph.hasNode(focus)) focusSet = null;
  else {
    focusSet = new Set(graph.neighbors(focus));
    focusSet.add(focus);
  }
  renderer?.refresh({ skipIndexation: true });
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
// Cluster labels (HTML overlay, visible when zoomed out)

let clusterEls: { el: HTMLDivElement; x: number; y: number; count: number }[] = [];

function updateClusterLabels(rebuild: boolean) {
  if (!renderer || !payload) return;
  const useCommunity = colorMode === "community" && hasCommunities;
  const names = useCommunity ? payload.communities : payload.folders;
  if (rebuild) {
    clusterLayer.replaceChildren();
    clusterEls = [];
    const acc = new Map<number, { x: number; y: number; n: number }>();
    graph.forEachNode((_, a) => {
      if (!isVisible(a)) return;
      const gid = useCommunity ? a.community : a.folder;
      const s = acc.get(gid) ?? { x: 0, y: 0, n: 0 };
      s.x += a.x; s.y += a.y; s.n++;
      acc.set(gid, s);
    });
    const minCount = Math.max(6, graph.order / 300);
    const ranked = [...acc.entries()]
      .filter(([gid, s]) => s.n >= minCount && names[gid])
      .sort((a, b) => b[1].n - a[1].n)
      .slice(0, 24);
    for (const [gid, s] of ranked) {
      const el = document.createElement("div");
      el.className = "cluster";
      el.textContent = names[gid];
      el.style.color = groupColor(gid, useCommunity);
      clusterLayer.appendChild(el);
      clusterEls.push({ el, x: s.x / s.n, y: s.y / s.n, count: s.n });
    }
  }
  const ratio = renderer.getCamera().ratio;
  const opacity = Math.max(0, Math.min(1, (ratio - LABEL_RATIO * 0.8) / (LABEL_RATIO * 0.6)));
  clusterLayer.style.opacity = String(highlight || focusSet ? opacity * 0.2 : opacity);
  if (opacity === 0) return;
  // Biggest clusters claim their spot first; a label that would overlap an
  // already placed one is hidden rather than stacked.
  const placed: { x0: number; y0: number; x1: number; y1: number }[] = [];
  for (const c of clusterEls) {
    const p = renderer.graphToViewport({ x: c.x, y: c.y });
    const w = c.el.offsetWidth || c.el.textContent!.length * 9, h = 20;
    const box = { x0: p.x - w / 2 - 6, y0: p.y - h / 2 - 3, x1: p.x + w / 2 + 6, y1: p.y + h / 2 + 3 };
    const hit = placed.some((b) => box.x0 < b.x1 && box.x1 > b.x0 && box.y0 < b.y1 && box.y1 > b.y0);
    c.el.style.visibility = hit ? "hidden" : "visible";
    if (!hit) placed.push(box);
    c.el.style.transform = `translate(${p.x}px, ${p.y}px) translate(-50%, -50%)`;
  }
}

// ---------------------------------------------------------------------------
// Commands (called from Swift)

function select(id: string | null, opts: { notify: boolean; fly: boolean }) {
  if (id && !graph.hasNode(id)) id = null;
  selected = id;
  highlight = null;
  recomputeFocus();
  if (opts.notify) post({ type: "select", id });
  if (id && opts.fly) fly(id, 0.22);
}

function fly(id: string, ratio: number) {
  if (!renderer) return;
  const attrs = graph.getNodeAttributes(id);
  if (!isVisible(attrs)) {
    // Searching a symbol reveals it even at a coarser detail level.
    raiseDetail(requiredDetail(attrs.kind));
  }
  const d = renderer.getNodeDisplayData(id);
  if (!d) return;
  renderer.getCamera().animate({ x: d.x, y: d.y, ratio }, { duration: duration(), easing: "cubicInOut" });
}

function showPath(nodeIds: string[], edgeKeys?: string[]) {
  if (!renderer) return;
  const nodes = new Set(nodeIds.filter((n) => graph.hasNode(n)));
  const edges = new Set<string>();
  if (edgeKeys) edgeKeys.forEach((e) => graph.hasEdge(e) && edges.add(e));
  else
    for (let i = 0; i + 1 < nodeIds.length; i++) {
      const a = nodeIds[i], b = nodeIds[i + 1];
      graph.edges(a, b).concat(graph.edges(b, a)).forEach((e) => edges.add(e));
    }
  highlight = { nodes, edges };
  raiseDetail(Math.max(...[...nodes].map((n) => requiredDetail(graph.getNodeAttributes(n).kind))) as Detail);
  renderer.refresh({ skipIndexation: true });
  fitTo([...nodes]);
  updateClusterLabels(false);
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
  highlight = { nodes, edges };
  raiseDetail(Math.max(...[...nodes].map((n) => requiredDetail(graph.getNodeAttributes(n).kind))) as Detail);
  renderer.refresh({ skipIndexation: true });
  fitTo([...nodes]);
  updateClusterLabels(false);
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
  renderer?.refresh();
  updateClusterLabels(true);
  post({ type: "detail", value: level });
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
    { x: (minX + maxX) / 2, y: (minY + maxY) / 2, ratio: Math.min(1.2, Math.max(0.08, span * 1.4)) },
    { duration: duration(), easing: "cubicInOut" },
  );
}

function recolor() {
  if (!payload) return;
  const useCommunity = colorMode === "community" && hasCommunities;
  graph.forEachNode((_, a) => {
    a.baseColor = groupColor(useCommunity ? a.community : a.folder, useCommunity);
    a.color = a.baseColor;
  });
  renderer?.setSetting("labelColor", { color: theme.label });
  renderer?.setSetting("defaultEdgeColor", theme.edge);
  renderer?.refresh();
  updateClusterLabels(true);
}

const api = {
  load: (url: string) => load(url).catch((e) => post({ type: "error", message: String(e?.message ?? e) })),
  select: (id: string | null) => select(id, { notify: false, fly: true }),
  focus: (id: string) => fly(id, 0.22),
  showPath,
  highlightSet,
  clearHighlight: () => {
    highlight = null;
    renderer?.refresh({ skipIndexation: true });
    updateClusterLabels(false);
  },
  setDetail: (d: Detail) => {
    detail = d;
    renderer?.refresh();
    updateClusterLabels(true);
  },
  setColorMode: (m: ColorMode) => {
    colorMode = m;
    recolor();
  },
  setHideTests: (v: boolean) => {
    hideTests = v;
    renderer?.refresh();
    updateClusterLabels(true);
  },
  fit: () => renderer?.getCamera().animatedReset({ duration: duration() }),
  zoom: (factor: number) => {
    const cam = renderer?.getCamera();
    if (cam) cam.animate({ ratio: cam.ratio / factor }, { duration: duration() / 2 });
  },
  relayout: () => {
    if (!payload) return;
    layout?.kill();
    payload.positions = null;
    placeNodes(payload);
    renderer?.refresh();
    runLayout("full");
  },
};
(window as any).atlasMap = api;

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

function groupColor(index: number, community: boolean): string {
  // Folder mode reuses the same hue wheel; index offset keeps the two modes
  // visually distinct when toggled.
  return clusterColor(community ? index : index + 5, theme.dark);
}

function nodeSize(kind: Kind, degree: number): number {
  const d = Math.sqrt(Math.max(0, degree));
  switch (kind) {
    case Kind.File:
      return 4 + Math.min(7, d * 0.9);
    case Kind.Type:
      return 3.2 + Math.min(5, d * 0.7);
    case Kind.Function:
    case Kind.Method:
      return 2.4 + Math.min(5, d * 0.6);
    default:
      return 1.8 + Math.min(3, d * 0.4);
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
