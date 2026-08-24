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
| 1 | Verify + close M7-57 CI automation | — | done |
| 2 | Verify + close M7-52 Android signing | — | done |
| 3 | Verify + close M7-53 Win/Linux packaging | — | done |
| 4 | Batch 1 → release cycle | defaults applied | done → v0.1.1 |
| 5 | Implement M6-47 in-flight state save/restore | — | done (v0.1.1 cycle) |
| 6 | Implement M6-48 retry/timeouts/offline/logs | — | done (v0.1.1 cycle) |
| 7 | Batch 2 → release cycle | defaults | done → v0.1.2 (verification batch) |
| 8 | Verify + close M7-59 signatures/updater wiring | — | done (v0.1.1 cycle) |
| 9 | Design + enforce M6-49 iOS background behavior | — | done (docs/06_background_ios.md) |
| 10 | Implement M7-55 privacy/data controls/metadata | Q4 default | done |
| 11 | Accessibility pass M7-54 (+textScale tests) | — | done; manual SR pass tracked |
| 12 | Generate ios/macos projects per Q3 default | Q3 default | done; Xcode check pending |
| 13 | Final validation sweep M7-56 (scanners+fixes) | — | done: security CLEAN, deps PASS, 271 tests |
| 14 | Batch 3 → final release cycle + session report | defaults | done → v0.1.3 |

## Excluded (hardware-blocked, need owner)

- M1-19/20 physical Android/Linux folder validation
- On-device foreground-service validation (46 companion bullet)
- Real upgrade-run verification (58) after CDN fix ships
