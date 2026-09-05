# Intent — Playthrough harness

Author: prabu
Date: 2026-09-04
Status: draft
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

## Problem / why now

Nobody had ever finished a run, so the entire back half of the game was
unobserved. Every presentation path past the first encounter was asserted by
unit tests and by nothing else.

[verified: the previous autopilot walked to a waypoint and stopped, so no run
reached the upgrade prompt, the elite, the boss, Extraction, or a terminal
outcome.]

That mattered most for the **upgrade gate**. `Simulation.step` returns
`.upgradeSelectionPending` and refuses to advance until a valid choice arrives,
so if the App's card hit-testing were wrong the game would be uncompletable —
and the drawing and the hit test computed their card rects independently, the
same shape of drift that produced the `mapReferenceRect` fault.

Boss telegraphs were the other exposure: `bosses.md` gives each attack a
wind-up that is the player's only warning, and no one had seen one drawn.

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- A run reaches a terminal outcome and the app persists a receipt for it.
- The upgrade gate opens through the real hit-test path, not by setting the
  choice directly.
- Boss telegraphs, the boss Integrity bar, the Extraction countdown, and each
  music state can be observed on device on demand.
- Telemetry survives a long run.

## Affected users / systems

- Users: none directly — this is a verification harness.
- Systems: `App/DebugAutopilot`, `GameScene` (DEBUG paths), `HUDRenderer` card
  geometry, one DEBUG-only seam in `Simulation`. No change to simulation rules,
  content, arena, or replay identity in a release build.

## Constraints

Product-true locks (do not reopen in implement):

- The pilot drives only the interfaces a person drives: a normalized
  `PlayerCommand`, and a synthetic tap in HUD point space.
- Everything added here is `#if DEBUG` and inert without a launch argument.
- A seeded run is evidence about **presentation only**. It says nothing about
  balance, pacing, or the acceptance gates, which need an actually-played run.

Non-goals:

- A competent combat AI. The pilot exists to reach states, not to play well.
- Anything that counts toward T901–T908.

## Open questions

- The pilot cannot clear M-B or M-C: it dies to Lockdown pressure. That may be a
  pilot-skill limit or a genuine difficulty signal, and only a human playtest
  (T903/T904) can tell the difference. Recorded, not guessed at.

## Claims

| Claim | Label |
|---|---|
| The upgrade gate opens | `[verified: device run logged "upgrade tap at (375.0, 191.0) -> index 1" and the objective advanced past M-A with upgrade=ricochetPulse]` |
| The objective graph advances by play | `[verified: node=M-A → M-B → M-C in one unseeded run]` |
| Boss telegraphs render | `[verified: seeded boss scenario, Safety Rationale cone drawn toward the Player with the Integrity bar at PUBLIC SAFETY; telegraphs=3 and telegraphs=1 observed]` |
| A run can be completed | `[verified: seeded Extraction scenario reached outcome=success and persisted a run receipt with a final digest]` |
| Four of six music states reach the device | `[verified: explore, lockdown, boss, extraction. observed and terminal not seen.]` |
| Straight-line steering wedges on arena solids | `[verified: pilot pinned at (1347,832) for ~5000 ticks before the wall-follow was added]` |

## Next

A human accepts this file (`Status: accepted`).
