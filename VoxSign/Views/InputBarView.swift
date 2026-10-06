//
//  InputBarView.swift
//  V4 Plan B (user-finalized 2026-10-05): Doubao-style bottom input bar
//  - Default (voice mode): [circle +] | [🎤 Hold to talk dark capsule flex:1, 56pt] | [circle ⌨]
//  - Tap ⌨ -> text mode: input field + send arrow (appears when there is text); tap ⌨ again to return to voice
//  - Hold the big button -> full-bleed waveform: dark #1a1a1a rectangle (no rounding, extends to the bottom edge)
//    ① top "Listening…" ② center 20 #ff3b30 vertical bars (follow meterLevel + phase breathing)
//    ③ bottom bold "Release to send · Slide up to cancel"
//  - Swipe up -80pt -> cancel state (bottom switches to "Release to cancel", slide back to keep recording); release to send
//  - While recording the input bar fades but stays in the hierarchy (the mic gesture host is not removed/disabled)
//  - The status strip above the input area keeps only four states: calibrating / empty recording / recognition failed / voice unavailable
//  - [Freeze-fix protections (commit 5f54837) must not regress] holdGesture dual host / holdInitiated anti-reentry /
//    light-tap race fallback / isRecording=true watchdog without a press
//

import SwiftUI

struct InputBarView: View {
    @EnvironmentObject var model: AppModel
    #if canImport(Speech)
    @EnvironmentObject var speech: SpeechRecognizer
    #endif
    // DESIGN.md §9.3: in ar (RTL) the hold-to-talk "slide up to cancel" mirrors to slide down.
    @Environment(\.layoutDirection) private var layoutDirection
    private var isRTL: Bool { layoutDirection == .rightToLeft }

    // Attachment panel (+ -> Sheet)
    @State private var showAttachPanel: Bool = false

    // V4 Plan B: text-input mode (default false = big voice button; tap ⌨ to toggle)
    @State private var useTextInput: Bool = false

    // v2.1 I14: 3s no-recognition hint (not shown during partial recognition)
    @State private var transcriptSnap: String = ""
    @State private var silentSeconds: Int = 0
    @State private var noSpeechDetected: Bool = false
    // UI v3: swipe-up cancel state (-80pt threshold, slide back to keep recording — same feel as Doubao)
    @State private var cancelling: Bool = false
    // [Hardening 1] whether this round's press was initiated by this view's gesture: on rapid taps / dual-host
    // double presses this blocks a second start, closing the async re-entry race in SpeechRecognizer (R2).
    @State private var holdInitiated: Bool = false
    // V6.4 instant visual state: show the held state on press immediately (don't wait for the async engine).
    // Visual precedes the engine — "responds on press at once"; the breathing waveform appears now, meterLevel plugs in later.
    @State private var pressActive: Bool = false

    private var isTyping: Bool { !model.inputText.isEmpty }

    /// V6: input enabled only when online (top-bar red dot = offline -> input bar disabled with a hint to switch machine).
    private var isConnected: Bool {
        ConnectivityService.shared.state == .online
    }

