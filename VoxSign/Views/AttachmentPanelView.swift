//
//  AttachmentPanelView.swift
//  VoxSign
//
//  "+ Add resource" sheet panel (chat-view T3 revamp, new file):
//  - Top: the list of pending attachments (model.pendingAttachments), each with a kind icon + title, deletable
//  - Four Doubao-style list entries: paste text / URL / image (PhotosPicker) / file (fileImporter)
//  - On success model.addAttachment; send() carries them along and clears them automatically
//  - Future extension: forward-email (Mail attachment) entry reserved, see MARK below
//
//  Depends on the frozen interfaces (implemented by the data-layer sub-agent; this view only calls them):
//    Attachment / AttachmentKind；AppModel.pendingAttachments / addAttachment(_:) / removeAttachment(_:)
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct AttachmentPanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    // Form inputs
    @State private var pasteText: String = ""
    @State private var urlString: String = ""
    @State private var pickedItem: PhotosPickerItem? = nil

    var body: some View {
        NavigationStack {
            List {
                // MARK: Pending attachments
                if !model.pendingAttachments.isEmpty {
                    Section("Pending resources (\(model.pendingAttachments.count))") {
                        ForEach(model.pendingAttachments) { att in
                            AttachmentRow(att: att, onDelete: { model.removeAttachment(att.id) })
                                .swipeActions {
                                    Button(role: .destructive) {
                                        model.removeAttachment(att.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }

                // MARK: Paste text
                Section("Paste text") {
                    TextEditor(text: $pasteText)
                        .frame(minHeight: 70)
                    HStack {
                        Button {
                            pasteText = UIPasteboard.general.string ?? ""
                        } label: {
                            Label("Read from clipboard", systemImage: "doc.on.clipboard")
                                .font(.system(size: 13))
                        }
                        Spacer()
                        Button("Add") { addText() }
                            .disabled(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // MARK: URL
                Section("Link") {
                    TextField("https://…", text: $urlString)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Spacer()
                        Button("Add") { addURL() }
                            .disabled(URL(string: urlString.trimmingCharacters(in: .whitespaces)) == nil)
                    }
                }

                // MARK: Image
                Section("Image") {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Label("Pick an image from Photos", systemImage: "photo")
                            .font(.system(size: 15))
                    }
                    .onChange(of: pickedItem) { newItem in
                        Task { await loadImage(newItem) }
                    }
                }

                // MARK: File
                Section {
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Choose file (PDF / text / image…)", systemImage: "doc")
                            .font(.system(size: 15))
                    }
                } footer: {
                    Text("Once chosen, it is sent as a file attachment with the message.")
                        .font(.system(size: 12))
                }

                // Future extension: forward-email (Mail attachment / body) entry —
                //   add Section("Mail") + a Mail composition call, Attachment(kind: .text/.file, …).
                //   Insert here at that time: Button("Forward email") { /* open Mail composer */ }.
            }
            .navigationTitle("Add resource")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.data, .pdf, .text, .image],
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result)
        }
    }

    // MARK: File-picker trigger state
    @State private var showFilePicker: Bool = false

    // MARK: - Add actions

    private func addText() {
        let content = pasteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }
        model.addAttachment(Attachment(id: UUID().uuidString,
                                       kind: .text,
                                       title: "Text",
                                       text: content,
                                       fileName: nil,
                                       localPath: nil))
        pasteText = ""
        dismiss()
    }

    private func addURL() {
        let s = urlString.trimmingCharacters(in: .whitespaces)
        guard URL(string: s) != nil else { return }
        model.addAttachment(Attachment(id: UUID().uuidString,
                                       kind: .url,
                                       title: "Link",
                                       text: s,
                                       fileName: nil,
                                       localPath: nil))
        urlString = ""
        dismiss()
    }

    @MainActor
    private func loadImage(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let uiImage = UIImage(data: data) else { return }
        // Save to the app's Documents directory to get a stable localPath.
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let name = "att_img_\(UUID().uuidString).png"
        let url = docs.appendingPathComponent(name)
        guard let png = uiImage.pngData() else { return }
        do {
            try png.write(to: url)
        } catch { return }
        model.addAttachment(Attachment(id: UUID().uuidString,
                                       kind: .image,
                                       title: "Image",
                                       text: nil,
                                       fileName: name,
                                       localPath: url.path))
        pickedItem = nil
        dismiss()
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let src = urls.first else { return }
        // Security-scoped access + copy to Documents to get a stable localPath.
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        guard let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let name = src.lastPathComponent
        let dst = docs.appendingPathComponent("att_" + UUID().uuidString + "_" + name)
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
        } catch { return }
        model.addAttachment(Attachment(id: UUID().uuidString,
                                       kind: .file,
                                       title: name,
                                       text: nil,
                                       fileName: name,
                                       localPath: dst.path))
        dismiss()
    }
}

// MARK: - Single attachment row (kind icon + title)

private struct AttachmentRow: View {
    let att: Attachment
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(att.kind))
                .font(.system(size: 16))
                .foregroundColor(VSColor.blue)
                .frame(width: 24)
            Text(att.title)
                .font(.system(size: 15))
                .lineLimit(1)
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func iconName(_ kind: AttachmentKind) -> String {
        switch kind {
        case .text: return "doc.text"
        case .url:  return "link"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}
