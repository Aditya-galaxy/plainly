import { useEffect, useMemo, useRef, useState } from "react";
import "./App.css";
import Vitals from "./Vitals.tsx";
import Install from "./Install.tsx";
import { deviceAvailability, explain, plainExplanation, prepareDevice, readPhoto, tidyNotes, type Explained } from "./lib/ai.ts";
import { firebase, firebaseConfigured, settings } from "./lib/firebase.ts";
import { parseMeta, parseRows } from "./lib/parse.ts";
import { pdfLines, pdfPreview } from "./lib/pdf.ts";
import { distance, flagOf, nearEdge, trendOf, verifyAgainstText, type Test, type Trend } from "./lib/ranges.ts";
import { clearReports, dateValue, listReports, saveReport, type SavedReport } from "./lib/vault.ts";
import { redFlags, tidyIsFaithful } from "./lib/symptoms.ts";

type Report = { tests: Test[]; age?: number; sex?: "female" | "male"; date?: string; preview?: string; readBy: "rules" | "on_device" };
type Row = Test & { flag: ReturnType<typeof flagOf>; edge: boolean; trend?: Trend; id: string };

const pref = (k: string, d: boolean) => {
  try {
    const v = localStorage.getItem(k);
    return v === null ? d : v === "1";
  } catch {
    return d;
  }
};

async function fileToJpeg(file: Blob, maxWidth: number): Promise<string> {
  const url = URL.createObjectURL(file);
  try {
    const img = new Image();
    img.src = url;
    await img.decode();
    const scale = Math.min(1, maxWidth / img.naturalWidth);
    const c = document.createElement("canvas");
    c.width = Math.round(img.naturalWidth * scale);
    c.height = Math.round(img.naturalHeight * scale);
    c.getContext("2d")!.drawImage(img, 0, 0, c.width, c.height);
    return c.toDataURL("image/jpeg", 0.85);
  } finally {
    URL.revokeObjectURL(url);
  }
}

