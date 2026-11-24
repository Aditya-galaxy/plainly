import { flagOf, type Test } from "./lib/ranges.ts";

type R = { date?: string; tests: Test[] };
const month = (d?: string) => { const t = Date.parse(d ?? ""); return Number.isFinite(t) ? new Date(t).toLocaleDateString("en-GB", { month: "short", year: "numeric" }) : "Undated"; };
const out = (t: Test) => t.verified !== false && (flagOf(t.value, t.range) === "high" || flagOf(t.value, t.range) === "low");

/** Every report as a flower, one petal per result (red when high, blue when low), then each test across the reports. */
export default function Timeline({ reports }: { reports: R[] }) {
  const sorted = [...reports].sort((a, b) => (Date.parse(a.date ?? "") || 0) - (Date.parse(b.date ?? "") || 0));
  const counts = new Map<string, { seen: number; out: number }>();
  for (const r of sorted) for (const t of r.tests) {
    const c = counts.get(t.name) ?? { seen: 0, out: 0 }; c.seen++; if (out(t)) c.out++; counts.set(t.name, c);
  }
  const names = [...counts].filter(([, c]) => c.seen >= 2).sort((a, b) => b[1].out - a[1].out || a[0].localeCompare(b[0])).map(([n]) => n);
  return (
    <section className="timeline">
      <h2>Your timeline</h2>
      <p className="hint">{sorted.length} reports, {month(sorted[0]?.date)} to {month(sorted[sorted.length - 1]?.date)}. Each flower is one report; a petal is one result, coloured when it was outside the range.</p>
      <div className="flowers">
        {sorted.map((r, i) => (
          <figure key={i}>
            <Flower tests={r.tests} />
            <figcaption><b>{month(r.date)}</b><span>{r.tests.filter(out).length ? `${r.tests.filter(out).length} outside` : "All in range"}</span></figcaption>
          </figure>
        ))}
      </div>
      <ol className="histories">
        {names.map((n) => {
          const pts = sorted.map((r) => r.tests.find((t) => t.name === n)).map((t, i) => t && { t, i }).filter(Boolean) as { t: Test; i: number }[];
          const last = pts[pts.length - 1].t;
          return <li key={n}><span className="name">{n.replace(/\s*\(.*\)$/, "")}</span><History pts={pts} total={sorted.length} /><span className="val">{last.value} {last.unit}</span></li>;
        })}
      </ol>
    </section>
  );
}

function Flower({ tests }: { tests: Test[] }) {
  const n = Math.max(tests.length, 1);
  return (
    <svg viewBox="-50 -50 100 100" className="flower" role="img" aria-label={`${tests.filter(out).length} of ${tests.length} results outside the range`}>
      {tests.map((t, i) => {
        const o = out(t);
        const f = flagOf(t.value, t.range);
        return <ellipse key={i} cx={o ? 24 : 17} cy={0} rx={o ? 24 : 17} ry={5.5} transform={`rotate(${(i / n) * 360 - 90})`}
          className={o ? (f === "high" ? "p-high" : "p-low") : "p-ok"} />;
      })}
      <circle r="7" className="core" />
    </svg>
  );
}

function History({ pts, total }: { pts: { t: Test; i: number }[]; total: number }) {
  const W = 300, H = 36;
  const vals = pts.map((p) => p.t.value);
  const lo = Math.min(...vals), hi = Math.max(...vals);
  const x = (i: number) => (total <= 1 ? W / 2 : 6 + (i / (total - 1)) * (W - 12));
  const y = (v: number) => (hi === lo ? H / 2 : H - 6 - ((v - lo) / (hi - lo)) * (H - 12));
  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="history" aria-hidden="true">
      <polyline points={pts.map((p) => `${x(p.i)},${y(p.t.value)}`).join(" ")} />
      {pts.map((p) => { const f = flagOf(p.t.value, p.t.range); return <circle key={p.i} cx={x(p.i)} cy={y(p.t.value)} r="4" className={f === "high" ? "p-high" : f === "low" ? "p-low" : "p-ok-dot"} />; })}
    </svg>
  );
}
