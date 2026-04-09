import XCTest
import AppKit
@testable import YazbozNoteApp

private struct StubScreenshotError: Error {}

private final class StubBrowserLinkResolver: BrowserLinkResolver {
    var directResult: String?
    var addressBarResult: String?
    private(set) var directCallCount = 0
    private(set) var addressBarCallCount = 0

    init(directResult: String? = nil, addressBarResult: String? = nil) {
        self.directResult = directResult
        self.addressBarResult = addressBarResult
    }

    override func resolveDirectURL(from context: BrowserLinkContext) -> String? {
        directCallCount += 1
        return directResult
    }

    override func captureURLViaAddressBar(from context: BrowserLinkContext) -> String? {
        addressBarCallCount += 1
        return addressBarResult
    }
}

private final class StubScreenshotService: QuickCaptureScreenshotCapturing, @unchecked Sendable {
    var result: Result<QuickCaptureScreenshotCapture, Error>
    private(set) var capturedContexts: [QuickCaptureCaptureContext] = []

    init(result: Result<QuickCaptureScreenshotCapture, Error>) {
        self.result = result
    }

    func capture(context: QuickCaptureCaptureContext) async throws -> QuickCaptureScreenshotCapture {
        capturedContexts.append(context)
        return try result.get()
    }
}

private final class StubScreenCaptureAuthorizer: ScreenCaptureAuthorizing {
    var status: ScreenCaptureAuthorizationStatus
    private(set) var callCount = 0

    init(status: ScreenCaptureAuthorizationStatus = .granted) {
        self.status = status
    }

    func authorizeIfNeeded() -> ScreenCaptureAuthorizationStatus {
        callCount += 1
        return status
    }
}

@MainActor
private final class PermissionGuidanceSpy: ScreenCapturePermissionGuiding {
    private(set) var callCount = 0

    func presentPermissionRequiredAlert(anchoredTo window: NSWindow) {
        callCount += 1
    }
}

@MainActor
private final class ToastSpy: QuickCaptureToasting {
    private(set) var messages: [String] = []

    func show(message: String, anchoredTo window: NSWindow) {
        messages.append(message)
    }
}