export default function App() {
  const [allowCloud, setAllowCloud] = useState(() => pref("pl.cloud", false));
  const [tab, setTab] = useState<"report" | "vitals">("report");
  const [vitalsLines, setVitalsLines] = useState<string[]>([]);
  const [nano, setNano] = useState({ status: "checking", progress: 0 });
  const [report, setReport] = useState<Report | null>(null);
  const [earlier, setEarlier] = useState<SavedReport[]>([]);
  const [explained, setExplained] = useState<Record<string, Explained | "busy">>({});
  const [busy, setBusy] = useState("");
  const [error, setError] = useState("");
  const [showNormal, setShowNormal] = useState(false);
  const [notes, setNotes] = useState(() => {
    try { return sessionStorage.getItem("pl.notes") ?? ""; } catch { return ""; }
  });
  const [tidied, setTidied] = useState<{ text: string; note?: string } | null>(null);
  const flags = useMemo(() => redFlags(notes), [notes]);
  const fileInput = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (firebaseConfigured) {
      try {
        firebase();
        settings();
      } catch (e) {
        setError((e as Error).message);
      }
    }
    deviceAvailability().then((s) => setNano({ status: s, progress: 0 }));
  }, []);

  const toggleCloud = (v: boolean) => {
    setAllowCloud(v);
    try {
      localStorage.setItem("pl.cloud", v ? "1" : "0");
    } catch {
      /* not remembered */
    }
  };

  const nanoReady = nano.status === "available";

  const prepare = async () => {
    setError("");
    setNano({ status: "downloading", progress: 0 });
    try {
      await prepareDevice((p) => setNano({ status: "downloading", progress: p }));
      setNano({ status: await deviceAvailability(), progress: 1 });
    } catch (e) {
      setNano({ status: "unavailable", progress: 0 });
      setError(`Gemini Nano couldn't start: ${(e as Error).message}`);
    }
  };

  /** Reads a report into results. The file itself never leaves this browser. */
  const openFile = async (file: File, opts: { keepEarlier?: boolean } = {}) => {
    setError("");
    setExplained({});
    setShowNormal(false);
    setBusy("Reading your report on this device…");
    try {
      let r: Report;
      if (file.type === "application/pdf" || file.name.toLowerCase().endsWith(".pdf")) {
        const data = await file.arrayBuffer();
        const lines = await pdfLines(data.slice(0));
        const meta = parseMeta(lines);
        let tests = parseRows(lines);
        let readBy: Report["readBy"] = "rules";
        if (tests.length < 3 && nanoReady) {
          // An unusual layout: let Gemini Nano read the first page, then check its numbers against the PDF's text.
          const page = await pdfPreview(data.slice(0), 1400);
          const got = await readPhoto(page.split(",")[1]);
          tests = verifyAgainstText(got.tests, lines.join(" "));
          readBy = "on_device";
        }
        r = { tests, ...meta, preview: await pdfPreview(data.slice(0)), readBy };
      } else if (file.type.startsWith("image/")) {
        if (!nanoReady) throw new Error("Reading a photo needs Gemini Nano on this device, and photos are never sent to the cloud. Prepare Gemini Nano above, or open the PDF version of the report.");
        const jpeg = await fileToJpeg(file, (await settings()).image_width);
        const got = await readPhoto(jpeg.split(",")[1]);
        r = { ...got, preview: jpeg, readBy: "on_device" };
      } else {
        throw new Error("Open a PDF or a photo (JPEG or PNG) of your report.");
      }
      if (!r.tests.length) throw new Error("No results were found in this report. If it's a scan, try a clear, flat photo in good light.");
      const prior = (await listReports()).filter((x) => x.date !== r.date && (!r.date || dateValue(x.date) < dateValue(r.date)));
      setEarlier(opts.keepEarlier ? prior : prior);
      setReport(r);
      await saveReport({ id: `${r.date ?? "undated"}-${r.tests.length}-${r.tests[0]?.value}`, date: r.date, savedAt: Date.now(), tests: r.tests });
    } catch (e) {
      setError((e as Error).message);
    }
    setBusy("");
  };

  const trySample = async () => {
    setError("");
    setBusy("Loading the sample…");
    try {
    // The earlier sample report goes into the local history first, so the November one shows trends.
    const prev = await (await fetch("/sample/report-may-2026.pdf")).arrayBuffer();
    const lines = await pdfLines(prev);
    const m = parseMeta(lines);
    await saveReport({ id: `sample-${m.date}`, date: m.date, savedAt: Date.now() - 1, tests: parseRows(lines) });
    const blob = await (await fetch("/sample/report-nov-2026.pdf")).blob();
    await openFile(new File([blob], "report-nov-2026.pdf", { type: "application/pdf" }), { keepEarlier: true });
    } catch (e) {
      setError((e as Error).message);
      setBusy("");
    }
  };

  const tryPhoto = async () => {
    const blob = await (await fetch("/sample/report-photo.jpg")).blob();
    await openFile(new File([blob], "report-photo.jpg", { type: "image/jpeg" }));
  };

  const rows: Row[] = useMemo(() => {
    if (!report) return [];
    return report.tests.map((t, i) => ({
      ...t,
      id: `${i}-${t.name}`,
      flag: flagOf(t.value, t.range),
      edge: nearEdge(t.value, t.range),
      trend: trendOf(t, earlier),
    }));
  }, [report, earlier]);
  const outside = rows.filter((r) => r.flag === "high" || r.flag === "low").sort((a, b) => distance(b.value, b.range) - distance(a.value, a.range));
  const edge = rows.filter((r) => r.edge);
  const normal = rows.filter((r) => r.flag === "normal" && !r.edge);
  const unknown = rows.filter((r) => r.flag === "unknown");

  const explainAll = async () => {
    if (!report) return;
    setError("");
    for (const r of [...outside, ...edge]) {
      if (explained[r.id] && explained[r.id] !== "busy") continue;
      setExplained((x) => ({ ...x, [r.id]: "busy" }));
      let e: Explained;
      try {
        e = firebaseConfigured ? await explain(r, report, r.trend, allowCloud) : plainExplanation(r, r.trend);
      } catch {
        e = { ...plainExplanation(r, r.trend), note: allowCloud ? "Couldn't reach a model just now, so a plain summary is shown." : "Gemini Nano isn't ready on this device and cloud is off, so a plain summary is shown." };
      }
      setExplained((x) => ({ ...x, [r.id]: e }));
    }
  };

  const questions = [...outside, ...edge].flatMap((r) => {
    const e = explained[r.id];
    return e && e !== "busy" ? e.questions.map((q) => ({ test: r.name, q })) : [];
  });
  const sources = Object.values(explained).filter((e): e is Explained => e !== "busy");
  const nDevice = sources.filter((s) => s.source === "on_device").length;
  const nCloud = sources.filter((s) => s.source === "in_cloud").length;

  const reset = () => {
    setReport(null);
    setExplained({});
    setError("");
  };

  return (
    <div className="page">
      <header className="top no-print">
        <button className="wordmark" onClick={reset} aria-label="Plainly home">
          <svg viewBox="0 0 20 20" aria-hidden="true"><path d="M3 10h4l2-5 3 10 2-5h3" /></svg>Plainly
        </button>
        <label className="toggle" title="Only de-identified values are ever sent: test, number, unit, range, age band and sex.">
          <input type="checkbox" checked={allowCloud} onChange={(e) => toggleCloud(e.target.checked)} />
          <span className="track" aria-hidden="true" />
          <span>Cloud explanations</span>
        </label>
      </header>
      <Install />

      <p className="where no-print">
        <span className={`status ${nanoReady ? "good" : ""}`}>
          <span className="dot" />Gemini Nano: {nano.status === "downloading" ? `downloading ${Math.round(nano.progress * 100)}%` : nanoReady ? "on this device" : nano.status === "checking" ? "checking" : nano.status === "downloadable" ? "not downloaded" : "not available here"}
          {nano.status === "downloadable" && <> · <button className="text" onClick={prepare}>prepare</button></>}
        </span>
        <span>Your report never leaves this device{allowCloud ? " · explanations may use the cloud with de-identified values" : ""}</span>
      </p>

      <nav className="tabs no-print" aria-label="Sections">
        <button className={tab === "report" ? "on" : ""} onClick={() => setTab("report")}>Lab report</button>
        <button className={tab === "vitals" ? "on" : ""} onClick={() => setTab("vitals")}>Vitals</button>
      </nav>
      {tab === "vitals" && <Vitals added={vitalsLines.length > 0} onAddToSheet={(lines) => { setVitalsLines(lines); setTab("report"); }} />}
      {error && <p className="error no-print" role="alert">{error}</p>}
      {busy && <p className="busy no-print" aria-live="polite">{busy}</p>}

      {tab === "report" && !report && !busy && (
        <main className="hero">
          <h1>Your lab report,<br /><em>in plain words.</em></h1>
          <p className="lead">
            Open a PDF or take a photo of a blood test report. Plainly reads it on your device, shows what's outside
            the normal range and what changed since last time, and helps you prepare questions for your doctor.
          </p>
          <div className="cta">
            <button className="primary" onClick={() => fileInput.current?.click()}>Open a report</button>
            <button className="quiet" onClick={trySample}>Try a sample report</button>
            <button className="text" onClick={tryPhoto}>or a sample photo</button>
          </div>
          <input ref={fileInput} type="file" accept="application/pdf,image/jpeg,image/png" capture="environment" hidden
            onChange={(e) => e.target.files?.[0] && openFile(e.target.files[0])} />
          <ul className="promises">
            <li><b>Read on your device.</b> The report, photo, name and lab details are never uploaded.</li>
            <li><b>Numbers checked by code.</b> Ranges, flags and trends are worked out exactly, not by AI.</li>
            <li><b>Explains, never diagnoses.</b> Every explanation is checked before you see it.</li>
          </ul>
          {vitalsLines.length > 0 && (
            <section className="doctor">
              <h2>For my doctor</h2>
              <h3>From my watch (last week vs my usual)</h3>
              <ul>{vitalsLines.map((l, i) => <li key={i}>{l}</li>)}</ul>
              <p className="hint">Open a report to add your results and questions to this sheet.</p>
            </section>
          )}
          {!nanoReady && nano.status !== "checking" && (
            <p className="hint">PDFs work everywhere. Photos and on-device explanations need Gemini Nano in desktop Chrome 139+ (about 22 GB free disk; enable <code>chrome://flags/#prompt-api-for-gemini-nano-multimodal-input</code>), or the Plainly Android app on a supported phone.</p>
          )}
        </main>
      )}

      {tab === "report" && report && (
        <main className="report">
          <section className="summary">
            <div>
              <p className="eyebrow">{report.date ? `Report from ${report.date}` : "Your report"}{report.age ? ` · ${report.age} y` : ""}{report.sex ? ` · ${report.sex}` : ""}</p>
              <h1>{outside.length ? `${outside.length} result${outside.length === 1 ? "" : "s"} outside the range` : "Everything is within range"}</h1>
              <p className="counts">
                <span><i className="sw high" />{outside.filter((r) => r.flag === "high").length} high</span>
                <span><i className="sw low" />{outside.filter((r) => r.flag === "low").length} low</span>
                <span><i className="sw edge" />{edge.length} near a limit</span>
                <span><i className="sw ok" />{normal.length} in range</span>
              </p>
              <p className="readby">
                Read {report.readBy === "rules" ? "from the PDF's text, by rules (no AI)" : "by Gemini Nano on this device"}
                {earlier.length ? ` · compared with ${earlier.length} earlier report${earlier.length === 1 ? "" : "s"} saved on this device` : ""}
              </p>
            </div>
            {report.preview && <img className="thumb no-print" src={report.preview} alt="Your report" />}
          </section>

          <div className="toolbar no-print">
            <button className="primary" onClick={explainAll} disabled={!outside.length && !edge.length}>Explain my results</button>
            <button className="quiet" onClick={() => window.print()}>Print for my doctor</button>
            <button className="quiet" onClick={reset}>Open another</button>
            {(nDevice > 0 || nCloud > 0) && <span className="tally"><i className="dot device" />{nDevice} on this device <i className="dot cloud" />{nCloud} in the cloud</span>}
          </div>

          <ol className="results">
            {[...outside, ...edge].map((r) => <Result key={r.id} r={r} e={explained[r.id]} />)}
          </ol>

          {normal.length > 0 && (
            <section className="normal">
              <button className="text no-print" onClick={() => setShowNormal((v) => !v)}>
                {showNormal ? "Hide" : "Show"} the {normal.length} results within range
              </button>
              {(showNormal || window.matchMedia?.("print").matches) && <ol className="results compact">{normal.map((r) => <Result key={r.id} r={r} />)}</ol>}
            </section>
          )}
          {unknown.length > 0 && <p className="hint">{unknown.length} result{unknown.length === 1 ? " has" : "s have"} no reference range Plainly could read, so {unknown.length === 1 ? "it isn't" : "they aren't"} flagged.</p>}

          <section className="notes no-print">
            <h2>Anything you've noticed?</h2>
            <p className="hint">Symptoms, how long, how often. They go on the sheet for your doctor and never leave this device.</p>
            <textarea value={notes} rows={3} placeholder="For example: tired for 3 weeks, cold hands, short of breath on stairs"
              onChange={(e) => { setNotes(e.target.value); setTidied(null); try { sessionStorage.setItem("pl.notes", e.target.value); } catch { /* not kept */ } }} />
            {notes.trim() && nanoReady && (
              <button className="text" onClick={async () => {
                try {
                  const out = await tidyNotes(notes);
                  setTidied(tidyIsFaithful(out, notes) ? { text: out } : { text: notes, note: "The tidied version added words you didn't write, so your own notes are kept." });
                } catch { setTidied({ text: notes, note: "Gemini Nano couldn't tidy the notes just now." }); }
              }}>Tidy my notes on this device</button>
            )}
          </section>
          {flags.length > 0 && (
            <section className="redflag" role="alert">
              <h2>Get care now</h2>
              {flags.map((f) => <p key={f.id}><b>{f.label}.</b> {f.advice}</p>)}
              <p className="hint">Plainly can't assess symptoms. These are standard warning signs that need a doctor straight away, not a result from AI.</p>
            </section>
          )}
          {(questions.length > 0 || notes.trim() || vitalsLines.length > 0) && (
            <section className="doctor">
              <h2>For my doctor</h2>
              {notes.trim() && (<>
                <h3>What I've noticed</h3>
                <p className="notes-out">{tidied?.text ?? notes}</p>
                {tidied?.note && <p className="note no-print">{tidied.note}</p>}
              </>)}
              {questions.length > 0 && (<>
                <h3>Questions about my results</h3>
                <ul>{questions.map((x, i) => <li key={i}><b>{x.test}:</b> {x.q}</li>)}</ul>
              </>)}
              {vitalsLines.length > 0 && (<>
                <h3>From my watch (last week vs my usual)</h3>
                <ul>{vitalsLines.map((l, i) => <li key={i}>{l}</li>)}</ul>
              </>)}
            </section>
          )}
          <p className="disclaimer">Plainly explains lab values and never diagnoses. Reference ranges are the ones printed on your report. Talk to your doctor before making any health decision.</p>
          <p className="no-print"><button className="text" onClick={async () => { await clearReports(); setEarlier([]); }}>Forget saved reports on this device</button></p>
        </main>
      )}
      <footer className="foot no-print">Built on Firebase AI Logic hybrid inference · reports are read on-device; the cloud sees only de-identified values.</footer>
    </div>
  );
}

