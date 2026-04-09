import SwiftUI
import AppKit

struct BlockEditorView: View {
    @Binding var blocks: [NoteBlock]
    @Binding var imageAssets: [ImageAsset]
    let mediaStore: MediaStore
    let onImportImageFromDisk: () -> ImageAsset?

    @State private var slashMenuBlockID: UUID?
    @State private var focusedBlockID: UUID?
    @State private var focusRequestID = UUID()

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(240, proxy.size.width - 32)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach($blocks) { $block in
                        VStack(alignment: .leading, spacing: 8) {
                            if block.kind == .image {
                                ImageBlockRow(
                                    block: $block,
                                    asset: asset(for: block),
                                    mediaStore: mediaStore,
                                    contentWidth: contentWidth,
                                    onDelete: {
                                        focusedBlockID = NoteBlockEditing.removeImageBlock(
                                            id: block.id,
                                            in: &blocks
                                        )
                                    }
                                )
                            } else {
                                TextBlockRow(
                                    block: $block,
                                    isFocused: focusedBlockID == block.id,
                                    focusRequestID: focusedBlockID == block.id ? focusRequestID : nil,
                                    onFocus: {
                                        focusedBlockID = block.id
                                    },
                                    onEnter: {
                                        slashMenuBlockID = nil
                                        requestFocus(NoteBlockEditing.insertParagraph(
                                            after: block.id,
                                            in: &blocks
                                        ))
                                    },
                                    onBackspaceWhenEmpty: {
                                        slashMenuBlockID = nil
                                        requestFocus(NoteBlockEditing.removeTextBlock(
                                            id: block.id,
                                            in: &blocks
                                        ))
                                    },
                                    onSlashRequest: {
                                        slashMenuBlockID = block.id
                                        focusedBlockID = block.id
                                    }
                                )
                            }

                            if slashMenuBlockID == block.id {
                                SlashMenuView { selectedKind in
                                    handleSlashSelection(
                                        selectedKind,
                                        from: block.id,
                                        contentWidth: contentWidth
                                    )
                                }
                            }
                        }
                        .onChange(of: block.text) { _, newValue in
                            if slashMenuBlockID == block.id && newValue != "/" {
                                slashMenuBlockID = nil
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }
        }
        .onAppear {
            if focusedBlockID == nil {
                requestFocus(blocks.first(where: { $0.isTextual })?.id)
            }
        }
        .onChange(of: blocks) { _, updatedBlocks in
            blocks = NoteBlockEditing.normalizedBlocks(updatedBlocks)
            if focusedBlockID == nil {
                requestFocus(blocks.first(where: { $0.isTextual })?.id)
            }
        }
    }

    private func asset(for block: NoteBlock) -> ImageAsset? {
        guard let imageAssetID = block.imageAssetID else { return nil }
        return imageAssets.first(where: { $0.id == imageAssetID })
    }

    private func handleSlashSelection(
        _ selectedKind: NoteBlockKind,
        from blockID: UUID,
        contentWidth: CGFloat
    ) {
        slashMenuBlockID = nil

        switch selectedKind {
        case .paragraph, .heading1, .heading2, .heading3:
            NoteBlockEditing.replaceTextBlockKind(id: blockID, with: selectedKind, in: &blocks)
            requestFocus(blockID)
        case .image:
            guard let asset = onImportImageFromDisk() else {
                if let index = blocks.firstIndex(where: { $0.id == blockID }) {
                    blocks[index].text = ""
                }
                requestFocus(blockID)
                return
            }

            if !imageAssets.contains(where: { $0.id == asset.id }) {
                imageAssets.append(asset)
            }

            let preferredWidth = min(Double(contentWidth), asset.pixelWidth)
            requestFocus(NoteBlockEditing.replaceWithImageBlock(
                id: blockID,
                assetID: asset.id,
                preferredWidth: preferredWidth,
                in: &blocks
            ))
        }
    }

    private func requestFocus(_ blockID: UUID?) {
        focusedBlockID = blockID
        guard blockID != nil else { return }
        focusRequestID = UUID()
    }
}

private struct SlashMenuView: View {
    let onSelect: (NoteBlockKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SlashMenuButton(title: "Paragraph", subtitle: "Normal metin") {
                onSelect(.paragraph)
            }
            SlashMenuButton(title: "H1", subtitle: "Buyuk baslik") {
                onSelect(.heading1)
            }
            SlashMenuButton(title: "H2", subtitle: "Orta baslik") {
                onSelect(.heading2)
            }
            SlashMenuButton(title: "H3", subtitle: "Kucuk baslik") {
                onSelect(.heading3)
            }
            SlashMenuButton(title: "Image", subtitle: "Diskten gorsel ekle") {
                onSelect(.image)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.10), radius: 12, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct SlashMenuButton: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .leading)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TextBlockRow: View {
    @Binding var block: NoteBlock
    let isFocused: Bool
    let focusRequestID: UUID?
    let onFocus: () -> Void
    let onEnter: () -> Void
    let onBackspaceWhenEmpty: () -> Void
    let onSlashRequest: () -> Void

    @State private var measuredHeight: CGFloat = 36

    var body: some View {
        BlockTextEditorRepresentable(
            text: $block.text,
            kind: block.kind,
            isFocused: isFocused,
            focusRequestID: focusRequestID,
            measuredHeight: $measuredHeight,
            onFocus: onFocus,
            onEnter: onEnter,
            onBackspaceWhenEmpty: onBackspaceWhenEmpty,
            onSlashRequest: onSlashRequest
        )
        .frame(height: measuredHeight)
    }
}

private struct ImageBlockRow: View {
    @Binding var block: NoteBlock
    let asset: ImageAsset?
    let mediaStore: MediaStore
    let contentWidth: CGFloat
    let onDelete: () -> Void

