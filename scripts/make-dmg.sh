#!/bin/zsh
# Собирает Flake.app и упаковывает в dist/Flake.dmg
# На другом Mac: открыть DMG → перетащить Flake в «Программы» → открыть.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/build.sh"

DIST="$ROOT/dist"
DMG="$DIST/Flake.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/flake-dmg.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$DIST"
rm -f "$DMG"

cp -R "$ROOT/Flake.app" "$STAGE/Flake.app"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/Как установить.txt" <<'EOF'
Flake — снег на рабочем столе

Установка
1. Перетащи Flake в папку «Программы» (Applications) справа.
2. Открой «Программы» и дважды кликни Flake.
3. Если macOS напишет, что приложение не удалось проверить:
   Системные настройки → Конфиденциальность и безопасность →
   прокрути вниз → «Всё равно открыть».
4. Для сугробов на окнах включи «Запись экрана» для Flake
   в тех же настройках конфиденциальности, затем перезапусти Flake.

После установки DMG можно извлечь (Извлечь) и удалить.
EOF

hdiutil create \
  -volname "Flake" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG" >/dev/null

# Чтобы локально открывалось без лишних вопросов
xattr -cr "$DMG" 2>/dev/null || true

echo "OK → $DMG"
echo "Отдай этот файл другому Mac: открыть → перетащить Flake в Программы."
