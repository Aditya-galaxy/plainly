import { parseRange, type Test } from "./ranges.ts";

/**
 * A rule-based reader for digital lab PDFs: most labs print one test per line as
 * "Name  Value [H|L]  Unit  Reference interval". It needs no model at all, so a PDF report can be read on any
 * device; Gemini Nano is used for photos and for layouts these rules don't recognise.
 */

// The unit is optional (OCR sometimes drops a short unit like "fL" or "%"), but must contain a letter or % so a
// range's first number is never mistaken for it.
const ROW = /^(?<name>[A-Za-z][A-Za-z0-9 ,()/.'+\-]*?[A-Za-z0-9)])\s+(?<value>-?\d+(?:\.\d+)?)\s*(?:(?<flag>[HL])\b)?(?:\s+(?<unit>(?=\S*[A-Za-zµ%])[A-Za-zµ%^/\d.]+(?:\/[A-Za-z0-9.]+)?))?\s+(?<range>.*\d.*)$/;
const SKIP = /^(test|result|unit|biological|reference|report|collected|reported|patient|age|sample|phone|ref\.?\s*by|checked|results relate)/i;

export type Meta = { age?: number; sex?: "female" | "male"; date?: string };

/** Units labs actually print. OCR often misreads "/" as "l", "i" or "1" ("gldL", "ngimL"), so a printed unit is
 *  snapped to the nearest of these when it is at most two characters away. */
const UNITS = ["g/dL", "mg/dL", "ng/mL", "pg/mL", "ng/dL", "uIU/mL", "mIU/L", "U/L", "IU/L", "fL", "pg", "%", "x10^3/uL", "x10^6/uL",
  "mmol/L", "umol/L", "mEq/L", "g/L", "mm/hr", "ratio"];

function edits(a: string, b: string): number {
  const d = Array.from({ length: a.length + 1 }, (_, i) => [i, ...Array(b.length).fill(0)]);
  for (let j = 1; j <= b.length; j++) d[0][j] = j;
  for (let i = 1; i <= a.length; i++)
    for (let j = 1; j <= b.length; j++)
      d[i][j] = Math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
  return d[a.length][b.length];
}

export function canonicalUnit(u: string): string {
  const t = u.trim().replace(/\.$/, "");
  if (!t) return "";
  let best = t;
  let bestD = 3;
  for (const c of UNITS) {
    const d = edits(t.toLowerCase(), c.toLowerCase());
    if (d < bestD) { best = c; bestD = d; }
  }
  return bestD <= 2 && (bestD === 0 || t.length >= 2) ? best : t;
}

/** "6,80" → "6.80" (a comma read for a decimal point); "1,200" (thousands) is left alone. */
const decimalComma = (s: string) => s.replace(/(\d),(\d{1,2})(?!\d)/g, "$1.$2");

export function parseMeta(lines: string[]): Meta {
  const text = lines.join("\n");
  // OCR often reads the "/" between age and sex as "I", "l" or "|".
  const as = text.match(/Age\s*[\/Il|]\s*Sex\s*:?\s*(\d{1,3})\s*(?:Y|Yrs?|Years?)?\s*[\/Il|]\s*(Male|Female|M|F)\b/i);
  const age = as ? Number(as[1]) : Number(text.match(/\bAge\s*:?\s*(\d{1,3})/i)?.[1]) || undefined;
  const sexRaw = as?.[2] ?? text.match(/\b(?:Sex|Gender)\s*:?\s*(Male|Female|M|F)\b/i)?.[1];
  const sex = sexRaw ? (/^f/i.test(sexRaw) ? "female" : "male") : undefined;
  const date = text.match(/(?:Collected|Collection|Sample date|Date)\s*:?\s*(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})/i)?.[1];
  return { age, sex, date };
}

export function parseRows(lines: string[]): Test[] {
  const out: Test[] = [];
  for (const line of lines) {
    const l = decimalComma(line.replace(/\s+/g, " ").trim());
    if (!l || SKIP.test(l)) continue;
    const m = l.match(ROW);
    if (!m?.groups) continue;
    const value = Number(m.groups.value);
    let range = parseRange(m.groups.range);
    if (range.low === undefined && range.high === undefined) {
      // A range printed as "< 200" can lose its "<" in a photo, leaving one number. The lab's own H/L mark says
      // which side it is: a value marked H above that number means an upper limit, and L below it a lower limit.
      // A lone number (OCR lost the "<" or ">", or read it as ":" or ";") is resolved by the lab's own H/L mark.
      const lone = m.groups.range.trim().match(/^[:;.,'`"]?\s*(\d+(?:\.\d+)?)$/);
      if (lone && m.groups.flag === "H" && value > Number(lone[1])) range = { high: Number(lone[1]), text: `< ${lone[1]}` };
      else if (lone && m.groups.flag === "L" && value < Number(lone[1])) range = { low: Number(lone[1]), text: `> ${lone[1]}` };
      else continue;
    }
    // Sanity: a broken OCR line can look like a row ("ng/dL 0 80-1.80"). A test name is never a unit, and a range's
    // low end is never above its high end; such rows are dropped rather than shown to a patient.
    const name = m.groups.name.trim();
    if (UNITS.includes(canonicalUnit(name)) || (name.match(/[A-Za-z]/g) ?? []).length < 2) continue;
    if (range.low !== undefined && range.high !== undefined && range.low > range.high) continue;
    out.push({ name, value, unit: canonicalUnit(m.groups.unit ?? ""), range, raw: m.groups.value, verified: true });
  }
  return out;
}
