// Territories and region bundles, drawn on a 2D canvas *under* the WebGL
// graph. This is the "mapo" layer: each folder becomes a soft country,
// and heavy traffic between countries becomes one ribbon instead of a fog
// of individual edges.

export interface Territory {
  color: string;
  /** Viewport-space points (already projected). */
  points: { x: number; y: number }[];
}

export interface Bundle {
  from: { x: number; y: number };
  to: { x: number; y: number };
  weight: number;
}

export interface RegionStyle {
  dark: boolean;
  /** Territory radius around each node, in CSS pixels. */
  radius: number;
  bundleColor: string;
  /** 0…1, fades the whole layer (e.g. while a node is focused). */
  opacity: number;
}

let scratch: HTMLCanvasElement | null = null;
/** Interior mask, so the interior is thinned in one operation (painting a
 * stroked+filled path with partial alpha would hit the overlap twice). */
let mask: HTMLCanvasElement | null = null;

export function drawRegions(canvas: HTMLCanvasElement, territories: Territory[], bundles: Bundle[], style: RegionStyle) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext("2d")!;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  if (style.opacity <= 0) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

  scratch ??= document.createElement("canvas");
  if (scratch.width !== canvas.width || scratch.height !== canvas.height) {
    scratch.width = canvas.width;
    scratch.height = canvas.height;
  }
  const s = scratch.getContext("2d")!;
  mask ??= document.createElement("canvas");
  if (mask.width !== canvas.width || mask.height !== canvas.height) {
    mask.width = canvas.width;
    mask.height = canvas.height;
  }
  const m = mask.getContext("2d")!;

  const r = style.radius;
  const fillAlpha = (style.dark ? 0.085 : 0.11) * style.opacity;
  const edgeAlpha = (style.dark ? 0.28 : 0.32) * style.opacity;

  for (const t of territories) {
    if (t.points.length === 0) continue;
    const hull = convexHull(t.points);
    // Work only inside this territory's on-screen box (not the whole canvas).
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (const p of hull) {
      x0 = Math.min(x0, p.x); y0 = Math.min(y0, p.y);
      x1 = Math.max(x1, p.x); y1 = Math.max(y1, p.y);
    }
    const pad = r + 4;
    const bx0 = Math.max(0, Math.floor(x0 - pad)), by0 = Math.max(0, Math.floor(y0 - pad));
    const bx1 = Math.min(w, Math.ceil(x1 + pad)), by1 = Math.min(h, Math.ceil(y1 + pad));
    if (bx1 <= bx0 || by1 <= by0) continue;
    const [px, py, pw, ph] = [bx0 * dpr, by0 * dpr, (bx1 - bx0) * dpr, (by1 - by0) * dpr];

    s.setTransform(1, 0, 0, 1, 0, 0);
    s.globalCompositeOperation = "source-over";
    s.globalAlpha = 1;
    s.clearRect(px, py, pw, ph);
    s.setTransform(dpr, 0, 0, dpr, 0, 0);
    // 1. Opaque shape slightly larger than the country = outline + interior.
    s.fillStyle = t.color;
    s.strokeStyle = t.color;
    grown(s, hull, r + 1.25);
    // 2. Thin the interior so that, composited at edgeAlpha, it lands at
    //    fillAlpha while the 1.25 px rim keeps edgeAlpha.
    m.setTransform(1, 0, 0, 1, 0, 0);
    m.clearRect(px, py, pw, ph);
    m.setTransform(dpr, 0, 0, dpr, 0, 0);
    m.fillStyle = "#000";
    m.strokeStyle = "#000";
    grown(m, hull, r);
    s.setTransform(1, 0, 0, 1, 0, 0);
    s.globalCompositeOperation = "destination-out";
    s.globalAlpha = 1 - fillAlpha / edgeAlpha;
    s.drawImage(mask, px, py, pw, ph, px, py, pw, ph);
    s.setTransform(dpr, 0, 0, dpr, 0, 0);
    // 3. Composite just this box.
    ctx.globalAlpha = edgeAlpha;
    ctx.drawImage(scratch, px, py, pw, ph, bx0, by0, bx1 - bx0, by1 - by0);
  }
  ctx.globalAlpha = 1;

  // Bundles: gentle arcs between territory centres, width by traffic.
  const maxW = Math.max(1, ...bundles.map((b) => b.weight));
  ctx.lineCap = "round";
  for (const b of bundles) {
    const t = Math.log2(1 + b.weight) / Math.log2(1 + maxW);
    ctx.strokeStyle = style.bundleColor;
    ctx.globalAlpha = (0.18 + 0.32 * t) * style.opacity;
    ctx.lineWidth = 1.5 + 7 * t;
    const mx = (b.from.x + b.to.x) / 2, my = (b.from.y + b.to.y) / 2;
    const dx = b.to.x - b.from.x, dy = b.to.y - b.from.y;
    const bend = 0.12;
    ctx.beginPath();
    ctx.moveTo(b.from.x, b.from.y);
    ctx.quadraticCurveTo(mx - dy * bend, my + dx * bend, b.to.x, b.to.y);
    ctx.stroke();
  }
  ctx.globalAlpha = 1;
}

type Pt = { x: number; y: number };

/** Fills the polygon grown by `r` (round joins), works for 1–2 points too. */
function grown(ctx: CanvasRenderingContext2D, hull: Pt[], r: number) {
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  ctx.lineWidth = r * 2;
  ctx.beginPath();
  ctx.moveTo(hull[0].x, hull[0].y);
  for (let i = 1; i < hull.length; i++) ctx.lineTo(hull[i].x, hull[i].y);
  if (hull.length === 1) ctx.lineTo(hull[0].x + 0.01, hull[0].y);
  ctx.closePath();
  ctx.stroke();
  if (hull.length > 2) ctx.fill();
}

/** Andrew's monotone chain. */
export function convexHull(points: Pt[]): Pt[] {
  if (points.length <= 2) return points.slice();
  const p = points.slice().sort((a, b) => (a.x === b.x ? a.y - b.y : a.x - b.x));
  const cross = (o: Pt, a: Pt, b: Pt) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  const lower: Pt[] = [];
  for (const q of p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], q) <= 0) lower.pop();
    lower.push(q);
  }
  const upper: Pt[] = [];
  for (let i = p.length - 1; i >= 0; i--) {
    const q = p[i];
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], q) <= 0) upper.pop();
    upper.push(q);
  }
  upper.pop();
  lower.pop();
  return lower.concat(upper);
}
