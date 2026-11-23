import { useEffect, useState } from "react";

type PromptEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };

const standalone = () =>
  window.matchMedia("(display-mode: standalone)").matches || (navigator as Navigator & { standalone?: boolean }).standalone === true;
const isIos = () => /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);

/** "Add Plainly to your home screen": Safari on iPhone has no install prompt, so it gets the two taps to make; Chrome
 *  on Android gets a real Install button. Hidden once installed or dismissed. */
export default function Install() {
  const [prompt, setPrompt] = useState<PromptEvent | null>(null);
  const [hidden, setHidden] = useState(() => {
    try { return standalone() || localStorage.getItem("pl.installHint") === "off"; } catch { return standalone(); }
  });
  useEffect(() => {
    const on = (e: Event) => { e.preventDefault(); setPrompt(e as PromptEvent); };
    window.addEventListener("beforeinstallprompt", on);
    return () => window.removeEventListener("beforeinstallprompt", on);
  }, []);
  const dismiss = () => { setHidden(true); try { localStorage.setItem("pl.installHint", "off"); } catch { /* private mode */ } };
  if (hidden || (!prompt && !isIos())) return null;
  return (
    <p className="install no-print" role="note">
      {prompt ? (
        <><span>Use Plainly like an app, even offline.</span> <button className="text" onClick={async () => { await prompt.prompt(); setPrompt(null); dismiss(); }}>Install</button></>
      ) : (
        <span>Use Plainly like an app: tap <ShareIcon /> <b>Share</b>, then <b>Add to Home Screen</b>.</span>
      )}
      <button className="text close" aria-label="Dismiss" onClick={dismiss}>×</button>
    </p>
  );
}

function ShareIcon() {
  return (
    <svg width="14" height="16" viewBox="0 0 14 18" aria-hidden="true" style={{ verticalAlign: "-2px" }}>
      <path d="M7 1v10M3.5 4.5 7 1l3.5 3.5M4 7H2v10h10V7h-2" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}
