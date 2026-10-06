# VoxSign iOS V4 · Plan B Final Design Spec (confirmed by the user 2026-10-06)

This document is the single design reference for the V4 implementation. The user replied "ok" to the
Plan B revision.

## 0. Background and baseline

- Project: VoxSign.xcodeproj / scheme VoxSign.
- Hold-state visual baseline (user's real-device photo) and chat reference: the original Doubao
  reference screenshots have been removed from this open-source release; this text stands on its own.
- Version: Info.plist 4.0 (build 10); bundle id = ai.voxsign.ios.

## 1. Must keep (no regression)

1. **Press-to-talk freeze fix** (commit `5f54837`; do not change byte-for-byte):
   - holdGesture dual host (the red bar / waveform area itself carries the gesture; the mic host is no
     longer disabled via allowsHitTesting(false))
   - holdInitiated re-entry guard
   - very-light-tap race fallback (after onEnded, stopHold on the next tick)
   - watchdog cancelHold when isRecording is true but no finger is pressed
   - Touches the call chain in InputBarView.swift + SpeechRecognizer.swift.
2. Doubao-style top bar: centered main title "VoxSign" + subtitle "VoxSign·metasystem" (already done by the earlier V4 agent; keep).
3. Doubao-style bubbles / timestamps, minimal empty state, AI message row collapsed to a … menu (no bell/speaker),
   no "cloud computer / skill" buttons.
4. The four ＋ add-resource kinds (text / URL / image / file); AttachmentPanelView logic kept.

## 2. Default-state input bar (bottom of the chat page, Plan B)

One row of three elements in a light-gray rounded container (mimicking the Doubao chat page):

```
[＋]   [ 🎤 HOLD TO TALK (big black button, flex:1) ]   [⌨]
```

- ＋: ~30×30 circular light-gray background; tap to open the add-resource panel (four kinds).
- **Main button: flex:1 fills the width, near-black background (#1A1A1A) with white text, ~48pt tall,
  ~24pt corner radius, centered "🎤 Hold to talk" (14–15pt bold) — press to start recording.**
- ⌨: ~30×30 circular light-gray keyboard icon; tap to switch to text input (keyboard + input field appear);
  tap again to return to voice mode.
- The empty-state caption must point clearly: **"Hold 🎤 to talk, or tap ⌨ to type"** (no more vague
  copy like "Say something, or hold the button below").

## 3. Hold state (full-bleed waveform) — the core new design of this revision

After pressing and holding the main button, the input bar switches to a **full-bleed waveform UI**
(confirmed by the user; distinct from the old red/blue bar):

- **Waveform**: a row of vertical bars (~18–20 bars, 5–6pt wide, 2–3pt radius, red #FF3B30), varying in
  height (~12–64pt), **animated by the live voice level while held** (feels like a GIF) — driven by
  SpeechRecognizer's meterLevel (WaveView already exists; just wire it up).
- Small text "Listening…" above the waveform.
- Centered bold "**Release to send · slide up to cancel**" below the waveform.
- **Shape: rectangle, no arc, no rounded border, fills the container width; extends downward: the waveform
  area hugs the bottom of the screen / container, with more space below it** (fuller and lower than the
  Doubao reference).
- Interactions kept: release to send; slide up (~-80pt) to cancel.

## 4. Acceptance checklist (all must pass)

1. Build (verbatim, **no code-signing overrides**):
   `xcodebuild -project VoxSign.xcodeproj -scheme VoxSign -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /tmp/vhs-v4-dd build`
2. Unit tests all green.
3. Simulator three-state screenshots (clean, no system alerts): default / hold (recording).
   - **UI tests need the env var `TEST_TARGET_NAME=VoxSign`** (otherwise Code=108).
   - The notification permission alert is dismissed inside the UI test (or pre-authorized).
   - Simulator hold-state screenshot works: SpeechRecognizer.start() sets isRecording=true the moment the
     button is pressed (the UI gives immediate feedback).
4. Real-device ipa V4 (ai.voxsign.ios), codesign TeamID 6ASMXVQHKK.
5. git commit to the working branch (no push); **do not touch or commit in-flight data under harness-output/**;
   the user's parallel flow may commit changes at any time (cross-check with reflog / git log to avoid duplicates).

## 5. Deliverables

- Simulator screenshots: default state, hold state (PNG, clear paths).
- Real-device ipa path + verification info (bundle id / copy / signature).
- Commit info (hash + message).
