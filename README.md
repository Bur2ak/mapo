# Mapo

Herhangi bir kod projesini canlı, gezilebilir bir haritaya çeviren macOS uygulaması.

- **Kod bilgisayarından çıkmaz.** Analiz tamamen yerel ([graphify](https://github.com/Graphify-Labs/graphify) motoru, yalnız kod modu).
- **Kendiliğinden güncel.** Dosya değişince, commit atınca, dal değişince harita yenilenir.
- **İnsanlar ve ajanlar için.** Haritada ara, editöre atla; Claude Code / Cursor aynı haritayı MCP ile sorgular.

> Durum: geliştirme aşamasında. Yol haritası: [docs/PLAN.md](docs/PLAN.md) · Tasarım: [docs/TASARIM.md](docs/TASARIM.md)

## Geliştirme

Gereken: macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate                          # Mapo.xcodeproj üretir (git'e girmez)
open Mapo.xcodeproj
swift test --package-path Packages/MapoCore
```

| Klasör | İçerik |
|---|---|
| `App/` | SwiftUI uygulaması |
| `Packages/MapoCore/` | graf modeli, yükleyici, arama, sorgular, kütüphane (arayüzden bağımsız, testli) |
| `scripts/` | ikon üretici ve yardımcı betikler |
| `docs/` | plan, tasarım dili, karar kaydı |

## Teşekkürler

Kod analizi [graphify](https://github.com/Graphify-Labs/graphify) (Apache-2.0 / MIT) üzerine kuruludur.
