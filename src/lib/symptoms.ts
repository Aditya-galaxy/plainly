/**
 * What the person notices goes on the sheet for their doctor. Plainly never turns symptoms into a diagnosis or a
 * test recommendation. One thing it does do, with fixed rules and no AI: if the notes mention a warning sign that
 * needs care now, it says so straight away.
 *
 * The signs are the widely published emergency warning signs (chest pain, trouble breathing, the FAST signs of a
 * stroke, fainting, heavy bleeding, seizures, thoughts of self-harm). Matching is deliberately generous: a false
 * "get care now" costs a phone call; a missed one can cost far more.
 */

export type RedFlag = { id: string; label: string; advice: string };

const CALL = "Call 112 (emergency) or go to the nearest emergency department now.";

const RULES: { id: string; label: string; advice: string; re: RegExp }[] = [
  { id: "chest", label: "Chest pain or pressure", advice: CALL,
    re: /\b(chest|heart)\b[^.]{0,30}\b(pain|pressure|tight|tightness|squeez|heavy|ache|hurt)|\b(pain|pressure|tightness)\b[^.]{0,20}\bchest\b/i },
  { id: "breath", label: "Trouble breathing", advice: CALL,
    re: /\b(can'?t|cannot|hard to|difficult(y)? (in )?|trouble|struggl\w*|short(ness)? of)\s*(breath|breathe|breathing)|\bbreathless\w*|\bgasping\b/i },
  { id: "stroke", label: "Signs of a stroke (face, arm, speech)", advice: CALL,
    re: /\b(face|mouth)\b[^.]{0,20}\b(droop|drooping|numb|weak|uneven)|\b(arm|leg|one side)\b[^.]{0,20}\b(weak|weakness|numb|can'?t move|paraly)|\b(slurred|garbled|trouble)\s*(speech|speaking|talking)|\bsudden(ly)?\b[^.]{0,25}\b(confus|vision|blind|severe headache|worst headache)/i },
  { id: "faint", label: "Fainting or passing out", advice: CALL,
    re: /\b(faint(ed|ing)?|pass(ed|ing)? out|blacked out|lost consciousness|unconscious|collapsed)\b/i },
  { id: "bleed", label: "Heavy bleeding, or vomiting or coughing blood", advice: CALL,
    re: /\b(vomit\w*|cough\w*|throw\w* up)\b[^.]{0,20}\bblood|\bblood\b[^.]{0,20}\b(vomit|stool|poo|cough)|\bblack (tarry )?stools?\b|\b(heavy|severe|won'?t stop)\b[^.]{0,15}\bbleed/i },
  { id: "seizure", label: "A seizure or fit", advice: CALL, re: /\b(seizure|convulsion|fit(s)?\b(?! ?bit)|fitting)\b/i },
  { id: "selfharm", label: "Thoughts of harming yourself", advice:
      "You don't have to face this alone. Call Tele-MANAS on 14416 (free, 24×7, India) or 112 in an emergency. If you can, tell someone near you now.",
    re: /\b(suicid\w*|kill (myself|me)|end (my|it all)|self[- ]?harm|hurt(ing)? myself|don'?t want to (live|be alive))\b/i },
];

export function redFlags(text: string): RedFlag[] {
  return RULES.filter((r) => r.re.test(text)).map(({ id, label, advice }) => ({ id, label, advice }));
}

// ── tidying notes, on-device only, without adding anything ──
const STOP = new Set("the a an and or but to of in on at for with from this that it is are was were be been i my me you we it's i'm im have has had".split(" "));
const words = (t: string) => (t.toLowerCase().match(/[a-z0-9']+/g) ?? []).map((w) => w.replace(/'s$/, "").replace(/(ing|ed|es|s)$/, "")).filter((w) => w.length > 2 && !STOP.has(w));

/** A tidied list may reorder and shorten the person's notes, but every content word must be one they wrote. */
export function tidyIsFaithful(tidied: string, notes: string): boolean {
  const src = new Set(words(notes));
  const out = words(tidied);
  if (!out.length) return false;
  return out.filter((w) => !src.has(w)).length / out.length <= 0.15 && tidied.length <= notes.length * 1.6 + 40;
}
