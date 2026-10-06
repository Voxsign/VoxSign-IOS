//
//  ClassifySheetView.swift
//  VoxSign
//
//  V6.3 filing panel (opens on session left-swipe "File"; talk-then-file):
//  - Top segment: Role / Domain
//  - Middle: list of existing containers; tap to file the session into it
//  - Bottom: enter a new container name + "Create and file"
//

import SwiftUI

struct ClassifySheetView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// The session to file.
    let sessionID: String
    @State private var kind: ContainerKind = .role
    @State private var newName: String = ""

    private var store: SessionStore { SessionStore.shared }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segments: Role / Domain
                Picker("Container type", selection: $kind) {
                    Text("Role").tag(ContainerKind.role)
                    Text("Domain").tag(ContainerKind.domain)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 14)

                List {
                    Section {
                        if store.containers(of: kind).isEmpty {
                            Text(kind == .role ? NSLocalizedString("No roles yet — create one", comment: "") : NSLocalizedString("No domains yet — create one", comment: ""))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(store.containers(of: kind)) { c in
                                Button {
                                    model.classifySession(sessionID, kind: kind, containerID: c.id)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: kind == .role ? "person.circle" : "folder")
                                            .font(.system(size: 15))
                                            .foregroundColor(kind == .role ? VSColor.blue : Color.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(c.name)
                                                .font(.system(size: 15, weight: .medium))
                                                .foregroundColor(.primary)
                                            Text(NSLocalizedString("\(store.sessions.filter { $0.containerID == c.id }.count) sessions", comment: ""))
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(kind == .role ? NSLocalizedString("File into role", comment: "") : NSLocalizedString("File into domain", comment: ""))
                    }
                }
                .listStyle(.insetGrouped)

                // Bottom: create a container and file into it
                HStack(spacing: 10) {
                    TextField(kind == .role ? NSLocalizedString("New role name…", comment: "") : NSLocalizedString("New domain name…", comment: ""), text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 14))
                    Button {
                        model.createContainerAndClassify(sessionID, kind: kind, name: newName)
                        newName = ""
                        dismiss()
                    } label: {
                        Text(NSLocalizedString("Create and file", comment: ""))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(VSColor.blue)
                            .clipShape(Capsule())
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle(NSLocalizedString("File session", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
            }
            .accessibilityIdentifier("vhs.classify")
        }
        .presentationDetents([.medium, .large])
    }
}
