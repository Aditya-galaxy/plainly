/**
 * Vitals from a watch or band: compared with the person's OWN normal, never with a population "ideal", and never
 * turned into a diagnosis. All arithmetic is here, in code. The recovery weighting (HRV 50%, resting heart rate 30%,
 * sleep 20%, 50 = a normal day) comes from OpenVitals (github.com/Aditya-galaxy/openvitals).
 *
 * Safety rules are fixed thresholds that are widely used as reasons to contact a doctor (a resting pulse above 100
 * for days, a blood-oxygen average below 90%). Consumer wearables can be wrong, so every rule says what to do and to
 * check how you feel, rather than claiming a condition.
 */

export type Day = {
  date: string; // YYYY-MM-DD
  restingHr?: number; // beats per minute
  hrv?: number; // RMSSD, milliseconds
  sleepMin?: number; // minutes asleep
  spo2?: number; // average blood oxygen overnight, %
};

export type Metric = "restingHr" | "hrv" | "sleepMin" | "spo2";

export const METRICS: { key: Metric; label: string; unit: string; better: "up" | "down"; minChange: number; relative?: boolean }[] = [
  { key: "restingHr", label: "Resting heart rate", unit: "bpm", better: "down", minChange: 5 },
  { key: "hrv", label: "Heart rate variability", unit: "ms", better: "up", minChange: 0.15, relative: true },
  { key: "sleepMin", label: "Sleep", unit: "min", better: "up", minChange: 45 },
  { key: "spo2", label: "Blood oxygen (overnight)", unit: "%", better: "up", minChange: 2 },
];

const mean = (xs: number[]) => xs.reduce((a, b) => a + b, 0) / xs.length;
const sd = (xs: number[]) => {
  const m = mean(xs);
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / Math.max(1, xs.length - 1));
};
const round = (x: number, d = 0) => Math.round(x * 10 ** d) / 10 ** d;

export type Change = {
  metric: Metric;
  label: string;
  unit: string;
  baseline: number;
  recent: number;
  delta: number;
  /** "better", "worse" or "steady" compared with the person's own baseline. */
  direction: "better" | "worse" | "steady";
  text: string;
};

export type Alert = { id: string; level: "urgent" | "doctor"; title: string; advice: string };

export type VitalsReport = {
  days: number;
  baselineDays: number;
  recentDays: number;
  recovery?: number; // 0–100, 50 = a normal day for this person
  changes: Change[];
  alerts: Alert[];
};

const fmtSleep = (min: number) => (min < 60 ? `${Math.round(min)} min` : `${Math.floor(min / 60)} h ${Math.round(min % 60)} min`);

/**
 * Baseline: the 28 days before the recent window. Recent: the last 7 days. A change counts only when it is bigger
 * than the person's usual day-to-day spread AND a minimum that matters (5 bpm, 15% HRV, 45 min sleep, 2 points SpO2).
 */
