# Intent — CI build guard and the merge artifact it hid

Author: prabu-openclaw
Date: 2026-09-05
Status: accepted
Product: Surveillance Survivor Runtime (`scrimshawlife-ctrl/SS-runtime`)

This file is a proto-spec. It comes **before** specify.
Next stage is `spec.md` in `scrimshawlife-ctrl/SS-specs` (pinned by
`SPEC_BASELINE.md`). Do not skip to code.

One committed intent per **runtime-only** change stream. Live under `intent/`.
Do not invent gameplay. Product intent stays in SS-specs.

## Problem / why now

`main` does not compile, and CI reports it green.

Two independent defects compound:

1. `App/HUDRenderer.swift` carries a byte-identical duplicate of the upgrade
   card geometry block (`upgradeCardSize`, `upgradeCardGap`,
   `upgradeCardRects(projector:)`, `upgradeCardCentre(for:projector:)`).
   Four `invalid redeclaration` errors. This is a semantic merge artifact: each
   contributing PR compiled alone, and the squash merges stacked both copies.

2. The `app` job's build guard cannot fail. It runs

   ```
   xcodebuild ... | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" || true
   test "${PIPESTATUS[0]}" -eq 0
   ```

   Under `set -o pipefail` a failed `xcodebuild` makes the pipeline non-zero, so
   `|| true` fires — and running `true` **resets `PIPESTATUS` to `[0]`**. The
   guard then reads 0 and passes. The job has never been able to fail on a
   build error, which is exactly why (1) reached `main` unnoticed.

[verified: `xcodebuild -scheme SSRuntime -sdk iphonesimulator` on 842b4c9 fails
with 4 `invalid redeclaration` errors at `App/HUDRenderer.swift:624-648`, while
`gh run list --branch main` reports `success` for that same SHA. The
`PIPESTATUS` reset is reproduced standalone in a 4-line bash probe.]

## Proposed outcome

Observable done (a stranger can check this without reading the chat):

- `xcodebuild -scheme SSRuntime -sdk iphonesimulator ... build` reports
  `** BUILD SUCCEEDED **` on `main`.
- The `app` CI job exits non-zero when `xcodebuild` exits non-zero, and zero
  when it succeeds — verified by probe, not by assertion.
- `swift test` stays green (356 tests, 60 suites) — this change removes a
  duplicate and touches no behaviour.

## Affected users / systems

- Users: anyone building the app from a clean checkout; every future PR author
  who would otherwise trust a green `app` check.
- Systems: `.github/workflows/ci.yml` (`app` job), `App/HUDRenderer.swift`.

## Constraints

Product-true locks (do not reopen in implement):

- Spec-pinned runtime. Do not invent gameplay the pinned SS-specs commit does not name.
- The surviving copy of the card geometry is unchanged. The two blocks are
  byte-identical (`md5` equal), so this is a deletion, not a merge of variants —
  no card moves by a pixel, and the hit test is untouched.
- Keep the grep summary in CI. Losing the human-readable error digest in the
  log would trade one usability problem for another.

Non-goals:

- Another level, weapon, character, campaign system, online feature, or meta-progression
- Reworking how the HUD lays out upgrade cards
- Auditing other CI jobs for unrelated shell issues

## Open questions

- Should CI also fail on `warning:`? Today warnings are surfaced but not
  enforced. Out of scope here; raising it because the same job prints them.
- Do the merged-but-still-`draft` intents (all eight now) need a batch accept,
  or does the gate only bind pre-merge? This PR does not assume an answer.

## Claims

| Claim | Label |
|---|---|
| The two card-geometry blocks are byte-identical | `[verified: md5 of lines 588-619 and 621-652 both e88066ec2e50d76d2ea2ce848cfe1be0]` |
| `true` resets `PIPESTATUS`, defeating the guard | `[verified: standalone bash probe prints PIPESTATUS[0]=0 after a simulated exit 65]` |
| The replacement guard fails and passes correctly | `[verified: probe exits 65 on simulated failure, 0 on simulated success]` |
| The duplicate arrived via squash merge, not a bad edit | `[assumed: each PR's app check was green pre-merge, and the block appears once per contributing branch]` |
| No gameplay or replay identity changes | `[verified: 356 tests in 60 suites pass, including digest and receipt round-trip gates]` |

## Next

A human accepts this file (`Status: accepted`). This change stream is truly
runtime-only — CI glue plus a compile repair — so it does not require a
matching `spec.md` in SS-specs.