    @State private var dragStartWidth: Double?

    var body: some View {
        if let asset {
            let naturalWidth = max(1, asset.pixelWidth)
            let displayWidth = NoteBlockEditing.clampedImageWidth(
                preferredWidth: block.preferredWidth,
                naturalWidth: naturalWidth,
                maxWidth: Double(contentWidth)
            )
            let displayHeight = max(1, displayWidth * (asset.pixelHeight / naturalWidth))

            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .bottomTrailing) {
                    if let image = NSImage(contentsOf: mediaStore.previewURL(for: asset)) {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: displayWidth, height: displayHeight)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
                            )
                            .onTapGesture {
                                NSWorkspace.shared.open(mediaStore.originalURL(for: asset))
                            }
                    }

                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.72))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .padding(10)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    if dragStartWidth == nil {
                                        dragStartWidth = block.preferredWidth ?? displayWidth
                                    }
                                    let proposedWidth = (dragStartWidth ?? displayWidth) + value.translation.width
                                    block.preferredWidth = NoteBlockEditing.clampedImageWidth(
                                        preferredWidth: proposedWidth,
                                        naturalWidth: naturalWidth,
                                        maxWidth: Double(contentWidth)
                                    )
                                }
                                .onEnded { _ in
                                    dragStartWidth = nil
                                }
                        )
                }

                HStack(spacing: 12) {
                    Text("PNG")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(asset.originalRelativePath.split(separator: "/").last.map(String.init) ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    Button("Sil", role: .destructive, action: onDelete)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                }
            }
        }
    }
}

@MainActor
private struct BlockTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    let kind: NoteBlockKind
    let isFocused: Bool
    let focusRequestID: UUID?
    @Binding var measuredHeight: CGFloat
    let onFocus: () -> Void
    let onEnter: () -> Void
    let onBackspaceWhenEmpty: () -> Void
    let onSlashRequest: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = BlockNSTextView()
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.string = text
        textView.onFocus = onFocus
        textView.keyHandler = { event in
            context.coordinator.handleKeyDown(event, textView: textView)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        context.coordinator.applyStyle(kind, to: textView)
        context.coordinator.updateMeasuredHeight(for: textView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            textView.string = text
        }

        context.coordinator.parent = self
        context.coordinator.applyStyle(kind, to: textView)
        context.coordinator.updateMeasuredHeight(for: textView)

        if isFocused,
           let focusRequestID,
           focusRequestID != context.coordinator.lastAppliedFocusRequestID,
           textView.window?.firstResponder != textView {
            context.coordinator.lastAppliedFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockTextEditorRepresentable
        weak var textView: BlockNSTextView?
        var lastAppliedFocusRequestID: UUID?

        init(_ parent: BlockTextEditorRepresentable) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            updateMeasuredHeight(for: textView)

            if textView.string == "/" {
                parent.onSlashRequest()
            }
        }

        func applyStyle(_ kind: NoteBlockKind, to textView: NSTextView) {
            switch kind {
            case .paragraph:
                textView.font = NSFont.systemFont(ofSize: 16, weight: .regular)
                textView.textColor = .textColor
            case .heading1:
                textView.font = NSFont.systemFont(ofSize: 30, weight: .bold)
                textView.textColor = .labelColor
            case .heading2:
                textView.font = NSFont.systemFont(ofSize: 24, weight: .semibold)
                textView.textColor = .labelColor
            case .heading3:
                textView.font = NSFont.systemFont(ofSize: 19, weight: .semibold)
                textView.textColor = .labelColor
            case .image:
                break
            }
        }

        func updateMeasuredHeight(for textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let usedRect = layoutManager.usedRect(for: textContainer)
            let minimumHeight: CGFloat = parent.kind == .paragraph ? 38 : 44
            parent.measuredHeight = max(minimumHeight, ceil(usedRect.height) + 12)
        }

        func handleKeyDown(_ event: NSEvent, textView: NSTextView) -> Bool {
            switch event.keyCode {
            case 36, 76:
                if parent.kind == .paragraph && event.modifierFlags.contains(.shift) {
                    return false
                }
                parent.onEnter()
                return true
            case 51:
                if textView.string.isEmpty {
                    parent.onBackspaceWhenEmpty()
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}

@MainActor
private final class BlockNSTextView: NSTextView {
    var keyHandler: ((NSEvent) -> Bool)?
    var onFocus: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onFocus?()
        }
        return didBecomeFirstResponder
    }
}