export function analyse(input: Day[], recentDays = 7, baselineDays = 28): VitalsReport {
  const days = [...input].sort((a, b) => a.date.localeCompare(b.date));
  const recent = days.slice(-recentDays);
  const base = days.slice(-(recentDays + baselineDays), -recentDays);
  const changes: Change[] = [];
  const z: Partial<Record<Metric, number>> = {};
  for (const m of METRICS) {
    const b = base.map((d) => d[m.key]).filter((v): v is number => typeof v === "number");
    const r = recent.map((d) => d[m.key]).filter((v): v is number => typeof v === "number");
    if (b.length < 7 || r.length < 3) continue;
    const bm = mean(b);
    const rm = mean(r);
    const spread = Math.max(sd(b), 1e-9);
    const delta = rm - bm;
    const threshold = Math.max(spread, m.relative ? Math.abs(bm) * m.minChange : m.minChange);
    z[m.key] = (delta / spread) * (m.better === "up" ? 1 : -1);
    const moved = Math.abs(delta) >= threshold;
    const good = (delta > 0) === (m.better === "up");
    const direction = !moved ? "steady" : good ? "better" : "worse";
    const show = (v: number) => (m.key === "sleepMin" ? fmtSleep(v) : `${round(v, m.key === "spo2" ? 1 : 0)} ${m.unit}`);
    const diff = m.key === "sleepMin" ? fmtSleep(Math.abs(delta)) : `${round(Math.abs(delta), m.key === "spo2" ? 1 : 0)} ${m.unit}`;
    const text = direction === "steady"
      ? `${m.label} is in your usual range (${show(rm)} this week, ${show(bm)} usually).`
      : `${m.label} is ${diff} ${m.key === "sleepMin" ? (delta > 0 ? "longer" : "shorter") : delta > 0 ? "higher" : "lower"} than your usual (${show(rm)} this week vs ${show(bm)}).`;
    changes.push({ metric: m.key, label: m.label, unit: m.unit, baseline: round(bm, 1), recent: round(rm, 1), delta: round(delta, 1), direction, text });
  }

  // Recovery: OpenVitals weights, on the latest day relative to baseline; 50 is a normal day for this person.
  let recovery: number | undefined;
  const last = days[days.length - 1];
  if (last && base.length >= 7) {
    const zLast = (key: Metric, better: "up" | "down") => {
      const b = base.map((d) => d[key]).filter((v): v is number => typeof v === "number");
      const v = last[key];
      if (b.length < 7 || typeof v !== "number") return undefined;
      return ((v - mean(b)) / Math.max(sd(b), 1e-9)) * (better === "up" ? 1 : -1);
    };
    const parts: [number | undefined, number][] = [[zLast("hrv", "up"), 0.5], [zLast("restingHr", "down"), 0.3], [zLast("sleepMin", "up"), 0.2]];
    const have = parts.filter((p): p is [number, number] => p[0] !== undefined);
    if (have.length) {
      const w = have.reduce((a, [, wt]) => a + wt, 0);
      const s = have.reduce((a, [v, wt]) => a + Math.max(-3, Math.min(3, v)) * wt, 0) / w;
      recovery = Math.round(Math.max(0, Math.min(100, 50 + s * 10)));
    }
  }

  const alerts: Alert[] = [];
  const lastN = (key: Metric, n: number) => days.slice(-n).map((d) => d[key]).filter((v): v is number => typeof v === "number");
  const hr3 = lastN("restingHr", 3);
  if (hr3.length === 3 && hr3.every((v) => v > 100))
    alerts.push({ id: "hr-high", level: "doctor", title: "Resting heart rate above 100 for 3 days",
      advice: "Contact a doctor today. If you have chest pain, feel faint or breathless, call 112." });
  if (hr3.length === 3 && hr3.every((v) => v < 40))
    alerts.push({ id: "hr-low", level: "doctor", title: "Resting heart rate below 40 for 3 days",
      advice: "Contact a doctor, unless a doctor already knows your heart rate runs this low. If you feel dizzy or faint, call 112." });
  const ox2 = lastN("spo2", 2);
  if (ox2.length === 2 && ox2.every((v) => v < 90))
    alerts.push({ id: "spo2-low", level: "urgent", title: "Blood oxygen averaged below 90% for 2 nights",
      advice: "Wrist sensors can be wrong, but don't ignore this. If you are breathless, confused or your lips look blue, call 112 now; otherwise contact a doctor today." });
  const rhr = changes.find((c) => c.metric === "restingHr");
  if (rhr && rhr.delta >= 10)
    alerts.push({ id: "hr-rise", level: "doctor", title: `Resting heart rate ${rhr.delta} bpm above your usual this week`,
      advice: "A sustained rise is worth mentioning to your doctor, especially with tiredness or other symptoms." });

  return { days: days.length, baselineDays: base.length, recentDays: recent.length, recovery, changes, alerts };
}

/** A deterministic 35-day sample (fictional) matching the sample lab report: a usual month, then a tired week. */
export function sampleDays(end = "2026-11-18"): Day[] {
  let seed = 7;
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) - 0.5;
  const out: Day[] = [];
  const endT = Date.parse(end + "T00:00:00Z");
  for (let i = 34; i >= 0; i--) {
    const t = new Date(endT - i * 86400000).toISOString().slice(0, 10);
    const tired = i < 7 ? (7 - i) / 7 : 0; // the last week drifts away from normal
    out.push({
      date: t,
      restingHr: Math.round(62 + rand() * 4 + tired * 14),
      hrv: Math.round(44 + rand() * 10 - tired * 14),
      sleepMin: Math.round(420 + rand() * 60 - tired * 75),
      spo2: round(96.2 + rand() * 1.2 - tired * 0.6, 1),
    });
  }
  return out;
}
