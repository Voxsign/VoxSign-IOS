//
//  MessageViews.swift
//  VoxSign
//
//  Chat-flow rendering: user right blue bubble (waveform for voice), harness left white bubble, light labels,
//  typing dots, exec card, receipt card. Pure views, no decision logic (decisions live in VSLogic).
//

import SwiftUI

// MARK: - Colors (Doubao visual: primary blue #3370FF -> purple #8B5CF6 gradient, white bg light-gray conversation, large radii)

enum VSColor {
    /// Doubao primary blue #3370FF
    static let blue = Color(red: 0.20, green: 0.44, blue: 1.0)
    /// Doubao gradient purple #8B5CF6
    static let purple = Color(red: 0.545, green: 0.36, blue: 0.965)
    /// Conversation background (light gray, Doubao-style)
    static let bg = Color(red: 0.949, green: 0.953, blue: 0.965)
    static let harnessBubble = Color.white
    /// Card-level shadow (App Store polish: soft, low opacity, not distracting)
    static let shadow = Color.black.opacity(0.06)
    /// UI v3 Doubao-style AI bubble shadow: deliberately almost invisible (design: opacity 0.045 / radius 0.75).
    static let shadowSoft = Color.black.opacity(0.045)
    /// User bubble highlight (brighter top-leading for depth)
    static var userBubbleGradientHigh: LinearGradient {
        LinearGradient(colors: [Color(red: 0.32, green: 0.55, blue: 1.0), purple],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Brand gradient (shared by titles/buttons)
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [blue, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// UI v3 user bubble: Doubao's 135° blue-purple gradient #4E7CFF -> #8E6BFF (used only by user bubbles and the voice button).
    static var userBubbleGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.306, green: 0.486, blue: 1.0),
                                Color(red: 0.557, green: 0.42, blue: 1.0)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let userBubble = blue
    static let receiptGreen = Color(red: 0.90, green: 0.97, blue: 0.91)
    static let confirmRed = Color(red: 0.97, green: 0.90, blue: 0.90)
}

// MARK: - Brand constants (V4 §0)

/// V4 Doubao-style UI shared design token: sender label.
/// Owned by the MessageViews author; the RootView top bar only references `VSBrand.agentLabel` and must not redefine it.
enum VSBrand {
    static let agentLabel = "VoxSign·metasystem"
}

/// V4 §3c: user voice-bubble duration caption as a pure function.
/// secs >= 60 -> "Total Xm Xs"; otherwise -> "Total Xs".
func voiceDurationCaption(_ secs: Int) -> String {
    if secs >= 60 {
        return String(format: NSLocalizedString("Total %d min %d s", comment: ""), secs / 60, secs % 60)
    } else {
        return String(format: NSLocalizedString("Total %d s", comment: ""), secs)
    }
}

// MARK: - Badges

struct BadgeView: View {
    let badge: Badge
    var body: some View {
        Text(badge.label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(toneColor.opacity(0.15))
            .foregroundColor(toneColor)
            .cornerRadius(6)
    }

    private var toneColor: Color {
        switch badge.tone {
        case "green": return .green
        case "red": return .red
        case "amber": return .orange
        case "gray": return .gray
        default: return VSColor.blue
        }
    }
}

// MARK: - Bubbles

struct UserBubbleView: View {
    let bubble: Bubble

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(alignment: .center, spacing: 6) {
                    if bubble.fromVoice {
                        WaveView()
                            // UI v3: recording waveform is white; completed state keeps thin white bars (Doubao-style).
                            .opacity(0.9)
                    }
                    Text(bubble.text)
                        // V4 §3d: message bubble text is uniformly 16pt (Doubao message size).
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    // UI v3: voice message duration (Doubao-style small "3s").
                    if let secs = bubble.voiceSeconds {
                        Text("\(secs)″")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.trailing, 4)
                    }
                }
                .background(VSColor.userBubbleGradientHigh)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18,
                                                  bottomTrailingRadius: 4, topTrailingRadius: 18))
                .shadow(color: VSColor.shadow, radius: 6, x: 0, y: 2)

                // Attachment chips: light-gray small tags, not overpowering; image attachments show a 40x40 thumbnail when localPath exists.
                if !bubble.attachments.isEmpty {
                    VStack(alignment: .trailing, spacing: 4) {
                        ForEach(bubble.attachments) { att in
                            attachmentChip(att)
                        }
                    }
                }

