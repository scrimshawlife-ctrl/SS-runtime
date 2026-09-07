#!/usr/bin/env python3
"""Admit delivered environment art against `presentation-assets-001`.

Sibling of `admit_original_art.py`, with one important difference: the sizes are
not free. A solid's art is drawn over its collision box, so it is verified
against `civic-seam-arena-001` rather than against an authored sprite box —
art that does not match its solid is refused rather than resampled, because
silently stretching a building to fit is how a player ends up blocked by
something that looks passable.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = ROOT / "Sources/SurveillanceCore/Resources/contracts"
DELIVERY = ROOT / "Sources/SurveillanceCore/Resources/RuntimeAssets"

LICENSE = "Original production for Surveillance Survivor, owner account"

# Ground tiles repeat across the plane; one tile spans 2x2 authoring cells.
GROUND_BOX = (128, 128)
# camera-placement-001 pole box, matching visual-language-001.
CAMERA_BOX = (64, 96)


def fail(message: str) -> int:
    print(f"error: {message}", file=sys.stderr)
    return 1


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def expected_sizes() -> dict[str, tuple[int, int]]:
    """Authoritative sizes, derived rather than authored twice."""
    arena = json.loads((CONTRACTS / "civic-seam-arena-001.json").read_text())
    sizes: dict[str, tuple[int, int]] = {}
    for solid in arena["permanentSolids"]:
        half = solid["halfSize"]
        asset_id = "env_" + solid["id"].replace("-", "_")
        sizes[asset_id] = (half["x"] * 2, half["y"] * 2)
    return sizes


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="source", required=True, type=Path)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    source = args.source.expanduser().resolve()
    if not source.is_dir():
        return fail(f"not a directory: {source}")

    presentation = json.loads((CONTRACTS / "presentation-assets-001.json").read_text())
    declared: list[str] = presentation.get("environmentAssetIds", [])
    if not declared:
        return fail(
            "presentation-assets-001 declares no environmentAssetIds. "
            "Without them the bundle filter cannot reach environment art."
        )

    catalog_path = CONTRACTS / "asset-catalog-001.json"
    catalog = json.loads(catalog_path.read_text())
    already = {
        e["record"]["assetId"]
        for e in catalog["entries"]
        if e["admissionDecision"] in ("adaptedAdmitted", "originalAccepted")
    }

    solid_sizes = expected_sizes()
    records: list[dict] = []
    missing: list[str] = []
    rejected: list[str] = []

    # Re-delivery: an asset already admitted is replaced when its source digest
    # has changed, rather than skipped. Regeneration is normal here, and silently
    # keeping the old art would be the worst outcome — the catalog would claim a
    # provenance the shipped file no longer has.
    existing_digest = {
        e["record"]["assetId"]: e["record"].get("sha256")
        for e in catalog["entries"]
    }
    replaced: list[str] = []

    for asset_id in declared:
        src = source / f"{asset_id}.png"
        if asset_id in already:
            if not src.exists() or existing_digest.get(asset_id) == sha256_of(src):
                continue
            catalog["entries"] = [
                e for e in catalog["entries"] if e["record"]["assetId"] != asset_id
            ]
            replaced.append(asset_id)
        if not src.exists():
            missing.append(asset_id)
            continue

        image = Image.open(src)
        width, height = image.size

        # Sized groups are checked, never resampled. Motifs and props are
        # reference sheets and placed art whose size the contract does not fix.
        want: tuple[int, int] | None = None
        if asset_id in solid_sizes:
            want = solid_sizes[asset_id]
        elif asset_id.startswith("env_ground_"):
            want = GROUND_BOX
        elif asset_id.startswith("env_camera_"):
            want = CAMERA_BOX

        if want is not None and (width, height) not in (want, (want[0] * 2, want[1] * 2)):
            rejected.append(
                f"{asset_id}: {width}x{height}, contract requires {want[0]}x{want[1]}"
            )
            continue

        name = f"{asset_id}@1x.png"
        if not args.dry_run:
            out = DELIVERY / name
            if (width, height) != want and want is not None:
                # Exactly 2x: downsample once, nearest, so authored pixels stay crisp.
                image.resize(want, Image.NEAREST).save(out)
            else:
                out.write_bytes(src.read_bytes())

        records.append(
            {
                "admissionDecision": "originalAccepted",
                "record": {
                    "schemaVersion": "asset-record-001",
                    "assetId": asset_id,
                    "kind": "sprite",
                    "productionStatus": "accepted",
                    # originalAccepted requires this. It means "ships in the
                    # runtime bundle", not "the game refuses to start without
                    # it" — the all-or-nothing fallback is a renderer behaviour
                    # and is independent of this flag.
                    "runtimeRequired": True,
                    "provenance": "projectOriginal",
                    "license": LICENSE,
                    "source": f"original://Surveillance-Survivor-Art/{asset_id}.png",
                    "runtimePath": name,
                    "sha256": sha256_of(src),
                    "dimensions": {"width": want[0] if want else width,
                                   "height": want[1] if want else height},
                    "colorSpace": "sRGB",
                    "alpha": "straight",
                    "ownerContract": "presentation-assets-001",
                    "notes": (
                        "Original environment art. Solid sizes are verified against "
                        "civic-seam-arena-001 rather than resampled: art that does not "
                        "match its collision box is refused, because stretching a "
                        "building to fit is how a player is blocked by something that "
                        "looks passable."
                    ),
                },
            }
        )

    if rejected:
        for line in rejected:
            print(f"  REJECTED {line}")
        return fail(f"{len(rejected)} asset(s) do not match their contract size")

    if not args.dry_run and records:
        catalog["entries"].extend(records)
        catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")

    print(f"admitted {len(records)} of {len(declared)} declared environment assets")
    if replaced:
        print(f"replaced {len(replaced)} re-delivered:")
        for r in replaced:
            print(f"  {r}")
    if missing:
        print(f"still missing {len(missing)}:")
        for m in missing[:10]:
            print(f"  {m}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
