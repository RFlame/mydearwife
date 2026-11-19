#!/usr/bin/env python3
"""Build the offline XiaoHongShu mini-tool without changing the Godot project."""

import hashlib
import json
import shutil
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "minitool"
TARGET = ROOT / "build" / "minitool"
ZIP_PATH = ROOT / "build" / "snack-dingdong-minitool.zip"
REPORT_PATH = ROOT / "build" / "minitool-build.json"

UI_ASSETS = [
    "bag.svg", "basket.svg", "blind.svg", "gift.svg", "pos_screen.svg",
    "scale_platform.svg", "scale_stand.svg", "cashier_aisle.svg",
    "cashier_arm.svg", "cashier_body.svg", "counter_top.svg", "bg_shop.svg",
]


def read_json(name):
    return json.loads((ROOT / "data" / name).read_text(encoding="utf-8"))


def main():
    payload = {
        "snacks": read_json("snacks.json"),
        "customers": read_json("customers.json"),
        "levels": read_json("levels.json"),
        "difficulty": read_json("difficulty.json"),
        "upgrades": read_json("upgrades.json"),
    }
    if len(payload["snacks"]["snacks"]) != 40:
        raise RuntimeError("Expected 40 original snacks")
    if len(payload["customers"]["customers"]) != 12:
        raise RuntimeError("Expected 12 original customers")
    levels = payload["levels"].get("levels", payload["levels"])
    if len(levels) != 20:
        raise RuntimeError("Expected 20 levels")

    if TARGET.exists():
        shutil.rmtree(str(TARGET))
    (TARGET / "js").mkdir(parents=True)
    (TARGET / "assets" / "svg").mkdir(parents=True)

    shutil.copy2(str(SOURCE / "index.html"), str(TARGET / "index.html"))
    shutil.copy2(str(SOURCE / "styles.css"), str(TARGET / "styles.css"))
    for source_js in sorted((SOURCE / "js").glob("*.js")):
        shutil.copy2(str(source_js), str(TARGET / "js" / source_js.name))

    data_js = "window.SnackDingDongData=" + json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ) + ";\n"
    (TARGET / "js" / "data.js").write_text(data_js, encoding="utf-8")

    asset_names = set(UI_ASSETS)
    asset_names.update(item["svg"] for item in payload["snacks"]["snacks"])
    asset_names.update(item["avatar"] for item in payload["customers"]["customers"])
    for name in sorted(asset_names):
        source = ROOT / "assets" / "svg" / name
        if not source.is_file():
            raise RuntimeError("Missing SVG asset: " + name)
        shutil.copy2(str(source), str(TARGET / "assets" / "svg" / name))

    if ZIP_PATH.exists():
        ZIP_PATH.unlink()
    with zipfile.ZipFile(str(ZIP_PATH), "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path in sorted(TARGET.rglob("*")):
            if not path.is_file():
                continue
            relative = path.relative_to(TARGET).as_posix()
            info = zipfile.ZipInfo(relative, (2026, 11, 19, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            archive.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

    files = [path for path in TARGET.rglob("*") if path.is_file()]
    report = {
        "source": str(SOURCE),
        "directory": str(TARGET),
        "zip": str(ZIP_PATH),
        "files": len(files),
        "uncompressed_bytes": sum(path.stat().st_size for path in files),
        "zip_bytes": ZIP_PATH.stat().st_size,
        "sha256": hashlib.sha256(ZIP_PATH.read_bytes()).hexdigest(),
        "snacks": 40,
        "customers": 12,
        "levels": 20,
        "svg_assets": len(asset_names),
        "godot_export_included": False,
        "audio": "local Web Audio synthesis; no WAV files",
    }
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