private func makeSampleScreenshotPNGData(
    width: Int = 16,
    height: Int = 10
) -> Data {
    let size = NSSize(width: width, height: height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemTeal.setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

private func makeTemporaryBaseURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("NoteLightTests-\(UUID().uuidString)")
}

private func removeTemporaryBaseURL(_ baseURL: URL) {
    try? FileManager.default.removeItem(at: baseURL)
}

@MainActor
private func makeEmptyAppState() -> (AppState, URL) {
    let baseURL = makeTemporaryBaseURL()
    let store = NoteStore(baseURL: baseURL)
    let appState = AppState(noteStore: store)
    appState.notes = []
    appState.selectedNoteID = nil
    try? store.saveNotes([])
    return (appState, baseURL)
}

final class QuickCaptureCoreTests: XCTestCase {
    func testHotkeyPolicyPrefersLayoutKey() {
        let selected = QuickCaptureHotkeyPolicy.choosePrimaryKeyCode(
            layoutKeyCode: 47,
            fallbackKeyCodes: [41]
        )

        XCTAssertEqual(selected, 47)
    }

    func testHotkeyPolicyFallsBackWhenLayoutMissing() {
        let selected = QuickCaptureHotkeyPolicy.choosePrimaryKeyCode(
            layoutKeyCode: nil,
            fallbackKeyCodes: [41]
        )

        XCTAssertEqual(selected, 41)
    }

    func testStateMachineFlow() {
        var machine = QuickCapturePanelStateMachine()

        XCTAssertEqual(machine.state, .hidden)
        XCTAssertTrue(machine.requestShow())
        XCTAssertEqual(machine.state, .showing)

        machine.markVisible()
        XCTAssertEqual(machine.state, .visible)

        XCTAssertTrue(machine.requestHide())
        XCTAssertEqual(machine.state, .hiding)

        machine.markHidden()
        XCTAssertEqual(machine.state, .hidden)
    }

    func testStateMachineRejectsDuplicateShowAndHide() {
        var machine = QuickCapturePanelStateMachine()

        XCTAssertTrue(machine.requestShow())
        XCTAssertFalse(machine.requestShow())

        machine.markVisible()
        XCTAssertTrue(machine.requestHide())
        XCTAssertFalse(machine.requestHide())
    }

    func testNormalizeSubmissionRejectsWhitespaceOnly() {
        XCTAssertNil(QuickCaptureInputCoordinator.normalizeSubmission("   \n  "))
    }

    func testNormalizeSubmissionTrimsAndReturnsText() {
        XCTAssertEqual(
            QuickCaptureInputCoordinator.normalizeSubmission("  Merhaba dunya  \n"),
            "Merhaba dunya"
        )
    }

    func testSubmissionRequestParsesLinkOnly() {
        let request = QuickCaptureSubmissionRequest(input: "   -link   ")

        XCTAssertTrue(request.wantsLink)
        XCTAssertFalse(request.wantsScreenshot)
        XCTAssertNil(request.normalizedText)
        XCTAssertTrue(request.shouldSubmit)
    }

    func testSubmissionRequestParsesTextAndLink() {
        let request = QuickCaptureSubmissionRequest(input: "  not metni -link ")

        XCTAssertTrue(request.wantsLink)
        XCTAssertFalse(request.wantsScreenshot)
        XCTAssertEqual(request.normalizedText, "not metni")
    }

    func testSubmissionRequestParsesTextScreenshotAndLink() {
        let request = QuickCaptureSubmissionRequest(input: " metin \"\" -link ")

        XCTAssertTrue(request.wantsLink)
        XCTAssertTrue(request.wantsScreenshot)
        XCTAssertEqual(request.normalizedText, "metin")
    }

    func testBrowserLinkResolverUsesDirectSafariURLWithoutFallback() {
        let resolver = StubBrowserLinkResolver(
            directResult: "https://example.com/safari",
            addressBarResult: "https://example.com/fallback"
        )
        let context = BrowserLinkContext(bundleID: "com.apple.Safari", processID: 1, icon: nil)

        XCTAssertEqual(resolver.resolve(context: context), "https://example.com/safari")
        XCTAssertEqual(resolver.directCallCount, 1)
        XCTAssertEqual(resolver.addressBarCallCount, 0)
    }

    func testBrowserLinkResolverFallsBackToAddressBarWhenDirectFails() {
        let resolver = StubBrowserLinkResolver(
            directResult: nil,
            addressBarResult: "https://example.com/fallback"
        )
        let context = BrowserLinkContext(bundleID: "com.brave.Browser", processID: 1, icon: nil)

        XCTAssertEqual(resolver.resolve(context: context), "https://example.com/fallback")
        XCTAssertEqual(resolver.directCallCount, 1)
        XCTAssertEqual(resolver.addressBarCallCount, 1)
    }

    func testBrowserLinkResolverReturnsNilWhenAllStrategiesFail() {
        let resolver = StubBrowserLinkResolver(
            directResult: "about:blank",
            addressBarResult: "notaurl"
        )
        let context = BrowserLinkContext(bundleID: "com.microsoft.edgemac", processID: 1, icon: nil)

        XCTAssertNil(resolver.resolve(context: context))
        XCTAssertEqual(resolver.directCallCount, 1)
        XCTAssertEqual(resolver.addressBarCallCount, 1)
    }

    func testWidthAdjustedFramePreservesCenterAndHeight() {
        let targetFrame = NSRect(x: 120, y: 340, width: 700, height: 62)
        let adjustedFrame = widthAdjustedFrame(targetFrame, width: 780)

        XCTAssertEqual(adjustedFrame.width, 780, accuracy: 0.001)
        XCTAssertEqual(adjustedFrame.height, targetFrame.height, accuracy: 0.001)
        XCTAssertEqual(adjustedFrame.midX, targetFrame.midX, accuracy: 0.001)
        XCTAssertEqual(adjustedFrame.origin.y, targetFrame.origin.y, accuracy: 0.001)
    }

    func testNoteBlockPlainTextAndPreviewIgnoreImages() {
        let blocks: [NoteBlock] = [
            .heading1("Baslik"),
            .image(assetID: UUID(), preferredWidth: 420),
            .paragraph("Detay satiri")
        ]

        XCTAssertEqual(blocks.plainText, "Baslik\nDetay satiri")
        XCTAssertEqual(blocks.previewText, "Baslik Detay satiri")
    }

    func testBlockEditingClampsImageWidth() {
        XCTAssertEqual(
            NoteBlockEditing.clampedImageWidth(preferredWidth: 1800, naturalWidth: 2200, maxWidth: 900),
            900
        )
        XCTAssertEqual(
            NoteBlockEditing.clampedImageWidth(preferredWidth: 120, naturalWidth: 300, maxWidth: 900),
            160
        )
    }

    func testBlockEditingReplacesSlashBlockWithImageAndAddsParagraph() {
        let assetID = UUID()
        let blockID = UUID()
        var blocks = [NoteBlock.paragraph("/", id: blockID)]

        let focusID = NoteBlockEditing.replaceWithImageBlock(
            id: blockID,
            assetID: assetID,
            preferredWidth: 480,
            in: &blocks
        )

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].kind, .image)
        XCTAssertEqual(blocks[0].imageAssetID, assetID)
        XCTAssertEqual(blocks[1].kind, .paragraph)
        XCTAssertEqual(focusID, blocks[1].id)
    }

    func testScreenCaptureAuthorizationServiceReturnsDeniedWhenRequestsAreDisabled() {
        let service = ScreenCaptureAuthorizationService(
            preflightAccess: { false },
            requestAccess: { XCTFail("requestAccess should not be called"); return false },
            requestsAccessIfNeeded: false
        )

        XCTAssertEqual(service.authorizeIfNeeded(), .denied)
    }

    func testScreenCaptureAuthorizationServiceReturnsGrantedWithoutRequestWhenPreflightSucceeds() {
        var requestCallCount = 0
        let service = ScreenCaptureAuthorizationService(
            preflightAccess: { true },
            requestAccess: {
                requestCallCount += 1
                return true
            }
        )

        XCTAssertEqual(service.authorizeIfNeeded(), .granted)
        XCTAssertEqual(requestCallCount, 0)
    }

    func testScreenCaptureAuthorizationServiceReturnsRequestDeniedWhenPromptFails() {
        let service = ScreenCaptureAuthorizationService(
            preflightAccess: { false },
            requestAccess: { false }
        )

        XCTAssertEqual(service.authorizeIfNeeded(), .requestDenied)
    }

    func testScreenshotPlannerPrefersActiveForegroundWindow() {
        let windows = [
            QuickCaptureWindowDescriptor(
                windowID: 11,
                frame: CGRect(x: 0, y: 0, width: 1600, height: 900),
                windowLayer: 0,
                processID: 42,
                isOnScreen: true,
                isActive: false
            ),
            QuickCaptureWindowDescriptor(
                windowID: 12,
                frame: CGRect(x: 0, y: 0, width: 600, height: 400),
                windowLayer: 0,
                processID: 42,
                isOnScreen: true,
                isActive: true
            )
        ]

        let selection = QuickCaptureScreenshotPlanner.selectTarget(
            foregroundProcessID: 42,
            windows: windows,
            displays: [QuickCaptureDisplayDescriptor(displayID: 77)],
            mainDisplayID: 77
        )

        XCTAssertEqual(selection, .window(12))
    }

    func testMediaStoreWritesOriginalAndPreviewPNG() throws {
        let baseURL = makeTemporaryBaseURL()
        defer { removeTemporaryBaseURL(baseURL) }

        let store = MediaStore(baseURL: baseURL)
        let pngData = makeSampleScreenshotPNGData(width: 600, height: 300)
        let asset = try store.storePNGImage(pngData)

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.originalURL(for: asset).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.previewURL(for: asset).path))

        let previewData = try Data(contentsOf: store.previewURL(for: asset))
        let previewImage = NSImage(data: previewData)
        XCTAssertNotNil(previewImage)
        XCTAssertLessThanOrEqual(previewImage?.size.width ?? 0, MediaStore.previewMaxPixelWidth + 0.5)
    }

    func testNoteStorePersistsAndReloadsBlockNotes() throws {
        let baseURL = makeTemporaryBaseURL()
        defer { removeTemporaryBaseURL(baseURL) }

        let store = NoteStore(baseURL: baseURL)
        let asset = try store.storeScreenshot(pngData: makeSampleScreenshotPNGData())
        let note = NoteItem(
            id: UUID(),
            title: "Kalici Not",
            blocks: [
                .heading1("Baslik"),
                .paragraph("Govde"),
                .image(assetID: asset.id, preferredWidth: 420)
            ],
            imageAssets: [asset],
            mediaAttachments: [store.mediaStore.makeMediaAttachment(for: asset)],
            createdAt: .now,
            updatedAt: .now
        )

        try store.saveNotes([note])
        let loadedNotes = try store.loadNotes()

        XCTAssertEqual(loadedNotes.count, 1)
        XCTAssertEqual(loadedNotes[0].title, "Kalici Not")
        XCTAssertEqual(loadedNotes[0].blocks.map(\.kind), [.heading1, .paragraph, .image, .paragraph])
        XCTAssertEqual(loadedNotes[0].mediaAttachments.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: loadedNotes[0].mediaAttachments[0].fileURL.path))
    }

    func testNoteStorePrunesOrphanedAssetsAfterSave() throws {
        let baseURL = makeTemporaryBaseURL()
        defer { removeTemporaryBaseURL(baseURL) }

        let store = NoteStore(baseURL: baseURL)
        let keptAsset = try store.storeScreenshot(pngData: makeSampleScreenshotPNGData())
        let removedAsset = try store.storeScreenshot(pngData: makeSampleScreenshotPNGData(width: 400, height: 220))
        let note = NoteItem(
            id: UUID(),
            title: "Tek Gorsel",
            blocks: [.image(assetID: keptAsset.id, preferredWidth: 300)],
            imageAssets: [keptAsset],
            mediaAttachments: [store.mediaStore.makeMediaAttachment(for: keptAsset)],
            createdAt: .now,
            updatedAt: .now
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaStore.originalURL(for: removedAsset).path))
        try store.saveNotes([note])

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.mediaStore.originalURL(for: keptAsset).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaStore.originalURL(for: removedAsset).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.mediaStore.previewURL(for: removedAsset).path))
    }

    func testDefaultApplicationSupportPathEndsWithNoteLight() {
        let path = MediaStore.defaultBaseURL().path

        XCTAssertTrue(path.contains("Application Support"))
        XCTAssertTrue(path.hasSuffix("/NoteLight"))
    }
}

