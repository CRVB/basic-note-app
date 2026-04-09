import Foundation
import AppKit

final class MediaStore {
    static let previewMaxPixelWidth: CGFloat = 1280

    let baseURL: URL
    private let fileManager: FileManager

    init(baseURL: URL, fileManager: FileManager = .default) {
        self.baseURL = baseURL
        self.fileManager = fileManager
    }

    static func defaultBaseURL(fileManager: FileManager = .default) -> URL {
        let appSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupportURL.appendingPathComponent("NoteLight", isDirectory: true)
    }

    var originalsDirectoryURL: URL {
        baseURL.appendingPathComponent("media/originals", isDirectory: true)
    }

    var previewsDirectoryURL: URL {
        baseURL.appendingPathComponent("media/previews", isDirectory: true)
    }

    func ensureDirectories() throws {
        try fileManager.createDirectory(at: originalsDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewsDirectoryURL, withIntermediateDirectories: true)
    }

    func storePNGImage(_ pngData: Data) throws -> ImageAsset {
        try ensureDirectories()

        guard let originalImage = NSImage(data: pngData), originalImage.size.width > 0, originalImage.size.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let assetID = UUID()
        let originalRelativePath = "media/originals/\(assetID.uuidString).png"
        let previewRelativePath = "media/previews/\(assetID.uuidString).png"
        let originalURL = baseURL.appendingPathComponent(originalRelativePath)
        let previewURL = baseURL.appendingPathComponent(previewRelativePath)

        try pngData.write(to: originalURL, options: .atomic)

        let previewData = try Self.makePreviewPNGData(
            from: originalImage,
            maxPixelWidth: Self.previewMaxPixelWidth
        )
        try previewData.write(to: previewURL, options: .atomic)

        return ImageAsset(
            id: assetID,
            originalRelativePath: originalRelativePath,
            previewRelativePath: previewRelativePath,
            pixelWidth: originalImage.size.width,
            pixelHeight: originalImage.size.height
        )
    }

