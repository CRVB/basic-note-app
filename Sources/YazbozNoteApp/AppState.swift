import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var notes: [NoteItem]
    @Published var selectedNoteID: UUID?

    let noteStore: NoteStore

    init(noteStore: NoteStore = NoteStore()) {
        self.noteStore = noteStore

        let loadedNotes: [NoteItem]
        do {
            loadedNotes = try noteStore.loadNotes()
        } catch {
            loadedNotes = []
        }

        notes = loadedNotes
        selectedNoteID = loadedNotes.first?.id
    }

    var selectedNote: NoteItem? {
        guard let selectedNoteID else { return nil }
        return notes.first(where: { $0.id == selectedNoteID })
    }

    func selectFirstIfNeeded() {
        if selectedNoteID == nil {
            selectedNoteID = notes.first?.id
        }
    }

    func createNewNote() {
        let item = NoteItem(
            id: UUID(),
            title: "Yeni Not",
            blocks: [.paragraph()],
            imageAssets: [],
            mediaAttachments: [],
            createdAt: .now,
            updatedAt: .now
        )
        notes.insert(item, at: 0)
        selectedNoteID = item.id
        persistCurrentNotes()
    }

    func updateSelectedNote(title: String, blocks: [NoteBlock], imageAssets: [ImageAsset]) {
        guard let selectedNoteID else { return }
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }

        let normalizedBlocks = NoteBlockEditing.normalizedBlocks(blocks)
        let referencedAssetIDs = Set(normalizedBlocks.compactMap(\.imageAssetID))
        let filteredAssets = imageAssets.filter { referencedAssetIDs.contains($0.id) }

        notes[index].title = normalizedTitle(from: title, blocks: normalizedBlocks)
        notes[index].blocks = normalizedBlocks
        notes[index].imageAssets = filteredAssets
        notes[index].mediaAttachments = filteredAssets.map(noteStore.mediaStore.makeMediaAttachment(for:))
        notes[index].updatedAt = .now
        persistCurrentNotes()
    }

    func addQuickCaptureNote(
        text: String?,
        linkURLString: String?,
        screenshotPNGData: Data?
    ) {
        do {
            var blocks: [NoteBlock] = []
            var imageAssets: [ImageAsset] = []

            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph(text))
            }

            if let linkURLString, !linkURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.paragraph("link: \(linkURLString)"))
            }

            if let screenshotPNGData {
                let asset = try noteStore.storeScreenshot(pngData: screenshotPNGData)
                imageAssets.append(asset)
                blocks.append(.image(assetID: asset.id, preferredWidth: min(760, asset.pixelWidth)))
            }

            let normalizedBlocks = NoteBlockEditing.normalizedBlocks(blocks)
            let title = normalizedTitle(
                from: text ?? "",
                blocks: normalizedBlocks,
                fallback: screenshotPNGData == nil ? "Yeni Not" : "Ekran Goruntusu"
            )

            let note = NoteItem(
                id: UUID(),
                title: title,
                blocks: normalizedBlocks,
                imageAssets: imageAssets,
                mediaAttachments: imageAssets.map(noteStore.mediaStore.makeMediaAttachment(for:)),
                createdAt: .now,
                updatedAt: .now
            )

            notes.insert(note, at: 0)
            selectedNoteID = note.id
            persistCurrentNotes()
        } catch {
            return
        }
    }

    func importImage(from fileURL: URL) throws -> ImageAsset {
        try noteStore.importImage(from: fileURL)
    }

    func deleteSelectedNote() {
        guard let selectedNoteID else { return }
        guard let index = notes.firstIndex(where: { $0.id == selectedNoteID }) else { return }
        notes.remove(at: index)
        self.selectedNoteID = notes.first?.id
        persistCurrentNotes()
    }

    private func persistCurrentNotes() {
        do {
            try noteStore.saveNotes(notes)
        } catch {
            return
        }
    }

    private func normalizedTitle(
        from title: String,
        blocks: [NoteBlock],
        fallback: String = "Basliksiz Not"
    ) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        if let firstLine = blocks.plainText
            .split(separator: "\n")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !firstLine.isEmpty {
            return firstLine
        }

        return fallback
    }
}
