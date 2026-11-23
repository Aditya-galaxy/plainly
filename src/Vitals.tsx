import { useEffect, useMemo, useRef, useState } from "react";
import { analyse, METRICS, sampleDays, type Day, type Metric, type VitalsReport } from "./lib/vitals.ts";
import { analyseWorkout, sampleWorkout, ZONES, type Session, type WorkoutSummary } from "./lib/workout.ts";

/**
 * Vitals from a watch or band, against the person's own normal. On the web this uses the built-in sample (fictional);
 * the Android app reads the same kind of data from Health Connect. Nothing here leaves the browser.
 */
export default function Vitals({ onAddToSheet, added }: { onAddToSheet: (lines: string[]) => void; added: boolean }) {
  const days = useMemo(() => sampleDays(), []);
  const report = useMemo(() => analyse(days), [days]);
  const session = useMemo(() => sampleWorkout(), []);
  const workout = useMemo(() => analyseWorkout(session, 52), [session]);

  const sheetLines = [
    ...report.changes.filter((c) => c.direction !== "steady").map((c) => c.text),
    ...(workout.recovery1min !== undefined ? [`After a ${workout.durationMin}-minute walk/jog, heart rate fell ${workout.recovery1min} bpm in the first minute.`] : []),
    ...report.alerts.map((a) => `${a.title}.`),
  ];

  return (
    <main className="vitals">
      <p className="eyebrow">Sample data (fictional) · 35 days from a watch, plus one workout · stays in this browser</p>
      <h1>{headline(report)}</h1>
      <p className="lead small">Compared with <b>your own</b> last 28 days, not with anyone else. The Android app reads the same data from Health Connect (Fitbit, Galaxy Watch, Pixel Watch, Garmin, Zepp, Oura).</p>

      {report.alerts.length > 0 && (
        <section className="redflag" role="alert">
          <h2>{report.alerts.some((a) => a.level === "urgent") ? "Get care now" : "Contact a doctor"}</h2>
          {report.alerts.map((a) => <p key={a.id}><b>{a.title}.</b> {a.advice}</p>)}
          <p className="hint">Fixed safety rules, not AI. Wearable sensors can be wrong; how you feel matters most.</p>
        </section>
      )}

      <section className="recovery">
        <Gauge value={report.recovery} />
        <div>
          <h2>Recovery today</h2>
          <p className="hint">50 is a normal day for you. Weighted from heart rate variability (50%), resting heart rate (30%) and sleep (20%), as in OpenVitals.</p>
        </div>
      </section>

      <ol className="metrics">
        {METRICS.map((m) => {
          const c = report.changes.find((x) => x.metric === m.key);
          if (!c) return null;
          return (
            <li key={m.key} className={`metric ${c.direction}`}>
              <div className="metric-head">
                <span className="name">{m.label}</span>
                <span className={`chip ${c.direction}`}>{c.direction === "steady" ? "Usual" : c.direction === "worse" ? "Off your usual" : "Better than usual"}</span>
              </div>
              <Spark days={days} metric={m.key} report={report} />
              <p className="sub">{c.text}</p>
            </li>
          );
        })}
      </ol>

      <Workout session={session} w={workout} />

      <div className="toolbar">
        <button className="primary" onClick={() => onAddToSheet(sheetLines)} disabled={added || !sheetLines.length}>
          {added ? "Added to my doctor sheet" : "Add to my doctor sheet"}
        </button>
        <span className="hint" style={{ margin: 0 }}>Adds the changes above to the sheet on the Lab report tab.</span>
      </div>
      <p className="disclaimer">Plainly describes changes in your own numbers and never diagnoses. Talk to your doctor about anything that worries you.</p>
    </main>
  );
}

function headline(r: VitalsReport) {
  const off = r.changes.filter((c) => c.direction === "worse").length;
  if (r.alerts.length) return "Something needs attention";
  if (!off) return "Your week looks like your usual";
  return `${off} of your vitals ${off === 1 ? "is" : "are"} off your usual this week`;
}

