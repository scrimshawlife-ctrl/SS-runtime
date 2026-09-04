# Agent contract — Surveillance Survivor Runtime

You are working in **Surveillance Survivor Runtime** (`scrimshawlife-ctrl/SS-runtime`).
This file is the canonical contract for Cursor, Claude, Codex, Grok, and OpenClaw.
Harness adapters (`CLAUDE.md`, optional `CODEX.md`) only point here.

## Intent

Gameplay and product intent live in `scrimshawlife-ctrl/SS-specs` at the commit
pinned in `SPEC_BASELINE.md`. Start at `specs/001-single-level-vertical-slice/spec.md`
and `specs/000-constitution.md`. Do not invent gameplay here.

Read `SPEC_BASELINE.md` before changing gameplay. For a runtime-only change
stream, read the active file in `intent/` (see `intent/README.md`). Next stage
is specify in SS-specs — do not skip to code.

If a non-trivial runtime-only change has no intent, draft one from
`intent/_TEMPLATE.md` and wait for a human to accept it.

## Commands

| Task | Command |
|---|---|
| Test | `swift test` |
| Generate Xcode project | `xcodegen generate` |

Fill only from this repo's README or CI. Do not invent commands.

## Invariants

- Treat SS-specs commit `39b04bb00ca5d3799513efed4e7970ec42975c96` as product authority.
- Cite task and contract IDs in gameplay commits and pull requests.
- Keep `SurveillanceCore` independent of UIKit, SwiftUI, SpriteKit, AVFoundation, wall clock, and unseeded randomness.
- Use fixed 60 Hz ticks, stable UInt64 entity IDs, ordered iteration, and fail-closed version loading.
- Never infer collision, targeting, or Camera fields from rendered nodes or sprite bounds.
- Do not add another level, weapon, character, campaign system, online feature, or meta-progression.
- Do not copy legacy source without an ADAPT decision and exact source citation.
- Run `swift test` before handoff.
- Do not invent product behavior the spec does not name.

## Escalation

If CI, tests, or validators look wrong — missing coverage, silent skips,
green-but-inert checks, or a suite that contradicts the spec:

1. Open a defect issue.
2. Do **not** patch tests, fixtures, or CI to force green.
3. Do **not** weaken an assertion to match a broken implementation.

A red honest check is better than a green lie.

## Environment gotchas

Long environment notes live in [`AGENT-GOTCHAS.md`](AGENT-GOTCHAS.md).
Keep them out of this file.

## Team context

Org and partner status is not this repo. Load `Zero-State-LLC/agent-context`:

1. `HANDOFF.md`
2. `STATUS.md`
3. `DECISIONS.md` only if a prior choice affects this task

Clone: `gh repo clone Zero-State-LLC/agent-context ~/agent-context`.
Pull `--ff-only` before trusting a local copy.

## Skills

Name only skills that already exist. Do not invent skills or bots.

Product `## Workflows` belong in SS-specs, not in this runtime.
Defaults when that section is empty: `anti-slop-code`, `production-systems`,
`google-developer-style`.

## Size

Keep this file short (about 80 lines; hard ceiling 12 KB).
Move procedure and gotchas out, not in.
