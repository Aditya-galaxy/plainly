import type { Test } from "./ranges.ts";

/**
 * Earlier fictional reports for the sample, so the timeline has a history: the same made-up patient in Aug 2025 and
 * Feb 2026, drifting towards the May values. Same numbers as the iPhone app's sample.
 */
const DRIFT: Record<string, [number, number]> = {
  "Haemoglobin": [0.07, 0.03], "MCV": [0.05, 0.02], "Glucose, Fasting": [-0.08, -0.04],
  "HbA1c (Glycated Haemoglobin)": [-0.07, -0.03], "Cholesterol, Total": [-0.06, -0.03], "LDL Cholesterol": [-0.10, -0.05],
  "HDL Cholesterol": [0.09, 0.04], "Triglycerides": [-0.09, -0.04], "TSH (Thyroid Stimulating Hormone)": [-0.30, -0.12],
  "Vitamin D, 25-Hydroxy": [0.35, 0.15], "Vitamin B12": [0.10, 0.05],
};

export function sampleEarlier(may: Test[]): { date: string; tests: Test[] }[] {
  const at = (k: 0 | 1) => may.map((t) => {
    const d = DRIFT[t.name];
    if (!d) return t;
    const digits = t.value < 10 ? 10 : 1;
    const value = Math.round(t.value * (1 + d[k]) * digits) / digits;
    return { ...t, value, raw: String(value) };
  });
  return [{ date: "12 Aug 2025", tests: at(0) }, { date: "20 Feb 2026", tests: at(1) }];
}
