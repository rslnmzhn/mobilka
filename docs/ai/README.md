# AI contributor entry point

This directory is the compact orientation layer for agents working on mobilka.
It documents the implemented runtime, not every roadmap proposal. Start here,
then read [architecture.md](architecture.md) and [tools.md](tools.md) only as
needed.

## Source precedence

When sources disagree, use this order:

1. Runtime code and tests are the authority for current behavior.
2. Root [AGENTS.md](../../AGENTS.md) contains durable project constraints.
3. [roadmap.md](../../roadmap.md) records completion and future intent.
4. These AI docs summarize the above and must be corrected when runtime changes.
5. [guide.md](../../guide.md) is broader design guidance and can describe future
   architecture; it is not proof that a feature exists.

Never infer current behavior from a checked roadmap heading alone. Inspect the
owning symbol when changing behavior.

## Repository and ownership map

| Area | Primary location | State/runtime owner |
|---|---|---|
| Startup, routing, shell | [`lib/main.dart`](../../lib/main.dart), [`lib/app.dart`](../../lib/app.dart) | Flutter bootstrap, GoRouter, Riverpod `ProviderScope` |
| Chat domain and persistence | [`lib/features/chat/`](../../lib/features/chat/) | `ChatController`, `ConversationStore`; `Conversation` owns usage |
| Streaming and tools | [`lib/features/chat/application/`](../../lib/features/chat/application/) | `ChatStreamingCoordinator`, `CompositeChatToolRuntime` |
| Models/endpoints | [`lib/features/models/`](../../lib/features/models/), [`lib/features/settings/`](../../lib/features/settings/) | Catalog/controller state; secure storage owns API keys |
| Memory and workspace | [`lib/features/memory/`](../../lib/features/memory/) | `MemoryRepository`, mutation coordinator/recovery journal, `ContextInjector` |
| Agents and delegation | [`lib/features/agents/`](../../lib/features/agents/) | `AgentsController`; memory still owns persona data |
| Artifacts | [`lib/features/artifacts/`](../../lib/features/artifacts/) | `ArtifactsController`, Hive metadata, app-private files |
| Updates | [`lib/features/updater/`](../../lib/features/updater/) | `GithubUpdateRepository` and platform bridges |
| Default prompts | [`assets/agents/`](../../assets/agents/) | Structured Markdown agent definitions |
| Platform/release | [`android/`](../../android/), [`windows/`](../../windows/), [`linux/`](../../linux/), [`.github/`](../../.github/) | Platform bridges and release workflow |

Presentation widgets do not own persistence or request lifecycle. Keep domain,
data/services, Riverpod state, and presentation separated.

## Commands

Run from the repository root:

```text
dart format .
flutter analyze
flutter test
flutter build apk
dart run build_runner build --delete-conflicting-outputs
```

Use code generation after changing annotated Riverpod declarations. Generated
files follow their source and are not hand-edited. Validation should be
proportional; documentation-only changes need link/path checks and
`git diff --check`, not Flutter tests.

## Working conventions

- Dart 3.x, `flutter_riverpod`/`riverpod_annotation`, and GoRouter are the
  current stack. Match nearby naming and comment density.
- Persist request lifecycle state before network work. Streaming mutations are
  identity-bound and operate on the latest authoritative conversation state.
- Physical keyboard: Enter sends; Shift+Enter inserts a newline.
- UI is adaptive at 320 px and desktop widths, localized in English/Russian,
  and uses the mobilka Workbench visual language rather than default Material.
- Update [roadmap.md](../../roadmap.md) only for implemented and verified work.
- Do not claim physical-device validation unless it was performed. Android
  validations still pending are tracked in roadmap items 3, 7, 18, 30, 33,
  and 37.

## Security and scope boundaries

- Current inference is remote OpenAI-compatible HTTP(S) only. Explicit HTTP is
  allowed but must visibly warn that keys, prompts, and responses are exposed
  in transit. Never forward `Authorization` through automatic redirects.
- API keys belong in `flutter_secure_storage`; chat and other local state are
  Hive-backed. Android backups remain disabled because chat is unencrypted.
- Memory is deterministic human-readable RLM Markdown, not RAG, embeddings, or
  vectors. Android uses SAF and desktop uses `file_selector`; do not request
  broad storage access.
- Tool availability is the intersection of the request's immutable allowed-tool
  set and the current registered runtime. See [tools.md](tools.md).
- `read_public_source` is the only current public-network reader: HTTPS text/raw
  HTML only, DNS-policy checked and connection-pinned, bounded and PromptGuarded.
- **Not current:** `web_search`, workspace file tools,
  OCR/document extraction, general attachments, and Chat / Advanced Coding.
  These are future roadmap items and must not be presented as registered tools
  or shipped behavior. Image-processing support in source does not make the
  planned general attachment UX complete.
- Updater trust and artifact ownership boundaries are summarized in
  [architecture.md](architecture.md); preserve their fail-closed checks.
