# Session plan — milestone closeout marathon

Started: 2026-08-24. Owner works through tasks top-down. Status updated per task.
Open questions block only the tasks marked ⛔; everything else proceeds on defaults.

## Open questions (answer by number anytime)

- **Q1. Standing release authorization** — may every finished batch go
  push → PR (green checks) → merge → auto-release without asking?
  *Default if no answer before first batch completes: YES* (matches all
  previous explicit approvals).
- **Q2. Release cadence** — A: merge each batch immediately (many small
  releases) vs B: accumulate, single PR at end.
  *Default: A.*
- **Q3. Platform project generation (M7-50/51)** — skip entirely, or generate
  ios/ macos/ folders mechanically marked "requires Xcode verification"?
  *Default: generate folders + minimal config, leave roadmap unchecked with
  note.*
- **Q4. M7-55 delete-all scope** — chats+artifacts only (memory .md untouched)
  vs wipe everything including memory folder.
  *Default: chats+artifacts only.*
- **Q5. Order changes** — any re-prioritization?
  *Default: order below.*

## Tasks (ordered)

| # | Item | Depends | Status |
|---|------|---------|--------|
| 1 | Verify + close M7-57 CI automation | — | in progress |
| 2 | Verify + close M7-52 Android signing | — | pending |
| 3 | Verify + close M7-53 Win/Linux packaging | — | pending |
| 4 | Batch 1 → push/PR/merge/release | Q1,Q2 | blocked-by-answer-default-A |
| 5 | Implement M6-47 in-flight state save/restore | — | pending |
| 6 | Implement M6-48 retry/timeouts/offline/logs | — | pending |
| 7 | Batch 2 → release cycle | Q1,Q2 | pending |
| 8 | Verify + close M7-59 signatures/updater wiring | — | pending |
| 9 | Design + enforce M6-49 iOS background behavior | — | pending |
| 10 | Implement M7-55 privacy/data controls/metadata | Q4 | pending |
| 11 | Accessibility pass M7-54 (+textScale tests) | — | pending |
| 12 | Generate ios/macos projects per Q3 | Q3 | pending |
| 13 | Final validation sweep M7-56 (scanners+fixes) | — | pending |
| 14 | Batch 3 → final release cycle + session report | Q1,Q2 | pending |

## Excluded (hardware-blocked, need owner)

- M1-19/20 physical Android/Linux folder validation
- On-device foreground-service validation (46 companion bullet)
- Real upgrade-run verification (58) after CDN fix ships
