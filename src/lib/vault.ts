import type { Test } from "./ranges.ts";

/**
 * Earlier reports, kept in this browser only (IndexedDB), so trends can be shown without any account or upload.
 * Only the extracted results are stored: no images, names or IDs.
 */
export type SavedReport = { id: string; date?: string; savedAt: number; tests: Test[] };

const DB = "plainly";
const STORE = "reports";

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: "id" });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
}

async function tx<T>(mode: IDBTransactionMode, fn: (s: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open();
  return new Promise((resolve, reject) => {
    const r = fn(db.transaction(STORE, mode).objectStore(STORE));
    r.onsuccess = () => resolve(r.result);
    r.onerror = () => reject(r.error);
  });
}

export async function listReports(): Promise<SavedReport[]> {
  try {
    const all = await tx<SavedReport[]>("readonly", (s) => s.getAll() as IDBRequest<SavedReport[]>);
    return all.sort((a, b) => (dateValue(b.date) || b.savedAt) - (dateValue(a.date) || a.savedAt));
  } catch {
    return []; // private windows can block IndexedDB; trends are simply unavailable then
  }
}

export async function saveReport(r: SavedReport): Promise<void> {
  try {
    await tx("readwrite", (s) => s.put(r));
  } catch {
    /* not saved: the current report still works */
  }
}

export async function clearReports(): Promise<void> {
  try {
    await tx("readwrite", (s) => s.clear());
  } catch {
    /* nothing to clear */
  }
}

export function dateValue(d?: string): number {
  if (!d) return 0;
  const t = Date.parse(d);
  return Number.isFinite(t) ? t : 0;
}
