import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var editorTitle = ""
    @State private var editorBlocks: [NoteBlock] = [.paragraph()]
    @State private var editorImageAssets: [ImageAsset] = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var filteredNotes: [NoteItem] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return appState.notes }
        return appState.notes.filter {
            $0.title.localizedCaseInsensitiveContains(needle) ||
            $0.content.localizedCaseInsensitiveContains(needle)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Notlarda ara...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(10)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 10)

                List(selection: $appState.selectedNoteID) {
                    ForEach(filteredNotes) { note in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(note.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(note.preview)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Text(dateFormatter.string(from: note.updatedAt))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                        .tag(note.id)
                    }
                }
                .listStyle(.inset)
            }
            .navigationTitle("Notlar")
        } detail: {
            if appState.selectedNote != nil {
                NoteEditorView(
                    title: $editorTitle,
                    blocks: $editorBlocks,
                    imageAssets: $editorImageAssets,
                    mediaStore: appState.noteStore.mediaStore,
                    onImportImageFromDisk: importImageFromDisk,
                    onSave: {
                        appState.updateSelectedNote(
                            title: editorTitle,
                            blocks: editorBlocks,
                            imageAssets: editorImageAssets
                        )
                    }
                )
                .id(appState.selectedNoteID)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                ContentUnavailableView("Not Secilmedi", systemImage: "note.text")
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    appState.createNewNote()
                    syncEditorFromSelection()
                } label: {
                    Label("Yeni Not", systemImage: "plus")
                }

                Button(role: .destructive) {
                    appState.deleteSelectedNote()
                    syncEditorFromSelection()
                } label: {
                    Label("Sil", systemImage: "trash")
                }
                .disabled(appState.selectedNote == nil)

                Button {
                    NotificationCenter.default.post(name: .toggleQuickCapturePanel, object: nil)
                } label: {
                    Label("Hizli Yakala", systemImage: "bolt.fill")
                }
            }
        }
        .onAppear {
            appState.selectFirstIfNeeded()
            syncEditorFromSelection()
        }
        .onChange(of: appState.selectedNoteID) { _, _ in
            syncEditorFromSelection()
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: appState.selectedNoteID)
        .animation(.easeInOut(duration: 0.2), value: appState.notes)
    }

    private func syncEditorFromSelection() {
        guard let note = appState.selectedNote else {
            editorTitle = ""
            editorBlocks = [.paragraph()]
            editorImageAssets = []
            return
        }

        editorTitle = note.title
        editorBlocks = NoteBlockEditing.normalizedBlocks(note.blocks)
        editorImageAssets = note.imageAssets
    }

    private func importImageFromDisk() -> ImageAsset? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .bmp]

        guard panel.runModal() == .OK, let fileURL = panel.url else {
            return nil
        }

        return try? appState.importImage(from: fileURL)
    }
}

private struct NoteEditorView: View {
    @Binding var title: String
    @Binding var blocks: [NoteBlock]
    @Binding var imageAssets: [ImageAsset]
    let mediaStore: MediaStore
    let onImportImageFromDisk: () -> ImageAsset?
    let onSave: () -> Void

    @State private var showSavedMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Baslik", text: $title)
                .font(.system(size: 28, weight: .bold))
                .textFieldStyle(.plain)
            Divider()
            BlockEditorView(
                blocks: $blocks,
                imageAssets: $imageAssets,
                mediaStore: mediaStore,
                onImportImageFromDisk: onImportImageFromDisk
            )
            .frame(minHeight: 260)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.quaternary, lineWidth: 1)
            )

            Spacer()
            HStack {
                if showSavedMessage {
                    Label("Kaydedildi", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.green)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                Spacer()
                Button("Kaydet") {
                    onSave()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                        showSavedMessage = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            showSavedMessage = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
    }
}
