import SwiftUI

struct QuickCaptureView: View {
    @FocusState private var isFocused: Bool
    @State private var text = ""

    let onClose: () -> Void
    let onSave: (String) -> Void

    var body: some View {
        VStack {
            TextField(
                "",
                text: $text,
                prompt: Text("Notunu yaz...")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            )
            .font(.system(size: 22, weight: .medium))
            .textFieldStyle(.plain)
            .focused($isFocused)
            .onSubmit {
                save()
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 10)
        }
        .frame(width: 560, height: 74)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .clipShape(Capsule(style: .continuous))
        .onAppear {
            isFocused = true
        }
        .onExitCommand(perform: onClose)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedText.isEmpty else { return }
        onSave(trimmedText)
        text = ""
        onClose()
    }
}
