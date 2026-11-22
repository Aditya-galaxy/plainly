import { flagOf, type Test, type Trend } from "./ranges.ts";

/**
 * What the cloud is allowed to see when on-device AI can't help: the test, its number, unit and printed range,
 * the flag code computed, an age band and sex. Never the name, the lab, dates, IDs, the doctor or the image.
 */
export type CloudTest = {
  test: string;
  value: number;
  unit: string;
  range: string;
  flag: string;
  previous?: number;
  ageBand?: string;
  sex?: "female" | "male";
};

export function ageBand(age?: number): string | undefined {
  if (!age || age < 0 || age > 120) return undefined;
  if (age < 18) return "under 18";
  const lo = Math.floor(age / 10) * 10;
  return `${lo}s`;
}

/** Test names can carry stray text from the report line; keep only a plain test name. */
export function cleanTestName(name: string): string {
  return name.replace(/[^A-Za-z0-9 ()%,.+\-/]/g, " ").replace(/\s+/g, " ").trim().slice(0, 60);
}

export function deidentify(t: Test, who: { age?: number; sex?: string }, trend?: Trend): CloudTest {
  const sex = /^f/i.test(who.sex ?? "") ? "female" : /^m/i.test(who.sex ?? "") ? "male" : undefined;
  return {
    test: cleanTestName(t.name),
    value: t.value,
    unit: t.unit.slice(0, 16),
    range: t.range.text.slice(0, 40),
    flag: flagOf(t.value, t.range),
    ...(trend ? { previous: trend.previous } : {}),
    ...(ageBand(who.age) ? { ageBand: ageBand(who.age) } : {}),
    ...(sex ? { sex } : {}),
  };
}
