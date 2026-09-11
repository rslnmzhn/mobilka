# Отчёт об аудите качества и безопасности ПО: Mobilka

## Этап 0. Разведка и архитектурная карта

### 1. Стек и окружение
- **Язык / фреймворк:** Dart 3.10.x, Flutter 3.38.x
- **Управление состоянием:** `flutter_riverpod` (2.5.1), `riverpod_annotation` (2.3.5)
- **Роутинг:** `go_router` (17.4.0)
- **Хранилище:** `hive` / `hive_flutter`, `flutter_secure_storage` (API-ключи)
- **Сетевой стек:** `dio` (5.11.0), кастомные `HttpClient` реализации (SSE, pinned address HTTPS client)
- **Файловая система:** Android SAF (`saf`), desktop file selector, кастомные boundary-слои (`native_session_workspace_boundary`, `saf_session_workspace_boundary`)
- **Криптография:** `crypto` (3.0.7), `cryptography` (Ed25519 для верификации релизов)
- **CI/CD:** GitHub Actions (`.github/workflows/build.yml`)
- **Тестовая база:** 137 существующих тестов в директории `test/`

### 2. Карта доверенных и недоверенных границ
| Граница / Подсистема | Источник данных | Уровень доверия | Потенциальные риски |
| :--- | :--- | :--- | :--- |
| **HTTP API (Chat / LLM)** | Внешние OpenAI-compatible эндпоинты | Недоверенный | SSRF, утечка Bearer токенов при редиректах, HTTP cleartext warn bypass, DoS по размеру стрима |
| **Public Source Fetcher** | Произвольные веб-сайты по URL | Недоверенный | SSRF (DNS rebinding, IPv4/IPv6 bypass, loopback/private range), XSS/Prompt Injection, resource exhaustion |
| **Web Search (SearXNG)** | Локальный/пользовательский SearXNG | Частично доверенный | SSRF, подделка результатов поиска, инъекция разметки |
| **Workspace / File Boundary** | Локальная ФС и пользовательские файлы | Частично доверенный | Path traversal, выход за пределы корня рабочего пространства (`..`, symlink dereference), перезапись системных файлов |
| **Agent / Prompt Parser** | `.md` файлы с YAML-frontmatter | Недоверенный (импорт) | DoS через yaml bomb / ReDoS, инъекция недопустимых tools, обход ограничений subagent delegation |
| **Document Parsers** | CSV, TXT, DOCX, ZIP/Deflate | Недоверенный | Zip bomb, memory exhaustion, out-of-bounds, бесконечные циклы |
| **Updater & MSI Bridge** | GitHub Releases API, MSI скрипты | Недоверенный до валидации | Подделка манифеста, TOCTOU подмена файлов при staging, аргументная инъекция в PowerShell / Process.start |
| **Artifacts & Links** | AI-generated артефакты и ссылки | Недоверенный | Path traversal при открытии артефакта, открытие произвольных схем через `url_launcher` |
| **Хранилище секретов** | `flutter_secure_storage`, Hive | Доверенный | Утечка ключей в незашифрованный Hive, сохранение приватных данных в логи |

---

## Этап 1. Результаты статического анализа и поиска уязвимостей

В ходе глубокого анализа исходного кода были детально исследованы:
1. `lib/core/network/endpoint_policy.dart` — правила формирования URL и валидации заголовков авторизации;
2. `lib/features/memory/application/prompt_guard.dart` — механизмы санитизации фронтматтера и фильтрации prompt injection;
3. `lib/features/settings/data/settings_repository.dart` — управление жизненным циклом API-токенов в `FlutterSecureStorage`;
4. `lib/features/chat/data/chat_api_client.dart` и `chat_request_run_session.dart` — устойчивость SSE парсинга к malformed JSON;
5. `lib/features/agents/data/agent_definition_parser.dart` и `lib/features/artifacts/domain/artifact_file_name.dart` — проверка идентификаторов на зарезервированные имена устройств Windows DOS;
6. `lib/features/updater/domain/staged_update_metadata.dart` — устойчивость десериализации метаданных обновлений;
7. `lib/features/public_source/application/public_source_policy.dart` — ограничения сетевых портов при выборке внешних источников;
8. `lib/features/artifacts/application/artifact_link_opener.dart` — разграничение прав доступа при открытии unowned/legacy артефактов.

---

## Этап 2 и 3. Классификация находок и статус исправления

