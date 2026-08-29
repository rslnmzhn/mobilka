# AGENTS.md

## Project
name: mobilka
build: flutter build apk
test: flutter test
lint: flutter analyze
format: dart format .

## Architecture rules
- Flutter client architecture with Riverpod state management (`flutter_riverpod`, `riverpod_annotation`) and GoRouter.
- The current product slice supports remote OpenAI-compatible endpoints only; retain the future architecture path for other remote providers, with no local model execution on device.
- OpenAI-compatible endpoints may use explicitly user-configured HTTP or HTTPS; send bearer API keys using the configured scheme.
- Automatic HTTP redirects must remain disabled whenever an `Authorization` header is present to prevent credential forwarding.
- Public-source reads have a persisted fail-closed 8 MiB wire-byte budget per conversation; successful source reads taint only the current request and centrally require explicit confirmation before later mutating/sensitive tools.
- Public-source reading uses only its dedicated direct HTTPS client: validate every resolved address and redirect, pin the connection to validated addresses, send no credentials or chat data, accept bounded text/raw HTML only, and pass returned chunks through PromptGuard.
- RLM Markdown memory is the sole context-memory architecture; no RAG, vector, or embeddings path is planned. Here, RLM means deterministic selected human-readable `.md` files injected as one atomic snapshot, manually managed by the user or updated by agents only after explicit user confirmation.
- RLM Markdown memory is stored in the app sandbox or a user-chosen external folder, using an Android SAF package on Android and `file_selector` on desktop.
- Manual edits, tool updates, and restores share an app-private Hive recovery journal and a single location transaction coordinator for memory mutations.
- Context injection performs pending-memory recovery before taking one atomic snapshot of the selected memory files.
- Current local persistence is Hive for chat history, favorites, model cache, and artifacts; retain Isar as a future architecture option and use `flutter_secure_storage` for API keys.
- Agent catalog/controller state owns active-agent selection and user-authored agent files in the app sandbox.
- Personas are presented under Agents, while the memory domain remains the owner of `personas.yaml` and its mutation safety.
- Chat / Advanced Coding mode and a separate coding-agent catalog are future architecture, not current product behavior.
- The chat application separates model/catalog state in the catalog controller from request streaming lifecycle in the streaming coordinator.
- Streaming coordination is bound to immutable conversation, request, and assistant-message IDs rather than mutable active-chat state.
- UI paradigm: Streaming chat with collapsible tool-calling cards, theme presets, and slide-up bottom sheets for artifacts, memory files, and tool execution logs.
- Current targets are Android, Windows, and Linux; iOS and macOS are future targets.
- Android application ID is `com.rslnmzhn.mobilka` and minimum SDK is 29.
- Updater discovery uses the latest stable GitHub Release and accepts only the canonical release manifest after Ed25519 verification with pinned public key `nH/Hnmn7UJtCy4Qb91c9dIAwQ3LSUkv6yRhDhMlZ3JY=`; selected assets are then size- and SHA-256-verified before staging.
- Automatic update application is limited to Android APKs and provenance-verified, per-machine MSI-installed Windows; Windows ZIP, Linux ZIP, and AppImage distributions are manual-update-only.

## Project structure
- `lib/`: Main Flutter codebase directory.
- `lib/core/`: Core utilities, HTTP clients, storage (Isar/Hive, secure storage).
- `lib/features/`: Feature modules (chat, memory, settings, artifacts, models, agents).
- `lib/features/updater/`: Signed-manifest discovery, verified download staging, platform eligibility, and Android/MSI installation bridges.
- `assets/agents/`: Default `.md` agent and subagent prompt templates.
- `.github/workflows/build.yml`: Quality, platform packaging, signing, manifest generation, and stable GitHub Release publication workflow.
- `roadmap.md`: Authoritative implementation checklist.
- `guide.md`: Architectural specification and future architecture guidance.

