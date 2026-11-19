# Расшифровка (Transcriber)

Приложение для macOS: локальная расшифровка голосовых и видео через whisper.cpp. Открытый
репозиторий, интерфейс на русском. Общайся с пользователем на русском.

## Ритуал

1. Прочитай [docs/STATUS.md](docs/STATUS.md) и [docs/DECISIONS.md](docs/DECISIONS.md).
2. Перед сменой подхода (аргументы whisper, форматы, раскладка окна) проверь DECISIONS.
3. После заметного шага перепиши STATUS и добавь D-NNN в DECISIONS.

## Карта

| Где | Что |
| --- | --- |
| `Sources/TranscriberCore/` | вся логика без UI: `Toolchain` (поиск программ и моделей), `WhisperRunner` (ffmpeg → whisper-cli, подсказка и словарь), `WhisperOutput` и `Cleanup` (разбор и чистка), `QualityCheck` (зацикливание, обрыв), `OutputFormat` (рендер форматов и запись файлов), `ModelCatalog` (каталог, загрузка с HuggingFace, SHA-256) |
| `Sources/Transcriber/` | SwiftUI: `AppModel` (очередь, история, выбранная модель), `ModelStore` (загрузки и удаление моделей), вьюхи, `DebugHooks` |
| `Tests/TranscriberCoreTests/` | тесты ядра |
| `scripts/build-app.sh` | сборка `.app`, `Resources/Info.plist` (типы документов для Дока и Finder) |
| [PRODUCT.md](PRODUCT.md), [DESIGN.md](DESIGN.md) | для кого приложение и как выглядит |

## Правила

- Логику кладём в `TranscriberCore` и покрываем тестами; в app-таргете только UI и связка.
- Внешние программы ищем по абсолютным путям (`Toolchain.binaryDirectories`): у приложений из
  Finder нет PATH из шелла.
- Файлы пользователя не перезаписываем (`OutputWriter.freeURL`).
- Новые фразы-галлюцинации добавляем в `Cleanup.hallucinations` вместе с тестом, что обычная речь с
  похожими словами не режется.
- UI не готов, пока не посмотрел на снимки окна (см. ниже).
- Репозиторий публичный: в коде, тестах, документах и скриншотах только выдуманные примеры, никаких
  настоящих записей, имён и путей пользователя. Демо-история: `TRANSCRIBER_SUPPORT_DIR=<папка>`.

## Команды

```bash
make test         # unit-тесты
make test-e2e     # + настоящий whisper-cli и скачивание с HuggingFace
make app          # dist/Расшифровка.app
make install      # в /Applications
```

`swift test` без Makefile не соберётся: в Command Line Tools у `_Testing_Foundation` нет модуля, в
Makefile для этого стоят `-F` к фреймворкам и `-disable-cross-import-overlays`.

## Снимки окна без разрешения на запись экрана

Запусти бинарник с `TRANSCRIBER_DEBUG=1`, команды шлются через distributed notification
`local.transcriber.debug` со строкой в `object`: `snapshot:<папка>`, `select:<индекс>`,
`settings[:models]`, `appearance:dark|light`, `timestamps:on|off`, `size:<ш>x<в>`, `dump:<файл>`,
`download:<файл модели>`. Снимок
`*-ws.png` настоящий (через window server), обычный `*.png` не видит стекло сайдбара.

## Куда записывать

| Что | Куда |
| --- | --- |
| Решение | `docs/DECISIONS.md` |
| Закончили шаг | `docs/STATUS.md`, переписать |
| Поменялся вид | `DESIGN.md` |
