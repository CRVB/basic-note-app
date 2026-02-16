import AppKit
import Carbon
import SwiftUI

extension Notification.Name {
    static let toggleQuickCapturePanel = Notification.Name("toggleQuickCapturePanel")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panelController: QuickCapturePanelController?
    private var hotKeyManager: GlobalHotKeyManager?
    private var statusBarController: StatusBarController?
    private weak var mainWindow: NSWindow?
    private let mainWindowDelegate = MainWindowDelegate()
    private var isConfigured = false
    private var observer: NSObjectProtocol?

    func configure(appState: AppState) {
        guard !isConfigured else { return }
        isConfigured = true

        panelController = QuickCapturePanelController(appState: appState)
        hotKeyManager = GlobalHotKeyManager { [weak self] in
            self?.toggleQuickCapturePanel()
        }
        statusBarController = StatusBarController(
            onOpenMainWindow: { [weak self] in self?.openMainWindowFromStatusBar() },
            onOpenQuickCapture: { [weak self] in self?.openQuickCaptureFromStatusBar() },
            onQuit: { [weak self] in self?.quitFromStatusBar() }
        )

        observer = NotificationCenter.default.addObserver(
            forName: .toggleQuickCapturePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.toggleQuickCapturePanel()
        }
    }

    func toggleQuickCapturePanel() {
        panelController?.toggle()
    }

    @objc func openMainWindowFromStatusBar() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        let fallbackWindow = NSApp.windows.first(where: { !($0 is NSPanel) })
        fallbackWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func openQuickCaptureFromStatusBar() {
        toggleQuickCapturePanel()
    }

    @objc func quitFromStatusBar() {
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.delegate = mainWindowDelegate
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private final class StatusBarController {
    private let statusItem: NSStatusItem
    private let onOpenMainWindow: () -> Void
    private let onOpenQuickCapture: () -> Void
    private let onQuit: () -> Void

    init(
        onOpenMainWindow: @escaping () -> Void,
        onOpenQuickCapture: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenQuickCapture = onOpenQuickCapture
        self.onQuit = onQuit
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Yazboz")
            image?.isTemplate = true
            button.image = image
            if image == nil {
                button.title = "YZ"
            }
            button.imagePosition = .imageOnly
            button.toolTip = "Yazboz"
        }

        let menu = NSMenu()
        menu.addItem(
            withTitle: "Ana Pencereyi Aç",
            action: #selector(AppDelegate.openMainWindowFromStatusBar),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Hızlı Not",
            action: #selector(AppDelegate.openQuickCaptureFromStatusBar),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Çıkış",
            action: #selector(quitTapped),
            keyEquivalent: "q"
        )
        menu.items[0].target = self
        menu.items[0].action = #selector(openMainWindowTapped)
        menu.items[1].target = self
        menu.items[1].action = #selector(openQuickCaptureTapped)
        menu.items[3].target = self
        statusItem.menu = menu
    }

    @objc private func openMainWindowTapped() {
        onOpenMainWindow()
    }

    @objc private func openQuickCaptureTapped() {
        onOpenQuickCapture()
    }

    @objc private func quitTapped() {
        onQuit()
    }
}

private final class QuickCapturePanelController {
    private let panel: QuickCapturePanel

    init(appState: AppState) {
        panel = QuickCapturePanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 74),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let rootView = QuickCaptureView(
            onClose: { [weak panel] in
                guard let panel else { return }
                Self.hidePanel(panel, animated: true)
            },
            onSave: { text in
                appState.addQuickNote(text: text)
            }
        )

        let hosting = NSHostingView(rootView: rootView)
        panel.contentView = hosting
    }

    func toggle() {
        panel.isVisible ? hide(animated: true) : show(animated: true)
    }

    private func show(animated: Bool) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let frame = screen.visibleFrame
        let width: CGFloat = 560
        let height: CGFloat = 74
        let x = frame.midX - (width / 2)
        let y = frame.maxY - height - 72

        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
        NSApp.activate(ignoringOtherApps: true)

        if animated {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            panel.setFrameOrigin(NSPoint(x: x, y: y + 12))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().alphaValue = 1
                panel.animator().setFrameOrigin(NSPoint(x: x, y: y))
            }
        } else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        }

        panel.makeKey()
    }

    func hide(animated: Bool) {
        Self.hidePanel(panel, animated: animated)
    }

    private static func hidePanel(_ panel: NSPanel, animated: Bool) {
        guard panel.isVisible else { return }
        if animated {
            let currentOrigin = panel.frame.origin
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
                panel.animator().setFrameOrigin(NSPoint(x: currentOrigin.x, y: currentOrigin.y + 8))
            } completionHandler: {
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
            return
        }
        panel.orderOut(nil)
    }
}

private final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class GlobalHotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let onHotKey: () -> Void

    init(onHotKey: @escaping () -> Void) {
        self.onHotKey = onHotKey
        register()
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }

    private func register() {
        let hotKeyID = EventHotKeyID(signature: FourCharCode("YZNB"), id: 1)
        let keyCode = UInt32(kVK_ANSI_K)
        let modifiers = UInt32(cmdKey | shiftKey)

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                manager.onHotKey()
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }
}

private func FourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
