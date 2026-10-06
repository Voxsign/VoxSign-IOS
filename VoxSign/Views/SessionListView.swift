//
//  SessionListView.swift
//  VoxSign
//
//  Doubao-style multi-session left drawer (V6: moved from a sheet to a left slide-out, split left/right to show more):
//  - Lists history sessions sorted by updatedAt descending
//  - Tap to switch session and close the drawer; swipe to delete (silently ignored when only one remains)
//  - Top-right "New session" entry in the header
//

import SwiftUI

struct SessionDrawerView: View {
    @EnvironmentObject var model: AppModel
    /// Close the drawer (injected by RootView, animated).
    var onClose: () -> Void
    /// Open Settings (V6.1: the Settings entry moved to the drawer's bottom-left).
    var onSettings: () -> Void

    /// V6.2 collapse state: fully expanded by default; tap a container row to collapse/expand (folder relationship).
    @State private var collapsed: Set<String> = []
    /// V6.3 session pending filing (left-swipe "File" opens the panel).
    @State private var classifyTarget: ChatSession?

    /// Sorted by updatedAt descending (most recent first).
    private var sorted: [ChatSession] {
        model.sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var domainContainers: [ContainerItem] {
        SessionStore.shared.containers(of: .domain)
    }
    private var roleContainers: [ContainerItem] {
        SessionStore.shared.containers(of: .role)
    }
    private var ungrouped: [ChatSession] {
        sorted.filter { $0.containerID == nil }
    }

    private func sessions(of c: ContainerItem) -> [ChatSession] {
        sorted.filter { $0.containerID == c.id }
    }

    private func toggle(_ key: String) {
        if collapsed.contains(key) { collapsed.remove(key) }
        else { collapsed.insert(key) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drawer header: X close | title "Sessions" | top-right "New session"
            HStack(spacing: 8) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("vhs.session.close")

                Spacer()

                Text("Sessions")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.black)

                Spacer()

                Button {
                    model.newSession()
                    onClose()
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityIdentifier("vhs.session.new")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // V6.3 list: ungrouped on top (talk-then-file) -> domain groups -> role groups; tap a container row to collapse/expand
            List {
                // Ungrouped (where new sessions land by default)
                if !ungrouped.isEmpty {
                    Section {
                        if !collapsed.contains("__ungrouped__") {
                            ForEach(ungrouped) { s in
                                sessionRow(s)
                            }
                        }
                    } header: {
                        Button {
                            toggle("__ungrouped__")
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tray")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                Text("Ungrouped")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text("\(ungrouped.count)")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .rotationEffect(.degrees(collapsed.contains("__ungrouped__") ? -90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Domain groups
                if !domainContainers.isEmpty {
                    ForEach(domainContainers) { c in
                        Section {
                            if !collapsed.contains(c.id) {
                                ForEach(sessions(of: c)) { s in
                                    sessionRow(s)
                                }
                            }
                        } header: {
                            containerHeader(c)
                        }
                    }
                }

                // Role groups
                if !roleContainers.isEmpty {
                    ForEach(roleContainers) { c in
                        Section {
                            if !collapsed.contains(c.id) {
                                ForEach(sessions(of: c)) { s in
                                    sessionRow(s)
                                }
                            }
                        } header: {
                            containerHeader(c)
                        }
                    }
                }

                if sorted.isEmpty {
                    Section {
                        VStack(spacing: 6) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.system(size: 22))
                                .foregroundColor(Color.black.opacity(0.25))
                            Text("No sessions yet")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            Text(NSLocalizedString("Tap \"New\" in the top-right to start a new chat", comment: ""))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
            }
            .listStyle(.plain)

            Divider()

            // Bottom-left: Settings entry (V6.1: Settings moved out of the top-right … menu into the drawer footer)
            Button {
                onSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                    Text("Settings")
                        .font(.system(size: 14, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .accessibilityIdentifier("vhs.session.settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityIdentifier("vhs.session.list")
        .sheet(item: $classifyTarget) { target in
            ClassifySheetView(sessionID: target.id)
                .environmentObject(model)
        }
    }

    // MARK: - V6.2 grouped rows

    /// Session row (tap to switch; left-swipe to file/unfile; right-swipe to delete).
    private func sessionRow(_ s: ChatSession) -> some View {
        SessionRow(session: s,
                   isCurrent: s.id == model.currentSessionID,
                   onTap: {
                       model.switchSession(s.id)
                       onClose()
                   })
                   .swipeActions(edge: .leading, allowsFullSwipe: false) {
                       Button {
                           classifyTarget = s
                       } label: {
                           Label("File", systemImage: "folder.badge.plus")
                       }
                       .tint(.blue)
                       // Already filed -> can move back to ungrouped
                       if s.containerID != nil {
                           Button {
                               model.unclassifySession(s.id)
                           } label: {
                               Label("Unfile", systemImage: "arrow.uturn.backward")
                           }
                           .tint(.gray)
                       }
                   }
                   .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                       Button(role: .destructive) {
                           // deleteSession returns false (only one left) -> silently ignore.
                           _ = model.deleteSession(s.id)
                       } label: {
                           Label("Delete", systemImage: "trash")
                       }
                   }
    }

    /// Container header (folder row): tap to collapse/expand.
    private func containerHeader(_ c: ContainerItem) -> some View {
        Button {
            toggle(c.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: c.kind == .domain ? "folder" : "person.circle")
                    .font(.system(size: 13))
                    .foregroundColor(c.kind == .domain ? Color.green : VSColor.blue)
                Text(c.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.primary)
                Text("\(sessions(of: c).count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed.contains(c.id) ? -90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Single row (title + update time + current marker)

private struct SessionRow: View {
    let session: ChatSession
    let isCurrent: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Blue dot on the left of the current session
            Circle()
                .fill(isCurrent ? VSColor.blue : Color.clear)
                .frame(width: 5, height: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.title.isEmpty ? "New Chat" : session.title)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(relativeTime(session.updatedAt))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if isCurrent {
                Text("Current")
                    .font(.system(size: 11))
                    .foregroundColor(VSColor.blue)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }

    /// Relative time: today -> HH:mm; this year -> MM-dd HH:mm; earlier -> yyyy-MM-dd.
    private func relativeTime(_ d: Date) -> String {
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) {
            f.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) {
            f.dateFormat = "MM-dd HH:mm"
        } else {
            f.dateFormat = "yyyy-MM-dd"
        }
        return f.string(from: d)
    }
}
