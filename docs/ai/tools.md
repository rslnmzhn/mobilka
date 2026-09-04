# Registered chat tools

The authoritative registry is `CompositeChatToolRuntime` in
[`chat_tool_runtime_registry.dart`](../../lib/features/chat/application/chat_tool_runtime_registry.dart).
It composes artifact, skill, session-workspace, persona, memory, and public-source runtimes. A tool
is advertised only when its name is in the immutable allowed-tool set captured
from the selected agent. The default agent definition is
[`general-assistant.md`](../../assets/agents/general-assistant.md).

The bundled default agent exposes the safe workspace tools and omits legacy
`write_skill` in favor of `propose_skill`.

Model-authored skill creation is never confirmation-free. Reflection reliably
produces one inspectable persisted proposal, and every create or update requires
explicit user confirmation. JWT/PAT/provider
tokens, authorization values, URL userinfo, private keys, secret/password/token
assignments, and raw tool/source blocks are rejected rather than proposed. This
is a conservative heuristic; users retain direct manual control of skill files.

| Tool | JSON arguments (`additionalProperties: false` where declared) | Runtime owner | Confirmation/effect |
|---|---|---|---|
| `generate_docx` | `title: string`, `markdown: string` (both required) | `ArtifactsChatToolRuntime` | Additive; no confirmation. Validates document/quotas, creates app-private MD+DOCX, then best-effort session mirror. |
| `write_skill` | `name: string`, `content: string` (both required) | `SkillsChatTools` | Legacy create-only compatibility path; refuses existing files and applies count/total-byte quotas. |
| `propose_skill` | `name`, `content` | `SkillsChatTools` | Reflection-only safe API. Provenance comes from persisted request state; every valid create/update persists an exact dedicated confirmation proposal and never writes directly. |
| `read_skill` | `name: string` (required) | `SkillsChatTools` | Reads one skill. |
| `list_skills` | empty object | `SkillsChatTools` | Lists skill files. |
| `write_session_notes` | `content: string` (required) | `WorkspaceChatToolRuntime` only | Compatibility alias for `write_file` targeting `session.md`; always requires exact confirmation. |
| `read_session_notes` | empty object | `WorkspaceChatToolRuntime` only | Reads bound `session.md` through the secure workspace authority. |
| `list_files` | optional `path`, `recursive` | `WorkspaceChatToolRuntime` | Bounded metadata-only listing in the immutable session workspace. |
| `search_files` | `query`; optional `path`, `case_sensitive` | `WorkspaceChatToolRuntime` | Bounded literal UTF-8 search in the immutable session workspace. |
| `read_file` | `path`; optional `offset`, `max_bytes` | `WorkspaceChatToolRuntime` | Bounded strict UTF-8 read. |
| `write_file` | `path`, `content` | Workspace proposal runtime | Confirmed exact create/replace proposal. |
| `apply_patch` | `path`, `patch` | Workspace proposal runtime | Confirmed single-file unified patch proposal. |
| `move_file` | `source`, `destination` | Workspace proposal runtime | Confirmed no-overwrite move proposal. |
| `delete_file` | `path` | Workspace proposal runtime | Confirmed regular-file deletion proposal. |
| `make_directory` | `path` | Workspace proposal runtime | Confirmed directory creation proposal. |
| `list_personas` | empty object | `PersonaChatTools` | Reads names and active persona. |
| `switch_persona` | optional `id: string|null`; null clears | `PersonaChatTools` / `PersonaRegistry` | Selects a canonical persona ID; exact unique title is temporary compatibility. |
| `save_persona` | `id`, `title`, `description`, `params`, `prompt` | `MemoryToolDispatcher` + memory proposal runtime | Creates/updates `personas/<id>.md` only after exact confirmation. |
| `delete_persona` | `id: string` | `MemoryToolDispatcher` + memory proposal runtime | Deletes `personas/<id>.md` only after exact confirmation. |
| `update_memory_file` | `file_name: "user.md"|"memory.md"`, `content: string` (both required; complete file content) | `MemoryToolDispatcher` + `MemoryChatToolRuntime` | `user.md`: exact-diff proposal and explicit confirmation. `memory.md`: bounded instant write. `soul.md` is prohibited. |
| `read_public_source` | `url: string` required, `offset: integer` 0..1 MiB optional | `PublicSourceChatToolRuntime` | Reads at most 1 MiB cumulatively per call through a DNS-validated, address-pinned HTTPS transport and returns at most 256 KiB including explicit untrusted-data delimiters. PromptGuard is heuristic marking, not proof of safety. |
| `web_search` | `query: string` required; optional `locale`, `time_range`, `max_results` | `WebSearchChatToolRuntime` | Discovery-only SearXNG JSON search. Returns guarded untrusted titles, canonical public URLs, and snippets; an HTTPS result must be explicitly read before citation/content claims. |

## Permission and confirmation rules