    var body: some View {
        VStack(spacing: 0) {
            #if canImport(Speech)
            // Voice status strip (calibrating / empty recording / recognition failed / unavailable; shown above the input area while holding/releasing).
            voiceStatusSection
            #endif

            if isConnected {
                inputRow
            } else {
                offlineBar
            }
        }
        .background(.ultraThinMaterial)
        // 0.5pt hairline on top of the input bar (Doubao-style).
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 0.5)
        }
        .sheet(isPresented: $showAttachPanel) {
            AttachmentPanelView()
                .environmentObject(model)
        }
    }

    /// V6 offline hint bar: when the top bar shows the red dot (disconnected), input is disabled; hint to tap the machine name above to switch.
    private var offlineBar: some View {
        HStack {
            Spacer()
            Label(NSLocalizedString("Offline · tap the machine name above to switch", comment: ""), systemImage: "wifi.slash")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer()
        }
        .frame(height: 56)
        .background(Color(.secondarySystemBackground))
        .clipShape(Capsule())
        .padding(.horizontal, 12).padding(.vertical, 10)
        .accessibilityIdentifier("vhs.offline")
    }

    // MARK: - Input row (Plan B: big voice button / text mode / full-bleed recording waveform)

    private var inputRow: some View {
        // ZStack overlay: while recording the dark waveform panel covers the whole row; the normal input row is not
        // removed during recording — [Freeze fix] the big voiceMainButton must stay in the hierarchy (opacity 0 fade)
        // WITHOUT allowsHitTesting(false): the in-progress DragGesture depends on that view staying alive to keep
        // receiving events, so onEnded always fires -> stopHold/cancelHold runs -> isRecording resets, never frozen.
        ZStack {
            normalInputRow
                .opacity((speechRecording || pressActive) ? 0.0 : 1.0)

            if speechRecording || pressActive {
                recordingHoldView
                    .transition(.opacity)
            }
        }
        #if canImport(Speech)
        // [Hardening 3 - watchdog] isRecording becomes true but no finger is pressing this round (e.g. the start()
        // kick after the first permission prompt, or any race residue) -> cancelHold immediately, never frozen.
        // On a normal press holdInitiated is set synchronously in onChanged, before the async set -> no false cancel;
        // cancelHold sets isRecording=false so it does not loop.
        .onChange(of: speech.isRecording) { recording in
            if recording && !holdInitiated { speech.cancelHold() }
        }
        #endif
        .animation(.easeOut(duration: 0.12), value: speechRecording)
    }

    /// Default input row (big voice button / text mode). While recording the whole row is opacity 0 but stays in the hierarchy.
    private var normalInputRow: some View {
        HStack(spacing: 10) {
            addAttachButton
                .allowsHitTesting(!speechRecording)
            if useTextInput {
                textField
                    .allowsHitTesting(!speechRecording)
                if isTyping {
                    sendButton
                        .allowsHitTesting(!speechRecording)
                } else {
                    keyboardToggleButton
                        .allowsHitTesting(!speechRecording)
                }
            } else {
                // Big voice button: never disable hit-testing (it is the gesture host; transparent hits while recording keep the drag continuous).
                // If the connection drops mid-recording the button dims (0.35) but the host stays, so release still resets.
                voiceMainButton
                    .opacity(isConnected ? 1.0 : 0.35)
                keyboardToggleButton
                    .allowsHitTesting(!speechRecording)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    /// Left: circular + button (30x30, light-gray circle, 16pt secondary plus) which opens the attachment panel.
    private var addAttachButton: some View {
        Button {
            showAttachPanel = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.05)))
        }
        .accessibilityIdentifier("vhs.attach")
    }

    /// Input field (text mode): placeholder "Message or voice command…".
    private var textField: some View {
        TextField(NSLocalizedString("Message or voice command…", comment: ""), text: $model.inputText, axis: .vertical)
            .lineLimit(...4)
            .font(.system(size: 15))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .accessibilityIdentifier("vhs.input")
    }

    /// Center: oversized "🎤 Hold to talk" dark capsule button (#1a1a1a, 56pt tall, corner radius = half height, fills remaining width).
    /// [Freeze fix - gesture host] fades while recording but keeps hit-testing — the drag starts here and keeps receiving events during recording.
    private var voiceMainButton: some View {
        Text(NSLocalizedString("🎤 Hold to talk", comment: ""))
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(Color(red: 0.102, green: 0.102, blue: 0.102)) // #1a1a1a
            .clipShape(Capsule())
            .contentShape(Capsule())
            .accessibilityIdentifier("vhs.mic")
            .gesture(holdGesture)
    }

    /// Right: circular ⌨ button (30x30, light-gray circle, 16pt secondary keyboard icon) toggles text-input mode.
    private var keyboardToggleButton: some View {
        Button {
            useTextInput.toggle()
        } label: {
            Image(systemName: "keyboard")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.black.opacity(0.05)))
        }
        .accessibilityIdentifier("vhs.keyboard")
    }

    /// Send arrow (when there is text in text mode).
    private var sendButton: some View {
        Button {
            model.send()
        } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 30))
                .foregroundColor(model.decision != nil ? .gray : VSColor.blue)
        }
        .accessibilityIdentifier("vhs.send")
        .disabled(model.decision != nil)
    }

    // MARK: - Held state: full-bleed waveform (Plan B, user-finalized)

    /// Geometry (hard): rectangle fills the width, square corners no rounding; background .ignoresSafeArea(edges:.bottom)
    /// extends to the bottom edge (below the home indicator); total height 260pt (V6: taller/fuller, not "half shown");
    /// bars 110pt tall; ~26pt below the bars for the bottom caption; background #1a1a1a, red bars/red text pop.
    /// Structure: ① small top "Listening…" ② center 20 #ff3b30 vertical bars ③ bottom bold "Release to send · Slide up to cancel".
    /// [Freeze fix - dual host] the whole waveform area is the held-state gesture host (.gesture(holdGesture)):
    /// release / swipe-up / slide-back anywhere triggers onEnded (cancelling->cancelHold else stopHold), isRecording always resets.
    private var recordingHoldView: some View {
        VStack(spacing: 0) {
            // V6.4 dropped the top "Listening…" hint: the held state shows only the waveform; recognition needs no text.

            #if canImport(Speech)
            HoldWaveBars(meterLevel: speech.meterLevel)
                .frame(height: 55)
                .padding(.top, 10)
            #else
            HoldWaveBars(meterLevel: 0)
                .frame(height: 55)
                .padding(.top, 10)
            #endif

            Text(holdBarText)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(HoldWaveBars.barRed)
                .padding(.top, 12)          // ~12pt below the bars before the bottom caption
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 130)
        // V6.7 more transparent: very light translucent white (0.15), nearly clear but keeps hierarchy, no haze.
        // (if a real device shows haze, drop to 0.10 — tuning knob).
        .background(Color.white.opacity(0.15))
        // Extend down: background sinks below the home indicator, flush to the bottom with no gap.
        .ignoresSafeArea(edges: .bottom)
        .animation(.easeOut(duration: 0.12), value: cancelling)
        // [Freeze fix - dual host] gesture host: pressing anywhere on the waveform mid-recording can take over the gesture;
        // the -80pt threshold and slide-back logic live inside holdGesture.onChanged/onEnded; unchanged here.
        .gesture(holdGesture)
        // noSpeechDetected timer (carried over). While recording, compare the transcript snapshot every second and count silent seconds; reset when not recording.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            #if canImport(Speech)
            if speech.isRecording {
                if speech.transcript != transcriptSnap {
                    transcriptSnap = speech.transcript
                    silentSeconds = 0
                } else {
                    silentSeconds += 1
                }
                noSpeechDetected = silentSeconds >= 3
            } else {
                noSpeechDetected = false
                silentSeconds = 0
                transcriptSnap = ""
            }
            #endif
        }
    }

    /// Top caption: no voice (>=3s) -> "No sound heard, please speak"; otherwise -> "Listening…".
    private var holdTopText: String {
        if noSpeechDetected { return NSLocalizedString("No sound heard, please speak", comment: "") }
        return NSLocalizedString("Listening…", comment: "")
    }

    /// Bottom caption: cancelling -> "Release to cancel"; otherwise -> "Release to send · Slide up/down to cancel" (mirrored in RTL per §9.3).
    private var holdBarText: String {
        if cancelling {
            return NSLocalizedString("Release to cancel", comment: "")
        }
        // In RTL, the cancel gesture is a swipe DOWN, so the hint says "Slide down to cancel".
        let key = isRTL ? "Release to send · Slide down to cancel" : "Release to send · Slide up to cancel"
        return NSLocalizedString(key, comment: "")
    }

    // MARK: - Held-state vertical waveform bars (defined here for Plan B; MessageViews' WaveView is untouched)

    /// 20 thin vertical bars (5pt wide, 2pt radius, #ff3b30) with staggered baselines forming a natural waveform outline.
    /// TimelineView(.animation) recomputes each frame:
    ///   barH[i] = baseline[i] x (0.30 + 0.70 x frameCoeff[i])
    ///   frameCoeff[i] = meterLevel(0~1)x0.75 + independent phase breath sin(tx4 + ix0.55)x0.25
    /// At low level coeff ~ 0~0.25 -> bars hold 30%~47% of baseline and breathe slightly (not static);
    /// when speaking meterLevel->1 -> bars rise near baseline (capped at the 55pt group), clearly following the mouth.
    private struct HoldWaveBars: View {
        var meterLevel: Float

        /// #ff3b30 waveform red (shared by bars and bottom caption).
        static let barRed = Color(red: 0.996, green: 0.231, blue: 0.188)
        /// #1a1a1a dark panel background (matches the main capsule).
        static let panelDark = Color(red: 0.102, green: 0.102, blue: 0.102)

        /// 20 staggered baseline heights (pt): a natural outline, high in the middle and low at the sides, peak 48pt against the 55pt group.
        private static let baselines: [CGFloat] = [
            10.5, 19.5, 30, 40.5, 27, 43.5, 33, 48, 22.5, 36,
            36, 22.5, 48, 33, 43.5, 27, 40.5, 30, 19.5, 10.5
        ]

        var body: some View {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let lvl = Double(meterLevel)
                HStack(alignment: .center, spacing: 4) {
                    ForEach(Array(Self.baselines.enumerated()), id: \.offset) { i, base in
                        // Each bar has its own phase: sin(txrate + ixdphase) -> [0,1] breath value
                        let breath = 0.5 + 0.5 * sin(t * 4.0 + Double(i) * 0.55)
                        let coeff = min(1.0, lvl * 0.75 + breath * 0.25)
                        let h = base * (0.30 + 0.70 * coeff)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Self.barRed)
                            .frame(width: 6, height: h)
                    }
                }
            }
        }
    }

    // MARK: - Voice status (4 states) section

    @ViewBuilder
    private var voiceStatusSection: some View {
        // V6.5 dropped the "Calibrating…" hint (meaningless); keep only states with real feedback value:
        if speech.emptyRecording {
            voiceStatusBar(kind: .silent, primary: NSLocalizedString("No sound captured, please speak again", comment: ""), secondary: NSLocalizedString("The recording was empty; nothing was sent", comment: ""))
        } else if speech.asrFailed {
            voiceStatusBar(kind: .failed, primary: NSLocalizedString("Recognition failed, press again", comment: ""), secondary: NSLocalizedString("Didn't catch that; nothing was sent", comment: ""))
        } else if speech.unavailable {
            Text(NSLocalizedString("Voice unavailable: please allow Microphone and Speech Recognition in Settings → VoxSign", comment: ""))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(10)
                .padding(.horizontal, 12).padding(.top, 6)
        }
    }

    private var speechRecording: Bool {
        #if canImport(Speech)
        return speech.isRecording
        #else
        return false
        #endif
    }

    // MARK: - Doubao-style light voice status bar

    private enum VoiceStatusKind {
        case listening, silent, cancelling, calibrating, failed
    }

    /// Light-background dark-text Doubao-style status bar (#FFECEB red / #FFF4E5 orange / #EDEDF0 gray / #EAF0FF blue).
    @ViewBuilder
    private func voiceStatusBar(kind: VoiceStatusKind, primary: String, secondary: String) -> some View {
        let (bg, fg) = statusColors(kind)
        HStack(spacing: 8) {
            if kind == .listening {
                WaveView(meterLevel: speech.meterLevel).colorScheme(.light)
            } else {
                Image(systemName: icon(kind))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(fg)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(primary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(fg)
                Text(secondary)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(fg.opacity(0.85))
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(bg)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(fg.opacity(0.18), lineWidth: 0.5)
        )
        .cornerRadius(12)
        .padding(.horizontal, 12).padding(.top, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard kind == .listening || kind == .silent else { return }
            #if canImport(Speech)
            if speech.isRecording {
                if speech.transcript != transcriptSnap {
                    transcriptSnap = speech.transcript
                    silentSeconds = 0
                } else {
                    silentSeconds += 1
                }
                noSpeechDetected = silentSeconds >= 3
            } else {
                noSpeechDetected = false
                silentSeconds = 0
                transcriptSnap = ""
            }
            #endif
        }
    }

    private func statusColors(_ kind: VoiceStatusKind) -> (Color, Color) {
        switch kind {
        case .listening:
            return (Color(red: 1.0, green: 0.925, blue: 0.922), Color(red: 0.776, green: 0.184, blue: 0.149))
        case .silent, .failed:
            return (Color(red: 1.0, green: 0.957, blue: 0.898), Color(red: 0.702, green: 0.416, blue: 0.0))
        case .cancelling:
            return (Color(red: 0.929, green: 0.929, blue: 0.941), Color(red: 0.333, green: 0.333, blue: 0.361))
        case .calibrating:
            return (Color(red: 0.918, green: 0.941, blue: 1.0), Color(red: 0.137, green: 0.333, blue: 0.78))
        }
    }

    private func icon(_ kind: VoiceStatusKind) -> String {
        switch kind {
        case .silent: return "speaker.slash.fill"
        case .cancelling: return "xmark.circle.fill"
        case .calibrating: return "waveform"
        case .failed: return "exclamationmark.triangle.fill"
        case .listening: return "waveform"
        }
    }

    // MARK: - Hold-to-talk gesture (press to record / swipe up to cancel and slide back / release to send) — semantics carried over

    #if canImport(Speech)
    /// Mic button gesture — press to record; dy < -80pt enters cancel state (slide back to continue); release sends per state.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // LAT: timestamp the instant the finger lands (main thread, closest to touch down).
                SpeechRecognizer.markTouch()
                // [Hold-latency fix] light haptic: vibrate the instant the finger lands, giving a "pressed" touch
                // before visuals/audio, no waiting for the engine/waveform; press feedback <0.1s.
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                // V6.4 enter the held state on press (visual first, don't wait for the async voice engine).
                pressActive = true
                // [Hardening 1] start only once when no initiator exists this round; no repeat start while recording/already initiated (R2).
                if !speech.isRecording && !holdInitiated {
                    holdInitiated = true
                    cancelling = false
                    // V6.5 async engine start: the waveform renders first, not blocked by engine init (audio session/permission)
                    // on the first frame — press -> waveform should appear within 0.1s.
                    DispatchQueue.main.async {
                        speech.startHold()
                    }
                }
                // Swipe -80pt in the cancel direction -> cancel; slide back -> resume recording (Doubao's reversible feel).
                // §9.3: in RTL the cancel direction mirrors from swipe-UP to swipe-DOWN.
                let c = isRTL ? (v.translation.height > 80) : (v.translation.height < -80)
                if c != cancelling { cancelling = c }
            }
            .onEnded { v in
                // V6.4 reset the visual state on release at once.
                pressActive = false
                // [Hardening 1/2] record whether this round was the initiator before resetting the flag.
                let wasInitiator = holdInitiated
                holdInitiated = false
                if speech.isRecording {
                    let cancelTriggered = isRTL ? (v.translation.height > 80) : (v.translation.height < -80)
                    if cancelling || cancelTriggered {
                        speech.cancelHold()   // swipe-cancel: do not send
                    } else {
                        speech.stopHold()     // release: auto-send after recognition
                    }
                } else if wasInitiator {
                    // [Hardening 2-R1 light-tap race fallback] isRecording is set true on the next runloop tick in
                    // start()'s DispatchQueue.main.async; if the finger releases first the old logic did nothing ->
                    // then it got set -> stuck recording with no finger. Main-queue FIFO guarantees this block runs
                    // after the set: if already set, finish at once (installTap is already done synchronously, stopHold is safe).
                    DispatchQueue.main.async {
                        if self.speech.isRecording { self.speech.stopHold() }
                    }
                }
                cancelling = false
            }
    }
    #else
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
    }
    #endif
}