## Business rules
- RLM Markdown memory uses the current human-readable files `user.md`, `soul.md`, `memory.md`, and `personas.yaml`; the app-private Hive journal is the recovery authority for coordinated mutations.
- Context Injector must deterministically prepend one atomic snapshot of the selected `.md` memory files and active Agent system prompts into System Prompt before sending requests.
- Native `update_memory_file` proposals must target approved filenames, persist the exact diff plus permission snapshot, require explicit confirm or reject, and revalidate current permissions before mutation.
- User retains 100% full control and manual editing capabilities over memory files and agent prompt files.
- Post-success skill learning is request-scoped and bounded to one stable reusable procedure. New trusted-local skills may be create-if-absent automatically; public-source-derived creates and every overwrite require persisted exact confirmation. Re-read and hash-check existing content at confirmation so manual edits are never overwritten.
- Agents use dynamically discovered structured `.md` definitions whose frontmatter declares identity, primary/subagent mode, model preference, subagents, and tools; users can create, import, edit, and select them.
- Subagent delegation has bounded depth and does not mutate parent conversation history or memory.
- OpenAI-compatible model discovery uses `/v1/models`; settings support model search, visibility, and favorites, while chat provides quick model selection.
- Chat provides a searchable model picker and new-chat action.
- Persist conversations, messages, and request lifecycle state in Hive before issuing network requests.
- SSE completion requires an explicit terminal event; a stream that closes prematurely remains interrupted and retryable.
- Token usage is owned by the `Conversation` domain model.
- Chat artifacts are immutably owned by their originating conversation ID and stable session key. Legacy ownerless artifacts remain global/unowned only; never infer ownership. Conversation deletion retains artifacts.
- Artifact representation types and sizes are derived from actual app-private files. A chat artifact may also have its existing session-workspace mirror; do not create a third copy or scan sessions/workspaces to build the global catalog.
- Android backups remain disabled because chat history is unencrypted local data.
- Android release APKs must have the sole signer SHA-256 fingerprint `4A:76:9B:92:8D:47:82:77:30:E3:C5:E1:5A:E3:86:5C:D8:B8:99:93:13:A3:E5:79:BA:A9:B7:34:56:46:55:CD`.
- Windows auto-update requires the MSI signer SHA-256 fingerprint `84EFAEE8B51EF463E312FC90D8B86613739961F11B0C6582B472BB3845D21BA4`, the expected per-machine `HKLM\Software\mobilka` marker/UpgradeCode, and an executable inside the recorded install location; portable or unknown installs are ineligible.

## Brand and design
- Product identity is mobilka; UI marks use lowercase `m` or uppercase `MOBILKA`, with no Hermes or Odysseus branding.
- mobilka Workbench is the default visual language; all existing theme presets remain supported.
- Use warm paper, clay, and ink surfaces in light mode, and charcoal and ink surfaces in dark mode.
- Favor fine technical dividers, clear editorial hierarchy, and compact desktop density.
- Use a custom adaptive shell with a bottom dock on phones and side navigation on desktop; on narrow screens only the exact `/chat` root defaults to a collapsed, explicitly revealable dock.
- Avoid generic default Material/MUI appearance, glassmorphism, decorative gradients, and network fonts.
- Require responsive, overflow-free behavior at 320px and desktop widths; memory Open and Edit actions must remain independently visible.
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
- On a physical keyboard, Enter sends and Shift+Enter inserts a newline.
- Run code generation with `dart run build_runner build --delete-conflicting-outputs`.
- The Riverpod generator stack is pinned as a compatible set for Flutter 3.38/Dart 3.10; migrate all related packages together later.
- Strict separation of core services, state providers, and UI presentation widgets.
- Async HTTP/SSE streaming (`stream: true`) for real-time model outputs.
- After every implemented feature, fix, or architecture change, immediately update `roadmap.md`: mark only implemented and verified items complete, add newly discovered work as unchecked items, and never count metadata-only maintenance as product roadmap progress.
- Git workflow: Develop work on its feature branch or, for roadmap milestones, a `milestone/<number>-<slug>` branch created from `main`.
- After every completed and verified feature or fix, create a focused commit on its feature/milestone branch; never mark environment-blocked or manually unverified items complete.
- When remote operations are authorized, push that feature/milestone branch, merge it into `main` without rewriting history, and push `main` after each completed feature or fix; this is the expected sequence and does not require the user to repeat it for each item.
- Never commit secrets, generated output, or local artifacts; inspect and stage only intended files.
- Remote Git operations require a configured remote and explicit user authorization under the current agent policy; the user's current request authorizes the current remote sequence only, not future remote sequences.
- Report automated verification separately from manual device checks, and never claim a manual device check is complete unless it was actually performed.
- Release signing secrets are named `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`, `WINDOWS_CERTIFICATE_BASE64`, `WINDOWS_CERTIFICATE_PASSWORD`, and `UPDATE_MANIFEST_PRIVATE_KEY`; never store or print their values.
- Release workflow tooling uses `.github/scripts/resolve_release_version.sh`, `apply_release_version.sh`, `verify_android_release.sh`, `package_linux_appimage.sh`, `package_windows_msi.ps1`, `generate_release_manifest.sh`, and `sign_release_manifest.sh`; local MSI validation runs `flutter build windows --release`, `dotnet tool install --global wix --version 5.0.2`, then `.github/scripts/package_windows_msi.ps1 -Version <version>`.

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