    func importImage(from fileURL: URL) throws -> ImageAsset {
        let data = try Data(contentsOf: fileURL)
        guard let image = NSImage(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let pngData = try Self.makePNGData(from: image)
        return try storePNGImage(pngData)
    }

    func makeMediaAttachment(for asset: ImageAsset) -> MediaAttachment {
        MediaAttachment(
            id: asset.id,
            fileURL: originalURL(for: asset),
            createdAt: .now
        )
    }

    func originalURL(for asset: ImageAsset) -> URL {
        baseURL.appendingPathComponent(asset.originalRelativePath)
    }

    func previewURL(for asset: ImageAsset) -> URL {
        baseURL.appendingPathComponent(asset.previewRelativePath)
    }

    func pruneOrphanedAssets(referencedAssetIDs: Set<UUID>) throws {
        try ensureDirectories()
        try pruneDirectory(originalsDirectoryURL, referencedAssetIDs: referencedAssetIDs)
        try pruneDirectory(previewsDirectoryURL, referencedAssetIDs: referencedAssetIDs)
    }

    private func pruneDirectory(_ directoryURL: URL, referencedAssetIDs: Set<UUID>) throws {
        let fileURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for fileURL in fileURLs {
            let candidate = fileURL.deletingPathExtension().lastPathComponent
            if let uuid = UUID(uuidString: candidate), !referencedAssetIDs.contains(uuid) {
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    static func makePNGData(from image: NSImage) throws -> Data {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return pngData
    }

    static func makePreviewPNGData(from image: NSImage, maxPixelWidth: CGFloat) throws -> Data {
        let originalSize = image.size
        let targetWidth = min(maxPixelWidth, max(1, originalSize.width))
        let scale = targetWidth / max(1, originalSize.width)
        let targetSize = NSSize(width: targetWidth, height: max(1, originalSize.height * scale))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width.rounded()),
            pixelsHigh: Int(targetSize.height.rounded()),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: originalSize),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        guard let previewData = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return previewData
    }
}

final class NoteStore {
    let baseURL: URL
    let notesDirectoryURL: URL
    let mediaStore: MediaStore
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        baseURL: URL = MediaStore.defaultBaseURL(),
        fileManager: FileManager = .default
    ) {
        self.baseURL = baseURL
        self.notesDirectoryURL = baseURL.appendingPathComponent("notes", isDirectory: true)
        self.fileManager = fileManager
        self.mediaStore = MediaStore(baseURL: baseURL, fileManager: fileManager)
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    var indexURL: URL {
        notesDirectoryURL.appendingPathComponent("index.json")
    }

    func ensureDirectories() throws {
        try fileManager.createDirectory(at: notesDirectoryURL, withIntermediateDirectories: true)
        try mediaStore.ensureDirectories()
    }

    func loadNotes() throws -> [NoteItem] {
        try ensureDirectories()

        guard fileManager.fileExists(atPath: indexURL.path) else {
            let seededNotes = seededNotes()
            try saveNotes(seededNotes)
            return seededNotes
        }

        let indexData = try Data(contentsOf: indexURL)
        let index = try decoder.decode(StoredNoteIndex.self, from: indexData)
        var notes: [NoteItem] = []

        for entry in index.entries {
            let fileURL = noteFileURL(for: entry.id)
            guard fileManager.fileExists(atPath: fileURL.path) else { continue }
            let noteData = try Data(contentsOf: fileURL)
            let stored = try decoder.decode(StoredNoteDocument.self, from: noteData)
            notes.append(makeNoteItem(from: stored))
        }

        if notes.isEmpty {
            let seededNotes = seededNotes()
            try saveNotes(seededNotes)
            return seededNotes
        }

        try pruneOrphanedAssets(from: notes)
        return notes
    }

    func saveNotes(_ notes: [NoteItem]) throws {
        try ensureDirectories()

        let normalizedNotes = notes.map(Self.normalizedNote)
        let index = StoredNoteIndex(entries: normalizedNotes.map { note in
            StoredNoteIndexEntry(
                id: note.id,
                title: note.title,
                previewText: note.preview,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt
            )
        })

        let indexData = try encoder.encode(index)
        try indexData.write(to: indexURL, options: .atomic)

        let existingNoteFiles = try fileManager.contentsOfDirectory(
            at: notesDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let keptNoteFileNames = Set(normalizedNotes.map { "\($0.id.uuidString).json" } + ["index.json"])
        for fileURL in existingNoteFiles where !keptNoteFileNames.contains(fileURL.lastPathComponent) {
            try? fileManager.removeItem(at: fileURL)
        }

        for note in normalizedNotes {
            let stored = StoredNoteDocument(
                id: note.id,
                title: note.title,
                blocks: note.blocks,
                assets: note.imageAssets,
                createdAt: note.createdAt,
                updatedAt: note.updatedAt
            )
            let noteData = try encoder.encode(stored)
            try noteData.write(to: noteFileURL(for: note.id), options: .atomic)
        }

        try pruneOrphanedAssets(from: normalizedNotes)
    }

    func storeScreenshot(pngData: Data) throws -> ImageAsset {
        try mediaStore.storePNGImage(pngData)
    }

    func importImage(from fileURL: URL) throws -> ImageAsset {
        try mediaStore.importImage(from: fileURL)
    }

    private func noteFileURL(for noteID: UUID) -> URL {
        notesDirectoryURL.appendingPathComponent("\(noteID.uuidString).json")
    }

    private func makeNoteItem(from stored: StoredNoteDocument) -> NoteItem {
        let blocks = NoteBlockEditing.normalizedBlocks(stored.blocks)
        let referencedAssetIDs = Set(blocks.compactMap(\.imageAssetID))
        let filteredAssets = stored.assets.filter { referencedAssetIDs.contains($0.id) }
        return NoteItem(
            id: stored.id,
            title: stored.title,
            blocks: blocks,
            imageAssets: filteredAssets,
            mediaAttachments: filteredAssets.map(mediaStore.makeMediaAttachment(for:)),
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt
        )
    }

    private func pruneOrphanedAssets(from notes: [NoteItem]) throws {
        let referencedAssetIDs = Set(notes.flatMap { $0.imageAssets.map(\.id) })
        try mediaStore.pruneOrphanedAssets(referencedAssetIDs: referencedAssetIDs)
    }

    private static func normalizedNote(_ note: NoteItem) -> NoteItem {
        let blocks = NoteBlockEditing.normalizedBlocks(note.blocks)
        let referencedAssetIDs = Set(blocks.compactMap(\.imageAssetID))
        let filteredAssets = note.imageAssets.filter { referencedAssetIDs.contains($0.id) }
        return NoteItem(
            id: note.id,
            title: note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Basliksiz Not" : note.title,
            blocks: blocks,
            imageAssets: filteredAssets,
            mediaAttachments: note.mediaAttachments.filter { referencedAssetIDs.contains($0.id) },
            createdAt: note.createdAt,
            updatedAt: note.updatedAt
        )
    }

    private func seededNotes() -> [NoteItem] {
        let now = Date()
        return [
            NoteItem(
                id: UUID(),
                title: "NoteLight'e hos geldin",
                blocks: [.paragraph("Hizli paneli acmak icin Cmd+c kullan.")],
                imageAssets: [],
                mediaAttachments: [],
                createdAt: now,
                updatedAt: now
            ),
            NoteItem(
                id: UUID(),
                title: "Ornek not",
                blocks: [.paragraph("Bu uygulamayi block tabanli bir akisla kullaniyoruz.")],
                imageAssets: [],
                mediaAttachments: [],
                createdAt: now.addingTimeInterval(-3600),
                updatedAt: now.addingTimeInterval(-3600)
            )
        ]
    }
}
