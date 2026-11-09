#!/bin/zsh
# Двойной клик в Finder: собрать, поставить в Программы и открыть.
# Также делает dist/Flake.dmg — его можно скинуть на другой Mac.
set -euo pipefail

cd "$(dirname "$0")"

echo "=== Flake: сборка ==="
./scripts/make-dmg.sh

echo
echo "=== Установка в Программы ==="
rm -rf /Applications/Flake.app
cp -R ./Flake.app /Applications/Flake.app
xattr -cr /Applications/Flake.app 2>/dev/null || true

open /Applications/Flake.app

echo
echo "Готово."
echo "• Flake запущен (снежинка в строке меню)."
echo "• Для друга: отдай файл dist/Flake.dmg — терминал не нужен."
echo
echo "Нажми любую клавишу, чтобы закрыть это окно…"
read -k 1
echo
