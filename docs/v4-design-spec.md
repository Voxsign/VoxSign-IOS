# V4 Doubao-Style UI Alignment Spec

This document is the single authoritative reference for the V4 UI revamp. Implementers must
follow it item by item and must not improvise. (The original visual reference screenshots have been
removed from the open-source release; this text stands on its own.)

## 0. Shared design tokens

- Sender-label constant: `enum VSBrand { static let agentLabel = "VoxSign·metasystem" }`
  - **Owned by the MessageViews implementer**: add it in MessageViews.swift next to the existing `VSColor` enum.
  - The RootView implementer **only references** `VSBrand.agentLabel` and must not redefine the same
    constant (that would cause a compile conflict).
- Colors: reuse the existing `VSColor` (blue #3370FF, bg, harnessBubble=white, etc.); no new color families.
- Message body text is uniformly 16pt (Doubao message size); metadata small text 11pt; sender label 11pt.

## 1. Top bar (RootView.swift)

Structure: `HStack` — left button | Spacer | center VStack(title row + small subtitle) | Spacer | right button.

- Left button: `bubble.left.and.bubble.right`, 15pt medium, black; 34×34 touch target;
  background `Color.black.opacity(0.05)` + `RoundedRectangle(cornerRadius: 10)` (subtle rounded);
  identifier `vhs.sessions` kept; action `model.showSessions = true` unchanged.
- Center title row: `HStack(spacing: 4)` { `ConnectionDotView` (existing logic and identifier
  `vhs.status.dot` **unchanged**), `Text("VoxSign")` 17pt semibold black }.
- Center subtitle: `Text(VSBrand.agentLabel)` 11pt `.secondary` (small, centered).
- Right button: `ellipsis`, 15pt medium, black; 34×34; same subtle rounded background;
  identifier `vhs.more` kept; menu contents (new session / settings) unchanged.
- Background `.ultraThinMaterial`, `.padding(.leading, 6)`, `.padding(.trailing, 10)` kept.

## 2. Empty state (RootView.swift)

When `model.rows.isEmpty`, replace the existing single gray line with a centered group:

- `VStack(spacing: 14)`, `.frame(maxWidth: .infinity)`, `.padding(.top, 120)`:
  - Icon: `ZStack` { `Circle().fill(VSColor.blue.opacity(0.10)).frame(width: 64, height: 64)`,
    `Image(systemName: "waveform.and.mic").font(.system(size: 26, weight: .medium)).foregroundColor(VSColor.blue)` }
  - Caption: `Text(NSLocalizedString("Hold 🎤 to talk, or tap ⌨ to type", comment: ""))` 14pt `Color(red: 0.682, green: 0.682, blue: 0.698)`
- Keep it simple and centered; no card, no example suggestions.

## 3. Message area

### 3a. Centered timestamp at the top of the list (RootView.swift)

- When rows is non-empty, insert before the first row of the LazyVStack:
  `HStack` { Spacer; `Text(first bubble timestamp as "HH:mm")` 11pt `.secondary`; Spacer }, with 4pt spacing below.
- "First bubble": start at rows.first, skip typing/execCard, and take the timestamp of the first user/harness bubble.
- DateFormatter `dateFormat = "HH:mm"`.

### 3b. AI bubble sender label (MessageViews.swift)

- `HarnessBubbleView`: add `Text(VSBrand.agentLabel)` 11pt `.secondary` above the bubble text;
  place it inside the existing `VStack(alignment: .leading, spacing: 3)` before the text, with
  `.padding(.leading, 6).padding(.bottom, 2)`.
- `ReceiptCardView`: add the same small sender label above the card (left-aligned,
  `.padding(.leading, 2).padding(.bottom, 4)`).
- Both `HarnessBubbleView` and `UserBubbleView` bubble text `Text(bubble.text)` get `.font(.system(size: 16))`.
- Bubble corner radius / gradient / shadow stay as-is (AI white 18/4/18/18; user blue-purple gradient
  18/18/4/18; AI shadow shadowSoft) — already aligned with Doubao.

### 3c. Metadata under the user bubble (MessageViews.swift)

- Inside `UserBubbleView`, below the bubble (after attachment chips), add a right-aligned small line:
  `HStack` { Spacer; `Text("HH:mm")`; if `bubble.fromVoice && (bubble.voiceSeconds ?? 0) > 0`:
  `Text("· total Xm Xs")` }, 11pt `.secondary`, `.padding(.trailing, 4).padding(.top, 2)`.
- The "total Xm Xs" format (pure function, defined in MessageViews.swift):
  `secs >= 60` -> `"Total \(secs/60)m \(secs%60)s"`; otherwise -> `"Total \(secs)s"`.

### 3d. AI bubble metadata (kept as-is)

- `HarnessBubbleView`'s infoRow (usage · time · … menu) 11pt `.secondary` stays untouched — already Doubao-style.

## 4. Input bar default state (InputBarView.swift) — unchanged

`[＋ add resource] | [input field "Message or voice command…" ~36pt radius 18] | [🎤 mic]` is already
aligned; keep it unchanged.

## 5. Hold state (InputBarView.swift) — main revamp

### 5a. New recordingHoldView replaces redHoldBar

When `speechRecording`, the input row shows `recordingHoldView` (in place of redHoldBar):

```
VStack(spacing: 6) {
    HStack(spacing: 8) {
        if !cancelling { WaveView(meterLevel: speech.meterLevel) }
        else { Image(systemName: "xmark.circle.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(.white) }
        Text(holdTopText).font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
        Spacer()
    }
    Text(holdBarText).font(.system(size: 15, weight: .semibold)).foregroundColor(.white).frame(maxWidth: .infinity)
}
.padding(.horizontal, 14).padding(.vertical, 12)
.background(holdBarColor)
.clipShape(RoundedRectangle(cornerRadius: 20))
.shadow(color: holdBarColor.opacity(0.3), radius: 6, x: 0, y: 2)
```

- `holdTopText`: cancelling -> `"Release to cancel"`; noSpeechDetected -> `"No sound heard, please speak"`; otherwise -> `"Listening…"`.
- `holdBarText`: cancelling -> `"Release · cancel"`; otherwise -> `"Release to send · slide up to cancel"`.
- `holdBarColor`: cancelling -> `Color(red: 0.55, green: 0.56, blue: 0.58)`; otherwise -> `Color(red: 0.96, green: 0.26, blue: 0.26)`.
- Transition animation: keep the existing `.transition(.opacity.combined(with: .scale(scale: 0.98)))` and the
  three controls' `.opacity(speechRecording ? 0.0 : 1.0)`.
- Delete the old redHoldBar (its "release to send" text is replaced by the new copy).

### 5b. [Freeze-regression guards — must NOT regress]

The following were completed and accepted in the previous revision; **do not change a single word**:

1. The whole `holdGesture` logic: holdInitiated guard, onChanged starts hold exactly once,
   the -80pt slide-up cancel can slide back, onEnded routes to cancelHold/stopHold by cancelling/translation,
   and a very-light tap has a `DispatchQueue.main.async` fallback.
2. **Gesture host**: `recordingHoldView` must carry `.gesture(holdGesture)` (the whole red container is
   the recording-state gesture host; release / slide-up / slide-back anywhere triggers onEnded, so
   isRecording always resets).
3. In the three-control HStack: `addAttachButton` and `textField` keep `.allowsHitTesting(!speechRecording)`;
   **the rightButton (mic) must NOT get allowsHitTesting(false)** — the in-progress drag must keep receiving events.
4. The `onChange(of: speech.isRecording)` watchdog (recording but no finger pressed -> cancelHold) is kept.

### 5c. noSpeechDetected timer migration

- Migrate the counting logic inside `voiceStatusBar`'s `onReceive(Timer 1s)` (transcriptSnap / silentSeconds /
  noSpeechDetected, with the equivalent of `guard kind == .listening || .silent`) **verbatim** onto recordingHoldView:
  count only while recording (speech.isRecording == true); reset when not recording.
