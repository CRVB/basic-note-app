# Yazboz Note

Yazboz Note, macOS için geliştirilmiş hızlı ve sade bir not alma uygulamasıdır. SwiftUI + AppKit üzerine inşa edilmiştir.

---

## Özellikler

- **Hızlı not paneli** — global kısayol ile (Spotlight benzeri) ekrana gelir
- **Status bar entegrasyonu** — arka planda sessizce çalışır
- **Not listesi ve detay görünümü** — tüm notlarınıza tek bir pencereden erişin
- **Klavye odaklı kullanım** — fare gerekmez

---

## Gereksinimler

| Araç | Versiyon |
|------|----------|
| macOS | 14 (Sonoma) veya üzeri |
| Xcode / Swift | Swift 5.10+ |

---

## Kurulum & Çalıştırma

**Projeyi derleyin:**

```bash
make build
```

**Uygulamayı başlatın:**

```bash
make run
```

**Derleme çıktısını temizleyin:**

```bash
make clean
```

---

## Klavye Kısayolları

| Kısayol | Eylem |
|---------|-------|
| `Cmd + Shift + K` | Hızlı not panelini aç / kapat |
| `Enter` | Notu kaydet |
| `Esc` | Paneli kapat |
| `Cmd + Q` | Uygulamayı kapat |

---

## Proje Yapısı

```
Sources/YazbozNoteApp/
├── YazbozNoteApp.swift       # Uygulama giriş noktası
├── AppState.swift            # Uygulama durumu yönetimi
├── ContentView.swift         # Ana pencere
├── QuickCapturePanel.swift   # Hızlı not paneli (NSPanel)
└── QuickCaptureView.swift    # Hızlı not arayüzü (SwiftUI)
```

---

## Yol Haritası

Uygulamanın planlanan geliştirme aşamaları için [roadmap.md](roadmap.md) dosyasına bakın.
