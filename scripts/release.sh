#!/bin/bash
# Atlas yayın hattı: derle → imzala → Apple onayı → DMG → Sparkle appcast → (isteğe bağlı) GitHub Release.
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

VERSION="${1:?Sürüm ver: bash scripts/release.sh 0.1.0}"
PUBLISH="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

IDENTITY="Developer ID Application: Burak Gemiciolu (BJRH6882TU)"
NOTARY_PROFILE="atlas-notary"
REPO="Bur2ak/atlas"
BUILD_DIR="$ROOT/build/release"
DIST="$ROOT/dist/$VERSION"
APP="$BUILD_DIR/Build/Products/Release/Atlas.app"
SPARKLE_BIN="$ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin"

step() { printf "\n\033[1m→ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

step "Ön kontroller"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Sürüm biçimi X.Y.Z olmalı"
[ -x Engine/dist/bin/graphify ] || fail "Gömülü motor yok: bash scripts/build-engine.sh"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || fail "Sertifika yok: $IDENTITY"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || fail "notarytool profili çalışmıyor: $NOTARY_PROFILE"
[ -z "$(git status --porcelain)" ] || fail "Commit edilmemiş değişiklik var"
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "  Atlas $VERSION ($BUILD_NUMBER), $(git rev-parse --short HEAD)"

step "Derleniyor (Release)"
xcodegen generate >/dev/null
rm -rf "$BUILD_DIR"
xcodebuild -project Atlas.xcodeproj -scheme Atlas -configuration Release \
  -derivedDataPath "$BUILD_DIR" -clonedSourcePackagesDirPath "$ROOT/build/SourcePackages" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  build -quiet 2>&1 | grep -E "error:|warning: Gömülü" || true
[ -d "$APP" ] || fail "Derleme başarısız"
[ -x "$APP/Contents/Resources/Engine/bin/graphify" ] || fail "Motor uygulamaya gömülmemiş"

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

step "İmzalanıyor: Atlas.app"
sign --entitlements App/Atlas.entitlements "$APP"
codesign --verify --deep --strict "$APP" || fail "İmza doğrulaması başarısız"
echo "  imza geçerli"

step "Apple onayı: uygulama"
mkdir -p "$DIST"
ditto -c -k --keepParent "$APP" "$DIST/Atlas-notarize.zip"
xcrun notarytool submit "$DIST/Atlas-notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST/notary-app.log"
grep -q "status: Accepted" "$DIST/notary-app.log" || fail "Apple onaylamadı (ayrıntı: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE)"
xcrun stapler staple "$APP"
rm "$DIST/Atlas-notarize.zip"

step "DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Atlas-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Atlas $VERSION" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait | tee "$DIST/notary-dmg.log"
grep -q "status: Accepted" "$DIST/notary-dmg.log" || fail "Apple DMG'yi onaylamadı"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 | sed 's/^/  /'

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
  { echo "## Atlas $VERSION"; echo; git log --pretty='- %s' "$(git describe --tags --abbrev=0 2>/dev/null || git rev-list --max-parents=0 HEAD)"..HEAD 2>/dev/null | head -40; } > "$NOTES"
  git tag -a "v$VERSION" -m "Atlas $VERSION"
  git push -q origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$DIST/appcast.xml" --repo "$REPO" --title "Atlas $VERSION" --notes-file "$NOTES" --latest
fi

printf "\n\033[32m✓ Atlas %s hazır: %s\033[0m\n" "$VERSION" "$DMG"
