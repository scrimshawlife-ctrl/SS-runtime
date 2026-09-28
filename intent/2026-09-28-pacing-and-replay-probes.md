# Intent — Pacing and long-replay probes (T305, T901)

Author: Claude (agent), for prabu
Date: 2026-09-28
Status: accepted (owner, 2026-09-28)
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

## Problem / why now

T305 (pacing probes) and T901 (deterministic replay across the supported
matrix) are open with no artifact. Two gaps block even a partial one:

- No automated pilot finishes a run. The App autopilot dies at M-C (#63), and a
  headless copy of its policy wedged at M-B, so no run length or segment time
  had ever been measured.
- The only replay fixtures are 5 ticks (`replay-smoke-001`) and 302 ticks with
  the encounter graph completed by test hooks (`complete-run-vectors-001`).
  Nothing replays a played run through the real encounter graph.

[verified: `swift test` on `59e5e4b`; headless copy of `DebugAutopilot` stalls
on M-B for seed 1 with Signal Jammer and Ghost Step.]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- `swift test` includes a piloted legal run of thousands of ticks that replays
  three times to its live digest, and round-trips through replay JSON.
- An opt-in sweep (`SS_PACING_SEEDS`, `SS_PACING_REPORT`) writes one JSON line
  per run: outcome, run length, zone entry ticks, milestone ticks, damage by
  source.
- The measured numbers and their limits are recorded in SS-specs
  `docs/review/T305` and `docs/review/T901`.

## Affected users / systems

- Users: none — test-target tooling only.
- Systems: `Tests/SurveillanceCoreTests/PacingProbe/`. No change to
  `Sources/`, `App/`, contracts, fixtures, golden vectors, or digests.

## Constraints

Product-true locks (do not reopen in implement):

- The pilot reads only `PresentationSnapshot` and drives only `PlayerCommand`.
- Legal runs never touch state outside `step`. The `sustained` diagnostic
  restores Integrity through the existing test hook, is labelled as not a
  legal run, and is never used as replay evidence.
- No new digest is pinned. A digest that no spec fixture owns is printed for
  cross-architecture comparison, not asserted.
- A bot run is not a playtest. It cannot close T305, E-011, or G-005.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Balance changes. The probe measures; it does not tune.
- Replacing the App autopilot.

## Open questions

- Should the piloted-run digest become a spec-owned replay fixture (a new
  `replay-matrix-001` entry)? That is a specification change and needs SS-specs
  first (Article VII).

## Claims

| Claim | Label |
|---|---|
| No automated run had finished before this change | `[verified: #63 commit message; headless copy of the App policy]` |
| The probe changes no golden vector | `[verified: no file under Sources/ changed; full suite green]` |
| Probe run lengths approximate a human run | `[assumed: no — they are a floor for this pilot, not an estimate]` |

## Next

A human accepts this file (`Status: accepted`). No SS-specs specify stage is
needed unless the open question is taken up.
