# Plainly

**Your watch and your lab results, explained in plain words. Privately, on your own phone.**

- **Vitals:** reads Apple Health (Apple Watch, WHOOP, Oura, Garmin) or Health Connect (Fitbit, Galaxy Watch, Pixel
  Watch). It compares this week with **your own** last month, with a deep dive and an info pack for every measure.
- **Lab reports:** opens the lab's PDF or a photo, shows what's outside the range and what changed, and explains each
  result.
- **Your doctor:** everything ends in one summary you can share.

It is built on **Firebase AI Logic hybrid inference** on **iOS, Android and the web**:
- **Private (the default):** explanations are written on the device, by Apple's on-device model through the
  Foundation Models framework on iPhone, or by Gemini Nano on Android and in Chrome.
- **Enhanced (opt-in):** Gemini fills in when the device can't write the explanation, and only ever receives the
  numbers, never a name, report or photo.

**Live demo:** https://plainly-app.web.app. **Android:** the APK is in
[the latest release](https://github.com/Aditya-galaxy/plainly/releases/latest). **iPhone:** a ready-to-install
[simulator build](https://github.com/Aditya-galaxy/plainly/releases/tag/ios-v0.1.0), or build from source (below).
All sample data is fictional.

Built for [#BuildHybridAI 2026](https://firebasehybridaihackathon.devpost.com/).

---

## The problem

Lab reports arrive as a PDF or a photo on the phone, full of red "H" and "L" marks and no context. The doctor visit is
often days away and short. So people paste their report into a chatbot. That uploads their name, age, phone number,
patient ID and full results to a cloud service, and the chatbot may misread a number or offer something that sounds
like a diagnosis.

Plainly takes the opposite approach.

## How Plainly works

1. **Reads the report on your device.**
   - **Digital PDFs:** a rule-based reader turns the report's text into results, with no AI involved
     ([`src/lib/parse.ts`](src/lib/parse.ts)).
   - **Photos and unusual layouts:** Gemini Nano reads them in `ONLY_ON_DEVICE` mode. A photo is **never** sent to
     the cloud, whatever the settings say.
   - **Every value is checked against the report's own text** when a text version exists. Values read from a photo are
     marked "check this value against your report".
2. **Code, not AI, does the numbers** ([`src/lib/ranges.ts`](src/lib/ranges.ts)): parsing ranges as labs print them
   ("12.0 - 15.0", "< 100", "> 50", "Upto 40"), high/low flags, near-a-limit warnings, and trends against earlier
   reports saved in the browser.
3. **Explains each result.** The model receives **only** these facts ([`src/lib/deid.ts`](src/lib/deid.ts)): test
   name, value, unit, printed range, the flag code computed, the earlier value, an age band ("50s") and sex. Never the
   name, lab, dates, IDs, doctor or image.
   - **Gemini Nano** writes the explanation on the device when it's available.
   - With **Enhanced explanations** on, Gemini fills in when the device can't, using the same de-identified
     facts.
   - Each explanation says how it was written: "Written privately on this device", "Written with Enhanced
     explanations", or a summary.
4. **Checks every explanation** with a guard ([`src/lib/guard.ts`](src/lib/guard.ts)). An answer is rejected, and a
   plain template shown instead, if it:
   - mentions a number that isn't this test's own (value, range limits, earlier value);
   - reads like a diagnosis ("you have…", "this means you are…");
   - suggests a medicine or a dose;
   - doesn't point back to the doctor.
5. **Prepares a sheet for the doctor:** the questions to ask, printable as one page.
   - It also holds symptoms you type, with fixed red-flag rules (not AI) that tell you when to get care now.

## Vitals from your watch

The **Vitals** tab compares your last 7 days with **your own** previous 28 days, never with a population "ideal".
- **Changes:** resting heart rate, heart rate variability, sleep and overnight blood oxygen count as changed only when
  the move is bigger than your usual day-to-day spread and a minimum that matters (5 bpm, 15% HRV, 45 min sleep,
  2 points SpO₂) ([`src/lib/vitals.ts`](src/lib/vitals.ts)).
- **Recovery today:** 50 is a normal day for you; weighted HRV 50%, resting heart rate 30%, sleep 20%, as in
  [OpenVitals](https://github.com/Aditya-galaxy/openvitals).
- **Safety alerts are fixed rules:** a resting pulse above 100 or below 40 for 3 days, blood oxygen below 90% for 2
  nights, or a rise of 10 bpm or more. Each says what to do; none names a condition.
- **Workout summary** ([`src/lib/workout.ts`](src/lib/workout.ts)): highs and lows, time in each zone (from 220 − age,
  labelled as an estimate), heart-rate recovery one minute after stopping, and a **live replay** at 60× speed.
- **Where the data comes from:**
  - **Android:** Health Connect, which Fitbit, Galaxy Watch, Pixel Watch, Garmin, Zepp, Oura and others sync to.
    Without a watch, **Put sample in Health Connect** writes the fictional sample and reads it back through the real
    API; **Remove Plainly's sample** deletes only what Plainly wrote.
  - **Web:** the built-in fictional sample.
- **The doctor sheet:** **Add to my doctor sheet** puts the week's changes under "From my watch".
- **Same numbers everywhere:** the Android engine ([`Vitals.kt`](android/app/src/main/java/com/kronagent/plainly/Vitals.kt))
  is a line-for-line port, and its tests check the same values as the web.

## On iPhone, Android and the web

| | iPhone (native) | Android (native) | Web |
|---|---|---|---|
| Private explanations | Apple's on-device model (Foundation Models) | Gemini Nano | Gemini Nano in desktop Chrome |
| Enhanced explanations | Gemini via Firebase AI Logic `GeminiLanguageModel` | Gemini via Firebase AI Logic | Gemini via Firebase AI Logic |
| Reading reports | Vision (photo and PDF) | ML Kit (photo) | Rules (PDF); Nano (photo) |
| Vitals | Apple Health | Health Connect | Built-in sample |

The rules (report reading, flags, trends, the guard, red flags, vitals, workouts, the lab-mark cross-check) are ported
line for line to Swift ([`ios/PlainlyCore`](ios/PlainlyCore)), Kotlin and TypeScript, and each platform's tests
assert the same numbers from the same fixtures.

### Try the iPhone app without building

Download `Plainly-iOS-simulator-0.1.0.zip` from the
[iOS release](https://github.com/Aditya-galaxy/plainly/releases/tag/ios-v0.1.0), unzip it, open an iOS 27 iPhone in
Simulator (Xcode 27), and run:

```bash
xcrun simctl install booted Plainly.app && xcrun simctl launch booted com.kronagent.plainly
```

### Build the iPhone app

You need Xcode 27 and an iOS 27 simulator or device. Apple Intelligence must be on for private explanations.

```bash
brew install xcodegen
cd ios && xcodegen generate && open Plainly.xcodeproj   # add your GoogleService-Info.plist to ios/Plainly/
cd PlainlyCore && swift test                             # the shared rules: 15 tests
```

On first launch the app prints an App Check debug token; register it in the Firebase console for Enhanced
explanations.

## How hybrid inference is used

| Job | Where it runs | Firebase mode | Input |
|---|---|---|---|
| Read a photographed report | **On this device only** | `InferenceMode.ONLY_ON_DEVICE` | report image (JPEG) |
| Read a digital PDF | Rules in the browser (no model) | none | the PDF's text |
| Explain a result | On this device, or the cloud when allowed | `PREFER_ON_DEVICE`, or `ONLY_ON_DEVICE` when the cloud is off | de-identified facts only |

- **JSON both ways:** on the device it uses `responseConstraint`; in the cloud, `responseJsonSchema`.
- **Each answer records its source:** `response.inferenceSource` is saved per explanation and shown in the app.
- **Nano is prepared after a click,** as Chrome requires: `initializeDeviceModel()` runs from the "prepare" link and
  shows download progress.

## Firebase products

- **AI Logic:** hybrid inference.
- **App Check:** Fraud Defense (reCAPTCHA Enterprise) in production; the debug provider locally.
- **Remote Config:** the cloud model and the image size sent to Nano.
- **Hosting:** with security headers, and the camera allowed only for the site itself.

There is no database. Earlier reports are kept only in your browser (IndexedDB), as extracted results without images
or names. You can delete them from the app.

## Safety and limits

- **No diagnosis or prescribing.** Plainly explains lab values and doesn't diagnose, treat or prescribe. The guard
  enforces this on every answer.
- **The report's ranges are used.** Reference ranges are the ones printed on your report; Plainly doesn't invent its
  own.
- **Photos can be misread.** Values read from a photo are marked for you to check.
- **The sample is fictional:** a made-up patient and lab, generated by [`tools/sample-report.html`](tools/sample-report.html).

## Run it yourself

You need Node 20+ and a Firebase project.

```bash
git clone https://github.com/Aditya-galaxy/plainly && cd plainly
npm install
cp .env.example .env.local      # fill in your Firebase web config
npm run dev
npm test                        # range parsing, the PDF reader, de-identification and the guard
```

Set up the Firebase project:
1. Add a **Web app** and copy its config into `.env.local`.
2. Go to **AI Logic → Get started**. Choose the Gemini Developer API (free) or the Agent Platform Gemini API (needs
   billing). Set `VITE_AI_BACKEND` to match (`google` or `agent-platform`).
3. In **App Check**, register reCAPTCHA Enterprise for production. For localhost, add a debug token as
   `VITE_APPCHECK_DEBUG_TOKEN`, and never commit it.

For Gemini Nano in Chrome:
1. Use desktop Chrome 139 or later with about 22 GB of free disk.
2. Set `chrome://flags/#prompt-api-for-gemini-nano-multimodal-input` to **Enabled** and restart Chrome.
3. Click **prepare** next to "Gemini Nano".

## Testing it as a judge

1. Open the live demo and press **Try a sample report**. It loads two fictional reports, May and November, so
   trends show.
2. Press **Explain my results**:
   - **Without Nano:** turn on **Enhanced explanations**. Each result says "Written with Enhanced explanations".
   - **With Nano prepared:** results are tagged "explained on this device".
3. With Nano prepared, try **or a sample photo**. The photo is read entirely on the device.
4. Press **Print for my doctor**.
5. Open **Vitals**: the fictional week shows 3 changes and recovery 20. Press **Replay live** on the workout, then
   **Add to my doctor sheet**.
6. **On Android** (sideload the APK from the [latest release](https://github.com/Aditya-galaxy/plainly/releases/latest)): open **Vitals → Connect Health Connect → Put sample in
   Health Connect**.

## Built during the hackathon

All of Plainly was written for #BuildHybridAI, from 22 Nov 2026. The App Check and hybrid-model setup follows my other
entry, [Talkthrough](https://github.com/Aditya-galaxy/talkthrough).

## License

MIT
