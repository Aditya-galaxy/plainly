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

export function parseMeta(lines: string[]): Meta {
  const text = lines.join("\n");
  const as = text.match(/Age\s*\/\s*Sex\s*:?\s*(\d{1,3})\s*(?:Y|Yrs?|Years?)?\s*\/\s*(Male|Female|M|F)\b/i);
  const age = as ? Number(as[1]) : Number(text.match(/\bAge\s*:?\s*(\d{1,3})/i)?.[1]) || undefined;
  const sexRaw = as?.[2] ?? text.match(/\b(?:Sex|Gender)\s*:?\s*(Male|Female|M|F)\b/i)?.[1];
  const sex = sexRaw ? (/^f/i.test(sexRaw) ? "female" : "male") : undefined;
  const date = text.match(/(?:Collected|Collection|Sample date|Date)\s*:?\s*(\d{1,2}\s+[A-Za-z]{3,9}\s+\d{4}|\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{2,4})/i)?.[1];
  return { age, sex, date };
}

export function parseRows(lines: string[]): Test[] {
  const out: Test[] = [];
  for (const line of lines) {
    const l = line.replace(/\s+/g, " ").trim();
    if (!l || SKIP.test(l)) continue;
    const m = l.match(ROW);
    if (!m?.groups) continue;
    const range = parseRange(m.groups.range);
    if (range.low === undefined && range.high === undefined) continue;
    out.push({ name: m.groups.name.trim(), value: Number(m.groups.value), unit: m.groups.unit ?? "", range, raw: m.groups.value, verified: true });
  }
  return out;
}
