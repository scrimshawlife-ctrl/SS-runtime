# Intent — autopilot wall-follow and the M-B/M-C question

Author: prabu-openclaw
Date: 2026-09-05
Status: draft
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

One committed intent per **runtime-only** change stream. Live under `intent/`.
Do not invent gameplay. Product intent stays in SS-specs.

## Problem / why now

The debug pilot could not clear M-B or M-C, and we did not know whether that was
a pilot limitation or a real difficulty signal from the game. That question has
been open since the harness landed (#48), and it blocks reading anything into
the pilot's failures.

It was the pilot. Two defects, both in `App/DebugAutopilot.swift`:

1. **A 280-unit dead zone.** The steering chain has no branch for "arrived at
   the target, and the nearest contact is between `kiteRange` (180) and
   `engageRange` (460)". All three branches miss, so `command` stays zero and
   the pilot stands still — at a trigger, while enemies gather. Observed losing
   Integrity 90 → 66 with contacts climbing 0 → 6 and no input issued.

2. **The unstick cannot rescue that, and oscillates besides.** The detour
   rotates an existing command, and `perpendicular` of zero is zero, so a wedged
   pilot detected the stall and then did nothing. Worse, `detourSign` flipped on
   *every* detour: correct for a dead end, but against a long wall it guarantees
   the pilot oscillates around one spot forever.

[verified: instrumented the pilot's own decision each tick. At M-A it logged
`orbit tgt=960,576 dTgt=39 near=210 cmd=31714,-8239` — a near-full command —
while `player=998,566` did not change for 3,000+ ticks, with `shots=0` despite a
contact 210 units away, i.e. pressed into a solid with no line of sight.]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- The pilot always issues an intent: no branch of the steering chain returns a
  zero command while a contact exists.
- A detour applied to an idle command produces real movement rather than
  rotating zero.
- `-SSAutopilot tour` clears M-A and M-B, where it previously wedged at M-A.
- The autopilot log carries the pilot's own reasoning (`pilot=[...]`), so the
  next stall is diagnosable from a log rather than by re-deriving it.

## Affected users / systems

- Users: whoever reads harness evidence for T903/T904 and needs to know whether
  a failure is the game or the bot.
- Systems: `App/DebugAutopilot.swift`, `App/GameScene.swift` (log line only).
  Both are `#if DEBUG`.

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- DEBUG-only. The pilot steers exclusively through normalized `PlayerCommand`,
  the same path a finger takes. No simulation, content, or arena change, and no
  effect on replay identity.
- Do not tune encounter difficulty to make the bot succeed. The bot is
  instrumentation; the game is the subject.

Non-goals:

- Real pathfinding. This stays a wall-follow, as the original comment intends.
- Making the pilot clear the whole run. It is not a substitute for T903/T904.
- Another level, weapon, character, campaign system, online feature, or meta-progression

## Open questions

- M-C is now reached deterministically and lost. Is that the designed pressure
  (`woundedKiteRange` exists because "M-C forces Lockdown by design, so the
  difference between reaching the elite and dying there is spacing"), or is the
  encounter genuinely over-tuned? **A human still has to answer this** — the
  bot only establishes that M-C is a fight, not a wedge.

## Claims

| Claim | Label |
|---|---|
| The dead zone left the pilot with a zero command | `[verified: pilot log showed the idle branch at a trigger while Integrity drained]` |
| `perpendicular` of an idle command is idle | `[verified: it negates and swaps components; both are zero]` |
| Flipping the detour side every time causes oscillation | `[verified: pilot held position ±1 unit across 3,000 ticks with detours firing throughout]` |
| The pilot now clears M-A and M-B | `[verified: three seeded `tour` runs each reach node M-C]` |
| M-C is lost in combat, not wedged | `[verified: 180 s run ends `outcome=failure` at `hp=0` on node M-C; three 115 s runs sit at `hp=32`, still playing]` |
| No gameplay or replay identity change | `[verified: 356 tests in 60 suites pass, including digest and receipt gates; all edits are inside `#if DEBUG`]` |

## Next

A human accepts this file (`Status: accepted`). Runtime-only DEBUG tooling, so
no matching `spec.md` is required in SS-specs. The M-C tuning question above is
product intent and belongs in SS-specs if it is pursued.
