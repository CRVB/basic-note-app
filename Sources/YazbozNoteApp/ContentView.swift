import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack {
            NavigationSplitView {
                List(selection: $appState.selectedNoteID) {
                    ForEach(appState.notes) { note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title)
                                .font(.headline)
                            Text(note.preview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .tag(note.id)
                    }
                }
                .navigationTitle("Notes")
            } detail: {
                if let note = appState.selectedNote {
                    NoteDetailView(note: note)
                } else {
                    ContentUnavailableView("No Note Selected", systemImage: "note.text")
                }
            }

            if appState.showQuickCapture {
                QuickCaptureView(
                    onClose: { appState.showQuickCapture = false },
                    onSave: { text in
                        appState.addQuickNote(text: text)
                        appState.showQuickCapture = false
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.88), value: appState.showQuickCapture)
        .toolbar {
            ToolbarItem {
                Button {
                    appState.showQuickCapture = true
                } label: {
                    Label("Quick Capture", systemImage: "bolt.fill")
                }
            }
        }
        .onAppear {
            appState.selectFirstIfNeeded()
        }
    }
}

private struct NoteDetailView: View {
    let note: NoteItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(note.title)
                .font(.title.bold())
            Text(note.content)
                .font(.body)
            Spacer()
        }
        .padding(24)
    }
}

private struct QuickCaptureView: View {
    @State private var text = ""
    let onClose: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Quick Capture", systemImage: "sparkle.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Esc") {
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }

            TextField("Write a quick note or todo...", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    save()
                }

            HStack {
                Text("Enter to save")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        )
        .shadow(radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        text = ""
    }
}
