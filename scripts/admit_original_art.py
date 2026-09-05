#!/usr/bin/env python3
"""Admit delivered original art.

Reads a delivery folder of PNGs named by asset ID, reconciles them against
`clip-metadata-001` and `presentation-assets-001`, copies what matches into the
runtime bundle, and writes an `asset-record-001` entry per delivered file.

Two reconciliations happen on the way in, both mechanical:

1. **Clip state, not clip suffix.** A clip's frame IDs are built from its
   `state` field, not the suffix of its `clipId`. So the clip
   `fogAnalyticsCloud_anticipate` produces `actor_fogAnalyticsCloud_pulse_…`.
   A delivery named after the clip ID is renamed here rather than rejected.

2. **Superseded clip names.** The Captain's attack clips were renamed to the
   attack IDs they present. A delivery using the old names is remapped.

Coverage is all-or-nothing per clip direction, so a direction that is short a
frame contributes nothing and the actor keeps its blockout. That is the
partial-coverage rule in `legacy-admission.md`, and it is why this script
reports short directions rather than admitting a stutter.

Usage:
    scripts/admit_original_art.py --from <delivery-dir> [--dry-run]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ROOT / "Sources/SurveillanceCore/Resources/contracts"
DELIVERY = ROOT / "Sources/SurveillanceCore/Resources/RuntimeAssets"

LICENSE = "Owned original work product, Zero State LLC"

# Captain attack clips renamed to the attacks they present.
SUPERSEDED_STATES = {
    "commandPulse": "safetyRationale",
    "targetedStrike": "narrowTailoring",
    "sweep": "independentReview",
    "reinforcementCall": "temporaryOrder",
}

# Delivered names that differ from the required asset ID.
SUPERSEDED_ASSET_IDS = {
    "objective_phoenix_network_blackout": "objective_network_blackout",
}


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_header(path: Path) -> tuple[int, int, bool] | None:
    """(width, height, has_alpha) without decoding the image."""
    with path.open("rb") as handle:
        head = handle.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    width, height = struct.unpack(">II", head[16:24])
    return width, height, head[25] in (4, 6)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="source", required=True, type=Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    source = args.source.expanduser().resolve()
    if not source.is_dir():
        return fail(f"not a directory: {source}")

    clips = json.loads((CONTRACTS / "clip-metadata-001.json").read_text())["clips"]
    presentation = json.loads((CONTRACTS / "presentation-assets-001.json").read_text())
    visual = json.loads((CONTRACTS / "visual-language-001.json").read_text())
    boxes = visual["spriteBoxes"]
    catalog_path = CONTRACTS / "asset-catalog-001.json"
    catalog = json.loads(catalog_path.read_text())
    already = {
        e["record"]["assetId"]
        for e in catalog["entries"]
        if e["admissionDecision"] == "adaptedAdmitted"
    }

    delivered = {p.stem: p for p in source.glob("*.png")}

    # --- reconcile names -----------------------------------------------------
    def locate(asset_id: str) -> Path | None:
        """Find the delivered file for a required ID, under any known alias."""
        if asset_id in delivered:
            return delivered[asset_id]
        m = re.match(r"actor_([A-Za-z]+)_([A-Za-z]+)_([nesw]|none)_(\d+)$", asset_id)
        if m:
            role, state, direction, frame = m.groups()
            aliases = []
            # (1) delivered under the clip ID suffix instead of the state
            for clip in clips:
                if clip["actorRole"] == role and clip["state"] == state:
                    suffix = clip["clipId"].split("_", 1)[1]
                    aliases.append(f"actor_{role}_{suffix}_{direction}_{frame}")
            # (2) delivered under a superseded state name
            for old, new in SUPERSEDED_STATES.items():
                if new == state:
                    aliases.append(f"actor_{role}_{old}_{direction}_{frame}")
            for alias in aliases:
                if alias in delivered:
                    return delivered[alias]
        for old, new in SUPERSEDED_ASSET_IDS.items():
            if new == asset_id and old in delivered:
                return delivered[old]
        return None

    box_for = {
        "player": boxes["playerAndStandardEnemy"],
        "improperSearchDaemon": boxes["improperSearchDaemon"],
        "algorithmicModerate": boxes["algorithmicModerate"],
        "camera": boxes["cameraPole"],
    }

    records: list[dict] = []
    short_directions: list[str] = []
    rejected: list[str] = []
    used: set[str] = set()

    # --- clip frames, all-or-nothing per direction ---------------------------
    for clip in clips:
        role = clip["actorRole"]
        directions = clip.get("directions") or ["-"]
        per = len(clip["frameIds"]) // len(directions)
        box = box_for.get(role, boxes["playerAndStandardEnemy"])
        for index, direction in enumerate(directions):
            ids = clip["frameIds"][index * per:(index + 1) * per]
            if all(i in already for i in ids):
                continue  # already backed by admitted legacy art
            found = {i: locate(i) for i in ids}
            missing = [i for i, p in found.items() if p is None and i not in already]
            if missing:
                short_directions.append(
                    f"{clip['clipId']} [{direction}] short {len(missing)}/{per}"
                )
                continue
            for asset_id, path in found.items():
                if path is None or asset_id in already:
                    continue
                header = png_header(path)
                if header is None:
                    rejected.append(f"{asset_id}: not a PNG")
                    continue
                width, height, has_alpha = header
                if (width, height) != (box["width"], box["height"]):
                    rejected.append(
                        f"{asset_id}: {width}x{height}, expected "
                        f"{box['width']}x{box['height']}"
                    )
                    continue
                records.append(
                    record_for(
                        asset_id,
                        path,
                        kind="sprite",
                        dimensions={"width": width, "height": height},
                        alpha="straight" if has_alpha else "opaque",
                        owner="clip-metadata-001",
                        note=(
                            f"Original art for {clip['clipId']} [{direction}]. "
                            f"Delivered as {path.stem}."
                        ),
                    )
                )
                used.add(path.stem)

    # --- interface assets ----------------------------------------------------
    for asset_id in presentation["requiredAssetIds"]:
        if asset_id in already:
            continue
        path = locate(asset_id)
        if path is None:
            short_directions.append(f"{asset_id} not delivered")
            continue
        header = png_header(path)
        if header is None:
            rejected.append(f"{asset_id}: not a PNG")
            continue
        width, height, has_alpha = header
        records.append(
            record_for(
                asset_id,
                path,
                kind="ui",
                dimensions={"width": width, "height": height},
                alpha="straight" if has_alpha else "opaque",
                owner="presentation-assets-001",
                note=f"Original interface asset. Delivered as {path.stem}.",
            )
        )
        used.add(path.stem)

    # --- write ---------------------------------------------------------------
    if not args.dry_run:
        DELIVERY.mkdir(parents=True, exist_ok=True)
        for entry in records:
            shutil.copyfile(entry.pop("_source"), DELIVERY / entry["record"]["runtimePath"])
        admitted_ids = {r["record"]["assetId"] for r in records}
        kept = [e for e in catalog["entries"] if e["record"]["assetId"] not in admitted_ids]
        catalog["entries"] = kept + sorted(records, key=lambda e: e["record"]["assetId"])
        catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")
    else:
        for entry in records:
            entry.pop("_source", None)

    print(f"admitted {len(records)} original assets")
    unused = sorted(set(delivered) - used)
    if unused:
        print(f"\ndelivered but unused ({len(unused)}):")
        for name in unused[:10]:
            print(f"  {name}")
        if len(unused) > 10:
            print(f"  … and {len(unused) - 10} more")
    if short_directions:
        print(f"\nnot admitted — incomplete or absent ({len(short_directions)}):")
        for line in short_directions:
            print(f"  {line}")
    if rejected:
        print(f"\nrejected ({len(rejected)}):")
        for line in rejected:
            print(f"  {line}")
    return 0


def record_for(asset_id, path, *, kind, dimensions, alpha, owner, note) -> dict:
    return {
        "_source": path,
        "admissionDecision": "originalAccepted",
        "record": {
            "schemaVersion": "asset-record-001",
            "assetId": asset_id,
            "kind": kind,
            "productionStatus": "accepted",
            "runtimeRequired": True,
            "provenance": "projectOriginal",
            "license": LICENSE,
            "source": f"original://Surveillance-Survivor-Art/{path.name}",
            "runtimePath": f"{asset_id}@1x.png",
            "sha256": sha256_of(path),
            "dimensions": dimensions,
            "colorSpace": "sRGB",
            "alpha": alpha,
            "ownerContract": owner,
            "notes": note,
        },
    }


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
