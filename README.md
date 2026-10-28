# LinkPlayer

Минималистичный нативный видеоплеер для macOS: открывает видео **по ссылке**
(прямые MP4/MOV/M4A и HLS `.m3u8`, поддерживаемые AVFoundation) и воспроизводит
его через системный `AVPlayer` со стандартными элементами управления.

- Стек: Swift, SwiftUI, AVKit/AVFoundation, AppKit. Без Electron/веба/Python.
- Данные (история, настройки) хранятся **только локально** в
  `~/Library/Application Support/LinkPlayer`. Никакой аналитики и телеметрии.
- URL обрабатывается как недоверенный ввод: схемы `file:`, `javascript:` и
  произвольные пользовательские схемы отклоняются; HTML-страницы сайтов не
  выдаются за медиапоток — вместо этого показывается понятная ошибка.

## Структура репозитория

```
Package.swift                 SwiftPM-манифест (Core + тесты; плейсхолдер app-таргета)
Sources/LinkPlayerCore/       Бизнес-логика, кроссплатформенная (Domain/Services/Infrastructure)
Sources/LinkPlayerApp/        Плейсхолдер исполняемого таргета (реальный код — ниже)
macOS/Sources/LinkPlayerApp/  Нативное приложение: SwiftUI UI, AVPlayerEngine, ViewModel'и
Tests/LinkPlayerCoreTests/    Unit- и интеграционные тесты (70 тестов)
Scripts/build_app.sh          Сборка самостоятельного LinkPlayer.app на macOS
docs/                         ARCHITECTURE, ADR, IMPLEMENTATION_PLAN, THREAT_MODEL
```

## Требования

- **macOS 13 Ventura или новее**, Apple Silicon (arm64) либо Intel.
- Xcode 15+ (или Command Line Tools со Swift 5.9+). Для Core-тестов достаточно
  любого Swift 5.9 toolchain (Linux тоже подходит).

## Запуск и сборка — пошагово

### 1. Логика и тесты (работают где угодно, включая Linux/CI)

```bash
swift build --target LinkPlayerCore   # компиляция бизнес-логики
swift test                            # unit + интеграционные тесты (~70)
```

Интеграционные тесты поднимают локальный HTTP-сервер (`python3`) и проверяют
валидацию, редиректы, 404/403 и fallback HEAD→GET без доступа в интернет.

### 2. Сборка LinkPlayer.app (только на macOS)

```bash
git clone <репозиторий> && cd LinkPlayer
chmod +x Scripts/build_app.sh
./Scripts/build_app.sh            # Debug
./Scripts/build_app.sh release    # Release
```

Скрипт компилирует Core + приложение одним `swiftc`, собирает
`build/LinkPlayer.app` (Info.plist, Resources), раскладывает ad-hoc подпись.
Xcode-проект создавать не нужно.

### 3. Запуск приложения

```bash
open build/LinkPlayer.app
# либо напрямую (видно логи):
build/LinkPlayer.app/Contents/MacOS/LinkPlayer
```

Приложение запускается **без Xcode** и без Homebrew/Python/Node — все
зависимости только системные фреймворки Apple.

### 4. Основной сценарий

1. Вставьте ссылку в поле на главном экране (⌘V, затем Return — или кнопка «Открыть»).
2. Приложение валидирует URL, резолвит редиректы и определяет тип ресурса.
3. Поддерживаемый медиапоток начинает воспроизводиться в `AVPlayerView`
   (play/pause, перемотка, громкость, полный экран — стандартные контролы macOS).
4. Открываемые ссылки попадают в локальную историю (меню «История»): повторное
   открытие, удаление записи, полная очистка.
5. Настройки (⌘,) : поведение при запуске, автозапуск, разрешение HTTP,
   громкость, приватность истории.

Тестовые прямые ссылки (проверяйте на своей машине):

- MP4: `https://download.blender.org/peach/bigbuckbunny_movies/BigBuckBunny_320x180.mp4`
- HLS: `https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8`

### 5. Подпись и notarization (для распространения)

Собранный `.app` подписан **ad-hoc** — этого достаточно для локального запуска,
но не для распространения. Для публикации:

```bash
codesign --force --deep --sign "Developer ID Application: Ваше Имя (TEAMID)" build/LinkPlayer.app
ditto -c -k --keepParent build/LinkPlayer.app LinkPlayer.zip
xcrun notarytool submit LinkPlayer.zip --keychain-profile yourprofile --wait
xcrun stapler staple build/LinkPlayer.app
spctl --assess --type execute build/LinkPlayer.app
```

Текущий статус: подпись Developer ID и notarization **не выполнялись**.

## Как это работает (под капотом)

