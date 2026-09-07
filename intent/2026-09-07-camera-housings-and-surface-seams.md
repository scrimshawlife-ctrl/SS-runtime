# Intent — camera housings and surface seams

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

Three defects found by running the built app on a simulator and reading the
frame, not by reasoning about the code.

**A black square sits beside every Camera.** `WorldState.liveSolids` appends a
`mount-<socketId>` box per Camera so the mount collides (T411 keeps the
footprint after destruction). `PresentationSnapshot` hands the renderer *all* of
`liveSolids`, and `WorldRenderer.renderSolids` finds no `env_mount_*` art, so it
falls through to the blockout: `Palette.solidFill`, `white: 0.18`. Eight
Cameras, eight near-black rectangles, each drawn over art that is already there.

**The five Camera housings never render.** `env_camera_*` is declared, admitted,
and shipping in the runtime bundle, but `EnvironmentTextures` is consulted only
for ground, decorations and solids. Every Camera draws the same legacy
`actor_camera_*` clip, so `housingFamily` — which placement assigns per
`camera-placement-001` — has no visible consequence at all.

**Zone boundaries are ruler-straight full-height seams.** Zones are axis-aligned
rectangles, so where Z-01 sidewalk meets Z-02 railbed the paving changes on one
pixel column, between two surfaces far apart in value. The existing 3-unit kerb
marks the line but does not soften it.

[verified: simulator capture on iPhone 17 / iOS 26.5 at `babc337`; asset
measurement below; `App/WorldRenderer.swift:357`,
`Sources/SurveillanceCore/World/WorldState.swift:40`]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- No blockout rectangle is drawn for a Camera mount; the Camera's own art is the
  only thing at that position.
- Two Cameras of different `housingFamily` are visibly different objects.
- Where two ground surfaces meet, the change is graded over several units rather
  than falling on one column, and the kerb reads as a kerb with height.
- `swift test` and the App test target stay green, and no golden replay fixture
  changes.

## Affected users / systems

- Users: anyone looking at the game
- Systems: `WorldRenderer`, `EnvironmentTextures`, `EnvironmentLibrary`,
  `PresentationSnapshot`

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- **Presentation only.** `WorldState.liveSolids` keeps every mount box: this
  changes what is drawn, never what collides. No change may reach the state
  digest, so `arenaVersion` and every replay fixture stay as they are.
- The housing is drawn *beneath* the clip, never instead of it. `camera-destruction.md`
  §16 requires operational, damaged, critical, destroyed, hit and field-off
  presentation per family, and those states live in the clip. Swapping in a
  static housing would regress T608.
- All-or-nothing survives: an incompletely delivered `camera` group draws no
  housings at all, exactly as `visual-assets-001` §3a requires of every group.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- A sixth housing family. `HousingFamily` names the five *standard* families;
  the sixth in `civic-seam-visual-direction.md` §6 is the Captain Camera, which
  is the boss and not one of the eight standard mounts. T507 is art production,
  not a missing enum case.
- Non-rectangular zones. The seam is softened where it is drawn; the arena
  contract is untouched.

## Open questions

- Should the housing tint by Integrity so a damaged Camera reads as damaged at
  the housing as well as the head? Deferred: the clip already carries state and
  doubling it risks two disagreeing signals.

## Claims

| Claim | Label |
|---|---|
| Housing art is a full-height pole and the legacy clip is a head in the middle band, so they compose rather than occlude | `[verified: env_camera_* bbox y 4–92 of 96; actor_camera_*_idle bbox y 37–73]` |
| Skipping the mount blockout cannot leave an invisible collider | `[verified: actor_camera_* is adaptedAdmitted legacy art present in every build, and renderCameras falls back to a drawn circle when no clip is backed]` |
| Nothing here can move the digest | `[verified: StateDigest hashes WorldState; PresentationSnapshot is derived from it and is not an input]` |
| The sixth housing family is the Captain Camera, not a gap in the enum | `[verified: civic-seam-visual-direction.md:217 table; visual-assets.md:376 "All eight standard Cameras use stationary housings"]` |

## Next

A human accepts this file (`Status: accepted`). Then specify in SS-specs
(`spec.md` + `## Workflows`) if product behavior is affected. Do not
implement from this file alone.
