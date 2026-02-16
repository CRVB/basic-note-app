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
            title: "Yazboz'a hoş geldin",
            content: "Hızlı not panelini açmak için Cmd+Shift+K kullan.",
            createdAt: .now
        ),
        NoteItem(
            id: UUID(),
            title: "Örnek not",
            content: "Bu uygulamayı sadeleştirilmiş bir akışla kullanıyoruz.",
            createdAt: .now.addingTimeInterval(-3600)
        )
    ]
    @Published var selectedNoteID: UUID?

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
        let title = text.split(separator: "\n").first.map(String.init) ?? "Hızlı Not"
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
