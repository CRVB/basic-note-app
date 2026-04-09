import AppKit
import Carbon
import QuartzCore

/// Uygulama içi panel tetiklemeleri için merkezi bildirim adı.
extension Notification.Name {
    static let toggleQuickCapturePanel = Notification.Name("toggleQuickCapturePanel")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var quickCaptureController: QuickCaptureWindowController?
    private var hotkeyService: QuickCaptureHotkeyService?
    private var statusBarController: StatusBarController?
    private weak var mainWindow: NSWindow?
    private let mainWindowDelegate = MainWindowDelegate()
    private var isConfigured = false
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    func configure(appState: AppState) {
        guard !isConfigured else { return }
        isConfigured = true

        NSApp.setActivationPolicy(.regular)

        let brandIcon = loadBrandIcon()
        if let brandIcon {
            NSApp.applicationIconImage = brandIcon
        }

        quickCaptureController = QuickCaptureWindowController(appState: appState)
        hotkeyService = QuickCaptureHotkeyService { [weak self] in
            self?.toggleQuickCapturePanel()
        }

        statusBarController = StatusBarController(
            icon: brandIcon,
            onOpenMainWindow: { [weak self] in self?.openMainWindowFromStatusBar() },
            onOpenQuickCapture: { [weak self] in self?.openQuickCaptureFromStatusBar() },
            onQuit: { [weak self] in self?.quitFromStatusBar() }
        )

        observer = NotificationCenter.default.addObserver(
            forName: .toggleQuickCapturePanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.toggleQuickCapturePanel()
            }
        }
    }

    func toggleQuickCapturePanel() {
        quickCaptureController?.toggle()
    }

    func openQuickCapturePanel() {
        quickCaptureController?.show()
    }

    @objc func openMainWindowFromStatusBar() {
        NSApp.activate(ignoringOtherApps: true)
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }
        NSApp.windows.first(where: { !($0 is QuickCapturePanelWindow) })?.makeKeyAndOrderFront(nil)
    }

    @objc func openQuickCaptureFromStatusBar() {
        openQuickCapturePanel()
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

    private func loadBrandIcon() -> NSImage? {
        guard let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

@MainActor
private final class MainWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

@MainActor
private final class StatusBarController {
    private let statusItem: NSStatusItem
    private let onOpenMainWindow: () -> Void
    private let onOpenQuickCapture: () -> Void
    private let onQuit: () -> Void

    init(
        icon: NSImage?,
        onOpenMainWindow: @escaping () -> Void,
        onOpenQuickCapture: @escaping () -> Void,
        onQuit: @escaping () -> Void
    ) {
        self.onOpenMainWindow = onOpenMainWindow
        self.onOpenQuickCapture = onOpenQuickCapture
        self.onQuit = onQuit

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon {
                let sized = icon.copy() as? NSImage
                sized?.size = NSSize(width: 18, height: 18)
                button.image = sized
            } else {
                let image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "NoteLight")
                image?.isTemplate = true
                button.image = image
            }
            if button.image == nil {
                button.title = "NL"
            }
            button.imagePosition = .imageOnly
            button.toolTip = "NoteLight"
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Ana Pencereyi Aç", action: #selector(openMainWindowTapped), keyEquivalent: "")
        menu.addItem(withTitle: "Hızlı Not", action: #selector(openQuickCaptureTapped), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Çıkış", action: #selector(quitTapped), keyEquivalent: "q")
        menu.items[0].target = self
        menu.items[1].target = self
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

enum QuickCaptureVisibilityState: Equatable {
    case hidden
    case showing
    case visible
    case hiding
}

struct QuickCapturePanelStateMachine {
    private(set) var state: QuickCaptureVisibilityState = .hidden

    mutating func requestShow() -> Bool {
        switch state {
        case .hidden, .hiding:
            state = .showing
            return true
        case .showing, .visible:
            return false
        }
    }

    mutating func markVisible() {
        if state == .showing {
            state = .visible
        }
    }

    mutating func requestHide() -> Bool {
        switch state {
        case .showing, .visible:
            state = .hiding
            return true
        case .hidden, .hiding:
            return false
        }
    }

    mutating func markHidden() {
        if state == .hiding {
            state = .hidden
        }
    }
}

enum QuickCaptureCloseReason {
    case toggle
    case escape
    case submit
}

@MainActor
final class QuickCaptureWindowController: NSObject, NSWindowDelegate {
    private let appState: AppState
    private let linkResolver: BrowserLinkResolver
    private let screenshotService: QuickCaptureScreenshotCapturing
    private let screenCaptureAuthorizationService: ScreenCaptureAuthorizing
    private let permissionGuidancePresenter: ScreenCapturePermissionGuiding
    private let toastPresenter: QuickCaptureToasting
    private let panel: QuickCapturePanelWindow
    private let inputView: QuickCaptureInputView
    private let inputCoordinator: QuickCaptureInputCoordinator
    private var stateMachine = QuickCapturePanelStateMachine()
    private var browserContextForSession: BrowserLinkContext?
    private var foregroundProcessIDForSession: pid_t?
    private var cachedBrowserURLForSession: String?
    private let screenshotCaptureDelay: TimeInterval

    init(
        appState: AppState,
        linkResolver: BrowserLinkResolver = BrowserLinkResolver(),
        screenshotService: QuickCaptureScreenshotCapturing = QuickCaptureScreenshotService(),
        screenCaptureAuthorizationService: ScreenCaptureAuthorizing = ScreenCaptureAuthorizationService(),
        permissionGuidancePresenter: ScreenCapturePermissionGuiding = ScreenCapturePermissionAlertPresenter(),
        toastPresenter: QuickCaptureToasting? = nil,
        screenshotCaptureDelay: TimeInterval = 0.12
    ) {
        self.appState = appState
        self.linkResolver = linkResolver
        self.screenshotService = screenshotService
        self.screenCaptureAuthorizationService = screenCaptureAuthorizationService
        self.permissionGuidancePresenter = permissionGuidancePresenter
        self.toastPresenter = toastPresenter ?? QuickCaptureToastController()
        self.screenshotCaptureDelay = screenshotCaptureDelay
        inputView = QuickCaptureInputView(frame: .zero)
        panel = QuickCapturePanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        inputCoordinator = QuickCaptureInputCoordinator(window: panel, textField: inputView.textField)

        super.init()

        panel.isFloatingPanel = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .mainMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        panel.onEscape = { [weak self] in
            self?.hide(reason: .escape)
        }

        inputView.onSubmit = { [weak self] text in
            self?.handleSubmission(text)
        }
        inputView.onEscape = { [weak self] in
            self?.hide(reason: .escape)
        }
        inputView.onTextChanged = { [weak self] text in
            self?.updateLinkIndicator(for: text)
        }

        panel.contentView = inputView
    }

    var visibilityState: QuickCaptureVisibilityState {
        stateMachine.state
    }

    var debugWindow: NSWindow { panel }
    var debugInputField: NSTextField { inputView.textField }
    var debugInputText: String { inputView.textField.stringValue }

    func debugSetBrowserContextForTests(_ context: BrowserLinkContext?) {
        browserContextForSession = context
        cachedBrowserURLForSession = nil
        inputView.setLinkBrowserIcon(context?.icon)
    }

    func debugSetForegroundProcessIDForTests(_ processID: pid_t?) {
        foregroundProcessIDForSession = processID
    }

    func toggle(animated: Bool = true) {
        switch stateMachine.state {
        case .hidden, .hiding:
            show(animated: animated)
        case .showing, .visible:
            hide(reason: .toggle, animated: animated)
        }
    }

    func show(animated: Bool = true) {
        show(animated: animated, refreshSessionContext: true)
    }

    private func show(animated: Bool, refreshSessionContext: Bool) {
        guard stateMachine.requestShow() else { return }
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            stateMachine.markHidden()
            return
        }
        if refreshSessionContext {
            foregroundProcessIDForSession = NSWorkspace.shared.frontmostApplication?.processIdentifier
            browserContextForSession = activeSupportedBrowserContext()
            cachedBrowserURLForSession = browserContextForSession.flatMap { linkResolver.resolveDirectURL(from: $0) }
            inputView.setLinkBrowserIcon(browserContextForSession?.icon)
        }
        inputView.setLinkBrowserIconVisible(false)

        let frame = screen.visibleFrame
        let width: CGFloat = 700
        let height: CGFloat = 62
        let x = frame.midX - (width / 2)
        let y = frame.maxY - height - 150
        let targetFrame = NSRect(x: x, y: y, width: width, height: height)

        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeKeyAndOrderFront(nil)

        if animated {
            let initialFrame = widthAdjustedFrame(targetFrame, width: 780)
            panel.setFrame(initialFrame, display: false)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 1.00, 0.30, 1.00)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(targetFrame, display: false)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.stateMachine.markVisible()
                    self.inputCoordinator.focusWithRetry()
                }
            }
        } else {
            panel.alphaValue = 1
            stateMachine.markVisible()
            inputCoordinator.focusWithRetry()
        }
    }

    func hide(
        reason: QuickCaptureCloseReason,
        animated: Bool = true,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        _ = reason
        guard stateMachine.requestHide() else { return }

        inputCoordinator.cancelPendingFocus()

        if animated {
            let currentFrame = panel.frame
            let recoilFrame = scaledFrame(currentFrame, scale: 0.988)
            let finalFrame = scaledFrame(currentFrame, scale: 1.02)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.80, 0.20, 1.00)
                panel.animator().setFrame(recoilFrame, display: false)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.20
                        context.timingFunction = CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.60, 0.20)
                        self.panel.animator().alphaValue = 0
                        self.panel.animator().setFrame(finalFrame, display: false)
                    } completionHandler: {
                        MainActor.assumeIsolated {
                            self.panel.orderOut(nil)
                            self.panel.alphaValue = 1
                            self.stateMachine.markHidden()
                            completion?()
                        }
                    }
                }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            stateMachine.markHidden()
            completion?()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        inputCoordinator.focusWithRetry()
    }

    func debugHandleEscape() {
        hide(reason: .escape, animated: false)
    }

    func debugSubmitForTests(_ text: String) {
        inputView.setInputText(text)
        handleSubmission(text, animatedHide: false)
    }

    private func handleSubmission(_ text: String, animatedHide: Bool = true) {
        let request = QuickCaptureSubmissionRequest(input: text)
        guard request.shouldSubmit else { return }

        let linkURLString = request.wantsLink ? activeBrowserURLString() : nil
        if request.wantsLink && linkURLString == nil {
            showLinkResolutionFailure()
            return
        }

        if request.wantsScreenshot {
            switch screenCaptureAuthorizationService.authorizeIfNeeded() {
            case .granted:
                break
            case .denied, .requestDenied:
                showScreenshotPermissionGuidance()
                return
            }

            inputView.playCaptureFeedbackAnimation { [weak self] in
                self?.completeSubmission(
                    request: request,
                    rawSubmission: text,
                    resolvedLinkURLString: linkURLString,
                    animatedHide: animatedHide
                )
            }
            return
        }

        completeSubmission(
            request: request,
            rawSubmission: text,
            resolvedLinkURLString: linkURLString,
            animatedHide: animatedHide
        )
    }

    private func updateLinkIndicator(for text: String) {
        let wantsLink = text.contains("-link")
        inputView.setLinkBrowserIconVisible(wantsLink && browserContextForSession?.icon != nil)
        if wantsLink && cachedBrowserURLForSession == nil {
            cachedBrowserURLForSession = browserContextForSession.flatMap { linkResolver.resolveDirectURL(from: $0) }
        }
    }

    private func completeSubmission(
        request: QuickCaptureSubmissionRequest,
        rawSubmission: String,
        resolvedLinkURLString: String?,
        animatedHide: Bool
    ) {
        let normalizedText = request.normalizedText

        guard request.wantsScreenshot else {
            appState.addQuickCaptureNote(
                text: normalizedText,
                linkURLString: resolvedLinkURLString,
                screenshotPNGData: nil
            )
            inputView.clearInput()
            hide(reason: .submit, animated: animatedHide)
            return
        }

        hide(reason: .submit, animated: animatedHide) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + self.screenshotCaptureDelay) {
                Task { [weak self] in
                    guard let self else { return }

                    do {
                        let capture = try await self.screenshotService.capture(
                            context: QuickCaptureCaptureContext(
                                foregroundProcessID: self.foregroundProcessIDForSession
                            )
                        )

                        await MainActor.run {
                            self.appState.addQuickCaptureNote(
                                text: normalizedText,
                                linkURLString: resolvedLinkURLString,
                                screenshotPNGData: capture.pngData
                            )
                            self.inputView.clearInput()
                        }
                    } catch let error as QuickCaptureScreenshotError {
                        await MainActor.run {
                            if error == .permissionDenied {
                                self.showScreenshotPermissionGuidance()
                            } else {
                                self.restoreSubmissionAfterCaptureFailure(rawSubmission)
                            }
                        }
                    } catch {
                        await MainActor.run {
                            self.restoreSubmissionAfterCaptureFailure(rawSubmission)
                        }
                    }
                }
            }
        }
    }

    private func activeBrowserURLString() -> String? {
        if let cachedBrowserURLForSession, linkResolver.isValidURL(cachedBrowserURLForSession) {
            return cachedBrowserURLForSession
        }
        let resolved = linkResolver.resolve(context: browserContextForSession)
        cachedBrowserURLForSession = resolved
        return resolved
    }

    private func showLinkResolutionFailure() {
        toastPresenter.show(message: "Aktif sekme linki alinamadi", anchoredTo: panel)
        inputCoordinator.focusWithRetry()
    }

    private func showScreenshotPermissionGuidance() {
        permissionGuidancePresenter.presentPermissionRequiredAlert(anchoredTo: panel)
        inputCoordinator.focusWithRetry()
    }

    private func restoreSubmissionAfterCaptureFailure(_ rawSubmission: String) {
        show(animated: false, refreshSessionContext: false)
        inputView.setInputText(rawSubmission)
        toastPresenter.show(message: "Ekran goruntusu alinamadi", anchoredTo: panel)
        inputCoordinator.focusWithRetry()
    }

    private func activeSupportedBrowserContext() -> BrowserLinkContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              BrowserLinkResolver.isSupportedBrowser(bundleID: bundleID) else {
            return nil
        }
        return BrowserLinkContext(bundleID: bundleID, processID: app.processIdentifier, icon: app.icon)
    }
}

