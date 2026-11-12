## API

```dart
Corlex.track('purchase', {'plan': 'pro', 'amount': 12.5});
Corlex.identify('user_42', {'plan': 'pro'});          // склеивает анонимного пользователя с вашим id
Corlex.setUserProperties({'locale': 'ru'});
Corlex.screen('/settings');                             // вручную; обычно хватает CorlexNavigatorObserver

// Remote Config и A/B
final days = Corlex.config.get('free_trial_days', 7);   // тип значения по умолчанию = тип параметра
final show = Corlex.flag('show_new_checkout', false);   // то же, для скаляров
final all = Corlex.config.getAll();
await Corlex.config.ready();                            // дождаться загрузки этого запуска (до configTimeout)
await Corlex.config.refresh();
final off = Corlex.config.onUpdate((u) => print(u.applied)); // off() — отписаться
final variant = Corlex.experiment('onboarding_test');   // null, пока тест не идёт; чтение = экспозиция

Corlex.recordError(error, stack);                       // ошибка из вашего try/catch или runZonedGuarded
Corlex.reset();                                         // выход из аккаунта: новый анонимный id
await Corlex.flush();
Corlex.optIn(); Corlex.optOut(); Corlex.consent;
```

- Имя события: 1–128 символов `[a-z0-9_.:-]`, префикс `corlex.` зарезервирован. Свойства: до 100 ключей, строки до 1024 байт, вложенность до 4 уровней; лишнее обрезается (`lib/src/properties.dart`).
- **Каждое событие** несёт `context.platform` = `ios` или `android` (не `flutter`, см. ниже), `os`, `os_version`, `device_model`, `locale`, `app_version`, `sdk` = `corlex-flutter`/версия, и свойства `build` (`CFBundleVersion` / `versionCode`; значение SDK, приложение его не подменит) и `framework: "flutter"`.
- Remote Config считается на устройстве по тем же правилам, что у остальных SDK (`packages/domain/test-vectors/remote-config.json`, тест `test/vectors_test.dart` читает этот файл из монорепозитория). Переопределение для платформы `flutter` в Corlex сильнее переопределения `ios`/`android`.

### Экраны

```dart
MaterialApp(
  navigatorObservers: [CorlexNavigatorObserver()],   // go_router: GoRouter(observers: [...])
  onGenerateRoute: (settings) => MaterialPageRoute(settings: settings, builder: ...),
);
```

Читается только **имя** маршрута (`RouteSettings.name`), аргументы не читаются никогда. Называйте маршруты шаблоном (`/product/:id`; go_router делает это сам). Сегменты из цифр, UUID и длинных hex-строк заменяются на `[id]`, query и `#` отрезаются. Диалоги и нижние листы не экраны. Маршруты без имени пропускаются. Событие `screen_view`: `screen`, `source` (`navigator` или `manual`), `previous_screen`.

### Согласие

`consent: StartConsent.pending` не отправляет запросы и не сохраняет события, идентификатор или конфиг. До 1000 событий могут ожидать в памяти; выбор согласия и его поколение хранятся отдельно как служебные сведения приватности. `Corlex.optIn()` разрешает отправку. `optOut()` сразу останавливает Dart-запросы; нативный общий запрет и очистка очереди, id, конфига и непосланных крашей выполняются при обработке MethodChannel. `await Corlex.flush()` дожидается очереди операций согласия. При ошибке записи нативный запрет остаётся действующим в текущем процессе; сохранение отказа после аварийного завершения при недоступном диске гарантировать нельзя. Только явное новое согласие может запустить свежую сессию без старых данных. `StartConsent.att` на iOS читает статус App Tracking Transparency (`notDetermined` — молчит, `authorized` — работает, `denied` и `restricted` — молчит) и перечитывает его при возврате в приложение; запрос ATT SDK не показывает, IDFA не читает. На Android `att` — то же, что `granted`. Правила для всех SDK: `services/ingest/docs/protocol.md`, §4.1. Манифест приватности (`PrivacyInfo.xcprivacy`) входит в плагин.


## Semantics

Event names use 1–128 characters from a-z, 0-9, underscore, dot, colon and hyphen. Do not build names/screens from user input. Properties are bounded/sanitized JSON; an individual event is limited to 32 KiB. identify links an internal application ID, not a hardware/advertising identifier. reset creates a fresh anonymous identity without relabeling queued history. Remote Config defaults are returned when a value is absent/inapplicable; listing config is not an experiment exposure.
