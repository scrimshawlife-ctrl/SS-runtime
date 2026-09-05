# Intent — Original art intake

Author: prabu
Date: 2026-09-05
Status: draft
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

## Problem / why now

The five Civic Seam enemies, the Improper Search Daemon, and the Algorithmic
Moderate had no art and no path to any. The legacy admission could not supply
them — LC-007 records that the legacy roster is a different cast — so they were
always going to need originals, and originals have now been produced.

The catalog had no way to accept them. `plannedOriginal` means an original
*still to be made*: its validation requires `productionStatus == .planned` with
no `source`, `runtimePath`, or `sha256`. A produced original had nowhere to go.

[verified: `AssetCatalog.validate` rejects a `plannedOriginal` record carrying a
file, and no other decision permits `provenance == .projectOriginal` with
`runtimeRequired`.]

Separately, only the Player and the Cameras were wired to clips. Every enemy —
including the elite and the Captain — drew its authored blockout regardless of
what art existed.

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- A delivered original can be admitted, with a digest, and ships.
- The five standard enemies, the elite, and the Captain draw from clips.
- Coverage is a number the runtime reports, not a claim.
- A clip that is short a frame stays unbacked and keeps its blockout.

## Affected users / systems

- Users: every player. The cast stops being grey polygons.
- Systems: `AssetCatalog`, `RuntimeBundleFilter`, `ClipFrameLibrary`, new
  `ActorClipProjection`, `PresentationSnapshot`, `App/WorldRenderer`. No change
  to simulation, rules, arena, or replay identity.

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- An original carries its own provenance and never claims a legacy source.
- Collision, targeting, and Camera fields are never inferred from a sprite.
- All-or-nothing per clip direction. A short direction keeps its blockout and
  must not borrow a frame from elsewhere.
- The gameplay digest must not change.

Non-goals:

- Locomotion clips for the standard enemies or the Captain (see below)
- Drawing the interface assets, which are admitted but still rendered
  procedurally

## Open questions

- **The cast has no locomotion clips.** `clip-metadata-001` gives the five
  standard enemies only an anticipate and a commit clip, and the Captain only
  attack, transition, stagger, and defeat clips. `visual-assets.md` §5 says each
  standard enemy "requires idle, move, attack/commit, hurt, and defeat
  presentation", so the contract is short of its own inventory. Until it grows
  those clips, a standard enemy shows art while telegraphing and a blockout
  while simply moving. The elite is unaffected: its clips cover every state.
- The 27 delivered interface assets are admitted and ship, but `HUDRenderer`
  still draws procedurally. Wiring them is a separate change.

## Claims

| Claim | Label |
|---|---|
| A produced original had no admissible state | `[verified: plannedOriginal validation forbids a record carrying a file]` |
| Coverage is 492 of 588 frames | `[verified: OriginalArtTests.coverageIsWhatTheRecordSays, and the device reported sprites=492/588]` |
| The elite and all five enemies are fully backed | `[verified: OriginalArtTests, per clip per direction]` |
| Short clips stay unbacked | `[verified: OriginalArtTests.shortClipsRemainUnbacked for player_idle and the three short Captain attacks]` |
| The cast renders on device | `[verified: iPhone 17 simulator, Daemon sprite drawn with its query apertures under the boss bar]` |

## Next

A human accepts this file (`Status: accepted`).