private func scaledFrame(_ frame: NSRect, scale: CGFloat) -> NSRect {
    let newWidth = frame.width * scale
    let newHeight = frame.height * scale
    let newX = frame.midX - (newWidth / 2)
    let newY = frame.midY - (newHeight / 2)
    return NSRect(x: newX, y: newY, width: newWidth, height: newHeight)
}

@MainActor
private final class QuickCapturePanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class QuickCaptureInputCoordinator {
    private weak var window: NSWindow?
    private weak var textField: NSTextField?
    private var pendingWorkItems: [DispatchWorkItem] = []

    init(window: NSWindow, textField: NSTextField) {
        self.window = window
        self.textField = textField
    }

    func focusWithRetry() {
        cancelPendingFocus()

        let retries: [Double] = [0.0, 0.04, 0.12]
        for delay in retries {
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, let window = self.window, let textField = self.textField else { return }
                window.orderFrontRegardless()
                window.makeKey()
                window.makeFirstResponder(nil)
                if !window.makeFirstResponder(textField) {
                    window.initialFirstResponder = textField
                    _ = window.makeFirstResponder(textField)
                }
                textField.selectText(nil)
            }
            pendingWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    func cancelPendingFocus() {
        for item in pendingWorkItems {
            item.cancel()
        }
        pendingWorkItems.removeAll()
    }

    nonisolated static func normalizeSubmission(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

@MainActor
private final class QuickCaptureTextField: NSTextField {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor
private final class QuickCaptureInputView: NSView, NSTextFieldDelegate {
    let textField = QuickCaptureTextField(frame: .zero)

    private let iconView = NSImageView(frame: .zero)
    private let placeholderLabel = NSTextField(labelWithString: "Aklından ne geçiyor?")
    private let shortcutHintLabel = NSTextField(labelWithString: "⌘ ç")
    private let linkBrowserIconView = NSImageView(frame: .zero)

    var onSubmit: ((String) -> Void)?
    var onTextChanged: ((String) -> Void)?
    var onEscape: (() -> Void)? {
        didSet { textField.onEscape = onEscape }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupStyle()
        setupSubviews()
        updatePlaceholderVisibility()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
    }

    override var acceptsFirstResponder: Bool { true }

    func clearInput() {
        setInputText("")
    }

    func setInputText(_ value: String) {
        textField.stringValue = value
        updatePlaceholderVisibility()
        onTextChanged?(value)
    }

    func setLinkBrowserIcon(_ image: NSImage?) {
        guard let image else {
            linkBrowserIconView.image = nil
            return
        }
        let sized = image.copy() as? NSImage
        sized?.size = NSSize(width: 14, height: 14)
        linkBrowserIconView.image = sized
    }

    func setLinkBrowserIconVisible(_ visible: Bool) {
        linkBrowserIconView.isHidden = !visible || linkBrowserIconView.image == nil
    }

    func playCaptureFeedbackAnimation(completion: @escaping @MainActor @Sendable () -> Void) {
        guard let layer else {
            completion()
            return
        }

        struct CaptureFeedbackSnapshot: @unchecked Sendable {
            let layer: CALayer
            let originalBorder: CGColor?
            let originalBackground: CGColor?
            let originalWidth: CGFloat
        }

        let snapshot = CaptureFeedbackSnapshot(
            layer: layer,
            originalBorder: layer.borderColor,
            originalBackground: layer.backgroundColor,
            originalWidth: layer.borderWidth
        )

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.00, 0.30, 1.00)
            layer.borderColor = NSColor.white.withAlphaComponent(0.70).cgColor
            layer.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
            layer.borderWidth = snapshot.originalWidth + 0.8
        } completionHandler: { [snapshot] in
            MainActor.assumeIsolated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.16
                    context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.80, 0.24, 1.00)
                    snapshot.layer.borderColor = snapshot.originalBorder
                    snapshot.layer.backgroundColor = snapshot.originalBackground
                    snapshot.layer.borderWidth = snapshot.originalWidth
                } completionHandler: {
                    MainActor.assumeIsolated {
                        completion()
                    }
                }
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        focusInput()
    }

    func controlTextDidChange(_ obj: Notification) {
        updatePlaceholderVisibility()
        onTextChanged?(textField.stringValue)
    }

    @objc private func submitAction() {
        let rawValue = textField.stringValue
        guard QuickCaptureInputCoordinator.normalizeSubmission(rawValue) != nil else { return }
        onSubmit?(rawValue)
    }

    private func focusInput() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.orderFrontRegardless()
            self.window?.makeKey()
            self.window?.makeFirstResponder(nil)
            if self.window?.makeFirstResponder(self.textField) == false {
                self.window?.initialFirstResponder = self.textField
                _ = self.window?.makeFirstResponder(self.textField)
            }
            self.textField.selectText(nil)
        }
    }

    private func setupStyle() {
        wantsLayer = true
        layer?.cornerRadius = 31
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.68).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.28).cgColor
        layer?.borderWidth = 2
    }

    private func setupSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        iconView.contentTintColor = NSColor.white.withAlphaComponent(0.58)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)
        addSubview(iconView)

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = NSFont.systemFont(ofSize: 22, weight: .regular)
        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        placeholderLabel.lineBreakMode = .byTruncatingTail
        addSubview(placeholderLabel)

        shortcutHintLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutHintLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        shortcutHintLabel.textColor = NSColor.white.withAlphaComponent(0.32)
        addSubview(shortcutHintLabel)

        linkBrowserIconView.translatesAutoresizingMaskIntoConstraints = false
        linkBrowserIconView.imageScaling = .scaleProportionallyUpOrDown
        linkBrowserIconView.isHidden = true
        addSubview(linkBrowserIconView)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = true
        textField.isSelectable = true
        textField.focusRingType = .none
        textField.font = NSFont.systemFont(ofSize: 22, weight: .regular)
        textField.textColor = NSColor.white.withAlphaComponent(0.95)
        textField.delegate = self
        textField.target = self
        textField.action = #selector(submitAction)
        addSubview(textField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 25),
            iconView.heightAnchor.constraint(equalToConstant: 25),

            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 62),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            textField.heightAnchor.constraint(equalToConstant: 32),

            placeholderLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutHintLabel.leadingAnchor, constant: -12),

            shortcutHintLabel.trailingAnchor.constraint(equalTo: linkBrowserIconView.leadingAnchor, constant: -8),
            shortcutHintLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            linkBrowserIconView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            linkBrowserIconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            linkBrowserIconView.widthAnchor.constraint(equalToConstant: 14),
            linkBrowserIconView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func updatePlaceholderVisibility() {
        let isEmpty = textField.stringValue.isEmpty
        placeholderLabel.isHidden = !isEmpty
        shortcutHintLabel.isHidden = !isEmpty
    }
}

