import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            List(selection: $appState.selectedNoteID) {
                ForEach(appState.notes) { note in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(note.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(note.preview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .tag(note.id)
                }
            }
            .navigationTitle("Notlar")
        } detail: {
            if let note = appState.selectedNote {
                NoteDetailView(note: note)
            } else {
                ContentUnavailableView("Not Seçilmedi", systemImage: "note.text")
            }
        }

        .toolbar {
            ToolbarItem {
                Button {
                    NotificationCenter.default.post(name: .toggleQuickCapturePanel, object: nil)
                } label: {
                    Label("Hızlı Yakala", systemImage: "bolt.fill")
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
