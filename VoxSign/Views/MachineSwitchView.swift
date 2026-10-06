//
//  MachineSwitchView.swift
//  VoxSign
//
//  V6.1 machine switch panel (tap the top-bar machine name to open):
//  - Cloud (default): zero-config, tap to switch
//  - Self-hosted server list: tap to switch (machine code / direct connect / cloud relay all supported)
//  - Top-right "Manage" -> Settings (add / manage servers)
//

import SwiftUI

struct MachinePickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Cloud (default)
                Section {
                    Button {
                        SettingsStore.shared.setMode(.cloud)
                        dismiss()
                    } label: {
                        HStack {
                            Label(NSLocalizedString("VoxSign Cloud", comment: ""), systemImage: "cloud")
                                .font(.system(size: 15))
                            Spacer()
                            if ConnectivityService.shared.state == .online
                                && SettingsStore.shared.mode == .cloud {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(VSColor.blue)
                            }
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Cloud", comment: ""))
                } footer: {
                    Text(NSLocalizedString("Zero-config; uses the VoxSign cloud service.", comment: ""))
                }

                // Self-hosted machines
                Section {
                    if SettingsStore.shared.servers.isEmpty {
                        Text(NSLocalizedString("No self-hosted machines; tap \"Manage\" in the top-right to add one", comment: ""))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(SettingsStore.shared.servers) { s in
                            Button {
                                SettingsStore.shared.setMode(.selfHosted)
                                SettingsStore.shared.switchServer(s.id)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.name.isEmpty ? NSLocalizedString("Unnamed server", comment: "") : s.name)
                                            .font(.system(size: 15))
                                            .foregroundColor(.primary)
                                        Text(s.base)
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if ConnectivityService.shared.state == .online
                                        && SettingsStore.shared.mode == .selfHosted
                                        && SettingsStore.shared.activeServerID == s.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(VSColor.blue)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text(NSLocalizedString("Self-hosted", comment: ""))
                }
            }
            .navigationTitle(NSLocalizedString("Choose machine", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                        model.showSettings = true
                    } label: {
                        Label(NSLocalizedString("Manage", comment: ""), systemImage: "gearshape")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
