# AGENTS.md

## Project
name: mobilka
build: flutter build apk
test: flutter test
lint: flutter analyze
format: dart format .

## Architecture rules
- Flutter client architecture with Riverpod state management (`flutter_riverpod`, `riverpod_annotation`) and GoRouter.
- The current product slice supports remote OpenAI-compatible endpoints only; retain the future architecture path for other remote providers, with no local LLMs or embeddings on device.
- OpenAI-compatible endpoints may use explicitly user-configured HTTP or HTTPS; send bearer API keys using the configured scheme.
- Automatic HTTP redirects must remain disabled whenever an `Authorization` header is present to prevent credential forwarding.
- Hermes-style `.md` memory architecture is stored in the app sandbox or a user-chosen external folder, using an Android SAF package on Android and `file_selector` on desktop.
- Manual edits, tool updates, and restores share an app-private Hive recovery journal and a single location transaction coordinator for memory mutations.
- Context injection performs pending-memory recovery before taking one atomic snapshot of the selected memory files.
- Current local persistence is Hive for chat history, favorites, model cache, and artifacts; retain Isar as a future architecture option and use `flutter_secure_storage` for API keys.
- Agent catalog/controller state owns active-agent selection and user-authored agent files in the app sandbox.
- The chat application separates model/catalog state in the catalog controller from request streaming lifecycle in the streaming coordinator.
- Streaming coordination is bound to immutable conversation, request, and assistant-message IDs rather than mutable active-chat state.
- UI paradigm: Streaming chat with collapsible tool-calling cards, theme presets, and slide-up bottom sheets for artifacts, memory files, and tool execution logs.
- Current targets are Android, Windows, and Linux; iOS and macOS are future targets.
- Android application ID is `com.rslnmzhn.mobilka` and minimum SDK is 29.

## Project structure
- `lib/`: Main Flutter codebase directory.
- `lib/core/`: Core utilities, HTTP clients, storage (Isar/Hive, secure storage).
- `lib/features/`: Feature modules (chat, memory, settings, artifacts, models, agents).
- `assets/agents/`: Default `.md` agent and subagent prompt templates.
- `roadmap.md`: Authoritative implementation checklist.
- `guide.md`: Architectural specification and future architecture guidance.

## Business rules
- Memory stored in human-readable Markdown files (`user_profile.md`, `project_context.md`, `system_instructions.md`, `memory_log.md`).
- `memory_log.md` is a human-readable audit mirror; the app-private Hive journal is the recovery authority.
- Context Injector must prepend `.md` memory files and active Agent system prompts into System Prompt before sending requests.
- Agents update memory via `update_memory_file` tool calls.
- User retains 100% full control and manual editing capabilities over memory files and agent prompt files.
- Agents use dynamically discovered structured `.md` definitions whose frontmatter declares identity, primary/subagent mode, model preference, subagents, and tools; users can create, import, edit, and select them.
- Subagent delegation has bounded depth and does not mutate parent conversation history or memory.
- OpenAI-compatible model discovery uses `/v1/models`; settings support model search, visibility, and favorites, while chat provides quick model selection.
- Persist conversations, messages, and request lifecycle state in Hive before issuing network requests.
- SSE completion requires an explicit terminal event; a stream that closes prematurely remains interrupted and retryable.
- Token usage is owned by the `Conversation` domain model.
- Android backups remain disabled because chat history is unencrypted local data.

## Brand and design
- Mobile-first adaptive UI with dark theme priority and customizable theme presets.
- Theme presets include Claude, Dark Cyber, Midnight OLED, Solarized, Nord, and Classic; every preset provides both light and dark variants.
- UI supports Russian and English localization through `easy_localization`.
- Use a high-contrast adaptive layout with smooth animations and haptic interaction feedback.
- Visibly warn users that HTTP endpoints expose API keys, prompts, and responses in transit.
- Bottom Sheets (`sliding_up_panel` / `showModalBottomSheet`) for artifacts, memory management, and execution logs.
- Markdown rendering via `gpt_markdown` / `flutter_markdown` with syntax highlighting (`flutter_highlight`).
- Stream tokens in real time with auto-scroll and isolated message repainting; show tool calls as collapsible status/input/output cards within messages.
- Artifacts use a tabbed bottom sheet for code, documents, rendered previews, and execution logs.

## Code conventions
- Dart 3.x with Riverpod code generation (`riverpod_annotation`).
- Run code generation with `dart run build_runner build --delete-conflicting-outputs`.
- The Riverpod generator stack is pinned as a compatible set for Flutter 3.38/Dart 3.10; migrate all related packages together later.
- Strict separation of core services, state providers, and UI presentation widgets.
- Async HTTP/SSE streaming (`stream: true`) for real-time model outputs.
- After every implemented feature, fix, or architecture change, immediately update `roadmap.md`: mark only implemented and verified items complete, add newly discovered work as unchecked items, and never count metadata-only maintenance as product roadmap progress.
- Git workflow: Develop each roadmap milestone on its own `milestone/<number>-<slug>` branch created from `main`.
- Give each completed and verified roadmap item within a milestone its own focused commit; never mark environment-blocked items complete.
- After every item in a milestone is complete and verified, push the milestone branch, merge it into `main` without rewriting history, and push `main` before starting the next milestone.
- Never commit secrets, generated output, or local artifacts; inspect and stage only intended files.
- Remote Git operations require a configured remote and explicit user authorization under the current agent policy.

## Agent registry
| agent | mode | role |
|-------|------|------|
| reasoning-builder | primary | classify task, invoke only needed subagents, proportional verification |
| lite-builder | primary | focused feature/fix/refactor with review loop |
| god-builder | primary | full-suite build with all scanners |
| prompt-classifier | subagent | classify prompt, task list, subagent and verification plan |
| context-assembler | subagent | git + project context snapshot |
| terminal-runner | subagent | safe command execution |
| test-runner | subagent | test execution and structured reporting |
| quick-reviewer | subagent | anti-pattern review, 3-attempt loop |
| skill-finder | subagent | remote skill search and local install into ./skills |
| agents-keeper | subagent | AGENTS.md maintenance |
| dead-code-scanner | subagent | unused exports and functions |
| security-scanner | subagent | secrets and unsafe patterns |
| dependency-auditor| subagent | outdated and vulnerable dependencies |
| complexity-checker| subagent | cyclomatic complexity and nesting hotspots |

## Known patterns
- DOCX generation fallback: Use template fallback / Markdown converting for complex document formatting.
- Background execution: Save chat state to Isar/Hive before API request, use Android Foreground Service for long tasks, handle SSE connection drops and auto-resume.
- Tool Calling Fallback Parser: Scan raw Markdown JSON blocks if model fails native tool_calls API.
- File sharing: Use `open_file_plus`/`share_plus` and Android `FileProvider` / iOS security-scoped URLs.
- Vision OOM prevention: Downscale/compress images before base64 encoding and transmission.
- Memory mutation serialization: Route manual edits, tool updates, and restores through the shared location transaction coordinator rather than independent file locks.

## Blocked items
- none
