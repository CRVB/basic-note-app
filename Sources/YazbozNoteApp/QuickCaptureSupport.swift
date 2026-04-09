import AppKit
import QuartzCore

/// Kullanıcının hızlı yakalama paneline girdiği metni ayrıştıran yapı
/// Ekran görüntüsü, link ve metin içerip içermediğini belirler
struct QuickCaptureSubmissionRequest: Equatable {
    private static let linkFlags = ["--link", "-link"]

    let wantsScreenshot: Bool  // "" (boş tırnak) içerirse ekran görüntüsü ister
    let wantsLink: Bool        // "-link" bayrağı içerirse tarayıcı linkini ister
    let normalizedText: String? // Temizlenmiş metin içeriği

    /// Giriş metnini ayrıştırır ve özel bayrakları tespit eder
    init(input: String) {
        // Kullanıcı "" yazarsa ekran görüntüsü almak istiyordur
        wantsScreenshot = input.contains("\"\"")
        // Kullanıcı "-link" yazarsa tarayıcıdaki linki almak istiyordur
        wantsLink = Self.linkFlags.contains { input.contains($0) }

        // Bayrağı temizle ve normalleştir
        var cleaned = input.replacingOccurrences(of: "\"\"", with: "")
        for flag in Self.linkFlags {
            cleaned = cleaned.replacingOccurrences(of: flag, with: "")
        }
        normalizedText = QuickCaptureInputCoordinator.normalizeSubmission(cleaned)
    }

    /// En az bir şey (screenshot, link veya metin) eklenecekse gönder
    var shouldSubmit: Bool {
        wantsScreenshot || wantsLink || normalizedText != nil
    }
}

/// Aktif tarayıcı uygulamasının bilgilerini tutar
/// Linkini almak için gereken kontekst verilerini içerir
struct BrowserLinkContext {
    let bundleID: String    // Tarayıcı tanıyıcısı (com.apple.Safari, com.google.Chrome, vb.)
    let processID: pid_t    // İşletim sistemi seviyesi işlem kimliği
    let icon: NSImage?      // Tarayıcı uygulaması ikonu
}

enum BrowserLinkResolutionFailure: Equatable {
    case noBrowserContext
    case unsupportedBrowser
    case automationDenied
    case noActiveTab
    case invalidURL
    case scriptError(code: Int?)
}

enum BrowserLinkResolutionResult: Equatable {
    case success(String)
    case failure(BrowserLinkResolutionFailure)
}

/// Açık tarayıcı penceresinden mevcut URL'i alan ana sınıf
/// Linki sadece tarayıcıya doğrudan Apple Events / AppleScript sorusu ile almaya çalışır
class BrowserLinkResolver {
    struct AppleScriptExecutionError: Error, Equatable {
        let code: Int?
        let message: String?
    }

    func resolve(context: BrowserLinkContext?) -> String? {
        switch resolveResult(context: context) {
        case .success(let value):
            return value
        case .failure:
            return nil
        }
    }

    func resolveResult(context: BrowserLinkContext?) -> BrowserLinkResolutionResult {
        guard let context else {
            return .failure(.noBrowserContext)
        }
        return resolveDirectResult(from: context)
    }

    func resolveDirectURL(from context: BrowserLinkContext) -> String? {
        switch resolveDirectResult(from: context) {
        case .success(let value):
            return value
        case .failure:
            return nil
        }
    }

    func resolveDirectResult(from context: BrowserLinkContext) -> BrowserLinkResolutionResult {
        guard let script = Self.directBrowserURLScript(for: context.bundleID) else {
            return .failure(.unsupportedBrowser)
        }

        switch executeAppleScript(script) {
        case .success(let value):
            let normalizedValue = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !normalizedValue.isEmpty else {
                return .failure(.noActiveTab)
            }
            guard isValidURL(normalizedValue) else {
                return .failure(.invalidURL)
            }
            return .success(normalizedValue)
        case .failure(let error):
            if error.code == -1743 {
                return .failure(.automationDenied)
            }
            return .failure(.scriptError(code: error.code))
        }
    }

    /// URL'nin geçerli olup olmadığını kontrol eder
    /// HTTP ve HTTPS şemaları kabul edilir, "about:blank" reddedilir
    func isValidURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else {
            return false
        }

        // "about:blank" gibi özel URL'ler kabul etme (geçerli değil)
        if value.lowercased() == "about:blank" {
            return false
        }