Открытие ссылки проходит через конвейер, разделённый по слоям:

```
Ввод URL (SwiftUI)
   │
   ▼
MediaURLValidator ──── отклоняет пустой ввод, некорректные URL и схемы
   │                  file:, javascript:, data:, произвольные кастомные схемы;
   │                  HTTP запрещён, пока явно не разрешён в Настройках.
   ▼
URLResolver (HEAD → GET) ── резолвит редиректы (302/301), получает финальный
   │                       URL и Content-Type; таймауты и отмена операции.
   ▼
MediaKindDetector ──── определяет тип: mp4/mov/m4a, HLS (.m3u8), аудио — или
   │                  HTML-страница сайта (её мы не выдаём за медиапоток).
   ▼
PlaybackCoordinator (actor) ── машина состояний:
   │   idle → validating → loading → playing ⇄ paused → stopped/failed
   │   При открытии новой ссылки предыдущий ресурс всегда останавливается,
   │   а устаревшая сетевая задача отменяется (без гонок и зависаний).
   ▼
AVPlayerEngine (AVFoundation/AVKit) ── реальное воспроизведение системным
   │   AVPlayer; стандартный AVPlayerView даёт play/pause, перемотку,
   │   громкость, длительность/позицию и полный экран.
   ▼
HistoryManager ────── при успешном открытии запись добавляется в локальную
                       историю (MRU, дедупликация, лимит 50 записей).
```

Ключевые детали:

- **Валидация до сети.** Плохой URL отсекается ещё до сетевого запроса —
  понятная ошибка появляется мгновенно.
- **Редиректы.** Ссылки-сокращатели и CDN-редиректы отслеживаются до финального
  адреса; определяется его реальный тип контента.
- **Честные ошибки.** «Это HTML-страница, а не медиафайл», «ресурс недоступен
  (404/403)», «нет сети», «формат не поддерживается AVFoundation» — каждая
  ситуация имеет отдельное человеческое сообщение (`PlaybackError`).
- **История и настройки** лежат в `~/Library/Application Support/LinkPlayer`
  (JSON, атомарная запись). Из URL вырезаются фрагменты и чувствительные
  query-параметры (токены, пароли) — ничего не уходит на серверы.
- **Конкурентность.** Тяжёлая логика — в `actor`; UI ничего не блокирует,
  отмена операций поддержана (новая ссылка отменяет незавершённую старую).
- **Тестируемость.** `PlaybackCoordinator` принимает протоколы
  (`URLResolving`, `Playing`, `Recording`) — юнит-тесты работают на фейках,
  интеграционные поднимают локальный HTTP-сервер.

## Архитектура проекта

| Слой | Путь | Ответственность |
|---|---|---|
| Domain | `Sources/LinkPlayerCore/Domain/` | Валидация URL, определение типа медиа, ошибки воспроизведения |
| Services | `Sources/LinkPlayerCore/Services/` | Резолв URL (сеть), координация воспроизведения (state machine) |
| Infrastructure | `Sources/LinkPlayerCore/Infrastructure/` | Файловый JSON-стор, история, настройки |
| macOS UI | `macOS/Sources/LinkPlayerApp/` | SwiftUI-экраны, ViewModel'и, AVPlayerEngine, Settings, История |
| Tests | `Tests/LinkPlayerCoreTests/` | 70 unit + интеграционных тестов логики |

Core собран как SwiftPM-пакет и компилируется даже на Linux — поэтому бизнес-логику
можно тестировать в CI без macOS. UI-слой использует только нативные фреймворки Apple.

## Интерфейс и горячие клавиши

- Главный экран: поле URL, кнопка «Открыть», область `AVPlayerView`,
  индикатор загрузки, текст ошибки, пустое состояние («Вставьте ссылку…»).
- **Return / ⌘O** — открыть ссылку, **⌘V** — вставить из буфера,
  **⌘,** — настройки, пробел (в фокусе плеера) — play/pause, **⌘F** — полный экран.
- Меню «История»: последние ссылки, повторное открытие, удаление записи, очистка.
- Light/Dark Mode — автоматически, системная типографика, VoiceOver-метки.

## Известные ограничения

- Воспроизводятся только форматы/кодеки, которые поддерживает AVFoundation
  (MP4/HLS/AAC и т.п.). DRM-контент и страницы сайтов (YouTube и подобные)
  не поддерживаются и обходить ограничения мы не будем.
- Sandbox-среда разработки (Linux) не позволяет собрать и запустить сам .app —
  финальная проверка проигрывания выполняется на macOS.

Документация: `docs/ARCHITECTURE.md`, `docs/ADR.md`, `docs/IMPLEMENTATION_PLAN.md`,
`docs/THREAT_MODEL.md`.
