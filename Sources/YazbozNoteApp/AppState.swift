import Foundation
import Combine

struct NoteItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var content: String
    var createdAt: Date

    var preview: String {
        content.replacingOccurrences(of: "\n", with: " ")
    }
}

final class AppState: ObservableObject {
    @Published var notes: [NoteItem] = [
        NoteItem(
            id: UUID(),
            title: "Welcome to Yazboz",
            content: "This is the initial skeleton. Next step is global shortcut + floating spotlight window.",
            createdAt: .now
        )
    ]
    @Published var selectedNoteID: UUID?
    @Published var showQuickCapture = false

    var selectedNote: NoteItem? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    func selectFirstIfNeeded() {
        if selectedNoteID == nil {
            selectedNoteID = notes.first?.id
        }
    }

    func addQuickNote(text: String) {
        let title = text.split(separator: "\n").first.map(String.init) ?? "Quick Note"
        let item = NoteItem(
            id: UUID(),
            title: title,
            content: text,
            createdAt: .now
        )
        notes.insert(item, at: 0)
        selectedNoteID = item.id
    }
}
