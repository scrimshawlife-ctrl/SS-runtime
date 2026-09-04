# Intent — {{CHANGE_STREAM}}

Author: {{AUTHOR}}
Date: {{DATE}}
Status: draft | accepted | superseded
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

One committed intent per **runtime-only** change stream. Live under `intent/`.
Do not invent gameplay. Product intent stays in SS-specs.

## Problem / why now

{{PROBLEM}}

[verified: {{EVIDENCE}}] or [assumed: {{REASON}}]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- {{OUTCOME_1}}
- {{OUTCOME_2}}

## Affected users / systems

- Users: {{USERS}}
- Systems: {{SYSTEMS}}

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- {{LOCK_1}}

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- {{NON_GOAL_1}}

## Open questions

- {{QUESTION_1}}

## Claims

Label every non-obvious claim. Prefer a table when there are several.

| Claim | Label |
|---|---|
| {{CLAIM}} | `[verified: {{EVIDENCE}}]` or `[assumed: {{REASON}}]` |

## Next

A human accepts this file (`Status: accepted`). Then specify in SS-specs
(`spec.md` + `## Workflows`) if product behavior is affected. Do not
implement from this file alone.
