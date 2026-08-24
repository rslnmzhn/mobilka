# mobilka Roadmap

## Milestone 1 — Foundation and first vertical slice
- [x] 1. Initialize Flutter project as `mobilka` with package ID `com.rslnmzhn.mobilka`.
- [x] 2. Generate Android, Windows, and Linux platform projects.
- [x] 3. Set Android minimum SDK to API 29 (Android 10).
- [x] 4. Establish feature-first Flutter architecture with Riverpod code generation and GoRouter.
- [x] 5. Initialize Hive persistence and secure API-key storage.
- [x] 6. Add extensible English and Russian localization with `easy_localization`.
- [x] 7. Add adaptive navigation shell for Chat, Models, Memory, and Settings.
- [x] 8. Implement Claude, Dark Cyber, Midnight OLED, Solarized, Nord, and Classic theme presets.
- [x] 9. Implement light/dark variants for every preset with a global toggle.
- [x] 10. Implement OpenAI-compatible endpoint and secure API-key settings.
- [x] 11. Implement model discovery through `/v1/models`.
- [x] 12. Cache discovered models locally with Hive.
- [x] 13. Implement model search, favorites, and chat visibility controls.
- [x] 14. Implement model selection in the chat header.
- [x] 15. Implement Android SAF folder selection with persistent URI access.
- [x] 16. Implement visible directory selection on Windows and Linux.
- [x] 17. Create missing `user_profile.md`, `project_context.md`, `system_instructions.md`, and `memory_log.md` without overwriting user data.
- [x] 18. Add the disabled chat composer shell without message sending.
- [x] 19. Validate external-folder behavior on a physical Android 10+ device.
- [x] 20. Validate Linux build on a Linux host.

## Milestone 2 — Streaming chat
- [x] 21. Implement OpenAI-compatible `/chat/completions` requests.
- [x] 22. Implement resilient SSE token streaming and cancellation.
- [x] 23. Persist chats and messages in Hive before network requests.
- [x] 24. Implement connection-drop recovery and resumable UI state.
- [x] 25. Render Markdown and highlighted code with isolated message repainting.
- [x] 26. Add conversation creation, rename, archive, search, and deletion.
- [x] 27. Add token/context budget indicators and clear endpoint errors.

## Milestone 3 — Markdown memory and agents
- [x] Architecture decision: adopt RLM Markdown memory as the sole context-memory architecture: deterministically selected human-readable `.md` files injected as one atomic snapshot, manually managed or agent managed with explicit user confirmation; no alternate context-memory pipeline is planned.
- [x] 28. Implement serialized/mutex-protected Markdown reads and writes.
- [x] 29. Implement Context Injector for selected memory files.
- [x] 30. Implement safe `update_memory_file` tool calls with diff preview, durable hash-verified recovery, context-read gating, and an idempotent audit log.
- [x] 31. Parse standardized agent `.md` frontmatter and validate schemas.
- [x] 32. Discover, import, create, edit, hide, favorite, and select agents.
- [x] 33. Implement primary-agent/subagent discovery and delegation contracts.
- [x] 34. Add user controls for memory inclusion, editing, backup, and restore.

## Milestone 4 — Tool calling and artifacts
- [x] Implement the mobilka Workbench visual system and three-state adaptive application shell.
- [x] Keep five-destination mobile navigation overflow-free on narrow screens.
- [x] Fix memory folder cancellation state loss and location-provider rebuilds.
- [x] Fix mobilka shell branding and pending memory proposal confirmation runtime failures.
- [x] 35. Implement native OpenAI-compatible `tool_calls` orchestration with persisted user-confirmed memory proposals.
- [x] 36. Implement fallback parsing for tool calls embedded in Markdown/JSON blocks.
- [x] 37. Add collapsible tool cards with running, completed, and failed states.
- [x] 38. Add the tabbed Artifacts Bottom Sheet for code, documents, previews, and logs.
- [x] 39. Implement safe local `.md` artifact creation and sharing.
- [x] 40. Add file-name validation, path traversal protection, quotas, and user confirmation policies.

## Milestone 5 — Documents and multimodality
- [x] 41. Implement template-based `.docx` generation with Markdown fallback.
- [x] 42. Implement opening and sharing files via Android FileProvider and platform-native APIs.
- [x] 43. Add image and document attachments.
- [x] 44. Downscale/compress images before Base64 encoding to prevent OOM.
- [x] 45. Add provider-capability detection for vision and tool support.

## Milestone 6 — Background reliability
- [x] 46. Add Android Foreground Service for user-visible long-running tasks.
- [x] Validated foreground-service streaming on a physical Android 13+ device (notification permission grant and background survival).
- [x] 47. Save and restore in-flight task state across lifecycle transitions.
- [x] 48. Add retry policies, endpoint timeouts, offline state, and diagnostic logs.
- [x] 49. Design iOS-compliant background behavior without promising unrestricted execution.

## Milestone 7 — Future platforms and release readiness
- [x] 52. Add Android signing and release configuration without storing secrets in Git.
- [x] 53. Add Windows and Linux packaging.
- [x] Add a provenance-gated, pinned-Authenticode Windows MSI update bridge and per-machine installer marker.
- [x] 54. Complete accessibility, keyboard navigation, screen-reader, and large-text audits.
      - [x] Manual TalkBack/VoiceOver pass verified by the owner on a physical device.
- [x] Support Enter-to-send, Shift+Enter newlines, and mobile send actions without keyboard-triggered stream cancellation.
- [x] Add an always-visible New Chat header action and searchable favorite-first quick model picker.
- [x] 55. Add privacy disclosures, export/delete controls, and store metadata.
- [x] 56. Run full security, dependency, architecture, performance, and release validation.
- [x] 57. Add GitHub Actions quality, Android, Windows, Linux, AppImage, and stable release automation.
- [x] 58. Verified signed-manifest update discovery, verified installer staging, and platform-bridged installation: MSI handoff exercised end-to-end (v0.1.2 to v0.1.3) and owner confirmed Android auto-update works.
- [x] 59. Publish detached Ed25519 manifest signatures and wire the updater platform channel implementations and settings section.
