#!/bin/bash
# Mapo'ın gömülü analiz motorunu hazırlar: bağımsız Python + graphify (sabit sürümler).
#
#   bash scripts/build-engine.sh
#
# Çıktı: Engine/dist/  (git'e girmez; derlemede Mapo.app/Contents/Resources/Engine'e kopyalanır)
#   Engine/dist/bin/graphify   → motoru çalıştıran sarmalayıcı
#   Engine/dist/python/        → python-build-standalone (aarch64)
#
# Güvenlik: Python arşivi yayıncının SHA256SUMS dosyasıyla doğrulanır; graphify
# sabit sürümle kurulur. Hiçbir şey sistem Python'una dokunmaz.
set -euo pipefail

PBS_TAG="20261003"
PY_VERSION="3.12.15"
GRAPHIFY_VERSION="0.9.79"
ARCH="aarch64"   # Apple Silicon. Intel desteği: PLAN A23.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Engine/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

NAME="cpython-${PY_VERSION}+${PBS_TAG}-${ARCH}-apple-darwin-install_only.tar.gz"
BASE="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}"

echo "→ Python ${PY_VERSION} indiriliyor (${ARCH})"
curl -fL --progress-bar -o "$WORK/$NAME" "$BASE/${NAME/+/%2B}"
curl -fsSL -o "$WORK/SHA256SUMS" "$BASE/SHA256SUMS"

echo "→ Doğrulanıyor"
EXPECTED="$(grep " ${NAME}\$" "$WORK/SHA256SUMS" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$WORK/$NAME" | awk '{print $1}')"
if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
  echo "✗ SHA256 tutmadı (beklenen: ${EXPECTED:-yok}, gelen: $ACTUAL)" >&2
  exit 1
fi
echo "  SHA256 doğru"

rm -rf "$OUT"
mkdir -p "$OUT"
tar -xzf "$WORK/$NAME" -C "$OUT"   # → $OUT/python
PY="$OUT/python/bin/python3"

echo "→ graphify ${GRAPHIFY_VERSION} kuruluyor"
# Every package pinned (scripts/engine-requirements.txt), wheels only (no
# local compilers, no Homebrew libraries), no user/global pip config.
PIP_DISABLE_PIP_VERSION_CHECK=1 "$PY" -m pip install --isolated --no-compile --quiet \
  --only-binary=:all: --index-url https://pypi.org/simple \
  -r "$ROOT/scripts/engine-requirements.txt"
"$PY" -c "import graphify" || { echo "✗ graphify kurulmadı" >&2; exit 1; }

echo "→ Gereksizler temizleniyor"
SP="$("$PY" -c 'import site; print(site.getsitepackages()[0])')"
rm -rf "$OUT/python/include" "$OUT/python/share" \
       "$OUT/python/lib/python3.12/test" "$OUT/python/lib/python3.12/idlelib" \
       "$OUT/python/lib/python3.12/tkinter" "$OUT/python/lib/python3.12/turtledemo" \
       "$OUT/python/lib/python3.12/ensurepip" "$OUT/python/lib/python3.12/lib2to3"
rm -f "$OUT"/python/lib/libtcl* "$OUT"/python/lib/libtk*
rm -rf "$OUT/python/lib/tcl"* "$OUT/python/lib/tk"* "$OUT/python/lib/itcl"* "$OUT/python/lib/thread"* 2>/dev/null || true
find "$OUT/python" -name "__pycache__" -type d -prune -exec rm -rf {} +
find "$SP" -type d \( -name "tests" -o -name "test" \) -prune -exec rm -rf {} + 2>/dev/null || true
# pip yalnız kurulum için gerekiyordu.
"$PY" -m pip uninstall --yes --quiet pip >/dev/null 2>&1 || true

echo "→ Sarmalayıcı yazılıyor"
mkdir -p "$OUT/bin"
cat > "$OUT/bin/graphify" <<'WRAP'
#!/bin/sh
# Mapo gömülü motoru: ana bilgisayarın Python'una ve ortamına bağımsız.
HERE="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONNOUSERSITE=1
export PYTHONDONTWRITEBYTECODE=1
unset PYTHONPATH PYTHONHOME
exec "$HERE/python/bin/python3" -m graphify "$@"
WRAP
chmod +x "$OUT/bin/graphify"

echo "→ Deneme"
"$OUT/bin/graphify" --help >/dev/null 2>&1 && echo "  graphify çalışıyor" || { echo "✗ graphify açılmadı" >&2; exit 1; }
echo "$GRAPHIFY_VERSION" > "$OUT/VERSION"

echo "✓ Motor hazır: $(du -sh "$OUT" | cut -f1)  →  $OUT"