        // Sadece HTTP ve HTTPS protokolü kabul et
        return scheme == "http" || scheme == "https"
    }

    /// Verilen tarayıcı kimliğinin desteklenip desteklenmediğini kontrol et
    static func isSupportedBrowser(bundleID: String) -> Bool {
        directBrowserURLScript(for: bundleID) != nil
    }

    /// Tarayıcı türüne göre uygun AppleScript döndür
    /// Desteklenen tarayıcılar: Safari, Chrome, Arc, Brave, Edge
    static func directBrowserURLScript(for bundleID: String) -> String? {
        switch bundleID {
        case "com.apple.Safari":
            return """
            tell application "Safari"
                if (count of windows) is 0 then return ""
                return (URL of current tab of front window as text)
            end tell
            """
        case "com.google.Chrome":
            return chromiumURLScript(for: "Google Chrome")
        case "company.thebrowser.Browser":
            return chromiumURLScript(for: "Arc")
        case "com.brave.Browser":
            return chromiumURLScript(for: "Brave Browser")
        case "com.microsoft.edgemac":
            return chromiumURLScript(for: "Microsoft Edge")
        default:
            // Desteklenmeyen tarayıcı
            return nil
        }
    }

    /// Chromium tabanlı tarayıcılar (Chrome, Arc, Brave, Edge) için AppleScript şablonu
    private static func chromiumURLScript(for applicationName: String) -> String {
        """
        tell application "\(applicationName)"
            if (count of windows) is 0 then return ""
            return (URL of active tab of front window as text)
        end tell
        """
    }

    private func executeAppleScript(_ script: String) -> Result<String, AppleScriptExecutionError> {
        guard let appleScript = NSAppleScript(source: script) else {
            return .failure(AppleScriptExecutionError(code: nil, message: nil))
        }

        var errorInfo: NSDictionary?
        let output = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = errorInfo[NSAppleScript.errorNumber] as? Int
            let message = errorInfo[NSAppleScript.errorMessage] as? String
            return .failure(AppleScriptExecutionError(code: code, message: message))
        }

        return .success(output.stringValue ?? "")
    }
}

/// Kullanıcıya bildirim mesajı göstermek için protokol
/// "Not eklendi", "Link kopyalandı" gibi toast (kısa çıkıcı) mesajlar gösterir
@MainActor
protocol QuickCaptureToasting: AnyObject {
    func show(message: String, anchoredTo window: NSWindow)
}

/// Toast (kısa bildirim) mesajlarını ekranda göstermek için controller sınıfı
/// Başlık penceresinin üstünde görünen kısa çıkıcı mesajları yönetir
@MainActor
final class QuickCaptureToastController: QuickCaptureToasting {
    private let panel: QuickCaptureToastWindow
    private let contentView = QuickCaptureToastView(frame: .zero)
    private var hideWorkItem: DispatchWorkItem?

    init() {
        // Borderless, şeffaf ve floating panel oluştur
        panel = QuickCaptureToastWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        // Panel özelliklerini ayarla
        panel.isFloatingPanel = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .mainMenu  // Her zaman üstte göster
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true  // Kullanıcı etkileşimine izin verme
        panel.contentView = contentView
    }

    /// Mesajı pencerenin üstünde göster
    func show(message: String, anchoredTo window: NSWindow) {
        // Önceki gizleme animasyonını iptal et
        hideWorkItem?.cancel()
        contentView.message = message

        // Mesaj için uygun boyutu hesapla
        let targetSize = preferredSize(for: message)
        let anchorFrame = window.frame
        
        // Pencerenin üstünde, ortasında konum hesapla
        let targetFrame = NSRect(
            x: anchorFrame.midX - (targetSize.width / 2),
            y: anchorFrame.minY - targetSize.height - 10,
            width: targetSize.width,
            height: targetSize.height
        )

        // Panel konumunu ayarla ve görünür yap
        panel.setFrame(targetFrame, display: false)
        panel.alphaValue = 0  // Başta şeffaf
        panel.orderFrontRegardless()

        // Fade-in animasyonuyla göster
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.20, 0.90, 0.30, 1.00)
            panel.animator().alphaValue = 1  // Görünür hale getir
        }

        // 2 saniye sonra otomatik gizle
        let workItem = DispatchWorkItem { [weak self] in
            self?.hideAnimated()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.94, execute: workItem)
    }

    private func hideAnimated() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.60, 0.20)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.panel.orderOut(nil)
            }
        }
    }

    private func preferredSize(for message: String) -> NSSize {
        let maxWidth: CGFloat = 320
        let textInsets = NSSize(width: 32, height: 16)
        let textFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let textBounds = NSAttributedString(
            string: message,
            attributes: [.font: textFont]
        ).boundingRect(
            with: NSSize(width: maxWidth - textInsets.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let width = min(maxWidth, max(180, ceil(textBounds.width) + textInsets.width))
        let height = max(38, ceil(textBounds.height) + textInsets.height)
        return NSSize(width: width, height: height)
    }
}

@MainActor
private final class QuickCaptureToastWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class QuickCaptureToastView: NSView {
    private let label = NSTextField(labelWithString: "")

    var message: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.borderWidth = 1

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.92)
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

func widthAdjustedFrame(_ frame: NSRect, width: CGFloat) -> NSRect {
    NSRect(
        x: frame.midX - (width / 2),
        y: frame.origin.y,
        width: width,
        height: frame.height
    )
}
