# Intent — fog layers

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

`civic-seam-visual-direction.md` §7 specifies fog as two layered presentation
passes, and the game has none. Fog is named in the setting paragraph of every
environment prompt written for this project; it is the most-cited element of the
art direction and the largest remaining gap between that direction and the
screen.

Built now, before the art exists, so the art has somewhere to land the day it
arrives rather than waiting on a renderer afterwards.

[verified: simulator capture at `d0c76d6` shows clear air; `visual-assets.md` §5
lists fog overlays as a required family with no delivered asset]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- With no fog art, the game renders exactly as it does today.
- With both fog assets delivered, two hazes drift across the arena at different
  speeds, the lower one under anything solid and the upper one over architecture.
- Neither haze is ever drawn above a Camera field, a telegraph, a mine, an
  actor, a projectile or a marker.
- Reduced motion holds both layers still without removing them.

## Affected users / systems

- Users: anyone looking at the game; players using Reduced Motion
- Systems: `WorldRenderer`, `EnvironmentTextures`, `EnvironmentLibrary`, `GameScene`

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- **Cosmetic only.** §7 reserves any gameplay visibility change for a separately
  versioned, simulation-authored decision. The renderer reads `snap.tick` and
  writes nothing, so it cannot reach the state digest.
- **§7's readability floor is a draw-order property.** Fog may not conceal
  authoritative collision, lethal telegraphs, or required Camera boundaries.
  Nothing enforces that except where the two layers sit in `Layer`, so that
  order is asserted by a test rather than left to review.
- All-or-nothing, like every other environment group: one layer without the
  other is a rendering fault the player would read as one.
- Deterministic drift. Derived from the authoritative tick, never from wall
  clock, so two devices agree and a paused game holds still.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Volumetrics, occlusion, or any visibility rule. This is two scrolling planes.
- Per-zone density. Worth having, but it is a spec decision (raised in SS-specs).
- Declaring the asset IDs. That is SS-specs; this ships inert until it lands.

## Open questions

- Drift speeds are chosen by eye at 120 and 300 milli-units per tick, because
  there is no art to judge them against. Expect to retune once the layers are
  visible.

## Claims

| Claim | Label |
|---|---|
| The renderer cannot affect the digest | `[verified: reads snap.tick only; StateDigest hashes WorldState, which the renderer never touches]` |
| Fog never covers a cue the player needs | `[verified: AppTests asserts every hazard layer sorts above both fog layers, and fails when fogHigh is moved above telegraphs]` |
| It is inert without art | `[verified: 408 core + 19 App tests green, and a simulator capture identical to the previous build]` |
| Scrolling never exposes a grid edge | `[verified: the offset is taken modulo the tile and the grid runs one tile past the arena on every side; asserted over 65 ticks spread across 40,000]` |

## Next

A human accepts this file (`Status: accepted`). Then specify in SS-specs
(`spec.md` + `## Workflows`) if product behavior is affected. Do not
implement from this file alone.