struct QuickCaptureHotkeyPolicy {
    static func choosePrimaryKeyCode(layoutKeyCode: UInt32?, fallbackKeyCodes: [UInt32]) -> UInt32? {
        if let layoutKeyCode {
            return layoutKeyCode
        }
        return fallbackKeyCodes.first
    }
}

@MainActor
final class QuickCaptureHotkeyService {
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?
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
        let candidates = hotKeyCandidates()
        let modifiers = UInt32(cmdKey)

        for keyCode in candidates {
            var candidateRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: fourCharCode("YZNB"), id: 1)
            let status = RegisterEventHotKey(
                keyCode,
                modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &candidateRef
            )

            if status == noErr, let candidateRef {
                hotKeyRef = candidateRef
                break
            }
        }

        guard hotKeyRef != nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                Task { @MainActor in
                    let service = Unmanaged<QuickCaptureHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                    service.onHotKey()
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &eventHandlerRef
        )
    }

    private func hotKeyCandidates() -> [UInt32] {
        var values: [UInt32] = []

        if let dynamicCedilla = keyCodeProducing(character: "ç") {
            values.append(dynamicCedilla)
        }
        if let dynamicUpperCedilla = keyCodeProducing(character: "Ç"), !values.contains(dynamicUpperCedilla) {
            values.append(dynamicUpperCedilla)
        }

        let fallback: [UInt32] = [UInt32(kVK_ANSI_Semicolon), UInt32(kVK_ANSI_Quote)]
        for keyCode in fallback where !values.contains(keyCode) {
            values.append(keyCode)
        }

        return values
    }

    private func keyCodeProducing(character: Character) -> UInt32? {
        guard let unmanagedInputSource = TISCopyCurrentKeyboardLayoutInputSource() else { return nil }
        let inputSource = unmanagedInputSource.takeRetainedValue()

        guard let rawLayoutData = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }

        let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
        guard let layoutPtr = CFDataGetBytePtr(layoutData) else { return nil }

        let keyboardLayout = UnsafePointer<UCKeyboardLayout>(OpaquePointer(layoutPtr))
        let target = String(character)

        for keyCode in UInt16(0)...UInt16(127) {
            var deadKeyState: UInt32 = 0
            let maxLength: Int = 4
            var actualLength: Int = 0
            var unicodeChars = [UniChar](repeating: 0, count: maxLength)

            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDown),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                maxLength,
                &actualLength,
                &unicodeChars
            )

            guard status == noErr, actualLength > 0 else { continue }
            let produced = String(utf16CodeUnits: unicodeChars, count: actualLength)
            if produced == target {
                return UInt32(keyCode)
            }
        }

        return nil
    }
}

private func fourCharCode(_ string: String) -> OSType {
    var result: OSType = 0
    for scalar in string.unicodeScalars {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