function Gauge({ value }: { value?: number }) {
  const v = value ?? 50;
  const angle = (v / 100) * 270 - 135;
  const r = 44;
  const arc = (from: number, to: number) => {
    const p = (a: number) => [60 + r * Math.cos(((a - 90) * Math.PI) / 180), 60 + r * Math.sin(((a - 90) * Math.PI) / 180)];
    const [x1, y1] = p(from);
    const [x2, y2] = p(to);
    return `M ${x1} ${y1} A ${r} ${r} 0 ${to - from > 180 ? 1 : 0} 1 ${x2} ${y2}`;
  };
  return (
    <svg className="gauge" viewBox="0 0 120 110" role="img" aria-label={`Recovery ${value ?? "unknown"} out of 100`}>
      <path d={arc(-135, 135)} className="track" />
      <path d={arc(-135, angle)} className={`fill ${v < 35 ? "low" : v > 65 ? "high" : ""}`} />
      <text x="60" y="66" textAnchor="middle" className="num">{value ?? "–"}</text>
      <text x="60" y="84" textAnchor="middle" className="of">of 100</text>
    </svg>
  );
}

function Spark({ days, metric, report }: { days: Day[]; metric: Metric; report: VitalsReport }) {
  const c = report.changes.find((x) => x.metric === metric)!;
  const vals = days.map((d) => d[metric]).filter((v): v is number => typeof v === "number");
  const base = days.slice(-(report.recentDays + report.baselineDays), -report.recentDays).map((d) => d[metric]).filter((v): v is number => typeof v === "number");
  const mean = base.reduce((a, b) => a + b, 0) / base.length;
  const sd = Math.sqrt(base.reduce((a, b) => a + (b - mean) ** 2, 0) / Math.max(1, base.length - 1));
  const lo = Math.min(...vals, mean - sd);
  const hi = Math.max(...vals, mean + sd);
  const W = 600, H = 70;
  const x = (i: number) => (i / (vals.length - 1)) * W;
  const y = (v: number) => H - 6 - ((v - lo) / (hi - lo || 1)) * (H - 12);
  const recentStart = x(vals.length - report.recentDays);
  return (
    <svg className="spark" viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none" aria-hidden="true">
      <rect x="0" y={y(mean + sd)} width={W} height={Math.max(1, y(mean - sd) - y(mean + sd))} className="usual" />
      <rect x={recentStart} y="0" width={W - recentStart} height={H} className="week" />
      <polyline points={vals.map((v, i) => `${x(i)},${y(v)}`).join(" ")} className={`line ${c.direction}`} />
    </svg>
  );
}

