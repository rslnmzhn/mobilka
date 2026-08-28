# Current architecture

This document summarizes implemented boundaries. Runtime symbols linked below
remain authoritative.

## Startup and persistence

[`main()`](../../lib/main.dart) initializes Flutter, localization, Hive, and the
Android foreground-task bridge, opens the preferences, models, conversations,
memory recovery/proposals, and artifacts boxes, then starts `MobilkaApp` under
`ProviderScope`. API keys use secure storage rather than Hive.

`ChatController.build` asks `ConversationStore.recoverInterrupted` to convert
persisted pending/streaming messages to interrupted before publishing restored
conversations. Hive is current persistence for conversations, catalog/cache
state, favorites, and artifact metadata. Memory payloads are files; its
app-private Hive journal is recovery authority for coordinated mutations.

## Chat request, SSE, and tool lifecycle

1. `ChatController` captures the active conversation/model, selected agent and
   immutable allowed-tool set, request IDs, stable session key, and an opaque
   `WorkspaceBinding`. It persists user/assistant request state before network
   execution.
2. `ChatRequestAdmission` is one controller-wide admission gate. It prevents a
   second request from entering while held; it is not tied to whichever chat is
   currently visible.
3. `ChatStreamingCoordinator` binds work to immutable conversation, request,
   and assistant-message IDs. It injects context, advertises only allowed
   definitions from `CompositeChatToolRuntime`, and streams OpenAI-compatible
   SSE deltas.
4. Every delta is applied through `PersistConversationMutation`: the mutation
   receives the latest authoritative `Conversation`, checks the pending request
   identity, saves it, and republishes it. The per-conversation serializer also
   coordinates automatic-title updates. Never replace this with a stale
   captured conversation or mutable active-chat lookup.
5. Native tool-call deltas are buffered by index. A terminal `tool_calls`
   finish executes calls through `ChatToolExecutor`; fenced fallback calls may
   be parsed only when no native calls were buffered. Tool results are
   persisted as tool-role messages, then a follow-up completion runs (maximum
   eight tool rounds).
6. Memory/persona mutations are intercepted by `MemoryToolDispatcher`.
   Confirmable proposals stop continuation until owner decision; instant
   `memory.md` writes return a normal tool result.
7. Completion requires an explicit terminal SSE event. Early close is
   interrupted and retryable. Cancellation/errors also persist an interrupted
   state. The request-scoped Android foreground lease is lifecycle support, not
   a separate state owner.

## Memory 2.0

[`MemoryFiles`](../../lib/features/memory/domain/memory_file_names.dart) defines
the current schema:

| File | Role and mutation policy |
|---|---|
| `user.md` | Durable user facts. Human-editable; model replacement requires exact diff review and explicit confirmation. |
| `soul.md` | Base personality. Human-owned and model-protected; missing/empty content uses the built-in default. |
| `memory.md` | Agent working notebook. Model writes use the bounded instant path; changes enter context only on the next session or explicit rebuild. |
| `personas.yaml` | Named persona overlays. Memory owns parsing and mutation safety; save/delete use confirmable exact-diff proposals. |

`ContextInjector` prepends a deterministic system message in active-agent,
`soul.md`, active-persona, `user.md` order after pending-memory recovery and an
atomic snapshot. `memory.md` and `personas.yaml` are not independently injected
as raw files. `PromptGuard` strips frontmatter and marks suspicious injected
text. Historical aliases migrate to these names; `project_context.md` is not in
the current schema.

Memory may live in the app sandbox or an owner-selected location (Android SAF;
desktop path selected through `file_selector`). Manual edits, tool proposals,
and restores share the location transaction coordinator and recovery journal.

## Agents, personas, and subagents

`AgentsController` owns dynamic structured `.md` agent definitions, selected
agent state, and user-authored agent files. Frontmatter declares identity,
primary/subagent mode, preferred model, subagents, and tools; the default is
[`general-assistant.md`](../../assets/agents/general-assistant.md). Agent prompts
are injected separately from memory.

Personas appear in Agents UI but remain memory-owned overlays from
`personas.yaml`. `PersonaRegistry` owns active persona persistence and parsing.
Subagent execution follows the declared graph with bounded depth and isolated
history: delegation does not mutate the parent conversation or memory.

## Skills, sessions, and workspace

`WorkspaceStore` resolves only beneath the configured memory/workspace root:

```text
skills/<kebab-name>.md
sessions/<stable-session-key>/session.md
sessions/<stable-session-key>/artifacts/<artifact-id>.md|docx
```

The stable session key derives from conversation creation date, title, and
conversation ID. Session tools require request context. Artifact mirror writes
use the opaque request-captured `WorkspaceBinding`, so changing the selected
folder cannot retarget an in-flight request. SAF/path boundaries validate
access and reject unsafe subpaths.

Typed general workspace file operations are **future**, not current. There is
no arbitrary shell, broad filesystem root, or current `list_files`/`read_file`/
`write_file` family.

## Artifact ownership and catalog

An artifact created from chat is immutably owned by its originating
`conversationId` and stable `sessionKey`; edits preserve both. Legacy artifacts
without an owner are global/unowned only—never infer ownership from title,
dates, files, or session names. Deleting a conversation intentionally retains
its artifacts, which the catalog shows as having an unavailable owner rather
than making them unowned.

`ArtifactsController` owns Hive metadata and authoritative app-private `.md`
and optional `.docx` files. Representation presence, type, and byte size are
derived from actual app-private regular files using fail-closed containment,
no-follow, and identity checks. The global catalog reads this metadata/file
set; a current-session view filters by immutable conversation ownership.

`generate_docx` creates the authoritative app-private Markdown and DOCX pair
and may additionally mirror that same pair into the bound session workspace.
These are the only two payload locations: **do not create a third copy and do
not scan session/workspace folders to build or repair the global catalog**.
Mirror failure does not invalidate the app-private artifact.

## Updater

`GithubUpdateRepository` reads only the latest stable GitHub Release, requires
one canonical release manifest and matching signature, and verifies Ed25519
with the pinned public key before selecting an asset. Download staging enforces
declared size and SHA-256. Automatic application is limited to Android APK and
provenance-verified per-machine MSI Windows installs. Windows ZIP and Linux
ZIP/AppImage remain manual update paths. Preserve Android signer and Windows
MSI provenance constraints in [AGENTS.md](../../AGENTS.md).

## Explicit future boundaries

The following are roadmap designs, not implemented current architecture:
`web_search`, public-source URL reading, typed workspace file tools, OCR and
document extraction, general message attachments, and Chat / Advanced Coding
with a separate coding-agent catalog. Physical Android validation remains
pending where called out in [roadmap.md](../../roadmap.md); automated coverage
must not be reported as a device check.
