# Specification Baseline

Status: PINNED

| Identity | Value |
|---|---|
| Specification repository | `scrimshawlife-ctrl/SS-specs` |
| Specification commit | `4a0bbd978d107faf29085b888bb1bcb862f2d928` |
| Ruleset | `ss-rules-001` |
| Content | `civic-seam-content-001` |
| Arena | `civic-seam-arena-001` |
| Replay schema | `runtime-kernel-001` |

Changing any pinned identity requires:

1. an adopted SS-specs commit;
2. affected contract and task IDs;
3. fixture review;
4. an explicit version migration or fail-closed incompatibility;
5. this file and `ContractVersions.swift` updated together.

Legacy evidence is frozen at `scrimshawlife-ctrl/Surveillance-Survivor@3b20d88d6a6e1fe8f07f45f581359d371fa65d98`. Copying legacy files is prohibited. Bounded reimplementation must follow `legacy-admission.md`.