- `voiceStatusSection`: remove the listening / cancelling / noSpeechDetected `voiceStatusBar` calls under the
  isRecording branch (they are merged into recordingHoldView); **keep** the calibrating / emptyRecording /
  asrFailed / unavailable branches.
- Unused VoiceStatusKind cases may stay (no compile impact) or be deleted, at the implementer's discretion,
  as long as other branches still compile.

## 6. Text input state — unchanged

After typing, the right-side blue `arrow.up.circle.fill` 30pt (vhs.send) already matches Doubao; keep it.

## 7. Kept elements (decided by the product owner, do not delete)

- ＋ add-resource entry and AttachmentPanelView (untouched)
- Top-bar red/blue connection status dot (ConnectionDotView / TopBarDot logic and tests untouched)
- Multi-session list hidden by default + top-left session entry (untouched)
- No bell/speaker on message rows (already satisfied); no "cloud computer / skill" buttons (already satisfied)

## 8. Version (RootView implementer owns this)

- `VoxSign/App/Info.plist`: `CFBundleShortVersionString` -> **4.0**; `CFBundleVersion` -> **10**.
- Do not change any other Info.plist key. SettingsView automatically shows "4.0 (build 10)"; no code change needed.

## 9. Execution discipline (both implementers)

- Only change files in your own list; **do not** touch other files (AppModel / SessionStore / other Views / tests).
- Do not build, run tests, or git add/commit (build and verification are done by a later implementer;
  git operations are finished by the lead agent).
- No new third-party dependencies; no new files (define constants inside existing files).
- When done, self-review: report "what changed / which section" against §1-§8, and confirm no §5b guard was touched.
