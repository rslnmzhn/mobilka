# mobilka roadmap

## Milestone M1 — Memory core (user/soul/memory)
- [ ] 1. Новые имена и стартовое содержимое файлов памяти: `user.md`, `soul.md`, `memory.md` (+ `personas.yaml` как конфиг персон).
- [ ] 2. Идемпотентная миграция legacy-имён (`user_profile`, `system_instructions`, `memory_log`) с `.migrated.bak` копиями; `project_context.md` выводится из схемы.
- [ ] 3. Инструмент `update_memory_file`: таргеты `user.md` (confirm-flow) и `memory.md` (мгновенная запись); `soul.md` недоступен модели.
- [ ] 4. Fast-path записи `memory.md` в координаторе стриминга, без proposal-диалога.

## Milestone M2 — Personas
- [ ] 5. `PersonaRegistry`: парсинг personas.yaml, персистентная активная персона, API list/switch/clear.
- [ ] 6. Инструменты `switch_persona` / `list_personas`: переключение по естественной просьбе пользователя в чате; оверлей накладывается поверх soul.md и не меняет его.
- [ ] 7. Сборка промпта: soul(фолбэк) → persona-overlay → user.

## Milestone M3 — Prompt hardening
- [ ] 8. `PromptGuard`: скан на prompt injection (маркер `[suspected-injection]`), вырезание YAML-frontmatter; без лимитов длины.

## Milestone M4 — Agent & UI
- [ ] 9. Новый системный промпт дефолтного агента (память, персоны через tools, docx-артефакты).
- [ ] 10. Memory-экран: файлы user/soul/memory + редактор personas.yaml.

## Milestone M5 — Shell polish
- [ ] 11. Нижняя панель и десктопный рельс: только иконки (подписи убраны), тултипы на десктопе.
- [ ] 12. Регресс-тесты шела на 320px без подписей.

## Milestone M6 — Validation
- [ ] 13. Полный analyze/test + обновление всех memory/fixture тестов под новые имена.
- [ ] 14. Ручная проверка владельцем: миграция старых файлов, /persona-запросы, запись в memory.md.
