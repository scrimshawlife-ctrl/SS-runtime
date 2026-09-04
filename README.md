# Surveillance Survivor Runtime

iPhone runtime for the one-level **Surveillance Survivor** reboot.

## Canonical specification

- Repository: [scrimshawlife-ctrl/SS-specs](https://github.com/scrimshawlife-ctrl/SS-specs)
- Baseline commit: `39b04bb00ca5d3799513efed4e7970ec42975c96`
- Ruleset: `ss-rules-001`
- Content: `civic-seam-content-001`
- Arena: `civic-seam-arena-001`
- Replay schema: `runtime-kernel-001`

Runtime behavior must trace to that baseline or a later explicitly adopted specification commit.

## Agent contract

Coding agents follow [`AGENTS.md`](AGENTS.md). Claude adapters use [`CLAUDE.md`](CLAUDE.md). Runtime-only intents live in [`intent/`](intent/). Gameplay intent is SS-specs at the pin above — do not invent it here.

## Platform

- iPhone only
- iOS 18.0+
- landscape left and right
- Swift 6
- SwiftUI shell
- SpriteKit renderer
- deterministic 60 Hz authoritative simulation
- 60 fps presentation target

## Bootstrap

```sh
swift test
xcodegen generate
open SSRuntime.xcodeproj
```

XcodeGen is used only to generate the project from `project.yml`. Do not commit personal signing data.

## Architecture boundary

`SurveillanceCore` owns gameplay authority and has no SpriteKit, SwiftUI, wall-clock, audio, haptic, or device dependencies. `App/` projects authoritative state to iPhone presentation.

Implementation order is defined by SS-specs `completeness-audit.md`.
