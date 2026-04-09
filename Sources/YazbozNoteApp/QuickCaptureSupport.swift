import AppKit
import QuartzCore

/// Kullanıcının hızlı yakalama paneline girdiği metni ayrıştıran yapı
/// Ekran görüntüsü, link ve metin içerip içermediğini belirler
struct QuickCaptureSubmissionRequest: Equatable {
    let wantsScreenshot: Bool  // "" (boş tırnak) içerirse ekran görüntüsü ister
    let wantsLink: Bool        // "-link" bayrağı içerirse tarayıcı linkini ister
    let normalizedText: String? // Temizlenmiş metin içeriği

    /// Giriş metnini ayrıştırır ve özel bayrakları tespit eder
    init(input: String) {
        // Kullanıcı "" yazarsa ekran görüntüsü almak istiyordur
        wantsScreenshot = input.contains("\"\"")
        // Kullanıcı "-link" yazarsa tarayıcıdaki linki almak istiyordur
        wantsLink = input.contains("-link")

        // Bayrağı temizle ve normalleştir
        let cleaned = input
            .replacingOccurrences(of: "\"\"", with: "")
            .replacingOccurrences(of: "-link", with: "")
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

/// Açık tarayıcı penceresinden mevcut URL'i alan ana sınıf
/// İki farklı yöntemle linki almaya çalışır: doğrudan AppleScript veya adres çubuğundan
class BrowserLinkResolver {
    /// Clipboard'ın anlık görüntüsünü tutar (eski haline dönüş için)
    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    /// Ana metod: Tarayıcıdan URL'i almaya çalışır
    /// Parametreler: BrowserLinkContext - Aktif tarayıcı bilgileri
    /// Dönüş: Başarılı olursa URL string'i, başarısız olursa nil
    func resolve(context: BrowserLinkContext?) -> String? {
        guard let context else { return nil }

        // 1. Adım: Direkt olarak tarayıcıdan URL'i almayı dene (hızlı ve güvenilir)
        if let direct = resolveDirectURL(from: context), isValidURL(direct) {
            return direct
        }

        // 2. Adım: Başarısız olursa, adres çubuğundan kopyalayarak almayı dene
        if let addressBar = captureURLViaAddressBar(from: context), isValidURL(addressBar) {
            return addressBar
        }

        // 3. Adım: Her iki yöntem de başarısız olursa nil döndür
        return nil
    }

    /// Yöntem 1: AppleScript kullanarak tarayıcıdan doğrudan URL çekme
    /// Bu yöntem daha güvenli ve clipboard'ı etkilemez
    func resolveDirectURL(from context: BrowserLinkContext) -> String? {
        // Tarayıcıya göre uygun AppleScript'i al
        guard let script = Self.directBrowserURLScript(for: context.bundleID),
              let value = executeAppleScript(script),  // AppleScript çalıştır
              isValidURL(value) else {                 // Geçerli bir URL mı kontrol et
            return nil
        }

        return value
    }

    /// Yöntem 2: Tarayıcıyı aktif yap, Cmd+L (adres çubuğu seç) ve Cmd+C (kopyala) yap
    /// Ardından clipboard'dan URL'i oku
    func captureURLViaAddressBar(from context: BrowserLinkContext) -> String? {
        let pasteboard = NSPasteboard.general
        // Eski clipboard içeriğini kaydet (restore etmek için)
        let snapshot = snapshotPasteboard()
        let originalString = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let currentApp = NSRunningApplication.current

        // Metod atıldığında, clipboard'ı geri yükle ve orijinal app'e dön
        defer {
            restorePasteboard(snapshot)
            _ = currentApp.activate(options: [.activateAllWindows])
        }

        // Hedef tarayıcıyı aktive et
        guard let app = NSRunningApplication(processIdentifier: context.processID) else { return nil }
        _ = app.activate(options: [.activateAllWindows])
        Thread.sleep(forTimeInterval: 0.14)  // Tarayıcının aktive olması için bekle

        let changeCount = pasteboard.changeCount
        // AppleScript: Cmd+L ile adres çubuğunu seç, ardından Cmd+C ile kopyala
        let script = """
        tell application "System Events"
            keystroke "l" using command down
            delay 0.08
            keystroke "c" using command down
        end tell
        """
        _ = executeAppleScript(script)

        // 700ms içinde clipboard'dan URL'i oku
        let timeout = CFAbsoluteTimeGetCurrent() + 0.7
        var didChangeClipboard = false
        while CFAbsoluteTimeGetCurrent() < timeout {
            // Clipboard'ın değişip değişmediğini kontrol et
            if pasteboard.changeCount != changeCount {
                didChangeClipboard = true
            }

            if let candidate = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               isValidURL(candidate),  // Geçerli bir URL mı?
               didChangeClipboard || candidate != originalString {  // Yeni içerik mi?
                return candidate
            }

            Thread.sleep(forTimeInterval: 0.04)  // 40ms bekle ve tekrar kontrol et
        }

        // Timeout sonrası final kontrol (redundant kontrol)
        if let candidate = pasteboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           isValidURL(candidate),
           didChangeClipboard || candidate != originalString {
            return candidate
        }

        return nil
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

    /// Clipboard'ın mevcut içeriğinin tam bir kopyasını oluştur
    /// Daha sonra restore etmek için kullanılır
    private func snapshotPasteboard() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        // Tüm clipboard öğelerini ve formatlarını kaydet
        let serialized: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var mapped: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    mapped[type] = data
                }
            }
            return mapped
        } ?? []

        return PasteboardSnapshot(items: serialized)
    }

    /// Clipboard'ı önceki haline geri yükle
    /// Kullanıcının orijinal clipboard içeriği korunur
    private func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        // Kaydedilen tüm öğeleri geri yükle
        for itemMap in snapshot.items {
            let item = NSPasteboardItem()
            for (type, data) in itemMap {
                item.setData(data, forType: type)
            }
            pasteboard.writeObjects([item])
        }
    }

    /// AppleScript'i çalıştır ve sonucu string olarak döndür
    private func executeAppleScript(_ script: String) -> String? {
        guard let appleScript = NSAppleScript(source: script) else { return nil }

        var errorInfo: NSDictionary?
        let output = appleScript.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }  // Hata varsa nil döndür

        let value = output.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
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
