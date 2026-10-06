//
//  ConnectionStatusView.swift
//  VoxSign
//
//  T2 Doubao-style interaction · connection-status capsule: a thin pill pinned at the top,
//  green=online · yellow=reconnecting · gray=offline (commands queued) — network state is always visible, no more "black-box freeze".
//

import SwiftUI

struct ConnectionStatusView: View {
    @ObservedObject var conn = ConnectivityService.shared

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch conn.state {
        case .online: return .green
        case .reconnecting: return .yellow
        case .offline: return .gray
        case .unknown: return .gray
        }
    }

    private var label: String {
        switch conn.state {
        case .online: return NSLocalizedString("Connected", comment: "")
        case .reconnecting: return NSLocalizedString("Reconnecting…", comment: "")
        case .offline: return NSLocalizedString("Offline · voice commands will queue", comment: "")
        case .unknown: return NSLocalizedString("Checking connection…", comment: "")
        }
    }
}
