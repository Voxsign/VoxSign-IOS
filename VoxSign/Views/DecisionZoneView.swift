//
//  DecisionZoneView.swift
//  VoxSign
//
//  One decision point per screen: need_ask candidate buttons / need_confirm confirm card / canceled·interrupted error bar.
//  UI v3 (Doubao-style): both decision cards are light cards inside the chat flow — white bg, 14pt radius, 0.5pt system stroke,
//  small header label ("Confirmation needed" gray + blue checkmark / "Pick one"), buttons 40-44pt tall.
//  Renders nothing when empty (matches the web decisionZone).
//

import SwiftUI

struct DecisionZoneView: View {
    let decision: DecisionPoint?
    let onAnswer: (String) -> Void

    // UI v3: ask-option selected state (#EAF0FF blue bg + blue text on tap).
    @State private var selectedID: String? = nil

    var body: some View {
        switch decision?.kind {
        case .confirm:
            VStack(alignment: .leading, spacing: 10) {
                // Header label: confirm needed (Doubao-style 11.5pt gray + blue checkmark)
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(VSColor.blue)
                    Text(NSLocalizedString("Confirmation needed", comment: ""))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(red: 0.557, green: 0.557, blue: 0.576))
                }
                Text(decision?.question ?? NSLocalizedString("Do you want to run this operation?", comment: ""))
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                // Split buttons 40pt tall: Cancel on gray / Execute on blue
                HStack(spacing: 10) {
                    Button(NSLocalizedString("Cancel", comment: "")) { onAnswer("reject") }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(Color.black.opacity(0.06))
                        .cornerRadius(10)
                    Button(NSLocalizedString("Execute", comment: "")) { onAnswer("execute") }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(VSColor.blue)
                        .cornerRadius(10)
                }
            }
            .padding(12)
            .background(Color.white)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.898, green: 0.898, blue: 0.918), lineWidth: 0.5)
            )

        case .ask:
            VStack(alignment: .leading, spacing: 8) {
                // Header label: pick one
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(VSColor.blue)
                    Text(NSLocalizedString("Pick one", comment: ""))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color(red: 0.557, green: 0.557, blue: 0.576))
                }
                Text(decision?.question ?? NSLocalizedString("What would you like me to do?", comment: ""))
                    .font(.system(size: 13))
                // Options are full-row 44pt white stroked buttons; on tap become #EAF0FF blue bg + blue text (Doubao-style)
                ForEach(decision?.options ?? [], id: \.id) { opt in
                    Button {
                        selectedID = opt.id
                        onAnswer(opt.id)
                    } label: {
                        HStack {
                            Text(opt.label)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                            if selectedID == opt.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundColor(VSColor.blue)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(selectedID == opt.id
                                    ? Color(red: 0.918, green: 0.941, blue: 1.0)   // #EAF0FF
                                    : Color.white)
                        .foregroundColor(selectedID == opt.id ? VSColor.blue : Color.primary)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(selectedID == opt.id
                                        ? VSColor.blue.opacity(0.4)
                                        : Color(red: 0.898, green: 0.898, blue: 0.918),
                                        lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color.white)
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(red: 0.898, green: 0.898, blue: 0.918), lineWidth: 0.5)
            )

        case .error:
            Text(decision?.message ?? NSLocalizedString("Task error", comment: ""))
                .font(.system(size: 13))
                .foregroundColor(.white)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.85))
                .cornerRadius(12)

        default:
            EmptyView()
        }
    }
}
