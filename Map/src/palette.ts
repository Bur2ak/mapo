// Cluster palette (docs/TASARIM.md §Renk): 12 hues evenly spaced in OKLCH at
// constant lightness/chroma so no cluster looks more "important" than another.
// Beyond 12, hues repeat with lightness shifted ±0.06.

export interface Theme {
  dark: boolean;
  canvas: string;
  label: string;
  labelMuted: string;
  edge: string;
  edgeActive: string;
  accent: string;
  hoverBox: string;
  hoverBorder: string;
}

export const LIGHT: Theme = {
  dark: false,
  canvas: "#F4F5F7",
  label: "#1B2230",
  labelMuted: "#6B7385",
  // Opaque, pre-blended against the canvas: WebGL alpha over a transparent
  // web view composites additively and turns faint edges bright.
  edge: "#DCDFE5",
  edgeActive: "#7A8191",
  accent: "#C9821E",
  hoverBox: "rgba(255,255,255,0.96)",
  hoverBorder: "rgba(27,34,48,0.12)",
};

export const DARK: Theme = {
  dark: true,
  canvas: "#0E1015",
  label: "#E6ECF7",
  labelMuted: "#7D869A",
  edge: "#1F232C",
  edgeActive: "#8C95A8",
  accent: "#F0AE47",
  hoverBox: "rgba(23,26,33,0.96)",
  hoverBorder: "rgba(230,236,247,0.14)",
};

const HUES = 12;

export function clusterColor(index: number, dark: boolean): string {
  const hue = ((index % HUES) * 360) / HUES + 18; // start off pure red
  const round = Math.floor(index / HUES);
  const shift = round === 0 ? 0 : (round % 2 === 1 ? -0.06 : 0.06);
  const L = (dark ? 0.74 : 0.6) + shift;
  const C = dark ? 0.12 : 0.14;
  return oklchToHex(L, C, hue);
}

/** Muted version for dimmed nodes, blended toward the canvas. */
export function mix(hexA: string, hexB: string, t: number): string {
  const a = hexToRgb(hexA), b = hexToRgb(hexB);
  return rgbToHex(a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t);
}

// --- colour math -----------------------------------------------------------

function oklchToHex(L: number, C: number, hDeg: number): string {
  const h = (hDeg * Math.PI) / 180;
  const a = C * Math.cos(h), b = C * Math.sin(h);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const bl = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  return rgbToHex(gamma(r) * 255, gamma(g) * 255, gamma(bl) * 255);
}

function gamma(x: number): number {
  const v = x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055;
  return Math.min(1, Math.max(0, v));
}

function hexToRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1, 7), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function rgbToHex(r: number, g: number, b: number): string {
  const h = (v: number) => Math.round(Math.min(255, Math.max(0, v))).toString(16).padStart(2, "0");
  return `#${h(r)}${h(g)}${h(b)}`;
}
