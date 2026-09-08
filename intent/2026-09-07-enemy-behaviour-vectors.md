# Intent — enemy behaviour vectors

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

`enemies-and-encounters.md` EN-004 through EN-010 had no coverage, and there was
no enemy behaviour test file of any kind. Seven of ten vectors, covering the
things a player actually fights: whether a Fog pulse can be broken by cover,
whether a Correlator charge ends at a wall, the Vendor mine budget, the M-C
forced Lockdown, and when an encounter is allowed to call itself finished.

Every rule is already implemented correctly. This is coverage, not repair — but
until now nothing would have noticed if a refactor quietly removed any of them.

[verified: cross-check of every vector ID in `specs/001-*/*.md` against every
file in `Tests/`, then by behaviour; the files that matched enemy archetype names
were all art and clip tests]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- EN-004 through EN-010 each have a test naming them.
- Each test **fails** when the rule it covers is removed — verified by mutating
  the source, not by assuming.
- No behaviour changes and no fixture moves: nothing outside `Tests/` is touched.

## Affected users / systems

- Users: nobody directly; this protects enemy behaviour against silent regression
- Systems: `Tests/` only

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- **Tests only.** If a vector and the implementation disagree, that is a spec
  question and goes to SS-specs — it does not get patched here to make a test green.
- A test that cannot fail is worth less than no test, because it reads as
  coverage. Every vector here is mutation-checked.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Changing enemy behaviour, including the EN-005 question below.
- EN-001, EN-002 and EN-003, which are already covered.

## Open questions

- **EN-005 may be narrower than the spec.** `enemies-and-encounters.md` says the
  charge "ends on first solid impact". The implementation ends it when the slide
  produces *no movement at all* (`moved == position`). A glancing impact that
  still permits sliding along the wall therefore does **not** end the charge, and
  the Correlator skids along the surface for the rest of its 24 ticks. That may
  be the better game — it is certainly the more forgiving one — but it is not
  what the sentence says. Tested as implemented, raised rather than changed.

## Claims

| Claim | Label |
|---|---|
| All seven rules are already implemented correctly | `[verified: each test passes against unmodified source]` |
| Each test fails when its rule is removed | `[verified: seven mutations, each caught by the matching test]` |
| EN-009's obvious assertion is too weak | `[verified: removing the queue check does not complete M-A, it advances to wave A2 with an A1 member unspawned — only waveIndex sees it]` |
| Killing the enemy by hand would have made EN-009 vacuous | `[verified: only killEnemy decrements `living`, so a corpse made by setting integrity leaves living at 1 and never reaches the condition]` |
| The event vocabulary contains no reward-shaped case | `[verified: EventType.allCases checked against reward/pickup/drop/loot/currency/collect/score; adding one fails EN-010]` |

## Next

A human accepts this file (`Status: accepted`). Then specify in SS-specs
(`spec.md` + `## Workflows`) if product behavior is affected. Do not
implement from this file alone.
