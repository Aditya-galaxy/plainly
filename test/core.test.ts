import { test } from "node:test";
import assert from "node:assert/strict";
import { checkExplanation } from "../src/lib/guard.ts";
import { deidentify, ageBand } from "../src/lib/deid.ts";
import { flagOf, nearEdge, parseRange, trendOf, verifyAgainstText } from "../src/lib/ranges.ts";

test("ranges as labs print them", () => {
  assert.deepEqual(parseRange("12.0 - 15.0"), { low: 12, high: 15, text: "12.0 - 15.0" });
  assert.equal(parseRange("< 100").high, 100);
  assert.equal(parseRange("Upto 40").high, 40);
  assert.equal(parseRange(">= 50").low, 50);
  assert.equal(parseRange("30 to 100").low, 30);
  assert.equal(parseRange("See note").low, undefined);
});

test("flags and near-edge", () => {
  const r = parseRange("12.0 - 15.0");
  assert.equal(flagOf(10.9, r), "low");
  assert.equal(flagOf(15.5, r), "high");
  assert.equal(flagOf(13, r), "normal");
  assert.equal(nearEdge(12.3, r), true);
  assert.equal(nearEdge(13.5, r), false);
  assert.equal(flagOf(5, parseRange("See note")), "unknown");
});

test("trend matches the same test and unit in an earlier report", () => {
  const now = { name: "HbA1c", value: 6.1, unit: "%", range: parseRange("4.0 - 5.6") };
  const t = trendOf(now, [{ date: "2026-05-02", tests: [{ name: "HbA1c (Glycated)", value: 5.8, unit: "%", range: parseRange("4.0 - 5.6") }] }]);
  assert.equal(t?.direction, "up");
  assert.equal(t?.previous, 5.8);
});

test("values the model read must appear in the report's text", () => {
  const src = "Haemoglobin 10.9 g/dL 12.0 - 15.0   TSH 6.80 uIU/mL 0.40 - 4.00";
  const out = verifyAgainstText([
    { name: "Haemoglobin", value: 10.9, unit: "g/dL", range: parseRange("12.0 - 15.0") },
    { name: "TSH", value: 6.8, unit: "uIU/mL", range: parseRange("0.40 - 4.00"), raw: "6.80" },
    { name: "Vitamin D", value: 41, unit: "ng/mL", range: parseRange("30 - 100") },
  ], src);
  assert.deepEqual(out.map((t) => t.verified), [true, true, false]);
});

test("guard: explains, never diagnoses or prescribes, numbers must be the test's own", () => {
  const allowed = [6.1, 4.0, 5.6, 5.8];
  assert.equal(checkExplanation("Your HbA1c is 6.1%, above the 5.6% upper limit and up from 5.8% last time. HbA1c reflects average blood sugar over about three months. Ask your doctor what this means for you.", allowed).ok, true);
  assert.equal(checkExplanation("You have diabetes. Ask your doctor.", allowed).ok, false);
  assert.equal(checkExplanation("Your HbA1c is 6.1%. Start metformin 500 mg daily and see your doctor.", allowed).ok, false);
  assert.equal(checkExplanation("Your HbA1c is 6.5%, above the limit. Ask your doctor.", allowed).ok, false);
  assert.equal(checkExplanation("Your HbA1c is 6.1%, a little above the 5.6% upper limit of the range.", allowed).ok, false);
});

test("de-identification keeps only the test, numbers, age band and sex", () => {
  const c = deidentify({ name: "TSH  •  Rhea Sharma", value: 6.8, unit: "uIU/mL", range: parseRange("0.40 - 4.00") }, { age: 52, sex: "F" });
  assert.equal(ageBand(52), "50s");
  assert.deepEqual(Object.keys(c).sort(), ["ageBand", "flag", "range", "sex", "test", "unit", "value"]);
  assert.equal(c.sex, "female");
  assert.equal(c.flag, "high");
});

import { parseMeta, parseRows } from "../src/lib/parse.ts";
test("rule-based reader handles the usual one-test-per-line layout", () => {
  const lines = [
    "Patient: Rhea Sharma Age / Sex: 52 Y / Female Ref. by: Dr. A. Kulkarni",
    "Report ID: FD-88213 Collected: 18 Nov 2026, 08:12",
    "Test Result Unit Biological reference interval",
    "Haemoglobin 10.9 L g/dL 12.0 - 15.0",
    "HbA1c (Glycated Haemoglobin) 6.1 H % 4.0 - 5.6",
    "LDL Cholesterol 148 H mg/dL < 100",
    "HDL Cholesterol 42 L mg/dL > 50",
    "TSH (Thyroid Stimulating Hormone) 6.80 H uIU/mL 0.40 - 4.00",
    "Platelet Count 248 x10^3/uL 150 - 410",
    "Free T4 0.92 ng/dL 0.80 - 1.80",
    "Vitamin B12 212 pg/mL 200 - 900",
    "MCV 76.2 L 83.0 - 101.0",
  ];
  const rows = parseRows(lines);
  assert.deepEqual(rows.map((r) => [r.name, r.value, r.unit]), [
    ["Haemoglobin", 10.9, "g/dL"], ["HbA1c (Glycated Haemoglobin)", 6.1, "%"], ["LDL Cholesterol", 148, "mg/dL"],
    ["HDL Cholesterol", 42, "mg/dL"], ["TSH (Thyroid Stimulating Hormone)", 6.8, "uIU/mL"], ["Platelet Count", 248, "x10^3/uL"],
    ["Free T4", 0.92, "ng/dL"], ["Vitamin B12", 212, "pg/mL"], ["MCV", 76.2, ""],
  ]);
  assert.equal(rows[2].range.high, 100);
  assert.equal(rows[3].range.low, 50);
  assert.deepEqual(parseMeta(lines), { age: 52, sex: "female", date: "18 Nov 2026" });
});

