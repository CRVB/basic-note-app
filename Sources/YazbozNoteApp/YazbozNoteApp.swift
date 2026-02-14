import SwiftUI

@main
struct YazbozNoteApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Yazboz Note") {
            ContentView()
                .environmentObject(appState)
        }
        .defaultSize(width: 900, height: 620)
        .commands {
            CommandMenu("Quick Actions") {
                Button("Toggle Quick Capture") {
                    appState.showQuickCapture.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}
