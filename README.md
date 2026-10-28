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

## Известные ограничения

- Воспроизводятся только форматы/кодеки, которые поддерживает AVFoundation
  (MP4/HLS/AAC и т.п.). DRM-контент и страницы сайтов (YouTube и подобные)
  не поддерживаются и обходить ограничения мы не будем.
- Sandbox-среда разработки (Linux) не позволяет собрать и запустить сам .app —
  финальная проверка проигрывания выполняется на macOS.

Документация: `docs/ARCHITECTURE.md`, `docs/ADR.md`, `docs/IMPLEMENTATION_PLAN.md`,
`docs/THREAT_MODEL.md`.
