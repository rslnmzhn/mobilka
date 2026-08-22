# mobilka

Mobile-first Flutter workspace for remote OpenAI-compatible models, streaming chat, RLM Markdown memory, agents, and artifacts.

RLM Markdown memory is the selected human-readable context architecture: a deterministic set of selected `.md` files is injected as one atomic snapshot and managed manually or by agents with explicit user confirmation.

## Current targets

- Android 10+ (`com.rslnmzhn.mobilka`)
- Windows
- Linux
- iOS and macOS are planned

## Development

```sh
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart format .
flutter analyze
flutter test
flutter build apk
```

Architecture and product decisions are documented in [`guide.md`](guide.md). The authoritative implementation checklist is [`roadmap.md`](roadmap.md).

## Security

API keys are stored with `flutter_secure_storage`. HTTPS is strongly recommended. Explicitly configured HTTP endpoints are supported, but expose API keys, prompts, and responses in transit.

Do not commit `.env` files, signing keys, `key.properties`, generated builds, local agent-tooling snapshots, or user memory files.