function Workout({ session, w }: { session: Session; w: WorkoutSummary }) {
  const [playing, setPlaying] = useState(false);
  const [t, setT] = useState<number | null>(null);
  const raf = useRef<number | null>(null);
  const s = session.samples;
  const endT = s[s.length - 1].t;

  // Replay at 60× speed: the 39-minute recording plays in about 40 seconds.
  useEffect(() => {
    if (!playing) return;
    const started = performance.now();
    const from = t ?? 0;
    const tick = (now: number) => {
      const cur = from + ((now - started) / 1000) * 60;
      if (cur >= endT) { setT(endT); setPlaying(false); return; }
      setT(cur);
      raf.current = requestAnimationFrame(tick);
    };
    raf.current = requestAnimationFrame(tick);
    return () => { if (raf.current) cancelAnimationFrame(raf.current); };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing]);

  const W = 700, H = 250, top = 14, bottom = 28;
  const minB = 60, maxB = Math.max(w.maxEstimate, ...s.map((p) => p.bpm)) + 5;
  const x = (tt: number) => (tt / endT) * W;
  const y = (b: number) => top + (1 - (b - minB) / (maxB - minB)) * (H - top - bottom);
  const shown = t === null ? s : s.filter((p) => p.t <= t);
  const live = t === null ? undefined : s.reduce((a, b) => (Math.abs(b.t - t) < Math.abs(a.t - t) ? b : a));
  const zoneOf = (b: number) => ZONES.find((z) => b / w.maxEstimate >= z.from && b / w.maxEstimate < z.to);
  const clock = (tt: number) => `${Math.floor(tt / 60)}:${String(Math.floor(tt % 60)).padStart(2, "0")}`;

  return (
    <section className="workout">
      <div className="metric-head">
        <h2>{session.name}</h2>
        <button className="quiet" onClick={() => { if (t !== null && t >= endT) setT(0); setPlaying((p) => !p); }}>
          {playing ? "Pause" : t !== null && t < endT ? "Resume" : "Replay live"}
        </button>
      </div>
      <p className="hint" style={{ marginTop: 4 }}>16 Nov, 6:30 am · {w.durationMin} min · zones from an estimated maximum of {w.maxEstimate} bpm (220 − age; real maximums vary)</p>
      {live && (
        <p className="live" aria-live="polite">
          <span className="beat" style={{ animationDuration: `${60 / live.bpm}s` }}>♥</span> {live.bpm} <small>bpm</small>
          <span className="live-zone">{live.t > session.endT ? "stopped, recovering" : zoneOf(live.bpm)?.name ?? "Resting"} · {clock(live.t)}</span>
        </p>
      )}
      <svg className="hr" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Heart rate during the workout">
        {ZONES.slice(1).map((z) => (
          <rect key={z.id} x="0" width={W} y={y(Math.min(maxB, z.to * w.maxEstimate))} height={Math.max(0, y(z.from * w.maxEstimate) - y(Math.min(maxB, z.to * w.maxEstimate)))} className={`zone z${z.id}`} />
        ))}
        <line x1={x(session.endT)} x2={x(session.endT)} y1={top} y2={H - bottom} className="stop" />
        <text x={x(session.endT) + 4} y={top + 12} className="axis">stop</text>
        <polyline points={shown.map((p) => `${x(p.t)},${y(p.bpm)}`).join(" ")} className="hrline" />
        {t === null && w.highs.map((h) => (<g key={`h${h.t}`}><circle cx={x(h.t)} cy={y(h.bpm)} r="4" className="hi" /><text x={x(h.t)} y={y(h.bpm) - 8} textAnchor="middle" className="axis">{h.bpm}</text></g>))}
        {t === null && w.lows.map((l) => (<g key={`l${l.t}`}><circle cx={x(l.t)} cy={y(l.bpm)} r="4" className="lo" /><text x={x(l.t)} y={y(l.bpm) + 24} textAnchor="middle" className="axis">{l.bpm}</text></g>))}
        {live && <circle cx={x(live.t)} cy={y(live.bpm)} r="6" className="cursor" />}
        {[0, 10, 20, 30].map((m) => <text key={m} x={x(m * 60)} y={H - 6} className="axis">{m} min</text>)}
      </svg>
      <div className="wstats">
        <div><b>{w.avg}</b><span>average bpm</span></div>
        <div><b>{w.peak.bpm}</b><span>peak at {clock(w.peak.t)}</span></div>
        <div><b>{w.lows.length ? Math.min(...w.lows.map((l) => l.bpm)) : w.low.bpm}</b><span>lowest between efforts</span></div>
        <div><b>{w.recovery1min ?? "–"}</b><span>bpm drop 1 min after stopping</span></div>
      </div>
      <ol className="zones">
        {w.zoneMin.map((z) => (
          <li key={z.id}><span className={`sw z${z.id}`} />{z.name}<span className="bar"><i className={`z${z.id}`} style={{ width: `${(z.minutes / w.durationMin) * 100}%` }} /></span>{z.minutes} min</li>
        ))}
      </ol>
      <ul className="wnotes">
        <li>Highs at {w.highs.map((h) => `${clock(h.t)} (${h.bpm})`).join(", ")}: each effort a little harder than the last.</li>
        {w.lows.length > 0 && <li>Lows at {w.lows.map((l) => `${clock(l.t)} (${l.bpm})`).join(", ")}: the easy stretches between efforts.</li>}
        {w.notes.map((n) => <li key={n}>{n}</li>)}
      </ul>
    </section>
  );
}
