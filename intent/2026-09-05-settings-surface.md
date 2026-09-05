# Intent — Settings surface

Author: prabu
Date: 2026-09-05
Status: draft
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

## Problem / why now

Several contracts specify player-adjustable settings, and none of them could be
adjusted. Every value was hard-wired to its default in code.

[verified: `hudScaleSetting` returned `.standard` unconditionally, handedness
came from `state.handedness` which is always `.right`, `AudioEngine.Mix` used
the contract defaults with no way to change them, and the Camera-counter `pinned`
parameter existed on `HUDLayout.cameraObjectiveVisible` with no caller passing
`true`.]

The concrete cost: **left-handed play is specified and impossible.**
`hud-tutorial-001` UI-002 is an acceptance vector for a mode no one can select.
The same applies to Reduced Motion, Reduced Flash, HUD scale, and every mix bus.

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- Pause opens a settings surface with the five `audio-haptics-001` mix buses at
  their contract defaults, HUD scale, handedness, the accessibility toggles, the
  Camera-counter pin, and the tutorial toggle.
- Changing any of them takes effect immediately and survives a relaunch.
- ER-007 holds: a settings change leaves the digest identical and moves only the
  receipt's declared presentation block.
- The receipt records whether tutorials were enabled.

## Affected users / systems

- Users: every player, and specifically left-handed players and anyone who needs
  reduced motion or flash.
- Systems: new `PresentationSettings` in Core, `RunReceipt.presentation`,
  `App/SettingsStore`, `App/SettingsView`, `GameContainerView`, `GameScene`,
  `HUDRenderer`. No change to simulation rules, arena, or replay identity.

## Constraints

Product-true locks (do not reopen in implement):

- Settings are local, independent, and excluded from replay authority. Nothing
  here may become a simulation input.
- The gameplay digest must not change. ER-007 is the acceptance vector.
- Controls never scale below their baseline or the 44-point touch target.
- Captions appear regardless of audio settings; haptics are never the only
  carrier.

Non-goals:

- Any new setting the contracts do not already name
- Cloud sync or per-profile settings

## Open questions

- `state.handedness` exists in `WorldState` and is always `.right`. The App now
  reads handedness from the settings store instead, because handedness is
  presentation and does not belong in authoritative state. The field is now
  unused and could be removed in a later change; I left it rather than widen
  this one.

## Claims

| Claim | Label |
|---|---|
| No setting reaches the digest | `[verified: PresentationSettingsTests.noSettingAppearsInTheDigest inspects the canonical form for every setting name]` |
| A settings change moves only the receipt's presentation block | `[verified: PresentationSettingsTests.settingsMoveOnlyTheReceiptPresentationBlock compares receipts field by field]` |
| Mix defaults match audio-haptics-001 | `[verified: 100/70/85/100/80]` |
| Stored settings are untrusted input | `[verified: decoding clamps out-of-range values; a decode failure falls back to defaults]` |
| Left-handed play now reachable | `[verified: handedness picker drives HUDRenderer.configure and ControlLayout]` |

## Next

A human accepts this file (`Status: accepted`).
