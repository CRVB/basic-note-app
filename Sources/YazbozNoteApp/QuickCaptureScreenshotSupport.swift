import AppKit
import CoreGraphics
import ScreenCaptureKit

struct QuickCaptureCaptureContext: Equatable {
    let foregroundProcessID: pid_t?
}

struct QuickCaptureScreenshotCapture {
    let pngData: Data
}

enum QuickCaptureScreenshotError: Error, Equatable {
    case permissionDenied
    case noCaptureTarget
    case missingDisplay
    case missingImage
    case failedToEncodeImage
    case captureFailed(code: Int)
}

enum ScreenCaptureAuthorizationStatus: Equatable {
    case granted
    case denied
    case requestDenied
}

protocol QuickCaptureScreenshotCapturing: Sendable {
    func capture(context: QuickCaptureCaptureContext) async throws -> QuickCaptureScreenshotCapture
}

protocol ScreenCaptureAuthorizing {
    func authorizeIfNeeded() -> ScreenCaptureAuthorizationStatus
}

@MainActor
protocol ScreenCapturePermissionGuiding: AnyObject {
    func presentPermissionRequiredAlert(anchoredTo window: NSWindow)
}

@MainActor
protocol SystemSettingsOpening {
    func openSystemSettings()
}

final class ScreenCaptureAuthorizationService: ScreenCaptureAuthorizing {
    private let preflightAccess: () -> Bool
    private let requestAccess: () -> Bool
    private let requestsAccessIfNeeded: Bool

    init(
        preflightAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        requestAccess: @escaping () -> Bool = { CGRequestScreenCaptureAccess() },
        requestsAccessIfNeeded: Bool = true
    ) {
        self.preflightAccess = preflightAccess
        self.requestAccess = requestAccess
        self.requestsAccessIfNeeded = requestsAccessIfNeeded
    }

    func authorizeIfNeeded() -> ScreenCaptureAuthorizationStatus {
        if preflightAccess() {
            return .granted
        }

        guard requestsAccessIfNeeded else {
            return .denied
        }

        return requestAccess() ? .granted : .requestDenied
    }
}

@MainActor
final class SystemSettingsOpener: SystemSettingsOpening {
    func openSystemSettings() {
        let settingsURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
        _ = NSWorkspace.shared.open(settingsURL)
    }
}

@MainActor
final class ScreenCapturePermissionAlertPresenter: ScreenCapturePermissionGuiding {
    private let systemSettingsOpener: SystemSettingsOpening

    init(systemSettingsOpener: SystemSettingsOpening = SystemSettingsOpener()) {
        self.systemSettingsOpener = systemSettingsOpener
    }

    func presentPermissionRequiredAlert(anchoredTo window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Screen Recording izni gerekli"
        alert.informativeText = """
        Ekran goruntusu eklemek icin Screen Recording izni gerekli. Izin verdikten sonra uygulamayi yeniden acman gerekebilir.
        """
        alert.addButton(withTitle: "System Settings")
        alert.addButton(withTitle: "Iptal")

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if alert.runModal() == .alertFirstButtonReturn {
            systemSettingsOpener.openSystemSettings()
        }
    }
}

struct QuickCaptureWindowDescriptor: Equatable {
    let windowID: CGWindowID
    let frame: CGRect
    let windowLayer: Int
    let processID: pid_t?
    let isOnScreen: Bool
    let isActive: Bool

    var area: CGFloat {
        max(0, frame.width) * max(0, frame.height)
    }
}

struct QuickCaptureDisplayDescriptor: Equatable {
    let displayID: CGDirectDisplayID
}

enum QuickCaptureScreenshotTarget: Equatable {
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

enum QuickCaptureScreenshotTargetIntent {
    case window
    case display
}

enum QuickCaptureScreenshotPlanner {
    static func orderedWindows(
        for foregroundProcessID: pid_t?,
        windows: [QuickCaptureWindowDescriptor]
    ) -> [QuickCaptureWindowDescriptor] {
        guard let foregroundProcessID else { return [] }

        return windows
            .filter {
                $0.processID == foregroundProcessID &&
                $0.windowLayer == 0 &&
                $0.isOnScreen
            }
            .sorted { lhs, rhs in
                if lhs.isActive != rhs.isActive {
                    return lhs.isActive && !rhs.isActive
                }

                if lhs.area != rhs.area {
                    return lhs.area > rhs.area
                }

                return lhs.windowID < rhs.windowID
            }
    }

    static func selectTarget(
        foregroundProcessID: pid_t?,
        windows: [QuickCaptureWindowDescriptor],
        displays: [QuickCaptureDisplayDescriptor],
        mainDisplayID: CGDirectDisplayID
    ) -> QuickCaptureScreenshotTarget? {
        if let window = orderedWindows(for: foregroundProcessID, windows: windows).first {
            return .window(window.windowID)
        }

        if displays.contains(where: { $0.displayID == mainDisplayID }) {
            return .display(mainDisplayID)
        }

        return displays.first.map { .display($0.displayID) }
    }

