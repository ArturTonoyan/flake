# Как выпустить релиз Flake

Чеклист, чтобы не забывать шаги. Репозиторий: `ArturTonoyan/flake`.

## Версии

В `Info.plist` две строки:

| Ключ | Пример | Что менять |
|------|--------|------------|
| `CFBundleShortVersionString` | `1.4.0` | видимая версия (semver) |
| `CFBundleVersion` | `5` | номер сборки — **каждый релиз +1** |

Тег всегда `v` + short version: `v1.4.0`.

`dist/` и `Flake.app/` в git **не коммитятся** — в релиз кладётся только готовый DMG через GitHub Releases.

## Быстрый путь (всё сразу)

Из корня репо:

```bash
# 1) Подними версию в Info.plist вручную (ShortVersion + Version)

# 2) Коммит + тег
git add -A
git status   # глянь, что нет .env / секретов
git commit -m "Release 1.4.0: кратко что изменилось."
git tag -a v1.4.0 -m "Flake 1.4.0"

# 3) Сборка DMG
./scripts/make-dmg.sh
# → dist/Flake.dmg  и  Flake.app (версия должна совпасть с Info.plist)

# 4) На GitHub: код + тег
git push origin HEAD
git push origin v1.4.0

# 5) Релиз с DMG (если gh уже залогинен)
gh release create v1.4.0 dist/Flake.dmg \
  -R ArturTonoyan/flake \
  --title "Flake 1.4.0" \
  --notes "$(cat <<'EOF'
## Что нового
- пункт 1
- пункт 2

DMG: открой → перетащи Flake в Программы.
EOF
)"
```

Проверка:

```bash
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Flake.app/Contents/Info.plist
gh release view v1.4.0 -R ArturTonoyan/flake
```

Ссылка для людей: https://github.com/ArturTonoyan/flake/releases/latest/download/Flake.dmg  
(она уже в README — после нового latest сама указывает на свежий файл.)

## Только локально (без GitHub)

Если нужно сначала проверить у себя / отдать другу файл:

```bash
# bump Info.plist → commit → tag (как выше)
./scripts/make-dmg.sh
open dist/Flake.dmg
# НЕ делай git push / gh release, пока не готов
```

Потом, когда готов:

```bash
git push origin HEAD && git push origin v1.4.0
gh release create v1.4.0 dist/Flake.dmg -R ArturTonoyan/flake --title "Flake 1.4.0" --notes "..."
```

## Если `gh` пишет «not logged in»

Пуш через `git` обычно уже работает (ключ в Keychain). Для `gh release` можно один раз подставить тот же токен, **без** `gh auth login` / Connect:

```bash
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git credential fill | awk -F= '/^password=/{print $2}')
export GH_TOKEN="$TOKEN"

gh release create v1.4.0 dist/Flake.dmg -R ArturTonoyan/flake \
  --title "Flake 1.4.0" --notes "..."

unset GH_TOKEN TOKEN
```

Или нормально залогиниться: `gh auth login` (один раз).

## Тег уже есть, а релиза на сайте нет

Так бывает, если запушили тег, но забыли `gh release create`.

```bash
./scripts/make-dmg.sh   # если dist/Flake.dmg старый или нет
gh release create v1.4.0 dist/Flake.dmg -R ArturTonoyan/flake \
  --title "Flake 1.4.0" --notes "..."
```

Если релиз уже создан без файла:

```bash
gh release upload v1.4.0 dist/Flake.dmg -R ArturTonoyan/flake --clobber
```

## Частые косяки

1. **Забыл bump `CFBundleVersion`** — short version новая, а build тот же → путаница.
2. **Забыл `./scripts/make-dmg.sh`** — на GitHub улетает старый/пустой ассет, или релиз без DMG.
3. **Закоммитил, но не запушил тег** — `git push` без `git push origin vX.Y.Z` → на сайте тега нет.
4. **Запушил тег, но не создал Release** — тег на GitHub есть, а кнопки Download DMG нет (нужен именно GitHub Release + asset).
5. **Пересобрал код после тега** — тег уже указывает на старый коммит. Либо новый патч-релиз (`1.4.1`), либо (осторожно) пересоздать тег только если его ещё никто не скачал.
6. **Не смотри версию в `dist/` из прошлого раза** — всегда пересобирай DMG перед upload.

## Минимальный чеклист

- [ ] Правки кода готовы и работают локально
- [ ] `Info.plist`: short version + build (+1)
- [ ] `git commit` с сообщением `Release X.Y.Z: …`
- [ ] `git tag -a vX.Y.Z`
- [ ] `./scripts/make-dmg.sh` → свежий `dist/Flake.dmg`
- [ ] Версия внутри `.app` = X.Y.Z
- [ ] `git push` + `git push origin vX.Y.Z`
- [ ] `gh release create … dist/Flake.dmg`
- [ ] Открыл страницу релиза — DMG скачивается
