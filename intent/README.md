# Intent — Surveillance Survivor Runtime

This directory holds **runtime-only** proto-specs. It does not own gameplay.

## Product intent lives in SS-specs

Gameplay, rules, and observable product intent are specified in
[`scrimshawlife-ctrl/SS-specs`](https://github.com/scrimshawlife-ctrl/SS-specs)
at the commit pinned in [`../SPEC_BASELINE.md`](../SPEC_BASELINE.md).

Start there:

- `specs/000-constitution.md`
- `specs/001-single-level-vertical-slice/spec.md` (section 1, Product intent)
- `specs/001-single-level-vertical-slice/plan.md` and `tasks.md`

SS-specs does not currently ship an `intent/` folder. Until it does, treat
those spec artifacts as the product intent home. Do **not** invent a parallel
gameplay intent in this runtime.

## When to use a local intent

Commit a file here only for a **runtime-only** change stream that does not
change rules, content, arena, or replay identity. Examples: docs, CI glue,
XcodeGen bootstrap, presentation projection that already has a spec.

One committed intent per change stream. Copy [`_TEMPLATE.md`](_TEMPLATE.md).
A human sets `Status: accepted` before specify (in SS-specs if the work
touches product behavior) or before implement (if it is truly runtime-only).

Do not skip to code. Do not fill this template with invented weapons, levels,
characters, campaign systems, online features, or meta-progression.

## SDLC order

Canonical pack: `Zero-State-LLC/agent-context` `templates/sdlc/README.md`.

`intent.md` → constitution (if needed) → specify → plan → tasks → implement
→ REVIEW / evidence → land.

FORGE owns plan and tasks. Cloud agents implement. Human yes on deploy,
spend, and legal.
