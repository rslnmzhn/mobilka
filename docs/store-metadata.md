# mobilka — store listing metadata

## Identity
- App name: mobilka (lowercase m)
- Application ID: com.rslnmzhn.mobilka

## Short description (<=80 chars)
Remote AI workspace: bring your own OpenAI-compatible endpoint and memory.

## Full description
mobilka connects to the OpenAI-compatible endpoint YOU choose. Bring your own
API key, pick any model, and keep a human-readable Markdown memory under your
control. Chats, artifacts, and keys never leave your device except in direct
requests to your configured endpoint. Signed auto-updates are available for
Android APK and per-machine Windows MSI installs; Windows ZIP builds are
manual-download only. Linux source remains dormant and Linux builds are not
currently published or supported.

## Category / tags
Productivity; AI chat client; developer tools.

## Data safety summary
- Stored locally: conversations, attachments, artifacts (.md/.docx), API key
  (flutter_secure_storage), Markdown memory files (user-chosen folder).
- Collected by mobilka: nothing. No analytics, no telemetry, no accounts.
- Network: only direct calls to the user-configured OpenAI-compatible base URL.
- Android backups: disabled (chat history is unencrypted local data).

## Export & deletion
Settings → Your data → Export all data (single JSON), Delete all data
(chats + artifacts incl. generated files). Memory .md folder is user-owned and
managed separately (open/edit/backup/restore inside the Memory tab).
