# Mapo — Ürün ve Yol Planı

> 7 Ekim 2026'ya kadar adı **Atlas**'tı (A27). Aşağıdaki geçmiş kararlar o adla yazıldı ve tarihçe olarak korunuyor.

> Herhangi bir kod projesini canlı, gezilebilir bir haritaya çeviren macOS uygulaması.
> İnsanlar haritaya bakar, Claude'lar haritayı sorgular, harita kendiliğinden güncel kalır.

Bu doküman Atlas'ın tek doğruluk kaynağıdır. Kurallar:
- Karar satırları (A-satırları) en alta eklenir, **hiçbir içerik silinmez**; geri alınan karar "geri alındı → A##" diye işaretlenir.
- Her faz bitince "Durum" tablosu güncellenir.

---

## 1. Neden

Büyüyen bir projede asıl zaman kaybı "bu nerede, neye bağlı, neyi bozar" sorusudur.
[Graphify](https://github.com/Graphify-Labs/graphify) kodu yerel olarak (tree-sitter AST, yapay zekâ çağrısı yok) bir bilgi grafına çeviriyor; ama
- komut satırı aracı, kurulumu Python/uv istiyor;
- kendi HTML çıktısı 5000 düğümden sonra zorlanıyor, arama/editöre atlama yok;
- güncel tutmak elle ya da repoya git hook kurarak;
- isimsiz route handler'ları (Hono/Express) ve istemci → sunucu HTTP geçişini görmüyor
  (Kontak'ta 7 Ekim 2026 ölçümü: `POST /api/kulup/:id/uye/:kisi/sohbet` grafta yoktu).

Atlas bu motoru içine gömer, üstüne profesyonel bir Mac arayüzü, canlılık, GitHub ve Claude bağlantısı ekler,
ve graphify'ın göremediği katmanı (route ↔ fetch köprüsü, SQL) kendi çıkarıcısıyla kapatır.

## 2. İlkeler

1. **Kod bilgisayardan çıkmaz.** Motor her zaman `--code-only`. Uygulama telemetri, analiz, çökme raporu göndermez.
   Ağa çıkan yalnız: kullanıcının açıkça bağladığı GitHub ve Sparkle güncelleme denetimi.
2. **Sıfır kurulum.** Python + graphify uygulamanın içinde gelir. Arkadaş DMG'yi açar, sürükler, kullanır.
3. **Hiçbir projeye dosya yazmaz.** Graflar `~/Library/Application Support/Atlas/` altında. Repoya hook kurulmaz.
4. **Mac yerlisi.** SwiftUI, sistem fontları, karanlık/aydınlık, klavye ile her şey, erişilebilirlik etiketleri.
5. **Kaynak her zaman kod.** Harita bir harita; Claude entegrasyonu araç olarak sunulur, "önce grafa sor" dayatması yapılmaz.
6. **Bayat veriyi saklamaz.** Haritanın hangi commit'e ait olduğu ve kaç commit geride kaldığı her zaman görünür.

## 3. Özellikler

### 3.1 Proje kütüphanesi
- Klasör sürükle-bırak veya "Klasör ekle…" (⌘O); GitHub'dan repo seçme (§3.4).
- Kart: ad, kök yolu, dil dağılımı çubuğu, dosya/düğüm/bağlantı sayısı, son indeksleme, güncellik rozeti.
- Sağ tık: Finder'da göster, editörde aç, yeniden indeksle, kaldır (graf silinir, proje dosyalarına dokunulmaz).

### 3.2 Harita
- WebGL çizim (gömülü, çevrimdışı); 10k düğümde akıcı.
- Kümeler (graphify community) renkli bölgeler; kümeye hub düğümünden ad.
- Anlamsal yakınlaştırma: uzakta küme etiketleri, yakında dosyalar, en yakında semboller.
- ⌘K bulanık arama (sembol, dosya, küme) → kamera uçar, komşular vurgulanır, gerisi söner.
- Denetçi paneli: tür, dosya:satır, çağırdıkları / çağıranlar / içe aktaranlar, kod önizlemesi (satır çevresi, sözdizimi renkli).
- Editöre atla: VS Code, Cursor, Zed, Xcode, Sublime — kurulu olan algılanır, tercih ayarlardan.
- Yol bulucu: iki düğüm arası en kısa yol, adım adım şerit.
- Etki analizi: bir dosya/sembol değişirse ters bağımlılık halkaları (1., 2., 3. derece).
- Son değişenler: son N commit'te dokunulan düğümler parlar; zaman kaydırıcısı.
- Filtreler: ilişki türü (calls / imports / contains…), klasör, test dosyalarını gizle, yalnız EXTRACTED.
- Dışa aktar: PNG (Retina), seçili alt grafı Mermaid / JSON.

### 3.3 Canlılık
- FSEvents ile proje klasörü izlenir; değişiklik 2 sn sakinleşince yalnız değişen dosyalar yeniden çıkarılır (`graphify update`).
- `.git/HEAD` ve ref değişimi izlenir: dal değişimi / commit / pull algılanır.
- Kuyruk: aynı anda tek indeksleme, düşük öncelik (QoS utility), pil modunda erteleme.
- Menü çubuğu ikonu: güncel / indeksleniyor (ilerleme) / hata. Uygulama penceresi kapalıyken de çalışır (ayarlanabilir).
- Oturum açılışında başlat (SMAppService), ayarlardan.

### 3.4 GitHub
- OAuth Device Flow (şifre uygulamaya girilmez); belirteç Anahtar Zinciri'nde.
- Repo listesi (kişisel + organizasyonlar), arama, özel repolar.
- Klonla → `~/Library/Application Support/Atlas/Repos/` (veya kullanıcının seçtiği yer) → otomatik indeksle.
- Arka planda periyodik `git fetch` + fast-forward pull (yerel değişiklik varsa dokunmaz, uyarır).

### 3.5 Claude ve diğer ajanlar
- Uygulamaya gömülü MCP sunucusu (stdio yardımcı ikili `atlas-mcp`).
- Araçlar: `mapo_projects`, `mapo_search`, `mapo_node`, `mapo_callers`, `mapo_callees`, `mapo_file_dependencies`, `mapo_path`, `mapo_endpoints`, `mapo_impact`, `mapo_changed` (A34).
  Her yanıt grafın commit'ini ve güncelliğini taşır.
- Ayarlar → Entegrasyonlar: Claude Code, Claude Desktop, Cursor için tek tık bağla / kaldır (yapılandırma dosyalarına yedekli yazım).

### 3.6 Atlas çıkarıcıları (graphify'ın üstüne)
- **HTTP köprüsü:** sunucu route tanımları (Hono, Express, Fastify, Next route handlers, Cloudflare Workers) → `route:METHOD /path` düğümü;
  istemci çağrıları (`fetch`, axios, ky, kendi `api()` sarmalayıcıları; şablon dizgileri normalize) → `requests` kenarı.
- **SQL:** migration dosyalarından tablo/sütun düğümleri, kod içindeki SQL dizgilerinden `reads/writes` kenarı.
- Çıktı graphify graf'ına `ATLAS` kökenli kenar olarak birleşir; kendi güven etiketi var.

### 3.7 Dağıtım ve güncelleme
- Developer ID imzası + Hardened Runtime + notarization; gömülü Python'daki tüm `.so/.dylib` imzalı.
- Sparkle 2 (EdDSA imzalı appcast, GitHub Releases'ta).
- GitHub Actions: `v*` etiketi → derle → imzala → notarize → staple → DMG → appcast → Release.
- Sırlar yalnız GitHub Secrets / Anahtar Zinciri'nde; betikler sır yazdırmaz.

### 3.8 Diğer
- Türkçe + İngilizce (String Catalog).
- Yerel günlük (`~/Library/Logs/Atlas`), "Tanılama paketini kaydet" (kullanıcı kendisi paylaşır).
- Hızlı Başlangıç: ilk açılışta 3 adımlık tanıtım + örnek proje (Atlas'ın kendi kodu).

## 4. Mimari

```
Atlas.app
├── App (SwiftUI)                   pencere, kütüphane, harita kabuğu, denetçi, ayarlar, menü çubuğu
├── AtlasCore (Swift paketi)        Graph modeli, yükleyici, arama dizini, sorgular (yol, etki),
│                                   ProjectStore, IndexQueue, FileWatcher, GitInfo, EngineRunner
├── Resources/Map (web)             WebGL harita (sigma.js + graphology), TypeScript, esbuild ile tek dosya
├── Resources/Engine                gömülü Python 3.12 (python-build-standalone) + graphifyy (sabit sürüm) + atlas_extractors
└── atlas-mcp (komut satırı)        AtlasCore'u kullanan MCP stdio sunucusu
```

- Swift ↔ harita köprüsü: `WKScriptMessageHandler` (JS → Swift: seçim, çift tık) ve `evaluateJavaScript` (Swift → JS: odakla, vurgula, filtre).
  Graf JSON'u diskte; web görünümü `atlas://` şemasıyla okur (büyük veri köprüden geçmez).
- Veri: `Application Support/Atlas/Projects/<uuid>/{project.json, graphify-out/…}`.
- Motor sürümü sabit; motor güncellemesi = uygulama güncellemesi (Sparkle). Grafın motor sürümü kaydedilir, uyumsuzsa yeniden indekslenir.
- Minimum macOS 14 (Sonoma).

## 5. Tasarım
Ayrıntı: [TASARIM.md](TASARIM.md).

## 6. Fazlar

| Faz | Kapsam | Bitti sayılır |
|---|---|---|
| 0 | Repo, plan, tasarım sistemi, Xcode iskeleti, AtlasCore graf modeli + testler | `xcodebuild` ve `swift test` yeşil, boş pencere açılıyor |
| 1 | Klasör ekleme, motor köprüsü (önce sistemdeki graphify, sonra gömülü), harita, ⌘K, denetçi, editöre atla | Kontak haritası açılıyor, arama → odak → editör çalışıyor |
| 2 | Canlılık (FSEvents, git), son değişenler, menü çubuğu, oturum açılışı | Kod değişince harita kendiliğinden güncelleniyor |
| 3 | GitHub Device Flow, repo listesi, klonla, arka plan pull | Özel repo bağlanıp haritası açılıyor |
| 4 | MCP sunucusu + tek tık entegrasyon, HTTP köprüsü, SQL çıkarıcı, yol bulucu, etki analizi | Claude Code'dan `atlas_callers` dönüyor; Kontak'ta route ↔ fetch bağlı |
| 5 | Gömülü Python, imza, notarization, Sparkle, Actions, DMG, ilk sürüm | Arkadaş DMG'yi açıp uyarısız kuruyor, güncelleme geliyor |

## 7. Durum

| Faz | Durum | Not |
|---|---|---|
| 0 | bitti (7 Ekim) | AtlasCore 32 test (gerçek Kontak grafı 0,15 sn), iskelet derleniyor, ikon. |
| 1 | bitti (7 Ekim) | Atlas yerleşimi, bölgeler, ⌘K, denetçi (dosya bağımlılıkları), editöre atlama; uygulama içinden indeksleme Burak'ın makinesinde çalıştı. |
| 2 | bitti (7 Ekim) | FSEvents izleyici (realpath), tek kuyruklu IndexCoordinator, otomatik güncelleme (kamera korunur, yeni dosya/ülke yerleşimi), menü çubuğu, Ayarlar, oturumda başlat. Uçtan uca sahte motorla doğrulandı. |
| 3 | bitti (7 Ekim) — giriş Burak'ın hesabıyla doğrulandı; repo indirme denemesi bekleniyor | Device Flow (Client ID Ov23ligebFbA7NFdB2o9, kod üretimi doğrulandı), Anahtar Zinciri, repo listesi, klonla + ilk harita, 10 dk'da bir hızlı ileri güncelleme. |

## 8. Karar kaydı

| # | Karar | Tarih |
|---|---|---|
| A1 | Ad **Atlas**. Repo `Bur2ak/atlas`, şimdilik özel; açık kaynak olabilir → kod tanımlayıcıları İngilizce, arayüz TR + EN, belgeler Türkçe. | 7 Ekim 2026 |
| A2 | Motor graphify (Apache-2.0 / MIT), sürümü sabit (ilk: 0.9.79), her zaman `--code-only`. Lisans metni uygulama içinde "Teşekkürler" bölümünde. | 7 Ekim 2026 |
| A3 | Arayüz SwiftUI (macOS 14+); harita gömülü WebGL (sigma.js). Saf Metal çizici şimdilik yok — maliyet/fayda; ihtiyaç olursa ayrı faz. | 7 Ekim 2026 |
| A4 | Graflar Application Support altında, projeye dosya/hook yazılmaz. Kontak'a 7 Ekim'de önerilen `graphify hook` Atlas canlılığı gelince kaldırılacak. | 7 Ekim 2026 |
| A5 | Harita varsayılanı **klasöre göre renk + Dosyalar düzeyi**. Graphify Kontak'ta 158 algoritmik küme buldu; 12 tonla anlamsız renk çorbası oluyordu. İnsanlar projeye "mobil / api / panel" diye bakar. Küme renklendirmesi menüde duruyor. | 7 Ekim 2026 |
| A6 | Yerleşim: ForceAtlas2 linLog; aynı klasör ×3, aynı küme ×2 çekim, klasöre göre tohumlama. Konumlar `layout.json`'a yazılır, ikinci açılış anında. | 7 Ekim 2026 |
| A7 | Kenarlar opak, zemine önceden karıştırılmış renkler: saydam WKWebView üstünde WebGL alfa toplanarak soluk çizgileri parlak beyaza çeviriyordu. | 7 Ekim 2026 |
| A8 | Derlenmiş harita (`App/Resources/Map/`) repoda tutulur; uygulamayı derlemek Node istemez. Harita kodu değişince `cd Map && npm run build`. | 7 Ekim 2026 |
| A9 | **Atlas yerleşimi (iki/üç katman):** her klasör ayrı bir ülke, içinde alt klasörler il, fonksiyonlar dosyalarının etrafında yörüngede. Ülkeler/iller aralarındaki trafiğe göre dizilir ve `noverlap` ile asla üst üste binmez. Tek bir küresel kuvvet yerleşimi klasörleri birbirine karıştırıyordu (Kontak'ta mobil/api iç içeydi). | 7 Ekim 2026 |
| A10 | Bölgeler yumuşak köşeli dışbükey zarf (alan + ince kenar) olarak 2D tuvalde, WebGL haritanın altında çizilir. Büyük haritada dururken tek tek kenarlar yerine ülkeler arası şeritler; küçük haritada yalnız ülkeler arası kenarlar. | 7 Ekim 2026 |
| A11 | Düğüm boyutları harita biriminde (`itemSizesReference: positions`): yakınlaştıkça büyür, yerleşimin aralığı çizilenle birebir. Ekran pikseliyle yerleşim "çakışmıyor" sanıp ekranda üst üste biniyordu. | 7 Ekim 2026 |
| A12 | Renk: dosya payı ≥%3 **veya** bağlantı payı ≥%5 olan (en çok 9) bölge eşit aralıklı ton alır, kalanı nötr "Diğer". `packages/shared` tek dosya ama mimarinin kalbi; dosya sayısına bakmak onu griye atıyordu. | 7 Ekim 2026 |
| A13 | Kenar çubuğu seçimi sistem vurgu rengini kullanır (Mac yerlisi); marka sarısı yalnız Atlas'ın kendi çizdiği öğelerde (seçim halkası, birincil düğmeler). | 7 Ekim 2026 |
| A14 | İndeksleme proje içinden uygulama düzeyine (`IndexCoordinator`) taşındı: tek kuyruk, aynı anda tek motor, düşük öncelik; arka plan hataları uyarı penceresi değil, alt başlık + kırmızı nokta. | 7 Ekim 2026 |
| A15 | Otomatik güncelleme yalnız **haritası olan** projelerde; ilk harita her zaman kullanıcının açık kararı. Atlas açılınca kapalıyken geride kalan projeler sıraya alınır. | 7 Ekim 2026 |
| A16 | Uçtan uca testler gerçek graphify yerine DEBUG'a özel sahte motorla (`ATLAS_ENGINE`, `scripts/fake-engine.py`) ve ayrı veri klasörüyle (`-atlasDataDir`) yapılır; kullanıcının kütüphanesine dokunulmaz. | 7 Ekim 2026 |
| A17 | Kontak'a önerilen `graphify hook` artık gereksiz (A4): Atlas'ın kendi izleyicisi var. Kuruluysa `graphify hook uninstall`. | 7 Ekim 2026 |
| A18 | GitHub girişi OAuth **Device Flow**, client secret yok (uygulamaya gömülemez). Token yalnız Anahtar Zinciri'nde (`ThisDeviceOnly`), süreli token + yenileme; yenileme reddedilirse oturum kapanır ve yeniden bağlanma istenir. | 7 Ekim 2026 |
| A19 | Token git'e yalnız `GIT_CONFIG_*` ortam değişkeniyle, tek komutluk HTTP başlığı olarak verilir: `.git/config`'e, URL'ye, komut satırına (ps) asla yazılmaz; hata metinlerinde maskelenir. | 7 Ekim 2026 |
| A20 | Arka plan güncellemesi yalnız `fetch` + `merge --ff-only`; kirli ağaç, yerel commit, ayrışmış dal varsa dokunulmaz ve sebebi not edilir. | 7 Ekim 2026 |
| A21 | Atlas'ın birincil düğmesi kendi stili (`.accent`): amber üstüne koyu mürekkep. Sistem `.borderedProminent` beyaz yazı veriyordu (~1.9:1 kontrast). | 7 Ekim 2026 |
| A22 | Anahtar Zinciri erişimi asla ana iş parçacığında yapılmaz (macOS izin penceresi arayüzü donduruyordu). Geliştirme sürümü sabit "Apple Development" kimliğiyle imzalanır (takım BJRH6882TU) ki izin derlemeler arasında korunsun; ad-hoc imza her derlemede yeniden izin istiyordu. Tüm GitHub isteklerinde 20 sn zaman aşımı. | 7 Ekim 2026 |
| A23 | Gömülü motor: python-build-standalone 3.12.15 (aarch64) + graphifyy 0.9.79, SHA256SUMS ile doğrulanır, `Engine/dist` → `Resources/Engine`. İlk sürüm yalnız Apple Silicon; Intel Mac'ler sistemde kurulu graphify'a düşer (talep olursa x86_64 ikinci motor). | 7 Ekim 2026 |
| A24 | MCP sunucusu `atlas-mcp` (stdio, JSON-RPC 2.0, protokol 2025-06-18), uygulamanın içinde `Contents/MacOS/atlas-mcp`. 8 salt okunur araç (projects, search, node, callers, callees, file_dependencies, path, impact); her yanıt dosya:satır + harita güncelliği taşır. Graf değişince (mtime) kendiliğinden yeniden yüklenir. | 7 Ekim 2026 |
| A25 | Ajan bağlama dört istemci: Claude Code (`~/.claude.json`), **Codex** (`~/.codex/config.toml`), Cursor (`~/.cursor/mcp.json`), Claude Desktop. JSON'da yalnız `mcpServers.atlas`; Codex TOML'unda yalnız `[mcp_servers.atlas]` tablosu değişir, gerisi bayt bayt korunur. İlk yazımda `.atlas-backup`, bozuk JSON'a asla yazılmaz, izinler 0600. | 7 Ekim 2026 |
| A26 | **0.1.0 hazır (7 Ekim):** Developer ID imzalı, Apple onaylı (uygulama + DMG), Gatekeeper "Notarized Developer ID", Sparkle appcast EdDSA imzalı, 46 MB. Yayın (repo açma + Release) isim ve lisans kararını bekliyor. Üçüncü taraf: 43 bileşen, hepsi serbest lisanslı (MIT/BSD/Apache/PSF); tree-sitter-groovy lisans dosyası göndermediği için upstream manifestten MIT metni eklendi. | 7 Ekim 2026 |
| A27 | **Ad: Mapo** (Atlas'tan). Sebep: OpenAI'ın "ChatGPT Atlas" Mac tarayıcısıyla karışma; Burak kısa, kolay okunur bir ad istedi. Kontrol: GitHub'da aynı alanda proje yok, Mac App Store'da "Mapo" yok; getmapo.app / mapoapp.com boş (mapo.app/.dev/.io alınmış). Bundle `io.github.bur2ak.mapo`, repo `Bur2ak/mapo`, MCP sunucusu `mapo` / araçlar `mapo_*`. Erken kullanıcılar için `LegacyMigration`: veri klasörü, ayarlar, Anahtar Zinciri token'ı taşınır; ajanlardaki eski `atlas` girdisi bağlanınca silinir. Korunanlar: Sparkle anahtar hesabı `atlas`, notary profili `atlas-notary` (Anahtar Zinciri adları). | 7 Ekim 2026 |
| A28 | **Lisans: Apache-2.0** (+ NOTICE). Üçüncü taraf lisanslarının hepsi uyumlu (A26). | 7 Ekim 2026 |
| A29 | **İç denetim (7 Ekim):** iki bağımsız inceleme ajanı + elle ekran turu. Düzeltilenler: git config ile kod çalıştırma (fsmonitor/hooks kapalı, testli), ajan ayar dosyalarını bozma/ezme riskleri (TOML ayrıştırma, CRLF, okunamayan dosya, symlink, yedek izinleri, DMG'den bağlama), göçte GitHub proje yolları, token yenileme yarışı, FETCH_HEAD'le gereksiz analiz, takılan motor (15 dk), MCP uyumu; harita performansı (ayar değişiminde tam yeniden işleme, her fare hareketinde tüm düğüm taraması, her karede bölge/trafik hesabı, yerleşim donması), sürüklerken hover, seçimin imleçten önce gelmesi, seçili ad önceliği, WebGL bağlam kaybı; yayın hattı (derleme hatası yutma, bayat harita/motor, Sparkle anahtar doğrulaması, Gatekeeper kontrolleri, atomik yayın). Uygulama yalnız Apple Silicon (arm64); motor bağımlılıkları sabit sürüm, yalnız wheel. 104 test. | 7 Ekim 2026 |
| A30 | **Harita: iç içe daire (circle packing) varsayılan (8 Ekim).** Eski kuvvet-yönelimli ağ (sigma) yerleşimi okunmuyordu: konum anlam taşımıyor, kenar yumağı, her açılışta farklı. Yeni harita klasör ağacını d3-hierarchy ile paketler, Canvas2D ile çizer: alan = satır sayısı, konum = klasör (deterministik). Tek çocuklu klasör zincirleri birleşir, yalnız klasör içeren klasörler düzleşir (`apps › mobile` → `apps/mobile`). Fonksiyonlar dosyanın içinde. Bağlantılar yalnız seçimde: kullandıkları (turuncu) / kullananlar (mavi), büyük bölgelere tek demet + sayı rozeti. Klasöre tıkla → içine gir (alt çubukta yol, dışı soluk); renk: bölge / son değişiklik (git) / bağlantı yoğunluğu. Eski ağ "Görünüm › Ağ (eski)" ile duruyor. Etiketler harita kuralıyla: önce balonun içine (gerekirse camelCase'ten iki satır), sığmazsa altına; fonksiyon adları en bağlantılıdan başlayıp dosyanın alanı kadar, yakınlaştıkça fazlası; uzun klasör adı küçük çemberde `…/son-parça`. Büyük klasörlere boyutla artan iç boşluk (iç içe halkalar tek çizgiye kaynamasın). Üzerine gelince tür · satır · bağlantı sayısı. Yükte yeni sütunlar: `path`, `owner`, `lines`, `age`. 105 test. | 8 Ekim 2026 |
| A31 | **Köprüler (Faz 4, 8 Ekim):** graphify'ın göremediği süreç sınırları `Bridges` ile çıkarılır, `mapo-bridges.json` olarak grafın yanına yazılır, `GraphLoader` birleştirir (uygulama + MCP aynı veriyi görür). HTTP: Hono/Express/Fastify `r.get('/x', …)` + `app.route/use('/api', r)` önekleri (import çözümlü, iç içe), Next.js `app/**/route.ts` ve `pages/api`; istemci `fetch` (yöntem yalnız çağrının kendi argümanından), `get/post/…` sarmalayıcıları, axios/ky; şablon delikleri parametre, yapışık delik sorgu soneki sayılır; eşleşmezse tek adaylı sonek (router'a göreli test çağrıları, alıcı adıyla daraltılır). SQL: `.sql` içindeki `CREATE TABLE` → tablo düğümü, kodda BÜYÜK harf `FROM/JOIN` okur, `INTO/UPDATE` yazar. Yeni türler `route`, `table`; ilişkiler `requests`, `reads`, `writes` (INFERRED). Kontak'ta: 167 uç, 163/163 istemci çağrısı eşleşti, 46 tablo, 688 sorgu bağı, 1,5 sn. MCP: `mapo_endpoints`, `mapo_node` köprüleri listeler. Ayrıca yol bulucu (A30 sonrası), ilk açılış tanıtımı + örnek proje (Mapo'nun kendi kodu), yeni ikon. | 8 Ekim 2026 |
| A32 | **Eksiklerin kapanışı (8 Ekim):** İngilizce arayüz (String Catalog, 300 dizgi, tekil/çoğul; harita kendi sözlüğüyle, dili uygulama bildirir; `scripts/check-strings.py` eksik çeviriyi yakalar). Dışa aktarma: görüntü (PNG, ekrandaki görünüm) ve Mermaid (seçimin komşuluğu ya da yol, panoya). Bağlantı filtresi (tümü / çağrılar / içe aktarmalar / HTTP+SQL). Tanılama paketi (özet + son 20 günlük, kod/harita/token yok). Düşük Güç modunda otomatik güncelleme bekler, elle güncelleme beklemez. **Bilinçli olarak yapılmayan:** "son değişenler zaman kaydırıcısı" — "Son değişikliğe göre" renk modu + denetçideki "Son değişenler" aynı soruyu daha az etkileşimle cevaplıyor; eski ağ görünümü çevrilmedi (yalnız geri dönüş seçeneği). | 8 Ekim 2026 |
| A33 | **Hedef kitle turu (9 Ekim):** Köprüler Supabase/Prisma/Drizzle/tRPC/Python (FastAPI, Flask, Django)/Cloudflare (Worker yönlendirmesi, servis bağlantısı) tanır; fonksiyon atfı süslü parantez/girinti aralığıyla, satır içi route işleyicisinin gövdesi route'a ait (SQL'i ve içe aktarılan fonksiyon çağrıları "GET /x → saveOrder → tablo"); test dosyalarındaki route'lar sayılmaz; dosya başına paralel tarama (cal.com 6,9 → 2,3 sn). **Büyük repo ölçümü (cal.com, 5.359 dosya, 33.897 düğüm, 106 bin bağ):** analiz 133 sn, motor en çok 1,5 GB, uygulama 408 MB; yerleşim 20 bin dosyada ~100 ms. Gezinme: geri/ileri (⌘[ ⌘]), üst düzeye çık (⌘↑), fareyle üzerine gelince bağlantı önizlemesi (tıklayınca kilitlenir). Araç çubuğunda yalnız Dosyalar/Kod; sabitler Görünüm menüsünde. Örnek proje artık küçük bir full-stack uygulama (Sample/CoffeeShop: mobil → Hono → D1), yol bulucu ilk açılışta mobil→API→tablo zincirini gösterir. Yardım › Geri Bildirim Gönder (GitHub issue, sürüm bilgisiyle). | 9 Ekim 2026 |
| A34 | **`mapo_changed` (10 Ekim):** "X'ten beri ne değişti?" haritanın diliyle: `git diff --unified=0 <since>` (çalışma ağacı dahil, `--relative`) + izlenmeyen dosyalar → dosyalar ve dokunulan fonksiyon / tip / route'lar, her birinin çağıran sayısıyla. Semboller yalnız başlangıç satırı taşıdığı için değişen satır, aynı dosyada kendisinden önceki en yakın bildirime atanır; ilk bildirimin üstü "dosya başı". `since` varsayılanı haritanın commit'i; yalnız güvenli ref kabul edilir (seçenek / aralık / kabuk karakteri yok, `rev-parse --end-of-options` ile doğrulanır); git `cleanEnvironment` + `gitSafety` ile çalışır, çıktı 8 MB'ta kesilir. Harita commit'i HEAD'den farklıysa not düşülür. Yapay zekâ yok; Kovan'ın Mimar peteği (değişiklik anlatıcısı, haftalık özet) bunun üstüne kurulur. 130 test. | 10 Ekim 2026 |