                // V4 §3c: right-aligned metadata below the bubble — HH:mm; voice messages append "· Total Xm Xs".
                metadataRow
            }
        }
    }

    /// V6.5 metadata under the user bubble: time only (dropped "Total Xs" — low value, keep it clean).
    private var metadataRow: some View {
        HStack(spacing: 4) {
            Spacer()
            Text(Self.timeFormatter.string(from: bubble.timestamp))
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.trailing, 4)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func attachmentChip(_ att: Attachment) -> some View {
        if att.kind == .image, let p = att.localPath, let img = UIImage(contentsOfFile: p) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            HStack(spacing: 5) {
                Image(systemName: chipIcon(att.kind))
                    .font(.system(size: 11))
                Text(att.title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func chipIcon(_ kind: AttachmentKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .url:  return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

struct HarnessBubbleView: View {
    let bubble: Bubble

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                // V6.5 dropped the "VoxSign·metasystem" sender label (low-value, keep it clean).
                Text(bubble.text)
                    // V4 §3d: message bubble text is uniformly 16pt (Doubao message size).
                    .font(.system(size: 16))
                    .foregroundColor(.black)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(VSColor.harnessBubble)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 4,
                                                      bottomTrailingRadius: 18, topTrailingRadius: 18))
                    // UI v3: AI bubble shadow pressed to nearly invisible (Doubao-style).
                    .shadow(color: VSColor.shadowSoft, radius: 0.75, x: 0, y: 1)

                // Lightweight info row: cost (hidden entirely if the server omits it) · time + … menu (no main speaker button; infrequent, tucked into the menu).
                infoRow
            }
            Spacer()
        }
    }

    private var infoRow: some View {
        HStack(spacing: 6) {
            if let cost = CostText.caption(for: bubble.costTokens) {
                Text(cost)
            }
            Text(Self.timeFormatter.string(from: bubble.timestamp))
            Spacer(minLength: 0)
            Menu {
                Button {
                    UIPasteboard.general.string = bubble.text
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                Button {
                    VoiceOutputService.shared.speak(bubble.text)
                } label: {
                    Label("Speak", systemImage: "waveform")
                }
                ShareLink(item: bubble.text)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .padding(.leading, 4)
        .padding(.trailing, 2)
    }
}

/// Waveform animation (voice-input indicator). Bar height = live recording amplitude (meterLevel) + light phase animation,
/// Doubao-style "responds on hold": the louder you speak, the taller the bars.
/// Default 3 small bars (for the top status strip); the full-bleed recording waveform passes barCount: 18 / barWidth: 5 / barMaxHeight: 64.
struct WaveView: View {
    var meterLevel: Float = 0.5
    var barCount: Int = 3
    var color: Color = .white
    var barWidth: CGFloat = 3
    var barMaxHeight: CGFloat = 20

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let lvl = Double(meterLevel)
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    let phase = sin(t * 5 + Double(i) * 0.9)
                    // Height = resting base + phase pulse + volume drive; with defaults it matches the original 3-bar behavior (~17pt)
                    let h = min(barMaxHeight, barMaxHeight * 0.22
                                + max(0, phase) * barMaxHeight * 0.14
                                + lvl * barMaxHeight * 0.5)
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: h)
                }
            }
        }
        .frame(height: barMaxHeight)
    }
}

/// Typing dots + dynamic text (I04 thinking state / I18 long-task escalation text).
/// Driven by TimelineView to avoid depending on @State macros.
struct TypingView: View {
    var text: String = NSLocalizedString("Thinking…", comment: "")

    var body: some View {
        HStack(spacing: 10) {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        let phase = sin(t * 4 + Double(i) * 0.9)
                        Circle()
                            .fill(VSColor.blue.opacity(0.75))
                            .frame(width: 7, height: 7)
                            .offset(y: max(0, phase) * -4)
                    }
                }
            }
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(.gray)
        }
        .padding(12)
        .background(VSColor.harnessBubble)
        .cornerRadius(16)
    }
}

// MARK: - Exec card (SSE stage events drive the rolling stage rows)

struct ExecCardView: View {
    let state: ExecCardState
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(NSLocalizedString("Processing…", comment: ""))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray)
            ForEach(state.stages) { stage in
                HStack(spacing: 6) {
                    Image(systemName: stage.done ? "checkmark.circle.fill"
                          : stage.active ? "circle.fill" : "circle")
                        .font(.system(size: 12))
                        .foregroundColor(stage.done ? .green
                                         : stage.active ? VSColor.blue : .gray.opacity(0.5))
                    Text(stage.name)
                        .font(.system(size: 12))
                        .foregroundColor(stage.done || stage.active ? .black : .gray.opacity(0.7))
                }
            }
        }
        .padding(12)
        .background(VSColor.harnessBubble)
        .cornerRadius(16)
    }
}

// MARK: - Receipt -> human-readable bubble (v2.1: I01 human reply / I12 action+object / I07+I17 small undo text 44pt)

struct ReceiptCardView: View {
    let receipt: Receipt
    let undo: UndoInfo
    let badges: [Badge]
    let onRollback: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // V6.5 dropped the small "VoxSign·metasystem" sender label above the receipt card (low-value).

            VStack(alignment: .leading, spacing: 8) {
                // Content text (backend human reply) — V6.4 dropped the "✅ Done · Xs" status line (low-value, keep it clean).

                Text(receipt.result)
                    .font(.system(size: 14))
                    .foregroundColor(.black)

                // Image receipt (closed-loop acceptance): a backend screenshot receipt containing "/screenshots/<file>.png" renders the image directly.
                if let shotURL = ScreenshotURL.from(receipt.result, base: SettingsStore.shared.base) {
                    AsyncImage(url: shotURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: VSColor.shadow, radius: 5, x: 0, y: 2)
                        case .failure:
                            Text(NSLocalizedString("(Screenshot failed to load)", comment: "")).font(.system(size: 12)).foregroundColor(.secondary)
                        default:
                            ProgressView().frame(width: 80, height: 80)
                        }
                    }
                }

                // V6.4 dropped the undo button (the UI shows only real content, keep it clean; undo stays in the voice-command chain).
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: VSColor.shadowSoft, radius: 4, x: 0, y: 2)
        }
    }
}


// MARK: - Image receipt URL parsing

enum ScreenshotURL {
    /// Extract the /screenshots/<file>.png relative path from the receipt text and prefix the current server base.
    static func from(_ text: String, base: String) -> URL? {
        guard let rng = text.range(of: "/screenshots/") else { return nil }
        var end = text.index(rng.lowerBound, offsetBy: "/screenshots/".count)
        var path = "/screenshots/"
        while end < text.endIndex {
            let ch = text[end]
            if ch == " " || ch == "\n" || ch == ")" { break }
            path.append(ch)
            end = text.index(after: end)
        }
        guard path.hasSuffix(".png") else { return nil }
        return URL(string: base + path)
    }
}
