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
| `personas/<slug>.md` | Canonical persona documents: strict frontmatter metadata and prompt body. No mutable catalog/index. |

`ContextInjector` prepends a deterministic system message in active-agent,
`soul.md`, active-persona, `user.md` order after pending-memory recovery and an
atomic snapshot. `memory.md` and persona frontmatter are not independently injected
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
canonical `personas/<slug>.md` files. `PersonaRegistry` owns active persona selection while the catalog is derived live from those files.
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

The skills folder is the only catalog (no second index). Agents list compact
filenames and read only likely matches. Skill candidates are bounded stable
procedures, at most one per immutable request. Every model-authored create and
update requires persisted exact confirmation and a current-content hash recheck
so manual edits survive; there is no confirmation-free model write path.
Request capture retains an immutable typed `WorkspaceRootLocation` plus a
request-scoped `WorkspaceBoundaryCapability`: canonical path identity on
desktop or exact SAF tree identity on Android. Memory-owned composition adapts
that neutral binding to the session-workspace boundary; core imports no feature
types and chat performs no concrete storage downcast. Reflection I/O uses that
binding rather than resolving mutable current settings. Path CAS is
serialized with no-follow revalidation; SAF CAS is serialized in-process,
re-reads immediately before write and fails closed when provider identity or
read-back verification cannot be established.
The conversation persists the newest 32 active-request execution entries with
only request ID, tool name, success, and trust class—never arguments or output.
A sticky aggregate records discarded successful untrusted/unknown outcomes;
tool trust uses an explicit allowlist and unknown tools are never trusted.
Reflection verifies that exact persisted identity and records it for inspection.
Public-source, `read_skill`, unknown, stale, or forged evidence never grants
write authority. Since transitive semantic provenance of arbitrary model prose
cannot be proven, no model-authored candidate is automatically created.
Chat proposals persist a `WorkspaceProposalContext` envelope containing chat,
agent, and tool-call authorization fields, plus one conversation-neutral
`WorkspaceOperationIdentity` containing the session/root, operation,
path/destination, hashes, and CAS proof. Workspace recovery records contain
only that operation identity/proof, the binding snapshot, and an opaque chat
owner token. The recovery journal key is canonical over root identity, session,
and operation ID; mismatched keys are quarantined without invoking native code.
Blocked binding or cleanup recovery is retained for retry and never prevents
chat history from loading. Terminal quarantined bytes are removed only after
the conversation has durably acknowledged the recovered outcome. Recovery
reconstructs the exact path/SAF boundary after restart while also requiring
current location and grant equality. Store-owned `commitSkillCandidate`
performs quota calculation,
hash comparison, conditional write, and read-back under one root lock. Desktop
creation reserves the final name exclusively; portable update replacement keeps
the documented tiny external-process rename window. SAF returns unsupported or
failed unless exact child identity and bytes can be verified.
The path store acquires its existing process-wide canonical-root lock before
calling `PathSkillCommit`; that helper owns no lock and receives only the
already lock-owned parent resolver and atomic-update callback. There is no
second lock or alternate mutation authority.
Explicit confirmation performs hash, quota, identity, and read-back checks; SAF
still fails closed when provider identity/read-back cannot be established.

Typed workspace operations are rooted at the immutable request-captured session
binding. Android uses strict SAF child traversal; Windows and Linux use native
no-follow brokers. Reads are bounded and mutations persist one exact proposal,
require explicit owner confirmation, revalidate target identity/hash, and commit
through a root-scoped recovery journal. The `artifacts/` mirror is mutation-
prohibited. No arbitrary shell or broad filesystem root is exposed.

Workspace domain, boundary, journal, and coordinator services are conversation-
agnostic. Chat owns `WorkspaceChatToolRuntime`, proposal continuation, and
startup application of recovery outcomes. The legacy session-note names are
aliases owned only by that workspace runtime; there is no independent
`SessionNotesTools` runtime.

Android workspace listings return capped provider metadata only. Proposal
metadata and both sides of a read use native bounded SHA-256 validation. Native
overwrite recovery recognizes only the exact before/after hashes and never
restores a backup over unknown bytes. Delete recovery follows the persisted
source document ID through intermediate provider names and cleanup fails unless
the operation-owned document is removed. Invalid startup records reset a
proposal only when they prove claim-only state; otherwise the matching request
is terminalized with `workspace_recovery_invalid`. Malformed proposal data is
isolated to its conversation and cannot block loading valid chat history.

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

Public-source reads use a dedicated direct HTTPS client, validate every DNS
address and redirect, pin the actual connection, cap transfer at 1 MiB and each
returned guarded chunk at 256 KiB, and never render HTML. PromptGuard only marks
heuristically suspicious lines; content remains explicitly delimited untrusted
data and must never be treated as instructions. Conversation caches are LRU
bounded to 1 MiB total and are removed with the conversation.

The following are roadmap designs, not implemented current architecture:
OCR and
document extraction, general message attachments, and Chat / Advanced Coding
with a separate coding-agent catalog. Physical Android validation remains
pending where called out in [roadmap.md](../../roadmap.md); automated coverage
must not be reported as a device check.
# Public-source mutation boundary

Conversation persistence owns the cumulative 8 MiB public-source wire counter.
The request-scoped streaming coordinator treats a successful source result as
untrusted taint. Central tool execution then persists exact immutable proposals
for subsequent mutating/sensitive calls and requires explicit confirmation;
new user requests start untainted. PromptGuard remains heuristic only.

`RequestToolSecurityState` is the sole in-memory taint authority for one
immutable request and is shared across coordinator tool rounds. Generic proposal
decisions are terminal: claim, exact execution or rejection, safe tool result,
proposal removal, and pending-request removal are persisted through the shared
conversation mutation boundary. Workspace startup recovery instead removes a
claim-only journal entry and resets its matching executing proposal to pending.
Malformed or forward records are quarantined and a matching proposal is safely
terminated. Orphan prepared records are reconciled or rolled back and cleaned;
orphan terminal records are acknowledged and cleaned.

Session workspace listings are metadata-only and may report a null regular-file
size when a SAF provider does not expose one. Direct metadata/read operations
require a verified size and hash. Workspace mutation quotas exclude the
case-insensitive top-level `artifacts/` subtree; artifact policy owns those
files. Root searches also exclude that subtree and report bounded per-file
skips for unknown metadata, oversized files, and unsupported text.