function RangeBar({ r }: { r: Row }) {
  const { low, high } = r.range;
  const lo = low ?? (high !== undefined ? 0 : r.value * 0.5);
  const hi = high ?? (low !== undefined ? low * 2 : r.value * 1.5);
  const span = hi - lo || 1;
  const min = lo - span * 0.5;
  const max = hi + span * 0.5;
  const pos = (v: number) => `${Math.min(100, Math.max(0, ((v - min) / (max - min)) * 100))}%`;
  return (
    <div className="bar" aria-hidden="true">
      <div className="band" style={{ left: pos(lo), width: `calc(${pos(hi)} - ${pos(lo)})` }} />
      {r.trend && <div className="mark prev" style={{ left: pos(r.trend.previous) }} title={`Last time: ${r.trend.previous}`} />}
      <div className={`mark now ${r.flag}`} style={{ left: pos(r.value) }} />
    </div>
  );
}

function Result({ r, e }: { r: Row; e?: Explained | "busy" }) {
  const label = r.flag === "high" ? "High" : r.flag === "low" ? "Low" : r.edge ? "Near a limit" : "In range";
  return (
    <li className={`result ${r.flag} ${r.edge ? "edge" : ""}`}>
      <div className="head">
        <span className="name">{r.name}</span>
        <span className="value">{r.value} <small>{r.unit}</small></span>
        <span className={`chip ${r.flag} ${r.edge ? "edge" : ""}`}>{label}</span>
      </div>
      <RangeBar r={r} />
      <p className="sub">
        Reference {r.range.text || "not printed"}
        {r.trend && <> · last time {r.trend.previous} <span className={`trend ${r.trend.direction}`}>{r.trend.direction === "up" ? "↑" : r.trend.direction === "down" ? "↓" : "→"}</span></>}
        {r.verified === false && <> · <span className="check">check this value against your report</span></>}
      </p>
      {e === "busy" && <p className="explain muted">Writing an explanation…</p>}
      {e && e !== "busy" && (
        <div className="explain">
          <p>{e.text}</p>
          <p className="meta"><span className={`tag ${e.source}`}>{e.source === "on_device" ? "explained on this device" : e.source === "in_cloud" ? "explained in the cloud, de-identified" : "plain summary"}</span>{e.note && <span className="note">{e.note}</span>}</p>
        </div>
      )}
    </li>
  );
}
