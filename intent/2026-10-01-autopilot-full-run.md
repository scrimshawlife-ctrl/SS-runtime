# Intent — debug autopilot finishes a full run

Author: luna (task brief for the D-094 readability pass)
Date: 2026-10-01
Status: accepted (owner task brief, 2026-10-01: "make the app's DebugAutopilot able to finish a full run")
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

One committed intent per **runtime-only** change stream. Live under `intent/`.
Do not invent gameplay. Product intent stays in SS-specs.

## Problem / why now

`-SSAutopilot run` stalls at M-C, so a whole run cannot be observed in the
app: no run card, no extraction, no Lockdown-to-boss sequence for visual
review. The D-094 self-review needs those frames.

[verified: #63 records the wall-follow pilot dying at M-C; the test-only
`ProbePilot` finishes runs headlessly (T305 probes, SS-runtime #106).]

## Proposed outcome

Observable done:

- `-SSAutopilot run` in a Debug build plays to a terminal outcome and shows
  the run card.
- The waypoint scenarios (`mobA` … `extraction`) behave as before.
- Release builds contain neither pilot.

## Affected users / systems

- Users: developers and reviewers using the simulator harness.
- Systems: `App/DebugAutopilot.swift`, `project.yml`, and
  `Tests/SurveillanceCoreTests/PacingProbe/ProbePilot.swift` (now compiled
  into Debug app builds as well as the test target).

## Constraints

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- Debug only. The pilot reads `PresentationSnapshot` and issues the commands
  a finger would; it never writes authoritative state and never reaches the
  digest. The upgrade gate is still passed through the real hit test.
- One pilot: share `ProbePilot`, do not fork a second copy into `App/`.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Making the pilot win every seed. It is the T305 competent profile, which
  wins about 40% of legal seeds (D-093 final probe); finishing means
  reaching a terminal outcome without stalling.

## Open questions

- None.

## Claims

| Claim | Label |
|---|---|
| The app pilot's run equals the headless probe's for the same seed and upgrade | `[verified: both call ProbePilot.command once per simulation step from the same snapshots; hit-stop frames step nothing]` |
| Release excludes `ProbePilot.swift` | `[verified: EXCLUDED_SOURCE_FILE_NAMES in the Release config; its only app user is #if DEBUG]` |

## Next

Implemented with the D-094 readability pass.
