#!/bin/bash
# Mapo yayın hattı: derle → imzala → Apple onayı → DMG → Sparkle appcast → (isteğe bağlı) GitHub Release.
#
#   bash scripts/release.sh 0.1.0            # her şey, yayınlamadan (dist/ altında)
#   bash scripts/release.sh 0.1.0 --publish  # + GitHub Release (appcast "latest" olur)
#
# Gerekenler (tek seferlik, PLAN §3.7):
#   - Anahtar Zinciri'nde "Developer ID Application" sertifikası
#   - notarytool profili:  xcrun notarytool store-credentials atlas-notary …
#   - Sparkle EdDSA anahtarı (generate_keys --account atlas)
#   - bash scripts/build-engine.sh  (gömülü motor)
# Hiçbir sır bu betikte yazmaz, yazdırılmaz.
set -euo pipefail

# Gövde tek fonksiyonda: bash dosyayı baştan sona okuyup öyle çalıştırır,
# betik çalışırken düzenlenirse yarıda bozulmaz.
main() {

VERSION="${1:?Sürüm ver: bash scripts/release.sh 0.1.0}"
PUBLISH="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="Developer ID Application: Burak Gemiciolu (BJRH6882TU)"
NOTARY_PROFILE="atlas-notary"
REPO="Bur2ak/mapo"
BUILD_DIR="$ROOT/build/release"
DIST="$ROOT/dist/$VERSION"
APP="$BUILD_DIR/Build/Products/Release/Mapo.app"
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

step() { printf "\n\033[1m→ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

step "Ön kontroller"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Sürüm biçimi X.Y.Z olmalı"
[ -x Engine/dist/bin/graphify ] || fail "Gömülü motor yok: bash scripts/build-engine.sh"
ENGINE_WANT="$(grep -E '^GRAPHIFY_VERSION=' scripts/build-engine.sh | cut -d'"' -f2)"
[ "$(cat Engine/dist/VERSION 2>/dev/null)" = "$ENGINE_WANT" ] || fail "Gömülü motor bayat (beklenen graphify $ENGINE_WANT): bash scripts/build-engine.sh"
# Sparkle: the key that signs the appcast must be the one the app trusts.
SPARKLE_PUB="$("$SPARKLE_BIN/generate_keys" --account atlas -p 2>/dev/null | tail -1)"
[ -n "$SPARKLE_PUB" ] || fail "Sparkle imza anahtarı Anahtar Zinciri'nde yok (generate_keys --account atlas)"
[ "$SPARKLE_PUB" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist)" ] \
  || fail "Sparkle anahtarı App/Info.plist'teki SUPublicEDKey ile uyuşmuyor: güncellemeler reddedilirdi"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || fail "Sertifika yok: $IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "notarytool profili çalışmıyor: $NOTARY_PROFILE"
# Swift paketleri (Sparkle) indirilmiş olmalı: lisans metni oradan okunur.
xcodegen generate >/dev/null
xcodebuild -resolvePackageDependencies -project Mapo.xcodeproj -scheme Mapo \
  -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" >/dev/null 2>&1 || fail "Swift paketleri indirilemedi"
python3 scripts/gen-notices.py >/dev/null || fail "Lisans bildirimleri üretilemedi (python3 scripts/gen-notices.py)"
# The map bundle in App/Resources/Map must match Map/src (it is committed).
( cd Map && npm ci --silent >/dev/null 2>&1 && npm run --silent build >/dev/null 2>&1 ) || fail "Harita derlenemedi (cd Map && npm run build)"
[ -z "$(git status --porcelain)" ] || fail "Commit edilmemiş değişiklik var (harita derlemesi ya da lisans bildirimleri değiştiyse commit et): $(git status --porcelain | head -3 | tr '\n' ' ')"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "  Mapo $VERSION ($BUILD_NUMBER), $(git rev-parse --short HEAD)"

step "Derleniyor (Release)"
xcodegen generate >/dev/null
rm -rf "$BUILD_DIR"
mkdir -p "$DIST"
if ! xcodebuild -project Mapo.xcodeproj -scheme Mapo -configuration Release \
  -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
  build > "$DIST/build.log" 2>&1; then
  grep -E "error:" "$DIST/build.log" | head -10 >&2
  fail "Derleme başarısız (ayrıntı: $DIST/build.log)"
fi
[ -x "$APP/Contents/MacOS/Mapo" ] || fail "Uygulama ikilisi yok"
[ -x "$APP/Contents/MacOS/mapo-mcp" ] || fail "mapo-mcp gömülmemiş"
[ -x "$APP/Contents/Resources/Engine/bin/graphify" ] || fail "Motor uygulamaya gömülmemiş"
# The embedded engine must be complete, not a half-copied tree.
diff -rq Engine/dist "$APP/Contents/Resources/Engine" >/dev/null || fail "Gömülü motor eksik kopyalanmış"

sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"; }

step "İmzalanıyor: gömülü motor"
COUNT=0
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q "Mach-O"; then sign "$f" >/dev/null 2>&1 || fail "İmzalanamadı: $f"; COUNT=$((COUNT+1)); fi
done < <(find "$APP/Contents/Resources/Engine" -type f -print0)
echo "  $COUNT ikili imzalandı"

step "İmzalanıyor: Sparkle"
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SP/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
sign "$SP/Autoupdate"
sign "$SP/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"

step "İmzalanıyor: mapo-mcp"
[ -x "$APP/Contents/MacOS/mapo-mcp" ] || fail "mapo-mcp gömülmemiş"
sign "$APP/Contents/MacOS/mapo-mcp"

step "İmzalanıyor: Mapo.app"
sign --entitlements App/Mapo.entitlements "$APP"
codesign --verify --deep --strict "$APP" || fail "İmza doğrulaması başarısız"
lipo -archs "$APP/Contents/MacOS/Mapo" | grep -qx arm64 || fail "Beklenmeyen mimari: $(lipo -archs "$APP/Contents/MacOS/Mapo")"
echo "  imza geçerli"

step "Apple onayı: uygulama"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/Mapo-notarize.zip"
xcrun notarytool submit "$DIST/Mapo-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log" || fail "Apple onaylamadı (ayrıntı: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
xcrun stapler staple "$APP"
spctl --assess --type execute "$APP" || fail "Gatekeeper uygulamayı reddediyor"
rm "$DIST/Mapo-notarize.zip"

step "DMG"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Mapo-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Mapo $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log" || fail "Apple DMG'yi onaylamadı"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper DMG'yi reddediyor"
echo "  DMG: Notarized Developer ID"

step "Sparkle appcast"
"$SPARKLE_BIN/generate_appcast" --account atlas \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  --link "https://github.com/$REPO" \
  -o "$DIST/appcast.xml" "$DIST" >/dev/null
grep -q "sparkle:edSignature" "$DIST/appcast.xml" || fail "appcast imzasız"
echo "  $DIST/appcast.xml"

if [ "$PUBLISH" = "--publish" ]; then
  step "GitHub Release v$VERSION"
  NOTES="$DIST/notes.md"
  PREV="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  { echo "## Mapo $VERSION"; echo; git log -40 --pretty='- %s' ${PREV:+"$PREV"..HEAD}; } > "$NOTES"
  # gh creates the tag on the remote with the release: a failed release
  # leaves no orphan tag, and rerunning is safe.
  gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1 && fail "v$VERSION zaten yayında"
  # A copy under a fixed name: .../releases/latest/download/Mapo.dmg is
  # always a direct download of the newest version (site, README).
  LATEST_DIR="$(mktemp -d)"
  cp "$DMG" "$LATEST_DIR/Mapo.dmg"
  gh release create "v$VERSION" "$DMG" "$LATEST_DIR/Mapo.dmg" "$DIST/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Mapo $VERSION" --notes-file "$NOTES" --latest
  git fetch -q --tags
fi

# Homebrew cask for the tap (Bur2ak/homebrew-tap: Casks/mapo.rb).
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  packaging/homebrew/mapo.rb > "$DIST/mapo.rb"
echo "  Homebrew: $DIST/mapo.rb (sha256 $SHA)"

printf "\n\033[32m✓ Mapo %s hazır: %s\033[0m\n" "$VERSION" "$DMG"
}

main "$@"
