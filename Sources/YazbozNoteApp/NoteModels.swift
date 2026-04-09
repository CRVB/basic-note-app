import Foundation
import AppKit

struct MediaAttachment: Identifiable, Hashable {
    let id: UUID
    var fileURL: URL
    var createdAt: Date
}

struct ImageAsset: Identifiable, Hashable, Codable {
    let id: UUID
    var originalRelativePath: String
    var previewRelativePath: String
    var pixelWidth: Double
    var pixelHeight: Double

    var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

enum NoteBlockKind: String, Codable, CaseIterable, Hashable {
    case paragraph
    case heading1
    case heading2
    case heading3
    case image
}

struct NoteBlock: Identifiable, Hashable, Codable {
    var id: UUID
    var kind: NoteBlockKind
    var text: String
    var imageAssetID: UUID?
    var preferredWidth: Double?

    init(
        id: UUID = UUID(),
        kind: NoteBlockKind,
        text: String = "",
        imageAssetID: UUID? = nil,
        preferredWidth: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.imageAssetID = imageAssetID
        self.preferredWidth = preferredWidth
    }

    static func paragraph(_ text: String = "", id: UUID = UUID()) -> NoteBlock {
        NoteBlock(id: id, kind: .paragraph, text: text)
    }

    static func heading1(_ text: String = "", id: UUID = UUID()) -> NoteBlock {
        NoteBlock(id: id, kind: .heading1, text: text)
    }

    static func heading2(_ text: String = "", id: UUID = UUID()) -> NoteBlock {
        NoteBlock(id: id, kind: .heading2, text: text)
    }

    static func heading3(_ text: String = "", id: UUID = UUID()) -> NoteBlock {
        NoteBlock(id: id, kind: .heading3, text: text)
    }

    static func image(assetID: UUID, preferredWidth: Double? = nil, id: UUID = UUID()) -> NoteBlock {
        NoteBlock(id: id, kind: .image, imageAssetID: assetID, preferredWidth: preferredWidth)
    }

    var isTextual: Bool {
        kind != .image
    }

    var isEmptyTextual: Bool {
        isTextual && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct StoredNoteDocument: Codable, Hashable {
    var id: UUID
    var title: String
    var blocks: [NoteBlock]
    var assets: [ImageAsset]
    var createdAt: Date
    var updatedAt: Date
}

struct StoredNoteIndexEntry: Codable, Hashable {
    var id: UUID
    var title: String
    var previewText: String
    var createdAt: Date
    var updatedAt: Date
}

struct StoredNoteIndex: Codable, Hashable {
    var entries: [StoredNoteIndexEntry]
}

struct NoteItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var blocks: [NoteBlock]
    var imageAssets: [ImageAsset]
    var mediaAttachments: [MediaAttachment]
    var createdAt: Date
    var updatedAt: Date

    var content: String {
        blocks.plainText
    }

    var preview: String {
        blocks.previewText
    }
}

extension Array where Element == NoteBlock {
    var plainText: String {
        compactMap { block in
            switch block.kind {
            case .image:
                return nil
            case .paragraph, .heading1, .heading2, .heading3:
                let normalized = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return normalized.isEmpty ? nil : normalized
            }
        }
        .joined(separator: "\n")
    }

    var previewText: String {
        let preview = plainText.replacingOccurrences(of: "\n", with: " ")
        let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Gorsel not" : trimmed
    }
}

enum NoteBlockEditing {
    static func makeEmptyParagraph() -> NoteBlock {
        .paragraph()
    }

    static func normalizedBlocks(_ blocks: [NoteBlock]) -> [NoteBlock] {
        var result = blocks

        if result.isEmpty {
            return [makeEmptyParagraph()]
        }

        if let last = result.last, last.kind == .image {
            result.append(makeEmptyParagraph())
        }

        if result.allSatisfy({ !$0.isTextual }) {
            result.append(makeEmptyParagraph())
        }

        return result
    }

    static func insertParagraph(after blockID: UUID, in blocks: inout [NoteBlock]) -> UUID {
        let newBlock = makeEmptyParagraph()
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else {
            blocks.append(newBlock)
            return newBlock.id
        }
        blocks.insert(newBlock, at: index + 1)
        return newBlock.id
    }

    static func removeTextBlock(id: UUID, in blocks: inout [NoteBlock]) -> UUID? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        guard blocks[index].isTextual else { return nil }

        if blocks.count == 1 {
            blocks[0] = makeEmptyParagraph()
            return blocks[0].id
        }

        blocks.remove(at: index)

        if blocks.isEmpty {
            let replacement = makeEmptyParagraph()
            blocks = [replacement]
            return replacement.id
        }

        let focusIndex = max(0, min(index - 1, blocks.count - 1))
        return blocks[focusIndex].id
    }

    static func replaceTextBlockKind(id: UUID, with kind: NoteBlockKind, in blocks: inout [NoteBlock]) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        guard kind != .image else { return }
        blocks[index].kind = kind
        blocks[index].text = ""
        blocks[index].imageAssetID = nil
        blocks[index].preferredWidth = nil
    }

    static func replaceWithImageBlock(
        id: UUID,
        assetID: UUID,
        preferredWidth: Double?,
        in blocks: inout [NoteBlock]
    ) -> UUID? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        blocks[index] = .image(assetID: assetID, preferredWidth: preferredWidth, id: id)

        if index == blocks.count - 1 {
            let newParagraphID = insertParagraph(after: id, in: &blocks)
            return newParagraphID
        }

        if !blocks[index + 1].isTextual {
            let newParagraphID = insertParagraph(after: id, in: &blocks)
            return newParagraphID
        }

        return blocks[index + 1].id
    }

    static func removeImageBlock(id: UUID, in blocks: inout [NoteBlock]) -> UUID? {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return nil }
        guard blocks[index].kind == .image else { return nil }

        blocks.remove(at: index)

        if blocks.isEmpty {
            let replacement = makeEmptyParagraph()
            blocks = [replacement]
            return replacement.id
        }

        if let nextText = blocks[index...].first(where: { $0.isTextual }) {
            return nextText.id
        }

        if let previousText = blocks[..<index].last(where: { $0.isTextual }) {
            return previousText.id
        }

        let replacement = makeEmptyParagraph()
        blocks.append(replacement)
        return replacement.id
    }

    static func clampedImageWidth(preferredWidth: Double?, naturalWidth: Double, maxWidth: Double) -> Double {
        let upperBound = max(160, maxWidth)
        let baseWidth = preferredWidth ?? naturalWidth
        return min(max(160, baseWidth), upperBound)
    }
}