    static func makeConfiguration(
        contentRect: CGRect,
        pointPixelScale: CGFloat,
        intent: QuickCaptureScreenshotTargetIntent
    ) -> SCScreenshotConfiguration {
        let configuration = SCScreenshotConfiguration()
        configuration.width = max(1, Int((contentRect.width * pointPixelScale).rounded(.up)))
        configuration.height = max(1, Int((contentRect.height * pointPixelScale).rounded(.up)))
        configuration.showsCursor = false
        configuration.includeChildWindows = true
        configuration.dynamicRange = .sdr
        configuration.displayIntent = .local

        switch intent {
        case .window:
            configuration.ignoreShadows = true
            configuration.ignoreClipping = true
        case .display:
            configuration.ignoreShadows = false
            configuration.ignoreClipping = false
        }

        return configuration
    }
}

final class QuickCaptureScreenshotService: QuickCaptureScreenshotCapturing, Sendable {
    private let shareableContentProvider: @Sendable () async throws -> SCShareableContent
    private let mainDisplayIDProvider: @Sendable () -> CGDirectDisplayID

    init(
        shareableContentProvider: @escaping @Sendable () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        },
        mainDisplayIDProvider: @escaping @Sendable () -> CGDirectDisplayID = { CGMainDisplayID() }
    ) {
        self.shareableContentProvider = shareableContentProvider
        self.mainDisplayIDProvider = mainDisplayIDProvider
    }

    func capture(context: QuickCaptureCaptureContext) async throws -> QuickCaptureScreenshotCapture {
        let shareableContent = try await shareableContentProvider()
        let selection = QuickCaptureScreenshotPlanner.selectTarget(
            foregroundProcessID: context.foregroundProcessID,
            windows: shareableContent.windows.map(Self.windowDescriptor(from:)),
            displays: shareableContent.displays.map(Self.displayDescriptor(from:)),
            mainDisplayID: mainDisplayIDProvider()
        )

        guard let selection else {
            throw QuickCaptureScreenshotError.noCaptureTarget
        }

        let filterAndIntent = try contentFilter(for: selection, shareableContent: shareableContent)
        let info = SCShareableContent.info(for: filterAndIntent.filter)
        let configuration = QuickCaptureScreenshotPlanner.makeConfiguration(
            contentRect: info.contentRect,
            pointPixelScale: CGFloat(info.pointPixelScale),
            intent: filterAndIntent.intent
        )

        do {
            let output = try await SCScreenshotManager.captureScreenshot(
                contentFilter: filterAndIntent.filter,
                configuration: configuration
            )

            guard let cgImage = output.sdrImage else {
                throw QuickCaptureScreenshotError.missingImage
            }

            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
                throw QuickCaptureScreenshotError.failedToEncodeImage
            }

            return QuickCaptureScreenshotCapture(pngData: pngData)
        } catch let error as QuickCaptureScreenshotError {
            throw error
        } catch {
            throw mapCaptureError(error)
        }
    }

    private func contentFilter(
        for selection: QuickCaptureScreenshotTarget,
        shareableContent: SCShareableContent
    ) throws -> (filter: SCContentFilter, intent: QuickCaptureScreenshotTargetIntent) {
        switch selection {
        case .window(let windowID):
            guard let window = shareableContent.windows.first(where: { $0.windowID == windowID }) else {
                throw QuickCaptureScreenshotError.noCaptureTarget
            }
            return (SCContentFilter(desktopIndependentWindow: window), .window)
        case .display(let displayID):
            guard let display = shareableContent.displays.first(where: { $0.displayID == displayID }) else {
                throw QuickCaptureScreenshotError.missingDisplay
            }
            return (SCContentFilter(display: display, excludingWindows: []), .display)
        }
    }

    private func mapCaptureError(_ error: Error) -> QuickCaptureScreenshotError {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 {
            return .permissionDenied
        }
        return .captureFailed(code: nsError.code)
    }

    private static func windowDescriptor(from window: SCWindow) -> QuickCaptureWindowDescriptor {
        QuickCaptureWindowDescriptor(
            windowID: window.windowID,
            frame: window.frame,
            windowLayer: window.windowLayer,
            processID: window.owningApplication?.processID,
            isOnScreen: window.isOnScreen,
            isActive: window.isActive
        )
    }

    private static func displayDescriptor(from display: SCDisplay) -> QuickCaptureDisplayDescriptor {
        QuickCaptureDisplayDescriptor(displayID: display.displayID)
    }
}
