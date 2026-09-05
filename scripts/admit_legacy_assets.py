#!/usr/bin/env python3
"""Admit role-identical legacy assets under legacy-admission.md.

Reads a checkout of the frozen legacy commit, resamples each admitted sprite to
the `visual-language-001` box for its role, copies admitted audio, and rewrites
`asset-catalog-001.json` with an `asset-record-001` entry per delivered file.

The admission test this implements is the one the specification states:

1. role identity — every mapping below pairs a legacy family with a clip whose
   runtime role is the same. Nothing maps a guard onto a Civic Seam enemy.
2. per-asset record — `sha256` is the digest of the file *at the frozen commit*,
   so admission stays verifiable against immutable evidence.
3. authored geometry — frames are resampled into the authored sprite box with
   nearest-neighbour filtering, bottom-anchored on the clip's anchor. Legacy
   pixel dimensions carry no authority.
4. no inference — nothing here reads collision, targeting, or Camera geometry.
5. audio obligations survive — this only delivers files; priority, coalescence,
   and captions stay with AudioProjector.

Usage:
    scripts/admit_legacy_assets.py --legacy <path-to-frozen-checkout> [--dry-run]

The frozen checkout must be scrimshawlife-ctrl/Surveillance-Survivor at
3b20d88d6a6e1fe8f07f45f581359d371fa65d98. The script verifies that by hashing a
known file before it writes anything.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image
except ImportError:
    sys.exit("Pillow is required: pip install pillow")

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "Sources/SurveillanceCore/Resources/contracts"
DELIVERY = ROOT / "Sources/SurveillanceCore/Resources/RuntimeAssets"

LEGACY_REPO = "scrimshawlife-ctrl/Surveillance-Survivor"
LEGACY_COMMIT = "3b20d88d6a6e1fe8f07f45f581359d371fa65d98"
# A file whose digest is already recorded in ArtSources/legacy-evidence/README.md.
FROZEN_PROBE = (
    "Resources/RuntimeSprites/san_francisco_skyline_parallax_01.png",
    "222e76f122b5e0beff86cce5c66e0220a5afb6a2a620257b5b4150cc9d27663d",
)

LICENSE_AUDIO = "ElevenLabs commercial license (owner account), recorded on the frozen audio manifest"
LICENSE_SPRITE = "Owned work product, Zero State LLC, from the frozen legacy commit"

# --- role mappings -----------------------------------------------------------
# Direction letters are the clip contract's: n, e, s, w.
DIRS = {"n": "up", "e": "right", "s": "down", "w": "left"}


def numbered(stem: str, count: int) -> list[str]:
    """Legacy frame numbering: stem.png, stem_2.png ... stem_N.png."""
    return [f"{stem}.png" if i == 1 else f"{stem}_{i}.png" for i in range(1, count + 1)]


def directional(stem_fmt: str, count: int) -> dict[str, list[str]]:
    return {d: numbered(stem_fmt.format(L), count) for d, L in DIRS.items()}


# clipId -> either {direction: [files]} or {"*": [files]} for non-directional pools.
SPRITE_POOLS: dict[str, dict[str, list[str]]] = {
    "player_idle": directional("player_idle_{}", 2),
    "player_move": directional("player_walk_{}", 6),
    "player_hurt": {"*": numbered("player_damage", 4)},
    "player_defeat": {"*": numbered("player_defeat", 10)},
    "player_extraction": {"*": numbered("player_extract", 10)},
    "camera_operational_idle": {"*": numbered("lpr_scan_loop", 6)},
    "camera_hit": {"*": ["lpr_damaged.png"] + numbered("fx_camera_disabled", 4)},
    "camera_critical_enter": {"*": numbered("fx_camera_disabled", 4)},
    "camera_destroy": {"*": numbered("lpr_destroy_sequence", 10)},
    "camera_field_off": {"*": numbered("fx_camera_destroyed", 8)},
    "camera_destroyed_idle": {"*": ["lpr_destroyed.png"] + numbered("fx_camera_destroyed", 8)},
}

# audio event ID -> legacy delivery path, only where gameplay meaning matches.
AUDIO_MAP: dict[str, str] = {
    "weapon_civic_pulse": "Runtime/sfx_weapon_fire.caf",
    "impact_enemy": "Runtime/sfx_countermeasure_hit.caf",
    "player_damage": "Runtime/sfx_player_damaged.caf",
    "player_death": "Runtime/sfx_player_defeated.caf",
    "camera_destroy": "Runtime/sfx_lpr_destroyed.caf",
    "camera_hit_01": "Shared/sfx_camera_scan_sweep.caf",
    "camera_field_off": "Shared/sfx_blind_spot_field_loop.caf",
    "exposure_state_up": "Runtime/sfx_suspicion_tier_up.caf",
    "extraction_armed": "Runtime/sfx_extraction_opened.caf",
    "run_success": "Runtime/sfx_extraction_completed.caf",
    "upgrade_selected_signalJammer": "Runtime/sfx_upgrade_selected.caf",
    "upgrade_selected_ricochetPulse": "Runtime/sfx_upgrade_selected.caf",
    "upgrade_selected_ghostStep": "Runtime/sfx_upgrade_selected.caf",
    # Five more cues whose legacy sound-design intent is the same gameplay
    # meaning, per the LC-010 admission test. The manifest prompt at the frozen
    # commit is quoted in each record's notes so the match can be checked.
    #
    #   camera_critical       <- "infrastructure integrity shift ... municipal
    #                            fault tone": a Camera at Integrity 1 is exactly
    #                            that
    #   camera_network_tamper <- "enemy coordination chain update ... cascade
    #                            confirm": the surveillance network losing a node
    #   lockdown_enter        <- "municipal PA power-up, security shutters,
    #                            synchronized camera servos ... institutional
    #                            authority": Lockdown is the city asserting itself
    #   daemon_query          <- "bureaucratic relay click, budget stamp,
    #                            institutional alert": an improper search is a
    #                            determination being made
    #   network_blackout      <- "lattice lock-in chirp, prepared-electronic
    #                            confirm": completing the full set of eight
    "camera_critical": "Runtime/sfx_city_state_changed.caf",
    "camera_network_tamper": "Runtime/sfx_coordination_changed.caf",
    "lockdown_enter": "Runtime/sfx_boss_activated.caf",
    "daemon_query": "Runtime/sfx_director_decision.caf",
    "network_blackout": "Runtime/sfx_build_synergy_changed.caf",
}

# Music beds, registered as `musicAssetIds` in presentation-assets-001. These
# are continuous beds, not event cues: no priority, no coalescence, no voice
# cost. The legacy run loop backs both `explore` and `observed` because it is
# the same "not yet in trouble" bed in both games; lockdown, extraction, and
# terminal have no legacy equivalent and stay planned originals.
MUSIC_MAP: dict[str, str] = {
    "music_explore": "Cities/san_francisco/music_san_francisco_run_loop.caf",
    "music_observed": "Cities/san_francisco/music_san_francisco_run_loop.caf",
    "music_boss": "Cities/san_francisco/music_san_francisco_boss_loop.caf",
    "ambience_civic_seam": "Cities/san_francisco/amb_san_francisco_city_identity_loop.caf",
    # The remaining three states take Shared beds. `Shared/` is not a city pack,
    # so T102's exclusion of non-San-Francisco packs does not reach it — the
    # same route by which sfx_camera_scan_sweep and sfx_blind_spot_field_loop
    # were already admitted. Each is matched to the state by what the zone it
    # was written for is doing, not by its name:
    #   lockdown   <- a security zone under active watch          (59s)
    #   extraction <- an urgent downtown push                     (44s)
    #   terminal   <- resolution after the pressure stops         (29s)
    "music_lockdown": "Shared/amb_shared_retail_security_zone_loop.caf",
    "music_extraction": "Shared/amb_shared_smart_downtown_loop.caf",
    "music_terminal": "Shared/amb_shared_gated_serenity_loop.caf",
}

DEFERRED_MUSIC: dict[str, str] = {}

ROLE_BOX = {
    "player": "playerAndStandardEnemy",
    "camera": "cameraPole",
    "improperSearchDaemon": "improperSearchDaemon",
    "algorithmicModerate": "algorithmicModerate",
}


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def deliver_audio(src: Path, dst: Path) -> None:
    """Transcode a delivery clip to AAC.

    The frozen clips are 48 kHz stereo Int16 PCM, which is a mastering format,
    not a shipping one: the four music beds alone are 32 MB uncompressed. This
    is the audio counterpart of resampling a sprite into its authored box — the
    record's `sha256` still documents the immutable source, and `runtimePath`
    names the delivered artifact.
    """
    dst.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["afconvert", "-f", "m4af", "-d", "aac", "-b", "128000", str(src), str(dst)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(f"afconvert failed for {src.name}: {result.stderr.strip()}")


def resample(src: Path, dst: Path, box_w: int, box_h: int, anchor: dict) -> tuple[int, int]:
    """Fit the frame inside the authored box, preserving aspect.

    Ground contact must be stable (`groundContactMustBeStable`), so the frame is
    bottom-aligned on the clip anchor's baseline and centred horizontally.
    Nearest-neighbour matches `visual-language-001.filtering`.
    """
    with Image.open(src) as im:
        im = im.convert("RGBA")
        scale = min(box_w / im.width, box_h / im.height)
        w = max(1, round(im.width * scale))
        h = max(1, round(im.height * scale))
        resized = im.resize((w, h), Image.NEAREST)
        canvas = Image.new("RGBA", (box_w, box_h), (0, 0, 0, 0))
        baseline = min(box_h, int(anchor.get("y", box_h)))
        canvas.paste(resized, ((box_w - w) // 2, max(0, baseline - h)), resized)
        dst.parent.mkdir(parents=True, exist_ok=True)
        canvas.save(dst, "PNG", optimize=True)
    return box_w, box_h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--legacy", required=True, type=Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    legacy = args.legacy.resolve()
    probe = legacy / FROZEN_PROBE[0]
    if not probe.exists():
        return fail(f"not a legacy checkout: {probe} missing")
    if sha256_of(probe) != FROZEN_PROBE[1]:
        return fail(
            "checkout does not match the frozen commit.\n"
            f"  {FROZEN_PROBE[0]}\n"
            f"  expected {FROZEN_PROBE[1]}\n"
            f"  found    {sha256_of(probe)}\n"
            "The Zero State repository is a separate history and is not an admission source."
        )

    sprites = legacy / "Resources/RuntimeSprites"
    audio = legacy / "Resources/Audio/Delivery"
    visual = json.loads((CONTRACTS / "visual-language-001.json").read_text())
    boxes = visual["spriteBoxes"]
    clips = json.loads((CONTRACTS / "clip-metadata-001.json").read_text())["clips"]

    records: list[dict] = []
    delivered = 0
    skipped: list[str] = []

    for clip in clips:
        pool = SPRITE_POOLS.get(clip["clipId"])
        if pool is None:
            skipped.append(f"{clip['clipId']}: no legacy source ({len(clip['frameIds'])} frames)")
            continue
        role = clip["actorRole"]
        box = boxes[ROLE_BOX[role]]
        dirs = clip.get("directions") or ["-"]
        per = len(clip["frameIds"]) // len(dirs)
        for di, direction in enumerate(dirs):
            files = pool.get(direction) or pool.get("*") or []
            for fi in range(per):
                frame_id = clip["frameIds"][di * per + fi]
                if fi >= len(files):
                    skipped.append(f"{frame_id}: pool exhausted")
                    continue
                src = sprites / files[fi]
                if not src.exists():
                    skipped.append(f"{frame_id}: missing {files[fi]}")
                    continue
                name = f"{frame_id}@1x.png"
                dst = DELIVERY / name
                if not args.dry_run:
                    resample(src, dst, box["width"], box["height"], clip.get("anchor", {}))
                delivered += 1
                records.append(
                    {
                        "admissionDecision": "adaptedAdmitted",
                        "record": {
                            "schemaVersion": "asset-record-001",
                            "assetId": frame_id,
                            "kind": "sprite",
                            "productionStatus": "accepted",
                            "runtimeRequired": True,
                            "provenance": "adaptedLegacy",
                            "license": LICENSE_SPRITE,
                            "source": f"legacy://Resources/RuntimeSprites/{files[fi]}@{LEGACY_COMMIT}",
                            "runtimePath": name,
                            "sha256": sha256_of(src),
                            "dimensions": {"width": box["width"], "height": box["height"]},
                            "colorSpace": "sRGB",
                            "alpha": "straight",
                            "ownerContract": "clip-metadata-001",
                            "notes": (
                                f"LC-009 bounded ADAPT. Role-identical: legacy {files[fi]} backs "
                                f"{clip['clipId']} for role {role}. Resampled to the "
                                f"visual-language-001 {ROLE_BOX[role]} box, nearest-neighbour, "
                                "bottom-anchored. sha256 is the digest at the frozen commit."
                            ),
                        },
                    }
                )

    # One source may back several IDs (upgrade_selected backs three upgrades,
    # the run loop backs explore and observed). Deliver each source once and let
    # every record that shares it point at the same file.
    delivered_by_source: dict[str, str] = {}
    for asset_id, rel in list(AUDIO_MAP.items()) + list(MUSIC_MAP.items()):
        src = audio / rel
        if not src.exists():
            skipped.append(f"{asset_id}: missing {rel}")
            continue
        if rel in delivered_by_source:
            name = delivered_by_source[rel]
        else:
            name = f"{Path(rel).stem}.m4a"
            delivered_by_source[rel] = name
            if not args.dry_run:
                deliver_audio(src, DELIVERY / name)
            delivered += 1
        records.append(
            {
                "admissionDecision": "adaptedAdmitted",
                "record": {
                    "schemaVersion": "asset-record-001",
                    "assetId": asset_id,
                    "kind": "music" if asset_id.startswith(("music_", "ambience_")) else "audio",
                    "productionStatus": "accepted",
                    "runtimeRequired": True,
                    "provenance": "adaptedLegacy",
                    "license": LICENSE_AUDIO,
                    "source": f"legacy://Resources/Audio/Delivery/{rel}@{LEGACY_COMMIT}",
                    "runtimePath": name,
                    "sha256": sha256_of(src),
                    "dimensions": None,
                    "colorSpace": None,
                    "alpha": None,
                    "ownerContract": "audio-haptics-001",
                    "notes": (
                        f"LC-010 bounded ADAPT. Same gameplay meaning as {asset_id}. "
                        "Delivered as AAC; sha256 is the digest of the PCM source at the "
                        "frozen commit. Priority, coalescence, and captions remain with "
                        "AudioProjector."
                    ),
                },
            }
        )

    # A registered music ID with no admitted bed still needs a catalog entry, or
    # the loader fails closed on an uncovered presentation ID.
    presentation = json.loads((CONTRACTS / "presentation-assets-001.json").read_text())
    for asset_id in presentation.get("musicAssetIds", []):
        if asset_id in MUSIC_MAP:
            continue
        records.append(
            {
                "admissionDecision": "plannedOriginal",
                "record": {
                    "schemaVersion": "asset-record-001",
                    "assetId": asset_id,
                    "kind": "music",
                    "productionStatus": "planned",
                    "runtimeRequired": True,
                    "provenance": "projectOriginal",
                    "license": None,
                    "source": None,
                    "runtimePath": None,
                    "sha256": None,
                    "dimensions": None,
                    "colorSpace": None,
                    "alpha": None,
                    "ownerContract": "audio-haptics-001",
                    "notes": (
                        f"No legacy bed carries this state. {asset_id} stays a project "
                        "original; the state plays no music until it is produced."
                    ),
                },
            }
        )

    catalog_path = CONTRACTS / "asset-catalog-001.json"
    catalog = json.loads(catalog_path.read_text())
    admitted_ids = {r["record"]["assetId"] for r in records}
    # Legacy entries that are now admitted lose their old rejected row.
    kept = [
        e
        for e in catalog["entries"]
        if e["record"]["assetId"] not in admitted_ids
    ]
    # Preserve the existing order and append; downstream tests address entries
    # positionally, and churn there would be noise rather than signal.
    catalog["entries"] = kept + sorted(records, key=lambda e: e["record"]["assetId"])
    if not args.dry_run:
        catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")

    print(f"delivered {delivered} assets -> {DELIVERY.relative_to(ROOT)}")
    print(f"catalog entries now {len(catalog['entries'])}")
    if skipped:
        print(f"\nnot backed by legacy ({len(skipped)}):")
        for line in skipped[:12]:
            print(f"  {line}")
        if len(skipped) > 12:
            print(f"  … and {len(skipped) - 12} more")
    return 0


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
