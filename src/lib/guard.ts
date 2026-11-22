/**
 * Plainly explains lab values; it never diagnoses or prescribes. Every explanation, on-device or from the cloud,
 * passes this check before it is shown:
 *  - every number it mentions must be one of this test's own numbers (value, range limits, earlier value);
 *  - it may not diagnose ("you have…", "this means you are…") or tell the person to take or stop a medicine;
 *  - it must point back to the person's doctor.
 */

const DIAGNOSE = [
  /\byou (?:have|are suffering from|are diagnosed|definitely|certainly)\b/i,
  /\b(?:this|it) (?:means|confirms|proves) (?:that )?you\b/i,
  /\bdiagnos(?:is|ed|e)\b(?! is not| isn't)/i,
  /\byou(?:'re| are) (?:diabetic|anaemic|anemic|hypothyroid|hyperthyroid)\b/i,
];
const PRESCRIBE = [
  /\b(?:take|start|stop|increase|reduce|double)\s+(?:a |an |your |the )?(?:dose|tablet|pill|medicine|medication|supplement|insulin|metformin|levothyroxine|thyroxine|statin)/i,
  /\b\d+(?:\.\d+)?\s?(?:mg|mcg|µg|iu|units)\b(?! ?\/)/i,
];
const DOCTOR = /\b(?:doctor|physician|clinician|gp|healthcare provider)\b/i;

export type Verdict = { ok: true } | { ok: false; reason: string };

const numbersIn = (text: string) =>
  (text.match(/-?\d+(?:[.,]\d+)?/g) ?? []).map((n) => Number(n.replace(/,/g, ""))).filter((n) => Number.isFinite(n));

export function checkExplanation(text: string, allowed: number[]): Verdict {
  const t = text.trim();
  if (t.length < 20) return { ok: false, reason: "The explanation was too short to be useful." };
  if (t.length > 900) return { ok: false, reason: "The explanation ran too long." };
  for (const re of DIAGNOSE) if (re.test(t)) return { ok: false, reason: "It read like a diagnosis, which Plainly never gives." };
  for (const re of PRESCRIBE) if (re.test(t)) return { ok: false, reason: "It suggested a medicine or dose, which only a doctor should." };
  const ok = (n: number) => allowed.some((a) => Math.abs(a - n) <= Math.max(1e-9, Math.abs(a) * 0.001));
  // Small counting words written as digits ("2 questions", "1 in 3") are allowed; any other number must be the test's own.
  const stray = numbersIn(t).filter((n) => !ok(n) && !(Number.isInteger(n) && n >= 0 && n <= 3));
  if (stray.length) return { ok: false, reason: `It mentioned a number that isn't on your report (${stray[0]}).` };
  if (!DOCTOR.test(t)) return { ok: false, reason: "It didn't point you back to your doctor." };
  return { ok: true };
}
