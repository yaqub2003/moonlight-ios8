# Moonlight для iOS 8

Порт современного [Moonlight iOS](https://github.com/moonlight-stream/moonlight-ios)
(9.x, с поддержкой Sunshine/Apollo) на старые устройства с **iOS 8.0+**, включая
32-битные (armv7): iPad 2/3/4, iPad mini 1, iPhone 4S/5/5c, iPod touch 5.

Старые сборки Moonlight 2.x, которые ещё ставятся на iOS 8, используют устаревший
протокол GameStream и не работают с Sunshine/Apollo. Здесь взят свежий код
(сетевой протокол `moonlight-common-c`, спаривание, обнаружение хостов) и
адаптирован под iOS 8.

## Что изменено по сравнению с upstream

| Что | Почему | Как |
| --- | --- | --- |
| Сборка без Xcode, на Linux | Xcode 14+ не умеет ни iOS 8, ни armv7 | `clang` + iOS 14.5 SDK + `ld64` из cctools-port, см. `build.sh` |
| Сториборды заменены кодом | `ibtool` есть только на macOS и не делает nib для iOS 8 | `AppDelegate`, `MainFrameViewController`, `SettingsViewController`, `LoadingFrameViewController` строят UI сами |
| Модель Core Data в коде | `momc` есть только на macOS | `Limelight/Database/MoonlightModel.{h,m}` |
| Asset catalog → PNG | `actool` есть только на macOS | `tools/flatten_assets.py`, PDF-иконки заранее отрендерены в `Resources/` |
| Звук: SDL2 → AudioQueue | SDL2 не поддерживает iOS 8/armv7 | `Limelight/Stream/Connection.m` |
| Только H.264 | HEVC — iOS 11 + A9, AV1 — A17; FFmpeg был нужен только для AV1 | `VideoDecoderRenderer.m`, `MainFrameViewController.m` |
| Без HDR, 120 FPS, мыши Citrix X1, вибрации геймпада | Нет на устройствах с iOS 8 / X1Kit написан на Swift / CoreHaptics — iOS 13+ | Пункты в настройках отключены |
| Шифрование видео на armv7 выключено | У 32-битных чипов нет аппаратного AES | Шифруется только звук (как в Moonlight на других платформах без AES) |
| `clock_gettime_nsec_np` (iOS 10) | Приложение упало бы при запуске | `compat/moonlight-common-ios8.h` |
| Проверки `@available` | Нет `libclang_rt.ios.a` в Linux-тулчейне | `Limelight/Utility/AvailabilityRuntime.m` |

При сборке:
* весь код компилируется с `-Werror=unguarded-availability` против iOS 8.0 — любое
  неохраняемое использование API новее iOS 8 ломает сборку;
* `tools/check_symbols.py` проверяет, что все не-weak импорты бинарника есть в
  iOS 9.3 SDK (иначе dyld не запустит приложение).

## Как получить IPA

### Через GitHub Actions (проще всего)

Каждый push запускает workflow **iOS 8 build**. Готовый `Moonlight-iOS8.ipa`
лежит в артефактах запуска (Actions → нужный запуск → Artifacts).

### Локально (Linux, например Ubuntu 24.04)

```bash
sudo apt-get install clang lld llvm cmake ninja-build make perl python3 zip libssl-dev uuid-dev libxml2-dev zlib1g-dev libplist-dev pkg-config
```

```bash
git submodule update --init --recursive
```

```bash
ios8/build.sh
```

Результат: `ios8/build/Moonlight-iOS8.ipa`. Отдельные шаги: `ios8/build.sh sdk toolchain deps app ipa`.

## Установка на устройство

IPA подписан фиктивной (ad-hoc) подписью через `ldid`, как это принято для джейлбрейка.
Bundle ID — `com.moonlight-stream.Moonlight.ios8`, так что приложение ставится рядом
с Moonlight 2.x из App Store и не заменяет его.

* **С джейлбрейком и AppSync Unified:** откройте IPA в Filza и нажмите Install.
* **Без джейлбрейка:** через инструмент для sideload с бесплатным Apple ID
  (например, [Sideloadly](https://sideloadly.io/); поддержка старых iOS у разных
  инструментов разная) — он заменит подпись на настоящую. Подпись бесплатного
  аккаунта действует 7 дней. Свой Bundle ID можно задать при сборке:
  `BUNDLE_ID=com.example.moonlight ios8/build.sh`.

## Настройка

* Sunshine/Apollo: добавьте ПК вручную по IP (кнопка «+»), если он не нашёлся сам,
  и введите PIN в веб-интерфейсе Sunshine/Apollo.
* Рекомендуемые параметры для iPad 2/3/mini 1: **720p, 30–60 FPS, 5–10 Мбит/с**.
  Аппаратный декодер A5/A6 рассчитан на 1080p, но 720p стабильнее.
* Кодек на хосте должен быть H.264 (Moonlight сам запросит только его).

## Известные ограничения

* Не проверено на всех устройствах; если что-то не работает — пришлите лог
  (Настройки → Конфиденциальность → Диагностика или вывод Xcode/`idevicesyslog`).
* Проект `Moonlight.xcodeproj` в этом форке не поддерживается — сборка только через `ios8/build.sh`.
