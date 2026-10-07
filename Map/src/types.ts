// Wire format shared with Swift (App/Map/MapPayload.swift). Columnar to keep
// 10k-node payloads small. Bump `version` on any breaking change.

export const enum Kind {
  File = 0,
  Function = 1,
  Method = 2,
  Type = 3,
  Symbol = 4,
  External = 5,
  Document = 6,
}

export const enum Rel {
  Contains = 0,
  Call = 1,
  Import = 2,
  Other = 3,
  /** File ↔ file, lifted from symbol edges (Payload.fileLinks). */
  FileLink = 4,
}

export interface Payload {
  version: 1;
  nodes: {
    id: string[];
    label: string[];
    kind: Kind[];
    community: number[];
    folder: number[];
    test: (0 | 1)[];
    degree: number[];
    sub: number[];
    noise: (0 | 1)[];
    /** Repo-relative path ("" for externals). */
    path?: string[];
    /** File a symbol lives in (-1 for files / externals). */
    owner?: number[];
    /** Lines of code (files). */
    lines?: number[];
    /** Days since last change in git (files, -1 unknown). */
    age?: number[];
  };
  edges: { s: number[]; t: number[]; r: Rel[] };
  communities: string[];
  folders: string[];
  subfolders: string[];
  /** Cached layout from a previous session, keyed by node id. */
  positions: Record<string, [number, number]> | null;
  fileLinks: { s: number[]; t: number[]; w: number[] };
}

/** 0: files only · 1: + types, functions, methods · 2: everything. */
export type Detail = 0 | 1 | 2;
export type ColorMode = "folder" | "recency" | "coupling" | "community";

export type Outgoing =
  | { type: "ready" }
  | { type: "loaded"; nodes: number; edges: number }
  | { type: "select"; id: string | null }
  | { type: "open"; id: string }
  | { type: "layoutProgress"; value: number }
  | { type: "detail"; value: Detail }
  | { type: "noise"; value: boolean }
  | { type: "groups"; mode: ColorMode; groups: GroupInfo[] }
  | { type: "layout"; positions: Record<string, [number, number]> }
  | { type: "error"; message: string };

/** One coloured area, reported to Swift for the legend. */
export interface GroupInfo {
  id: number;
  name: string;
  color: string;
  /** Visible nodes in the group. */
  count: number;
}
