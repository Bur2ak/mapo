# Mapo — Tasarım Dili

## Kimlik
Mapo bir **harita**dır; arayüz çerçeve, harita sahnedir. Krom (kenar çubuğu, araç çubuğu, denetçi) sessiz ve sisteme yerli;
renk ve hareket yalnız haritada ve yalnız anlam taşıdığında.

- **Kartografi, oyun değil.** Parlama, neon, parçacık efekti yok. İnce çizgiler, net etiketler, katmanlı derinlik.
- **Durum biçimle anlatılır.** Güncellik bir rozet (renk + ikon + metin), indeksleme bir ilerleme halkası; yalnız renge dayanan durum yok.
- **Hiç boş ekran yok.** İlk açılışta örnek proje (Mapo'nun kendisi) hazır; boş kütüphane bir eylem sunar.

## Renk

Krom: sistem renkleri (`.background`, `.secondary`, `NSColor.controlAccentColor` değil — Mapo vurgusu).

| Jeton | Aydınlık | Karanlık | Kullanım |
|---|---|---|---|
| `canvas` | `#F4F5F7` | `#0E1015` | harita zemini |
| `canvasGrid` | `#E6E8EC` | `#171A21` | ızgara noktaları |
| `edge` | `#1B2230` %10 | `#C9D3E6` %9 | sönük kenar |
| `edgeActive` | `#1B2230` %55 | `#E6ECF7` %60 | vurgulu kenar |
| `label` | `#1B2230` | `#E6ECF7` | düğüm etiketi |
| `labelMuted` | `#6B7385` | `#7D869A` | ikincil etiket |
| `accent` (**Pusula**) | `#C9821E` | `#F0AE47` | seçim halkası, odak, birincil eylem |
| `fresh` | `#2F9E6B` | `#46C08A` | güncel |
| `stale` | `#C9821E` | `#F0AE47` | geride (pusula ile aynı aile: "dikkat") |
| `error` | `#D2453A` | `#F06A5E` | hata |

**Küme paleti** — 12 ton, OKLCH'de eşit aralıklı, açıklık/doygunluk sabit (aydınlıkta L 0.60 C 0.14, karanlıkta L 0.74 C 0.12)
böylece hiçbir küme ötekinden "önemli" görünmez. 12'den fazla kümede ton döner, açıklık ±0.06 kaydırılır.
Değerler `Map/src/palette.ts` ve `App/Design/Palette.swift`'te tek kaynaktan üretilir.

## Tipografi
- Krom: SF Pro (sistem). Başlık `.title3.weight(.semibold)`, gövde `.body`, yardımcı `.callout` / `.caption`.
- Kod, yol, satır: SF Mono (`.monospaced()`), sayılarda `monospacedDigit()`.
- Harita etiketleri: `-apple-system` 11 pt (sembol) / 13 pt yarı kalın (dosya) / 15 pt kalın, harf aralığı +0.2 (küme).

## Yerleşim
```
┌──────────────┬──────────────────────────────────────────┬─────────────────┐
│ Projeler     │  [proje ▾]  ● güncel · a1b2c3d   ⌘K  ⚲ ⇄ ◎ │  Denetçi        │
│              │                                          │                 │
│ ◉ kontak     │                                          │  kulupSohbetiAc │
│ ○ mapo      │                HARİTA                    │  fonksiyon      │
│              │                                          │  lib/kulup…:20  │
│              │                                          │  Çağırdıkları   │
│ + Klasör     │                                          │  Çağıranlar     │
│ + GitHub     │   [küme göstergesi]        [mini harita] │  Önizleme       │
└──────────────┴──────────────────────────────────────────┴─────────────────┘
```
- `NavigationSplitView` üç sütun; kenar çubuğu 220 pt, denetçi 300 pt (⌥⌘0 gizle/göster).
- Araç çubuğu: proje adı, güncellik rozeti (commit kısa hash), arama (⌘K), modlar: yol (⇄), etki (◎), filtre (⚲).
- ⌘K: Spotlight benzeri yüzen palet, haritanın üstünde; ok tuşları + ↩, ⌘↩ editörde aç.

## Hareket
- Kamera geçişleri 450 ms, `easeInOutCubic`; `prefers-reduced-motion` / "Hareketi azalt" açıksa anlık.
- Vurgu: seçilenin komşuları 160 ms'de belirir, gerisi %12 opaklığa söner.
- İndeksleme halkası belirsiz değil, gerçek ilerleme (graphify "N/M" çıktısından).

## Metin
- Kullanıcının dili: "Harita güncel", "3 commit geride", "Güncelle" — "graf yeniden derle" değil.
- Hata: ne oldu + ne yapmalı. "Motor başlatılamadı. Ayarlar → Tanılama'dan günlüğü kaydedip paylaş."

## Uygulama ikonu
Yuvarlatılmış kare (macOS şablonu: 824/1024 kare, köşe yarıçapı %22,37); koyu mürekkep zemin üstünde üç küme halinde bağlı düğümler (camgöbeği, mor, mercan), en büyüğünün etrafında pusula sarısı seçim halkası.
- Çizim: `App/Resources/Brand/icon-source-gemini.jpg` (7 Ekim 2026, Gemini; prompt Burak'la birlikte, ChatGPT sürümüyle karşılaştırıldı — küçük boyutta daha okunur olduğu için seçildi).
- Üretim: `python3 scripts/make-icon-from-art.py App/Resources/Brand/icon-source-gemini.jpg` → 16–1024 tüm boyutlar.
- `scripts/make-icon.swift` ilk (programatik) ikondu; yedek olarak duruyor.
