# Intent — damage ordering vectors

Author: prabu-openclaw
Date: 2026-09-07
Status: draft
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

One committed intent per **runtime-only** change stream. Live under `intent/`.
Do not invent gameplay. Product intent stays in SS-specs.

## Problem / why now

`combat.md` CB-005 through CB-010 had no coverage — not by vector ID, and not by
behaviour under another name. That is five of ten combat vectors, and they are
the ones determinism rests on: the order a tick's hits resolve in. A build that
breaks a tie differently diverges on the tick it happens and every replay after
it is wrong, which is precisely what gate B-002 checks across architectures.

The rule lived as a local `struct Hit` and a `sort` closure inside a 180-line
`resolveDamage`, where it could not be tested as a rule and could not be read
without scrolling past sixty lines of hit collection.

Found while auditing vector coverage across both repos. That audit also corrects
an earlier claim of mine: **UP-004 and CD-014 were already covered**, in
`KernelVectorTests` and `CameraDestructionOrderTests` — I had grepped a single
file and reported them missing.

[verified: cross-check of every `XX-000` ID in `specs/001-*/*.md` against every
file in `Tests/`, then by behaviour for CB and EN]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- CB-005, CB-006, CB-007, CB-008 and CB-010 each have a test naming them.
- Each of those tests **fails** when the rule it covers is removed. Verified by
  mutation, not by assuming.
- No golden replay fixture and no digest changes: the extraction is a move.

## Affected users / systems

- Users: nobody directly; this protects replay integrity across devices
- Systems: `Simulation.resolveDamage`, new `DamageHit`

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- **The extraction must be a pure move.** The comparator keeps its exact
  precedence; the 409 existing tests including the golden replays are the check.
- Test the real rule, never a copy. A parallel implementation in
  `IsolatedKernel` would be a second thing to drift, and a test of a copy is the
  green lie `AGENTS.md` forbids — which is why `resolveDamage` now calls the same
  `DamageHit.ordered` the tests do.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Changing any ordering rule. This makes the existing behaviour visible and
  checked; if a rule is wrong, that is a spec question, not a patch here.
- EN-004 through EN-010, which are also uncovered and want their own stream —
  there is no enemy behaviour test file at all.

## Open questions

- CB-007's wall precedence is currently unreachable: `resolveDamage` always
  builds wall hits with `EntityID(0)`, which already sorts before every entity
  ID, so the clause never decides anything today. Kept and tested as a defensive
  rule. Worth asking whether wall hits should carry a real solid ID, which is
  when it would start mattering.

## Claims

| Claim | Label |
|---|---|
| The extraction changes no behaviour | `[verified: 409 tests including golden replay digests pass before and after]` |
| Each test fails when its rule is removed | `[verified: five mutations, each caught by exactly the matching test]` |
| Two of these tests passed for the wrong reason on the first attempt | `[verified: CB-007 passed with the wall clause deleted, because a wall's EntityID(0) wins the ID tiebreak anyway; CB-010 passed with the liveness guard deleted, because min(damage, integrity) is already 0 against a corpse]` |
| `killEnemy` is not idempotent, so CB-010 protects the receipt and not just the damage | `[verified: it re-emits entityDied, increments defeatsByArchetype, and decrements encounter.living again]` |
| `isCamera` was dead | `[verified: written at four construction sites, read nowhere]` |

## Next

A human accepts this file (`Status: accepted`). Then specify in SS-specs
(`spec.md` + `## Workflows`) if product behavior is affected. Do not
implement from this file alone.
