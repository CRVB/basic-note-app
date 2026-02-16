import SwiftUI
import AppKit

@main
struct YazbozNoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Yazboz Not", id: "main-window") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    appDelegate.configure(appState: appState)
                }
                .background(MainWindowBinder(appDelegate: appDelegate))
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandMenu("Hızlı İşlemler") {
                Button("Hızlı Paneli Aç/Kapat") {
                    NotificationCenter.default.post(name: .toggleQuickCapturePanel, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

private struct MainWindowBinder: NSViewRepresentable {
    let appDelegate: AppDelegate

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                appDelegate.registerMainWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                appDelegate.registerMainWindow(window)
            }
        }
    }
}