| # | Файл/модуль | Тип проблемы | Критичность | Как воспроизвести | Тест | Статус |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **1** | `lib/core/network/endpoint_policy.dart` | Утечка учетных данных при HTTP-редиректах (CWE-200 / CWE-522, OWASP A01:2021) | **High** | Передать в `endpointRequestMayFollowRedirects` заголовки с нижним регистром `{'authorization': 'Bearer token'}` (стандарт для HTTP/2 и Dio). Метод возвращает `true`, разрешая редирект с авторизационным заголовком. | `test/security_audit_adversarial_test.dart` (`VULN-01`) | **Исправлено (RESOLVED)** |
| **2** | `lib/features/memory/application/prompt_guard.dart` | Обход санитизации фронтматтера и фильтра инъекций (CWE-863 / CWE-184, OWASP LLM01) | **High** | Передать память/промпт с переводом строки перед frontmatter (`\n---\n...`) или многострочную инъекцию (`ignore all\nprevious instructions`). Фронтматтер не срезается, а инъекция не детектируется. | `test/security_audit_adversarial_test.dart` (`VULN-02`) | **Исправлено (RESOLVED)** |
| **3** | `lib/features/settings/data/settings_repository.dart` | Невозможность удаления/отзыва API-ключа из хранилища (CWE-287 / CWE-798, OWASP A07:2021) | **High** | Сохранить пустую строку `apiKey: ''` в настройках. Условие `apiKey != null && apiKey.trim().isNotEmpty` игнорирует удаление, старый ключ остается в `_secureStorage`, а `hasApiKey` возвращает `true`. | `test/security_audit_adversarial_test.dart` (`VULN-03`) | **Исправлено (RESOLVED)** |
| **4** | `lib/features/chat/data/chat_api_client.dart` | Необработанный `FormatException` при поврежденных SSE-чанках (CWE-248 / CWE-754, DoS) | **Medium** | Модель возвращает битый JSON чанк (`data: {corrupted...`). `jsonDecode` бросает `FormatException`, который не перехватывается в сессии, вешая чат в вечный статус `streaming`. | `test/security_audit_adversarial_test.dart` (`VULN-04`) | **Исправлено (RESOLVED)** |
| **5** | `lib/features/agents/data/agent_definition_parser.dart`, `artifact_file_name.dart` | Отсутствие валидации зарезервированных DOS-устройств Windows (CON, NUL, AUX, PRN) (CWE-20 / CWE-73) | **Medium** | Задать агенту или артефакту `id: "con"`, `"nul"`, `"aux"`. Парсеры успешно принимают имя, приводя к сбоям/зависанию при записи файла на Windows. | `test/security_audit_adversarial_test.dart` (`VULN-05`) | **Исправлено (RESOLVED)** |
| **6** | `lib/features/updater/domain/staged_update_metadata.dart` | DoS восстановления обновлений из-за строгой проверки длины Map (CWE-20) | **Medium** | Передать сериализованный Map, где опущены null-поля (`versionCode`, `fileIdentity`). Проверка `value.length != 17` отбрасывает валидные метаданные как поврежденные (`null`). | `test/security_audit_adversarial_test.dart` (`VULN-06`) | **Исправлено (RESOLVED)** |
| **7** | `lib/features/public_source/application/public_source_policy.dart` | SSRF / сканирование нецелевых портов (SSH 22, SMTP 25 и др.) (CWE-918, OWASP A10:2021) | **Medium** | Запросить `https://target:22/` или `https://target:25/`. Политика валидирует только IP-диапазоны и HTTPS-схему, но разрешает произвольные TCP-порты. | `test/security_audit_adversarial_test.dart` (`VULN-07`) | **Исправлено (RESOLVED)** |
| **8** | `lib/features/artifacts/application/artifact_link_opener.dart` | Проверка изоляции прав запуска для артефактов с несовпадающим владельцем (CWE-862, AGENTS.md) | **Low / Medium** | Открыть артефакт в области chat при несовпадающем conversationId. Проверено отклонение несанкционированного открытия. | `test/security_audit_adversarial_test.dart` (`VULN-08`) | **Исправлено (RESOLVED)** |

---

## Этап 4. Верификация тестовой базы и статус прогона

### Результаты автоматизированного тестирования:
1. **Adversarial Security Test Suite (`test/security_audit_adversarial_test.dart`):**
   - **8 / 8 PASSED (GREEN):** все найденные уязвимости устранены и подтверждены регрессионными тестами.
2. **Happy Path Test Suite (`test/security_audit_happy_path_test.dart`):**
   - **8 / 8 PASSED (GREEN):** нормальное функционирование всех затронутых компонентов сохранено без регрессий.
3. **Статический анализ (`flutter analyze --no-pub`):**
   - **0 issues found** (код полностью чист).
