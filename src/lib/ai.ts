import { AgentPlatformBackend, getAI, getGenerativeModel, GoogleAIBackend, InferenceMode, type GenerativeModel, type Part } from "firebase/ai";
import { deidentify, type CloudTest } from "./deid.ts";
import { firebase, settings } from "./firebase.ts";
import { checkExplanation } from "./guard.ts";
import { flagOf, parseRange, type Test, type Trend } from "./ranges.ts";

/**
 * Two jobs, two privacy rules:
 *  - READING a report (a photo) is ON-DEVICE ONLY. The raw report never leaves the device, whatever the
 *    "Allow cloud" switch says. No Gemini Nano, no photo reading (PDFs still work through the rule-based reader).
 *  - EXPLAINING a value uses the same de-identified facts on-device or in the cloud: test, number, unit, range,
 *    flag, earlier value, age band, sex. Nothing else exists in the prompt, so nothing else can leak.
 */

export type Source = "on_device" | "in_cloud" | "rules";

const READ_SYSTEM =
  "You read a medical laboratory report and copy its results exactly. " +
  "For every test row, copy the test name, the result value exactly as printed, the unit, and the reference interval as printed. " +
  "Never guess a missing value. Do not copy the patient's name, IDs, phone, address, doctor or lab name. " +
  "Also give the patient's age in years and sex if printed, and the sample collection date if printed.";

const READ_SCHEMA: Record<string, unknown> = {
  type: "object",
  properties: {
    age: { type: "integer" },
    sex: { type: "string", enum: ["female", "male", "unknown"] },
    date: { type: "string" },
    tests: {
      type: "array",
      items: {
        type: "object",
        properties: { name: { type: "string" }, value: { type: "string" }, unit: { type: "string" }, range: { type: "string" } },
        required: ["name", "value", "unit", "range"],
      },
    },
  },
  required: ["tests"],
};

const EXPLAIN_SYSTEM =
  "You help a person understand one result on their own lab report, in plain, calm English for someone without medical training. " +
  "Use only the facts given. Say what the test measures in one sentence, where the value sits against the printed reference interval, " +
  "and, if an earlier value is given, which way it moved. Do not diagnose, do not name a disease the person has, do not suggest medicines or doses. " +
  "Only use numbers that appear in the facts. End by suggesting they discuss it with their doctor. " +
  "Then give two short questions they could ask their doctor.";

const EXPLAIN_SCHEMA: Record<string, unknown> = {
  type: "object",
  properties: {
    explanation: { type: "string", maxLength: 600 },
    questions: { type: "array", items: { type: "string", maxLength: 160 }, maxItems: 2 },
  },
  required: ["explanation", "questions"],
};

type Models = { reader: GenerativeModel; explainer: GenerativeModel };
const cache = new Map<string, Models>();

async function models(allowCloud: boolean): Promise<Models> {
  const s = await settings();
  const key = `${allowCloud}:${s.cloud_model}`;
  const hit = cache.get(key);
  if (hit) return hit;
  const backend = import.meta.env.VITE_AI_BACKEND === "google" ? new GoogleAIBackend() : new AgentPlatformBackend("global");
  const ai = getAI(firebase(), { backend });
  const onDevice = (system: string, schema: Record<string, unknown>, image: boolean) => ({
    createOptions: {
      expectedInputs: image ? [{ type: "text" as const, languages: ["en"] }, { type: "image" as const }] : [{ type: "text" as const, languages: ["en"] }],
      expectedOutputs: [{ type: "text" as const, languages: ["en"] }],
      initialPrompts: [{ role: "system" as const, content: [{ type: "text" as const, value: system }] }],
    },
    promptOptions: { responseConstraint: schema },
  });
  const m: Models = {
    // The reader never gets a cloud fallback: a report image is the most private thing in the app.
    reader: getGenerativeModel(ai, { mode: InferenceMode.ONLY_ON_DEVICE, onDeviceParams: onDevice(READ_SYSTEM, READ_SCHEMA, true) }),
    explainer: getGenerativeModel(ai, {
      mode: allowCloud ? InferenceMode.PREFER_ON_DEVICE : InferenceMode.ONLY_ON_DEVICE,
      onDeviceParams: onDevice(EXPLAIN_SYSTEM, EXPLAIN_SCHEMA, false),
      inCloudParams: {
        model: s.cloud_model,
        systemInstruction: EXPLAIN_SYSTEM,
        generationConfig: { temperature: 0.2, maxOutputTokens: 400, responseMimeType: "application/json", responseJsonSchema: EXPLAIN_SCHEMA },
      },
    }),
  };
  cache.set(key, m);
  return m;
}

export async function deviceAvailability(): Promise<string> {
  const LM = (globalThis as unknown as { LanguageModel?: { availability(o?: object): Promise<string> } }).LanguageModel;
  if (!LM) return "unsupported";
  try {
    return await LM.availability({ expectedInputs: [{ type: "text", languages: ["en"] }, { type: "image" }] });
  } catch {
    return "unavailable";
  }
}

