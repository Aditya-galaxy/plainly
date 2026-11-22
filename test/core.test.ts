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