import { readFileSync } from "node:fs";
test("phone OCR of the sample photo (ML Kit on a Redmi): misread units, a lost '<', a decimal comma", () => {
  const lines = readFileSync(new URL("./redmi-mlkit-rows.txt", import.meta.url), "utf8").split("\n");
  const rows = parseRows(lines);
  const by = Object.fromEntries(rows.map((r) => [r.name, r]));
  // Free T4's value was lost by the OCR (it landed on no row), so 15 of the 16 can be read.
  assert.equal(rows.length, 15);
  assert.equal(rows.filter((r) => flagOf(r.value, r.range) === "high" || flagOf(r.value, r.range) === "low").length, 10);
  assert.equal(by["Cholesterol, Total"].range.high, 200);
  assert.equal(by["LDL Cholesterol"].range.high, 100);
  assert.equal(by["TSH (Thyroid Stimulating Hormone)"].value, 6.8);
  assert.deepEqual(["Haemoglobin", "Glucose, Fasting", "Vitamin D, 25-Hydroxy", "Creatinine", "ALT (SGPT)", "Total Leucocyte Count", "TSH (Thyroid Stimulating Hormone)"].map((n) => by[n].unit),
    ["g/dL", "mg/dL", "ng/mL", "mg/dL", "U/L", "x10^3/uL", "uIU/mL"]);
  assert.deepEqual(parseMeta(lines), { age: 52, sex: "female", date: "18 Nov 2026" });
});

import { redFlags, tidyIsFaithful } from "../src/lib/symptoms.ts";
test("red flags: fixed rules catch emergency warning signs, and only those", () => {
  const ids = (t: string) => redFlags(t).map((f) => f.id);
  assert.deepEqual(ids("tired for 3 weeks, cold hands"), []);
  assert.deepEqual(ids("mild headache in the evenings"), []);
  assert.deepEqual(ids("tightness in my chest when climbing stairs"), ["chest"]);
  assert.deepEqual(ids("I get short of breath lying down"), ["breath"]);
  assert.deepEqual(ids("her face is drooping and speech is slurred"), ["stroke"]);
  assert.deepEqual(ids("I fainted at work yesterday"), ["faint"]);
  assert.deepEqual(ids("vomited blood this morning"), ["bleed"]);
  assert.deepEqual(ids("sometimes I don't want to live"), ["selfharm"]);
  assert.ok(redFlags("sometimes I don't want to live")[0].advice.includes("14416"));
});
test("tidied notes may only use the person's own words", () => {
  const notes = "um so ive been really tired for like 3 weeks and my hands are cold all the time";
  assert.equal(tidyIsFaithful("- Tired for 3 weeks\n- Hands cold all the time", notes), true);
  assert.equal(tidyIsFaithful("- Fatigue for 3 weeks, possibly anaemia\n- Poor circulation", notes), false);
});

import { analyse, sampleDays, type Day } from "../src/lib/vitals.ts";
test("vitals: changes are against the person's own baseline; the sample's tired week shows", () => {
  const r = analyse(sampleDays());
  assert.equal(r.days, 35); assert.equal(r.baselineDays, 28); assert.equal(r.recentDays, 7);
  const by = Object.fromEntries(r.changes.map((c) => [c.metric, c]));
  assert.equal(by.restingHr.direction, "worse"); assert.ok(by.restingHr.delta > 0);
  assert.equal(by.hrv.direction, "worse"); assert.equal(by.sleepMin.direction, "worse");
  assert.equal(by.spo2.direction, "steady");
  assert.ok(r.recovery !== undefined && r.recovery < 50, `recovery ${r.recovery}`);
  assert.deepEqual(r.alerts.map((a) => a.id), []); // a tired week is a change to mention, not an emergency
});
test("vitals: fixed safety rules", () => {
  const base: Day[] = Array.from({ length: 35 }, (_, i) => ({ date: `2026-10-${String(i + 1).padStart(2, "0")}`.replace("2026-10-32", "2026-11-01").replace("2026-10-33", "2026-11-02").replace("2026-10-34", "2026-11-03").replace("2026-10-35", "2026-11-04"), restingHr: 64, hrv: 40, sleepMin: 420, spo2: 96 }));
  const high = base.map((d, i) => (i >= 32 ? { ...d, restingHr: 108 } : d));
  assert.ok(analyse(high).alerts.some((a) => a.id === "hr-high"));
  const lowOx = base.map((d, i) => (i >= 33 ? { ...d, spo2: 88 } : d));
  assert.equal(analyse(lowOx).alerts.find((a) => a.id === "spo2-low")?.level, "urgent");
  assert.deepEqual(analyse(base).alerts, []);
  assert.equal(analyse(base).recovery, 50);
});

import { analyseWorkout, sampleWorkout } from "../src/lib/workout.ts";
test("workout summary: highs, lows between efforts, zones, heart-rate recovery", () => {
  const w = analyseWorkout(sampleWorkout(), 52);
  assert.equal(w.maxEstimate, 168);
  assert.equal(w.durationMin, 36);
  assert.equal(w.highs.length, 4);
  assert.ok(w.highs.every((h, i) => i === 0 || h.bpm >= w.highs[i - 1].bpm - 2), "efforts get a little harder");
  assert.ok(w.lows.every((l) => l.t >= 300 && l.bpm < w.highs[0].bpm));
  assert.ok(w.peak.bpm < w.maxEstimate);
  assert.ok((w.recovery1min ?? 0) >= 12);
  assert.equal(Math.round(w.zoneMin.reduce((a, z) => a + z.minutes, 0)), 36);
});
