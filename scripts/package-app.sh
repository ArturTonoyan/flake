#!/bin/zsh
# Совместимость: то же, что make-dmg.sh
exec "$(cd "$(dirname "$0")" && pwd)/make-dmg.sh"
