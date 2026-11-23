/**
 * A workout, summarised from heart-rate samples: highs, lows, time in each zone, and heart-rate recovery (how far
 * the pulse falls in the first minute after stopping, a standard fitness measure). All of it is arithmetic.
 *
 * Zones use the common percentages of an estimated maximum heart rate (220 − age), labelled as an estimate:
 * the real maximum varies a lot between people.
 */

export type Sample = { t: number; bpm: number }; // t = seconds from the start
export type Session = { name: string; start: string; samples: Sample[]; endT: number }; // endT = when exercise stopped

export const ZONES = [
  { id: 1, name: "Easy", from: 0.5, to: 0.6 },
  { id: 2, name: "Steady", from: 0.6, to: 0.7 },
  { id: 3, name: "Moderate", from: 0.7, to: 0.8 },
  { id: 4, name: "Hard", from: 0.8, to: 0.9 },
  { id: 5, name: "Maximum", from: 0.9, to: 1.2 },
];

export type Moment = { t: number; bpm: number; label: string };

export type WorkoutSummary = {
  durationMin: number;
  avg: number;
  peak: Moment;
  low: Moment;
  maxEstimate: number;
  zoneMin: { id: number; name: string; minutes: number }[];
  highs: Moment[]; // the hardest stretches
  lows: Moment[]; // the easiest stretches between efforts (after the warm-up)
  recovery1min?: number; // bpm drop in the first minute after stopping
  notes: string[];
};

const clock = (t: number) => `${Math.floor(t / 60)}:${String(Math.round(t % 60)).padStart(2, "0")}`;

/** Highs (or lows): local extremes of the 30-second average, at least 3 minutes apart, most extreme first. */
function extremes(s: Sample[], kind: "high" | "low", n = 4): Moment[] {
  const smooth = s.map((p, i) => {
    const w = s.slice(Math.max(0, i - 3), i + 4); // samples every ~5 s → about 30 s
    return { t: p.t, bpm: w.reduce((a, b) => a + b.bpm, 0) / w.length };
  });
  const sign = kind === "high" ? 1 : -1;
  const cand = smooth.filter((p, i) => i > 0 && i < smooth.length - 1 && sign * (p.bpm - smooth[i - 1].bpm) >= 0 && sign * (p.bpm - smooth[i + 1].bpm) >= 0);
  const out: Moment[] = [];
  for (const c of cand.sort((a, b) => sign * (b.bpm - a.bpm))) {
    if (out.every((o) => Math.abs(o.t - c.t) >= 180))
      out.push({ t: c.t, bpm: Math.round(c.bpm), label: `${kind === "high" ? "High" : "Low"} at ${clock(c.t)}` });
    if (out.length === n) break;
  }
  return out.sort((a, b) => a.t - b.t);
}

export function analyseWorkout(sess: Session, age?: number): WorkoutSummary {
  const s = sess.samples;
  const during = s.filter((p) => p.t <= sess.endT);
  const maxEstimate = 220 - (age && age > 10 && age < 100 ? age : 35);
  const avg = Math.round(during.reduce((a, b) => a + b.bpm, 0) / during.length);
  const pk = during.reduce((a, b) => (b.bpm > a.bpm ? b : a));
  const lo = during.reduce((a, b) => (b.bpm < a.bpm ? b : a));
  const zoneSec = new Map<number, number>();
  for (let i = 1; i < during.length; i++) {
    const dt = during[i].t - during[i - 1].t;
    const frac = during[i].bpm / maxEstimate;
    const z = ZONES.find((zz) => frac >= zz.from && frac < zz.to);
    if (z) zoneSec.set(z.id, (zoneSec.get(z.id) ?? 0) + dt);
  }
  const atStop = s.filter((p) => p.t <= sess.endT).at(-1);
  const oneMin = s.find((p) => p.t >= sess.endT + 60);
  const recovery1min = atStop && oneMin ? atStop.bpm - oneMin.bpm : undefined;

  const notes: string[] = [];
  const hard = (zoneSec.get(4) ?? 0) + (zoneSec.get(5) ?? 0);
  notes.push(`You spent ${Math.round(hard / 60)} min hard or harder, and ${Math.round((zoneSec.get(2) ?? 0) / 60 + (zoneSec.get(3) ?? 0) / 60)} min steady to moderate.`);
  if (recovery1min !== undefined)
    notes.push(recovery1min >= 12
      ? `Your heart rate fell ${recovery1min} bpm in the first minute after stopping, a normal recovery.`
      : `Your heart rate fell only ${recovery1min} bpm in the first minute after stopping. A slow recovery now and then is common when tired; if it keeps happening, mention it to your doctor.`);
  const maxSec = during.filter((p, i) => i > 0 && p.bpm / maxEstimate >= 0.95).length * 5;
  if (maxSec >= 120) notes.push(`You were at 95% or more of your estimated maximum for about ${Math.round(maxSec / 60)} min. If you felt chest pain, dizziness or unusual breathlessness, stop and get checked.`);

  return {
    durationMin: Math.round(sess.endT / 60),
    avg,
    peak: { t: pk.t, bpm: pk.bpm, label: `Peak ${pk.bpm} bpm at ${clock(pk.t)}` },
    low: { t: lo.t, bpm: lo.bpm, label: `Lowest ${lo.bpm} bpm at ${clock(lo.t)}` },
    maxEstimate,
    zoneMin: ZONES.map((z) => ({ id: z.id, name: z.name, minutes: Math.round(((zoneSec.get(z.id) ?? 0) / 60) * 10) / 10 })),
    highs: extremes(during, "high"),
    // Lows that matter are the recoveries between efforts, so the warm-up's first 5 minutes are left out.
    lows: extremes(during.filter((p) => p.t >= 300), "low", 3),
    recovery1min,
    notes,
  };
}

/** A fictional 36-minute brisk walk/jog for the 52-year-old sample patient, with 3 minutes recorded after stopping:
 *  warm-up, four 3-minute brisker efforts with easy walking between, a short cool-down. Samples every 5 seconds. */
export function sampleWorkout(): Session {
  let seed = 11;
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647) - 0.5;
  const samples: Sample[] = [];
  let bpm = 76;
  const END = 36;
  const target = (t: number) => {
    const m = t / 60;
    if (m < 7) return 92 + m * 4; // warm-up to ~120
    if (m < 31) {
      const k = Math.floor((m - 7) / 6); // four 6-minute blocks: 3 brisk, 3 easy
      return (m - 7) % 6 < 3 ? 138 + k * 2.5 : 116;
    }
    if (m < END) return 128 - (m - 31) * 2; // short cool-down
    return 72 + (118 - 72) * Math.exp(-(m - END) / 1.1); // stopped: recovery
  };
  for (let t = 0; t <= (END + 3) * 60; t += 5) {
    bpm += (target(t) - bpm) * 0.18 + rand() * 2;
    samples.push({ t, bpm: Math.round(bpm) });
  }
  return { name: "Brisk walk and jog (sample)", start: "2026-11-16T06:30:00+05:30", samples, endT: END * 60 };
}