@MainActor
final class QuickCaptureIntegrationTests: XCTestCase {
    private func waitForCondition(
        description: String,
        timeout: TimeInterval = 1.2,
        pollInterval: TimeInterval = 0.02,
        condition: @escaping () -> Bool
    ) {
        let expectation = expectation(description: description)
        let deadline = Date().addingTimeInterval(timeout)

        func poll() {
            if condition() {
                expectation.fulfill()
                return
            }

            if Date() >= deadline {
                XCTFail("Timed out waiting for condition: \(description)")
                expectation.fulfill()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: poll)
        }

        poll()
        wait(for: [expectation], timeout: timeout + 0.3)
    }

    func testControllerShowSetsVisibleAndSingleWindow() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let controller = QuickCaptureWindowController(appState: appState)

        controller.show(animated: false)
        XCTAssertEqual(controller.visibilityState, .visible)

        let firstWindow = controller.debugWindow
        controller.toggle(animated: false)
        XCTAssertEqual(controller.visibilityState, .hidden)

        controller.toggle(animated: false)
        XCTAssertEqual(controller.visibilityState, .visible)
        XCTAssertTrue(firstWindow === controller.debugWindow)

        controller.hide(reason: .toggle, animated: false)
        XCTAssertEqual(controller.visibilityState, .hidden)
    }

    func testControllerFocusesInputAfterShow() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let controller = QuickCaptureWindowController(appState: appState)

        controller.show(animated: false)

        let expectation = expectation(description: "input focus acquired")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if controller.debugWindow.firstResponder === controller.debugInputField ||
                controller.debugWindow.firstResponder === controller.debugInputField.currentEditor() {
                expectation.fulfill()
                return
            }

            XCTFail("Input field did not become first responder")
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1.0)
        controller.hide(reason: .toggle, animated: false)
    }

    func testEscapePathHidesPanel() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let controller = QuickCaptureWindowController(appState: appState)

        controller.show(animated: false)
        XCTAssertEqual(controller.visibilityState, .visible)

        controller.debugHandleEscape()
        XCTAssertEqual(controller.visibilityState, .hidden)
    }

    func testSubmitPathAddsPersistentParagraphNoteAndHidesPanel() throws {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let controller = QuickCaptureWindowController(appState: appState)

        controller.show(animated: false)
        controller.debugSubmitForTests("  Test notu  ")

        XCTAssertEqual(appState.notes.count, 1)
        XCTAssertEqual(appState.notes.first?.content, "Test notu")
        XCTAssertEqual(appState.notes.first?.blocks.map(\.kind), [.paragraph])
        XCTAssertEqual(controller.visibilityState, .hidden)

        let reloaded = try NoteStore(baseURL: baseURL).loadNotes()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.content, "Test notu")
    }

    func testLinkSubmitAddsNoteAndHidesPanelWhenResolverSucceeds() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let resolver = StubBrowserLinkResolver(directResult: "https://example.com")
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            linkResolver: resolver,
            toastPresenter: toastSpy
        )

        controller.show(animated: false)
        controller.debugSetBrowserContextForTests(
            BrowserLinkContext(bundleID: "com.google.Chrome", processID: 1, icon: nil)
        )
        controller.debugSubmitForTests("Linkli not -link")

        XCTAssertEqual(appState.notes.count, 1)
        XCTAssertEqual(appState.notes.first?.content, "Linkli not\nlink: https://example.com")
        XCTAssertEqual(controller.visibilityState, .hidden)
        XCTAssertTrue(toastSpy.messages.isEmpty)
    }

    func testLinkSubmitKeepsPanelVisibleWhenResolverFails() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let resolver = StubBrowserLinkResolver()
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            linkResolver: resolver,
            toastPresenter: toastSpy
        )

        controller.show(animated: false)
        controller.debugSetBrowserContextForTests(
            BrowserLinkContext(bundleID: "com.google.Chrome", processID: 1, icon: nil)
        )
        controller.debugSubmitForTests("Link denemesi -link")

        XCTAssertEqual(appState.notes.count, 0)
        XCTAssertEqual(controller.visibilityState, .visible)
        XCTAssertEqual(controller.debugInputText, "Link denemesi -link")
        XCTAssertEqual(toastSpy.messages, ["Aktif sekme linki alinamadi"])
    }

    func testScreenshotSubmitAddsPersistentImageNoteWhenCaptureSucceeds() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let screenshotService = StubScreenshotService(
            result: .success(QuickCaptureScreenshotCapture(pngData: makeSampleScreenshotPNGData()))
        )
        let authorizer = StubScreenCaptureAuthorizer(status: .granted)
        let permissionSpy = PermissionGuidanceSpy()
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            screenshotService: screenshotService,
            screenCaptureAuthorizationService: authorizer,
            permissionGuidancePresenter: permissionSpy,
            toastPresenter: toastSpy,
            screenshotCaptureDelay: 0
        )

        controller.show(animated: false)
        controller.debugSetForegroundProcessIDForTests(42)
        controller.debugSubmitForTests("Toplanti notu \"\"")

        waitForCondition(description: "screenshot note saved") {
            appState.notes.count == 1
        }

        let note = appState.notes[0]
        XCTAssertEqual(authorizer.callCount, 1)
        XCTAssertEqual(permissionSpy.callCount, 0)
        XCTAssertEqual(screenshotService.capturedContexts, [QuickCaptureCaptureContext(foregroundProcessID: 42)])
        XCTAssertEqual(controller.visibilityState, .hidden)
        XCTAssertEqual(controller.debugInputText, "")
        XCTAssertEqual(note.title, "Toplanti notu")
        XCTAssertEqual(note.mediaAttachments.count, 1)
        XCTAssertEqual(note.blocks.map(\.kind), [.paragraph, .image, .paragraph])
        XCTAssertEqual(note.mediaAttachments[0].fileURL.pathExtension, "png")
        XCTAssertTrue(note.mediaAttachments[0].fileURL.path.contains("/media/originals/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.mediaAttachments[0].fileURL.path))
        XCTAssertTrue(toastSpy.messages.isEmpty)
    }

    func testScreenshotSubmitKeepsPanelVisibleWhenPermissionIsDenied() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let screenshotService = StubScreenshotService(
            result: .success(QuickCaptureScreenshotCapture(pngData: makeSampleScreenshotPNGData()))
        )
        let authorizer = StubScreenCaptureAuthorizer(status: .requestDenied)
        let permissionSpy = PermissionGuidanceSpy()
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            screenshotService: screenshotService,
            screenCaptureAuthorizationService: authorizer,
            permissionGuidancePresenter: permissionSpy,
            toastPresenter: toastSpy,
            screenshotCaptureDelay: 0
        )

        controller.show(animated: false)
        controller.debugSubmitForTests("Yetki testi \"\"")

        XCTAssertEqual(appState.notes.count, 0)
        XCTAssertEqual(controller.visibilityState, .visible)
        XCTAssertEqual(controller.debugInputText, "Yetki testi \"\"")
        XCTAssertEqual(authorizer.callCount, 1)
        XCTAssertEqual(permissionSpy.callCount, 1)
        XCTAssertTrue(screenshotService.capturedContexts.isEmpty)
        XCTAssertTrue(toastSpy.messages.isEmpty)
    }

    func testScreenshotSubmitRestoresPanelWhenCaptureFails() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let screenshotService = StubScreenshotService(result: .failure(StubScreenshotError()))
        let authorizer = StubScreenCaptureAuthorizer(status: .granted)
        let permissionSpy = PermissionGuidanceSpy()
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            screenshotService: screenshotService,
            screenCaptureAuthorizationService: authorizer,
            permissionGuidancePresenter: permissionSpy,
            toastPresenter: toastSpy,
            screenshotCaptureDelay: 0
        )

        controller.show(animated: false)
        controller.debugSubmitForTests("Geri yukle \"\"")

        waitForCondition(description: "panel restored after screenshot error") {
            controller.visibilityState == .visible &&
            controller.debugInputText == "Geri yukle \"\"" &&
            toastSpy.messages == ["Ekran goruntusu alinamadi"]
        }

        XCTAssertEqual(appState.notes.count, 0)
        XCTAssertEqual(permissionSpy.callCount, 0)
    }

    func testLinkAndScreenshotSubmitAddsRichNoteWhenBothSucceed() {
        _ = NSApplication.shared
        let (appState, baseURL) = makeEmptyAppState()
        defer { removeTemporaryBaseURL(baseURL) }

        let resolver = StubBrowserLinkResolver(directResult: "https://example.com/path")
        let screenshotService = StubScreenshotService(
            result: .success(QuickCaptureScreenshotCapture(pngData: makeSampleScreenshotPNGData()))
        )
        let authorizer = StubScreenCaptureAuthorizer(status: .granted)
        let permissionSpy = PermissionGuidanceSpy()
        let toastSpy = ToastSpy()
        let controller = QuickCaptureWindowController(
            appState: appState,
            linkResolver: resolver,
            screenshotService: screenshotService,
            screenCaptureAuthorizationService: authorizer,
            permissionGuidancePresenter: permissionSpy,
            toastPresenter: toastSpy,
            screenshotCaptureDelay: 0
        )

        controller.show(animated: false)
        controller.debugSetBrowserContextForTests(
            BrowserLinkContext(bundleID: "com.google.Chrome", processID: 1, icon: nil)
        )
        controller.debugSubmitForTests("Kaynak notu \"\" -link")

        waitForCondition(description: "rich screenshot note saved") {
            appState.notes.count == 1
        }

        let note = appState.notes[0]
        XCTAssertEqual(permissionSpy.callCount, 0)
        XCTAssertEqual(controller.visibilityState, .hidden)
        XCTAssertEqual(note.mediaAttachments.count, 1)
        XCTAssertEqual(note.content, "Kaynak notu\nlink: https://example.com/path")
        XCTAssertEqual(note.blocks.map(\.kind), [.paragraph, .paragraph, .image, .paragraph])
        XCTAssertTrue(toastSpy.messages.isEmpty)
    }
}
