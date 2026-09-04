# Agent gotchas — Surveillance Survivor Runtime

Environment notes that used to bloat `AGENTS.md`. Keep secrets out.
If a gotcha is fixed, delete the row. Do not leave historical traps as current guidance.

## Local environment

| Trap | What happens | What to do |
|---|---|---|
| Commit `SSRuntime.xcodeproj` or signing data | Personal team / bundle IDs leak; project.yml is no longer the source | Generate with `xcodegen generate`. The xcodeproj is gitignored. |
| Expect `swift test` on Linux | Toolchain / iOS 18 SDK missing | Core tests are macOS CI (`macos-15`). Do not invent a Linux substitute. |

## CI and validators

| Trap | What happens | What to do |
|---|---|---|
| First CI job skips `CameraPlacementTests` and `CameraFairnessTests` | Looks like those suites are gone | Later jobs run them with `--filter`. Do not drop those jobs to stay green. |
| App job greps `xcodebuild` then checks `PIPESTATUS` | Grep can hide a failed build if you drop the pipe check | Keep the `PIPESTATUS` gate. A red honest build is required. |

If a check looks green-but-inert, follow `AGENTS.md` **Escalation**. Do not
patch the test to match the broken path.

## Measurement traps

| Looks like | Actually is |
|---|---|
| Sprite / node bounds as hitboxes or Camera FOV | Authoritative geometry lives in `SurveillanceCore`, not rendered nodes |
| Wall-clock elapsed time as simulation advance | Fixed 60 Hz ticks. App suspension must not advance authority by wall clock |

Record only traps that have bitten someone. A measurement trap is not a product
defect. Do not file one as a bug.

## Do not put here

- Architecture invariants (those stay in `AGENTS.md`)
- Command tables (those stay in `AGENTS.md`)
- Tokens, mailbox passwords, or live world IDs
- Deploy runbooks
- Invented gameplay
