/**
 * Everything numeric is done here, in code, never by a model: reading reference ranges as printed by labs,
 * flagging values, and comparing with earlier reports. Models read and write words; code does the arithmetic.
 */

export type Range = { low?: number; high?: number; text: string };
export type Flag = "low" | "high" | "normal" | "unknown";

export type Test = {
  name: string;
  value: number;
  unit: string;
  range: Range;
  /** The value exactly as printed, used to check the model didn't invent it. */
  raw?: string;
  /** True when the printed value was found in the report's own text. */
  verified?: boolean;
};

const num = (s: string) => Number(s.replace(/,/g, ""));

/** Reads ranges the way Indian and international labs print them: "12.0 - 15.0", "< 100", ">= 50", "Upto 40". */
export function parseRange(text: string): Range {
  const t = text.replace(/\s+/g, " ").trim();
  const between = t.match(/(-?\d+(?:[.,]\d+)?)\s*(?:-|–|to)\s*(-?\d+(?:[.,]\d+)?)/i);
  if (between) return { low: num(between[1]), high: num(between[2]), text: t };
  const below = t.match(/(?:<=?|≤|less than|below|up\s?to|upto)\s*(-?\d+(?:[.,]\d+)?)/i);
  if (below) return { high: num(below[1]), text: t };
  const above = t.match(/(?:>=?|≥|more than|above|greater than)\s*(-?\d+(?:[.,]\d+)?)/i);
  if (above) return { low: num(above[1]), text: t };
  return { text: t };
}

export function flagOf(value: number, r: Range): Flag {
  if (r.low === undefined && r.high === undefined) return "unknown";
  if (r.low !== undefined && value < r.low) return "low";
  if (r.high !== undefined && value > r.high) return "high";
  return "normal";
}

/** How far outside the range, as a share of the nearest limit: 0.1 means 10% beyond it. */
export function distance(value: number, r: Range): number {
  if (r.low !== undefined && value < r.low) return (r.low - value) / Math.abs(r.low || 1);
  if (r.high !== undefined && value > r.high) return (value - r.high) / Math.abs(r.high || 1);
  return 0;
}

/** Inside the range but within 5% of a limit: worth a look, not a flag. */
export function nearEdge(value: number, r: Range, margin = 0.05): boolean {
  if (flagOf(value, r) !== "normal") return false;
  const near = (limit?: number) => limit !== undefined && Math.abs(value - limit) <= Math.abs(limit) * margin;
  return near(r.low) || near(r.high);
}

const key = (name: string) => name.toLowerCase().replace(/\(.*?\)/g, "").replace(/[^a-z0-9]+/g, " ").trim();

export type Trend = { previous: number; change: number; direction: "up" | "down" | "same"; date?: string };

/** The same test in an earlier report, matched by name and unit. */
export function trendOf(t: Test, earlier: { date?: string; tests: Test[] }[]): Trend | undefined {
  for (const r of earlier) {
    // Units must match, unless OCR dropped one of them; then the test name alone decides.
    const p = r.tests.find((x) => key(x.name) === key(t.name) && (!x.unit || !t.unit || x.unit.toLowerCase() === t.unit.toLowerCase()));
    if (p) {
      const change = t.value - p.value;
      const same = Math.abs(change) <= Math.abs(p.value) * 0.02;
      return { previous: p.value, change, direction: same ? "same" : change > 0 ? "up" : "down", date: r.date };
    }
  }
  return undefined;
}

/**
 * A model reading a report can misread or invent a number. When the report's own text is available (a digital
 * PDF), each value must appear in it exactly as printed; otherwise the test is shown with a "check against your
 * report" mark instead of being trusted silently.
 */
export function verifyAgainstText(tests: Test[], source: string): Test[] {
  const hay = source.replace(/\s+/g, " ");
  return tests.map((t) => {
    const printed = (t.raw ?? String(t.value)).trim();
    const variants = new Set([printed, String(t.value), t.value.toFixed(1), t.value.toFixed(2)]);
    const found = [...variants].some((v) => new RegExp(`(^|[^0-9.])${v.replace(/\./g, "\\.")}([^0-9]|$)`).test(hay));
    return { ...t, verified: found };
  });
}
