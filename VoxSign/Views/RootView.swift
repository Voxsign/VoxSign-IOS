//
//  RootView.swift
//  VoxSign
//
//  Root view: top bar (session entry + connection dot + title + … menu) / red interrupt system bar / chat flow (bubbles · exec card · receipt card) / decision zone / bottom input bar / Settings / session list.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel
    /// V6.3 top-bar ownership capsule -> file the current session.
    @State private var showClassifyCurrent: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Main content area (chat flow + input bar)
            VStack(spacing: 0) {
                // T4 Doubao-style top bar: [session entry (subtle rounded)] | Spacer | center(status dot+title / small machine name) | Spacer | [new session (rounded) · … menu (subtle rounded)]
                HStack(spacing: 6) {
                    // Top-left: session history entry (34pt touch target + subtle rounded background)
                    Button {
                        model.showSessions = true
                    } label: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.black)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityIdentifier("vhs.sessions")

                    Spacer()

                    // Center: title row (5pt status dot + VoxSign) + small machine name (V6: tap to switch machine)
                    VStack(spacing: 1) {
                        HStack(spacing: 4) {
                            // 5pt connection/harness status dot (blue=ok · red=offline · gray=reconnecting/unknown · orange=decision)
                            ConnectionDotView(conn: ConnectivityService.shared.state,
                                              harness: model.harnessState)
                            Text("VoxSign")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(.black)
                        }
                        // V6.3 subtitle row: machine name (tap=switch machine) + ownership label (tap=file current session)
                        HStack(spacing: 6) {
                            Button {
                                model.showMachinePicker = true
                            } label: {
                                HStack(spacing: 3) {
                                    Text(model.machineLabel)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .accessibilityIdentifier("vhs.machine")

                            // Ownership capsule: ungrouped/role/domain -> filing panel
                            Button {
                                showClassifyCurrent = true
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: model.currentContainerLabel == "Ungrouped" ? "tray" : "folder")
                                        .font(.system(size: 8))
                                        .foregroundColor(.secondary)
                                    Text(model.currentContainerLabel)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.05), in: Capsule())
                            }
                            .accessibilityIdentifier("vhs.classify")
                        }
                    }

                    Spacer()

                    // Top-right: only "new session" (V6.3: direct new session, no more role/domain prompt — talk-then-file)
                    Button {
                        model.newSession()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.black)
                            .frame(width: 34, height: 34)
                            .contentShape(Rectangle())
                            .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .accessibilityIdentifier("vhs.newsession")
                }
                .padding(.leading, 6)
                .padding(.trailing, 10)
                .background(.ultraThinMaterial)

                // Red interrupt system bar (dismissible)
                if let bar = model.systemBar {
                    SystemBarView(bar: bar,
                                  onRollback: { model.rollback() },
                                  onClose: { model.closeSystemBar() })
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Chat flow
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            // T4 Doubao-style empty state: centered icon + text (no welcome screen, no example cards).
                            if model.rows.isEmpty {
                                VStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(VSColor.blue.opacity(0.10))
                                            .frame(width: 64, height: 64)
                                        Image(systemName: "waveform.and.mic")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(VSColor.blue)
                                    }
                                    Text(NSLocalizedString("Hold 🎤 to talk, or tap ⌨ to type", comment: ""))
                                        .font(.system(size: 14))
                                        .foregroundColor(Color(red: 0.682, green: 0.682, blue: 0.698)) // #AEAEB2
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 120)
                            }

                            // T4 §3a: centered timestamp at the top of the list (HH:mm of the first user/harness bubble), 4pt below.
                            if let topTime = topMessageTimeText {
                                HStack {
                                    Spacer()
                                    Text(topTime)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.bottom, 4)
                            }

                            ForEach(model.rows) { row in
                                rowView(row)
                            }
                        }
                        .padding(12)
                    }
                    // T2 scroll fix: use scrollTick (+1 on every appended bubble) to ensure the harness reply / exec
                    // card / receipt always scrolls into view after the user speaks.
                    .onChange(of: model.scrollTick) { _ in
                        if let last = model.rows.last {
                            // T3 Doubao-style: quick light scroll to bottom (0.1s), not jerky, not interrupting reading.
                            withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // One decision point per screen
                DecisionZoneView(decision: model.decision, onAnswer: { ans in model.answer(ans) })
                    .padding(.horizontal, 12)

                // T3 Doubao-style: no diagnostic line / poll indicator (keep a pure chat flow).
                InputBarView()
            }
            .background(VSColor.bg.ignoresSafeArea())
            .preferredColorScheme(.light)

            // V6 Doubao-style left drawer (split left/right: left=session list, right=chat area peeks out):
            // a translucent mask closes on tap; the 320pt drawer slides in from the left, covering the status bar / bottom.
            if model.showSessions {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                    .onTapGesture { closeSessions() }
                    .transition(.opacity)
                SessionDrawerView(onClose: { closeSessions() },
                                  onSettings: { model.showSettings = true })
                    .transition(.move(edge: .leading))
                    .frame(width: 320)
                    .frame(maxHeight: .infinity)
                    .ignoresSafeArea()
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.showSessions)
        .sheet(isPresented: $showClassifyCurrent) {
            ClassifySheetView(sessionID: model.currentSessionID)
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $model.showMachinePicker) {
            MachinePickerView()
                .presentationDetents([.medium, .large])
        }
    }

    /// V6: close the session drawer (animated).
    private func closeSessions() {
        model.showSessions = false
    }

    /// T4 §3a: starting at rows.first, skip typing/execCard/receipt; take the first user/harness bubble's time, formatted HH:mm.
    /// Western digits by default (§9.2).
    private static let topTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private var topMessageTimeText: String? {
        for row in model.rows {
            switch row {
            case .user(let b), .harness(let b):
                return Self.topTimeFormatter.string(from: b.timestamp)
            default:
                continue
            }
        }
        return nil
    }

    @ViewBuilder
    private func rowView(_ row: ChatRow) -> some View {
        switch row {
        case .user(let b): UserBubbleView(bubble: b)
        case .harness(let b): HarnessBubbleView(bubble: b)
        case .typing: TypingView(text: model.typingText)
        // T3 Doubao-style: the execution phase no longer renders a seven-stage card, collapsing to "three dots thinking" (same as Doubao).
        // v2.1 I18: thinking-state text escalates dynamically (5s/10s), driven by model.typingText.
        case .execCard: TypingView(text: model.typingText)
        case .receipt(let r):
            ReceiptCardView(receipt: r.receipt, undo: r.undo, badges: r.badges, onRollback: { model.rollback() })
        }
    }
}

// MARK: - Top-bar 5pt connection status dot (Doubao-style minimal)

/// 5pt dot: color is decided by `TopBarDot.tone(conn:harness:)` (red/blue/gray/orange);
/// breathing animation while busy / decision. No text, no capsule — keep the top bar restrained.
struct ConnectionDotView: View {
    let conn: ConnectionState
    let harness: HarnessState

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.6)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .scaleEffect(animating ? 1.0 + 0.35 * max(0, sin(t * 5)) : 1.0)
                .opacity(conn == .unknown ? 0.55 : 1.0)
        }
        .padding(.leading, 2)
        .accessibilityIdentifier("vhs.status.dot")
    }

    private var tone: DotTone {
        TopBarDot.tone(conn: conn, harness: harness)
    }

    private var color: Color {
        switch tone {
        case .blue:   return VSColor.blue
        case .red:    return Color.red
        case .gray:   return Color.gray
        case .orange: return Color.orange
        }
    }

    /// Breathe only while the harness is busy / needs a decision (static dots do not pulse).
    private var animating: Bool {
        harness == .busy || harness == .decision
    }
}
