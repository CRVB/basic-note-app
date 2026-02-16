# Yazboz Note Roadmap

Bu dosya, uygulamanin bugunku durumunu ve hedeflenen gelisim planini asama asama tanimlar.

## 0) Mevcut Durum (Bugun)

- Platform: macOS SwiftUI + AppKit
- Global kisayol: `Cmd+Shift+K`
- Spotlight benzeri hizli not paneli: var
- Status bar ikonu ve menu: var
- Temel not listesi ve detay gorunumu: var
- Hedeflenen davranis:
- Ana pencere kapaninca uygulama arka planda calisabilir
- Hizli panelden not girilip kaydedilebilir

## 1) Temel Not Yonetimi (Kisa Vade)

Hedef: Ana pencerede not olusturma, duzenleme, silme akislarini tamamlamak.

- Yeni not olusturma (`+ Yeni Not`)
- Not basligi ve icerik duzenleme
- Not silme (onayli)
- Klavye odakli kisayollar (yeni not, sil, kaydet)
- Temel veri kaliciligi (ilk adim: local JSON/SQLite secimi)
- Basit geri alma/yeniden yapma stratejisi

## 2) Bilgi Zenginlestirme (Orta Vade)

Hedef: Notlari salt metinden cikarip zengin icerikli hale getirmek.

- Renkli etiketler (tag sistemi)
- Zaman damgasi / guncellenme tarihi
- Kisi referanslari
- E-posta baglantilari
- Onizlemeli web linkleri
- Medya ogeleri (resim, ses, dosya ekleri)
- Arama ve filtreleme (etiket, tarih, icerik)

## 3) Gelismis Uretkenlik Modulleri

Hedef: Not uygulamasini fikir ve planlama araci haline getirmek.

- Mindmap modulu
- Cizim modu (serbest cizim/canvas)
- Nottan gorev/todo donusturme
- Moduller arasi gecis (metin <-> mindmap <-> cizim)

## 4) Gelismis Spotlight Paneli

Hedef: Hizli paneli gunluk kullanim icin daha guclu ve ogrenmesi kolay hale getirmek.

- Komut paleti yaklasimi
- Basit metin komutlari (or: `todo:`, `etiket:`, `ara:`)
- Hedefe yonelik hizli eylemler (ac, olustur, bagla)
- Son eylemler ve oneriler
- Daha iyi odak/klavye navigasyonu

## 5) UI/UX ve Animasyon Iyilestirmeleri

Hedef: Uygulamayi akici, net ve modern hissettirmek.

- Gecis animasyonlarinin iyilestirilmesi
- Panel acilis/kapanis davranisi tuning
- Tipografi ve bosluk sistemi standardizasyonu
- Erisilebilirlik kontrolleri (font, contrast, keyboard flow)

## 6) Sistem Entegrasyonlari ve Performans

Hedef: Uygulamanin OS seviyesinde daha guclu calismasi.

- Baslangicta acilma secenegi
- Acilista indexleme / yeniden indexleme modu
- Arka plan gorevleri ve veri senkronizasyonu hazirligi
- Loglama ve hata tespiti

## 7) Dagitim ve Surumleme

Hedef: Test ve dagitim surecini standardize etmek.

- `.app` paketleme adimlarini netlestirme
- `.dmg` dagitim paketi
- Sürüm notları ve changelog
- (Sonraki adim) imzalama/notarization

## Teknik Notlar

- Yol haritasi iteratif ilerleyecek.
- Her asama sonunda:
- calisan demo
- teknik borc listesi
- sonraki asamaya gecis kriterleri

## Yaklasim

1. Once 1. asamayi bitir (CRUD + kalicilik).
2. Sonra 2 ve 4. asamalari paralel gotur (zengin not + hizli panel).
3. Ardindan 3, 5 ve 6 ile urunu derinlestir.
4. Her milestone sonunda dagitim artefakti (`.dmg`) uret.