- The request captures selected agent ID and an unmodifiable allowed-tool set.
  Runtime execution checks that set again; memory confirmation also revalidates
  that the selected agent still owns the permission before mutation.
- Unknown or unadvertised calls fail without mutation. Tool-call rounds are
  capped at eight. Only one memory/persona, generic, skill, or workspace proposal
  can await confirmation per conversation; subsequent calls in that response
  are not executed.
- Confirmable proposals persist proposed complete content, exact diff,
  permission snapshot, version/token, and target. Confirm/reject is explicit;
  confirm revalidates permissions and current storage state through the shared
  memory mutation coordinator.
- `memory.md` uses `InstantMemoryWriter` and the same `update_memory_file`
  permission but bypasses proposal confirmation by product design. Its soft
  size limit still applies.
- `generate_docx` receives immutable conversation/session/workspace context.
  Artifact ownership is assigned at creation and cannot be retargeted.

## Output conventions

Tool message content is a JSON object encoded as text and linked to the source
call with `toolCallId`. Normal runtime results use `{"ok": true, ...}` or
`{"ok": false, "error": ...}`. Memory dispatch failures additionally expose
a bounded `error_code`; unexpected failures are converted to a generic safe
error while details remain in privacy-safe app logging.

Notable success fields include:

- `generate_docx`: `artifact_id`, canonical internal `artifact_uri`, ready-to-use
  `artifact_markdown`, `file_name`, `workspace_saved`, and optional
  `workspace_status` (the app-private artifact remains valid if mirroring fails).
- skill tools: `file`, `name`/`content`, or `skills`.
- session tools: `file` or `content`.
- persona tools: `active`, `personas`, or `status`.
- instant memory: `file` and `status`.
- public source: requested/final URLs, MIME/charset, redirects, byte offsets,
  continuation metadata, guard counts, and untrusted `content`.

Public-source bodies are cached per conversation by canonical original/final URL.
Aliases share one object; LRU eviction keeps at most 16 resources and 1 MiB total
body bytes per conversation. Evicted resources may be fetched again. Deleting a
conversation drops its cache.

Confirmable memory/persona calls do not emit a successful tool result until the
owner decision lifecycle resolves; they persist a pending proposal and pause
the model continuation.

Workspace mutation proposals persist a chat-owned authorization envelope and a
conversation-neutral operation identity with exact source/target identities, hashes,
binding and permission snapshots, operation output, and preview hash. Confirm
atomically claims the proposal, reconstructs and revalidates the same binding,
rechecks agent permission and target CAS, then commits through the recovery
journal. `artifacts/` and every descendant are read-only to workspace mutations.

## Not registered/current

OCR/document extraction tools, attachment tools, arbitrary
HTTP, shell/terminal tools, and Advanced Coding tools are **future roadmap
items, not current chat tools**. Do not add them to prompts or documentation as
available until registry code, permissions, tests, and roadmap status agree.
# Public-source trust and budget

`read_public_source` has a persisted, fail-closed 8 MiB wire-byte budget per
conversation. `web_search` shares and reserves from this same budget. Search is
disabled by default and sends only the query and explicit controls to the exact
self-hosted endpoint. The provider/operator controls server retention. HTTP
requires endpoint-bound acknowledgement and can never carry bearer auth.
Every body byte read is charged, including failed responses and
refetches; cache hits are free. The counter is stored with the Conversation and
is removed only when that conversation is deleted.

Canonical public URLs are limited to 8 KiB and ASCII hostnames without a
trailing DNS dot. Cache aliases are bounded to 8 per resource and 64 per
conversation with deterministic LRU eviction.

After a successful public-source read, the current request is tainted. Later
mutating or sensitive tools require a persisted, exact-call user confirmation;
read-only tools remain available. Unclassified future tools fail closed as
sensitive. Runtime-owned memory/persona confirmation remains single-layered.
PromptGuard is heuristic marking, not a security boundary.

Generic confirmation or rejection terminally finalizes the originating request;
the user starts a new request afterward. A proposal is atomically claimed before
execution. Workspace claims are distinct: startup removes a claim-only record
and resets the exact matching proposal to pending, while any prepared native
receipt is reconciled or rolled back before the conversation is finalized.
Public-source cache misses conservatively reserve up to 1 MiB from the persisted
8 MiB budget before opening transport; unused reservation is refunded normally,
while a crash leaves the reservation charged.

Public-source citations in final answers must use meaningful Markdown labels and
the absolute `final_url` actually read. The UI independently canonicalizes only
absolute HTTP(S) links and launches them in an external browser. Canonical
`mobilka-artifact:<id>?representation=md|docx` links remain internal and resolve
only authoritative app-private files after ownership and no-follow checks.
DOCX opening additionally requires persisted SHA-256 freshness against the
current authoritative Markdown bytes. Legacy DOCX without this hash must be
re-exported. The final path identity is rechecked immediately before the native
bridge; portable Dart APIs cannot prevent a same-user replacement after OS
handoff.