/** Starts or finishes the Gemini Nano download. Chrome requires this to come from a click. */
export async function prepareDevice(onProgress: (p: number) => void): Promise<void> {
  const { reader, explainer } = await models(false);
  await reader.initializeDeviceModel(onProgress);
  await explainer.initializeDeviceModel();
}

function parseJson<T>(raw: string): T | undefined {
  const a = raw.indexOf("{");
  const b = raw.lastIndexOf("}");
  try {
    return JSON.parse(raw.slice(a, b + 1)) as T;
  } catch {
    return undefined;
  }
}

export type Reading = { tests: Test[]; age?: number; sex?: "female" | "male"; date?: string };

/** Reads a photographed report with Gemini Nano, on this device only. */
export async function readPhoto(jpegBase64: string): Promise<Reading> {
  const { reader } = await models(false);
  const parts: (string | Part)[] = [
    "Copy every test result from this lab report.",
    { type: "inlineData", inlineData: { data: jpegBase64, mimeType: "image/jpeg" } },
  ];
  const res = await reader.generateContent(parts);
  const out = parseJson<{ age?: number; sex?: string; date?: string; tests?: { name: string; value: string; unit: string; range: string }[] }>(res.response.text());
  const tests: Test[] = [];
  for (const t of out?.tests ?? []) {
    const v = Number(String(t.value).replace(/[^\d.\-]/g, ""));
    if (!t.name || !Number.isFinite(v)) continue;
    // Photos can't be checked against text, so every value read from one is marked for the person to confirm.
    tests.push({ name: t.name.trim(), value: v, unit: (t.unit ?? "").trim(), range: parseRange(t.range ?? ""), raw: String(t.value), verified: false });
  }
  const sex = out?.sex === "female" || out?.sex === "male" ? out.sex : undefined;
  return { tests, age: out?.age && out.age > 0 && out.age < 120 ? out.age : undefined, sex, date: out?.date };
}

export type Explained = { text: string; questions: string[]; source: Source; note?: string };

const TIDY =
  "Rewrite these notes a person wrote for their doctor as a short bullet list. Keep their own words and every detail " +
  "(how long, how often, when). Drop filler. Do not add anything, do not guess causes, do not name conditions. " +
  "Return only the bullet list, one item per line starting with \"- \".";
let tidier: GenerativeModel | undefined;

/** Tidies symptom notes with Gemini Nano. On this device only: symptom notes are never sent to the cloud. */
export async function tidyNotes(notes: string): Promise<string> {
  const ai = getAI(firebase(), { backend: new GoogleAIBackend() });
  tidier ??= getGenerativeModel(ai, {
    mode: InferenceMode.ONLY_ON_DEVICE,
    onDeviceParams: { createOptions: { expectedInputs: [{ type: "text", languages: ["en"] }], expectedOutputs: [{ type: "text", languages: ["en"] }],
      initialPrompts: [{ role: "system", content: [{ type: "text", value: TIDY }] }] } },
  });
  const res = await tidier.generateContent(notes.slice(0, 2000));
  return res.response.text().trim();
}

/** The template explanation: used when no model is available, or when a model's answer fails the guard. */
export function plainExplanation(t: Test, trend?: Trend): Explained {
  const f = flagOf(t.value, t.range);
  const where = f === "high" ? "above" : f === "low" ? "below" : f === "normal" ? "within" : "compared with";
  const lim = t.range.text ? ` the printed reference interval (${t.range.text})` : " the reference interval";
  const moved = trend
    ? trend.direction === "same" ? ` It is about the same as last time (${trend.previous} ${t.unit}).` : ` It has gone ${trend.direction} from ${trend.previous} ${t.unit} last time.`
    : "";
  return {
    text: `Your ${t.name} is ${t.value} ${t.unit}, ${where}${lim}.${moved} Ask your doctor what this means for you.`,
    questions: [`What could be behind my ${t.name} result?`, `Should I repeat this test, and when?`],
    source: "rules",
  };
}

/** Explains one result from de-identified facts only, and checks the answer before returning it. */
export async function explain(t: Test, who: { age?: number; sex?: string }, trend: Trend | undefined, allowCloud: boolean): Promise<Explained> {
  const facts: CloudTest = deidentify(t, who, trend);
  const allowed = [t.value, t.range.low, t.range.high, trend?.previous, trend ? Math.abs(trend.change) : undefined]
    .filter((n): n is number => typeof n === "number");
  if (who.age) allowed.push(who.age);
  const { explainer } = await models(allowCloud);
  const res = await explainer.generateContent(`Facts: ${JSON.stringify(facts)}`);
  const source = (res.response.inferenceSource ?? (allowCloud ? "in_cloud" : "on_device")) as Source;
  const out = parseJson<{ explanation?: string; questions?: string[] }>(res.response.text());
  const text = (out?.explanation ?? "").replace(/\s+/g, " ").trim();
  const verdict = checkExplanation(text, allowed);
  if (!verdict.ok) return { ...plainExplanation(t, trend), source, note: "A summary is shown instead of the written explanation." };
  const questions = (out?.questions ?? []).map((q) => q.trim()).filter((q) => q && checkExplanation(`${q} Ask your doctor.`, allowed).ok).slice(0, 2);
  return { text, questions: questions.length ? questions : plainExplanation(t, trend).questions, source };
}
