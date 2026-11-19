#!/usr/bin/env python3
"""Structural, policy, resource and syntax checks for the mini-tool artifact."""

import hashlib
import json
import re
import subprocess
import sys
import tempfile
import zipfile
from html.parser import HTMLParser
from pathlib import Path, PurePosixPath

MIB = 1024 * 1024
ALLOWED_SUFFIXES = {".html", ".css", ".js", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".woff", ".woff2", ".json"}
TEXT_SUFFIXES = {".html", ".css", ".js", ".json"}
EXPECTED_SCRIPTS = ["js/data.js", "js/model.js", "js/game.js", "js/platform.js", "js/audio.js", "js/renderer.js", "js/app.js"]
FORBIDDEN_PARTS = {".git", "node_modules", "__pycache__", ".godot"}
FORBIDDEN_NAMES = {".ds_store", "package.json", "package-lock.json", "project.godot", "export_presets.cfg"}
FORBIDDEN_JS = [
    (r"\beval\s*\(", "eval"),
    (r"\bnew\s+Function\b", "dynamic Function"),
    (r"\bWebAssembly\b", "WebAssembly"),
    (r"\b(?:localStorage|sessionStorage|indexedDB)\b", "browser storage"),
    (r"\bcaches\s*\.", "Cache API"),
    (r"\bfetch\s*\(", "fetch"),
    (r"\bXMLHttpRequest\b", "XMLHttpRequest"),
    (r"\bWebSocket\b", "WebSocket"),
    (r"\bSharedArrayBuffer\b", "SharedArrayBuffer"),
    (r"\bnew\s+(?:Worker|SharedWorker|ServiceWorker)\b", "worker"),
    (r"\bserviceWorker\b", "service worker"),
    (r"\bimportScripts\s*\(", "worker imports"),
    (r"\bimport\s*\(", "dynamic import"),
    (r"(?:^|\n)\s*(?:import|export)\s+", "module syntax"),
    (r"\?\.", "optional chaining"),
    (r"\?\?", "nullish coalescing"),
    (r"(?:&&|\|\|)\s*=", "logical assignment"),
    (r"\bcatch\s*\{", "optional catch binding"),
    (r"\bglobalThis\b", "globalThis"),
    (r"\.\.\.", "spread/rest syntax requiring focused review"),
    (r"\b\d[\d_]*_\d", "numeric separator"),
    (r"\(\?<[=!]", "regex lookbehind"),
]


class EntryHTMLParser(HTMLParser):
    def __init__(self):
        HTMLParser.__init__(self)
        self.scripts = []
        self.references = []
        self.errors = []
        self._script = None
        self._script_data = []
        self.text_parts = []

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        for name, value in attrs:
            if name.lower().startswith("on"):
                self.errors.append("inline event handler: " + name)
            if value and value.strip().lower().startswith("javascript:"):
                self.errors.append("javascript URI")
        if tag in {"base", "iframe", "object", "embed"}:
            self.errors.append("forbidden HTML tag: " + tag)
        if tag == "meta" and attributes.get("http-equiv", "").lower() == "content-security-policy":
            self.errors.append("custom CSP meta")
        if tag == "script":
            src = attributes.get("src")
            if not src:
                self.errors.append("inline script")
            if attributes.get("type", "").lower() == "module" or "type" in attributes:
                self.errors.append("script must be classic and omit type")
            if "defer" not in attributes:
                self.errors.append("script missing defer: " + str(src))
            self._script = src
            self._script_data = []
            if src:
                self.scripts.append(src)
                self.references.append(src)
        for attribute in ("src", "href", "poster"):
            value = attributes.get(attribute)
            if value and tag != "script":
                self.references.append(value)

    def handle_endtag(self, tag):
        if tag == "script" and self._script is not None:
            if "".join(self._script_data).strip():
                self.errors.append("script with src also has inline content")
            self._script = None

    def handle_data(self, data):
        if self._script is not None:
            self._script_data.append(data)
        else:
            self.text_parts.append(data)


def safe_relative(name):
    path = PurePosixPath(name)
    return not path.is_absolute() and ".." not in path.parts and "\\" not in name and not name.startswith("/")


def external_reference(value):
    lowered = value.lower().strip()
    return lowered.startswith(("http:", "https:", "//", "data:", "blob:", "file:", "javascript:"))


def audit(root):
    errors = []
    warnings = []
    files = sorted(path for path in root.rglob("*") if path.is_file())
    names = []
    for path in files:
        name = path.relative_to(root).as_posix()
        names.append(name)
        pure = PurePosixPath(name)
        if not safe_relative(name):
            errors.append(name + ": unsafe path")
        if any(part.lower() in FORBIDDEN_PARTS for part in pure.parts):
            errors.append(name + ": forbidden directory")
        if pure.name.lower() in FORBIDDEN_NAMES or pure.suffix.lower() in {".map", ".import", ".wasm", ".pck", ".wav"}:
            errors.append(name + ": forbidden artifact")
        if pure.suffix.lower() not in ALLOWED_SUFFIXES:
            errors.append(name + ": suffix is not in mini-tool whitelist")
        if path.is_symlink():
            errors.append(name + ": symbolic link")
        if pure.suffix.lower() in TEXT_SUFFIXES and path.stat().st_size > 2 * MIB:
            warnings.append(name + ": text file exceeds 2 MiB")
        if path.stat().st_size == 0:
            warnings.append(name + ": empty file")
    if "index.html" not in names:
        errors.append("root index.html missing")
    html_files = [name for name in names if name.lower().endswith(".html")]
    if html_files != ["index.html"]:
        errors.append("ZIP must contain exactly one root HTML file: " + repr(html_files))
    text_total = sum(path.stat().st_size for path in files if path.suffix.lower() in TEXT_SUFFIXES)
    if text_total > 5 * MIB:
        warnings.append("uncompressed text exceeds 5 MiB")

    parser = EntryHTMLParser()
    index_path = root / "index.html"
    if index_path.is_file():
        parser.feed(index_path.read_text(encoding="utf-8"))
        errors.extend("index.html: " + message for message in parser.errors)
        if parser.scripts != EXPECTED_SCRIPTS:
            errors.append("index.html: script order mismatch: " + repr(parser.scripts))
        visible_text = " ".join("".join(parser.text_parts).split())
        for required in ("零食叮叮咚", "柜台准备中", "重新打开本小工具"):
            if required not in visible_text:
                errors.append("index.html: static first screen missing " + required)
        for reference in parser.references:
            if external_reference(reference) or not safe_relative(reference):
                errors.append("index.html: external or unsafe reference " + reference)
            elif not (root / reference).is_file():
                errors.append("index.html: missing reference " + reference)

    allowed_platform_methods = {"getLaunchOptions", "getStorage", "setStorage", "getWindowInfo", "vibrateShort", "vibrateLong"}
    for path in files:
        suffix = path.suffix.lower()
        name = path.relative_to(root).as_posix()
        if suffix not in {".js", ".css", ".svg"}:
            continue
        text = path.read_text(encoding="utf-8")
        if suffix == ".js":
            for pattern, label in FORBIDDEN_JS:
                if re.search(pattern, text):
                    errors.append(name + ": forbidden/non-baseline JS " + label)
            for method in re.findall(r"miniTool\.([A-Za-z0-9_]+)", text):
                if method not in allowed_platform_methods:
                    errors.append(name + ": unreviewed platform API " + method)
            result = subprocess.run(["node", "--check", str(path)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
            if result.returncode:
                errors.append(name + ": node syntax check failed: " + result.stderr.strip())
        if suffix == ".css":
            for pattern, label in [(r"(?:^|;)\s*gap\s*:", "flex gap"), (r"aspect-ratio\s*:", "aspect-ratio"),
                                   (r"clamp\s*\(", "clamp"), (r":has\s*\(", ":has")]:
                if re.search(pattern, text):
                    errors.append(name + ": non-baseline CSS " + label)
            for reference in re.findall(r"url\(\s*['\"]?([^)'\"]+)", text):
                if not reference.startswith("#") and (external_reference(reference) or not safe_relative(reference)):
                    errors.append(name + ": external CSS resource " + reference)
                elif not reference.startswith("#") and not (root / reference).is_file():
                    errors.append(name + ": missing CSS resource " + reference)
        if suffix == ".svg":
            if re.search(r"<\s*(?:script|foreignObject|image)\b", text, re.I):
                errors.append(name + ": active or embedded SVG content")
            for href in re.findall(r"(?:href|src)\s*=\s*['\"]([^'\"]+)", text, re.I):
                if not href.startswith("#"):
                    errors.append(name + ": SVG external reference")
        for match in re.finditer(r"data:[^;]+;base64,([A-Za-z0-9+/=\s]+)", text):
            decoded_size = len(re.sub(r"\s", "", match.group(1))) * 3 / 4
            if decoded_size > MIB:
                errors.append(name + ": Base64 payload exceeds 1 MiB")
            elif decoded_size > 100 * 1024:
                warnings.append(name + ": Base64 payload exceeds 100 KiB")

    data_path = root / "js" / "data.js"
    if data_path.is_file():
        data_text = data_path.read_text(encoding="utf-8")
        try:
            payload = json.loads(data_text[len("window.SnackDingDongData="):-2])
            asset_references = [entry["svg"] for entry in payload["snacks"]["snacks"]]
            asset_references += [entry["avatar"] for entry in payload["customers"]["customers"]]
            for asset in asset_references:
                if not safe_relative(asset) or not (root / "assets" / "svg" / asset).is_file():
                    errors.append("data.js: missing SVG " + asset)
            if len(payload["levels"].get("levels", [])) != 20:
                errors.append("data.js: expected 20 levels")
        except (ValueError, KeyError, IndexError) as error:
            errors.append("data.js: invalid generated data: " + str(error))
    return {"files": len(files), "errors": errors, "warnings": warnings, "text_bytes": text_total}


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 audit_minitool.py <directory-or-zip>")
        return 2
    target = Path(sys.argv[1]).resolve()
    if not target.exists():
        print("ERROR: path not found")
        return 2
    zip_size = None
    with tempfile.TemporaryDirectory(prefix="mydearwife-minitool-audit-") as temporary:
        root = target
        if target.is_file():
            zip_size = target.stat().st_size
            if zip_size > 10 * MIB:
                print("ERROR: ZIP exceeds 10 MiB")
                return 1
            try:
                with zipfile.ZipFile(str(target)) as archive:
                    bad = archive.testzip()
                    if bad:
                        print("ERROR: ZIP CRC failure: " + bad)
                        return 1
                    names = [info.filename for info in archive.infolist() if not info.is_dir()]
                    if len(names) != len(set(names)):
                        print("ERROR: duplicate ZIP entries")
                        return 1
                    for info in archive.infolist():
                        if not safe_relative(info.filename):
                            print("ERROR: unsafe ZIP path: " + info.filename)
                            return 1
                        if info.flag_bits & 1:
                            print("ERROR: encrypted ZIP entry")
                            return 1
                    archive.extractall(temporary)
                root = Path(temporary)
            except zipfile.BadZipFile:
                print("ERROR: invalid ZIP")
                return 1
        report = audit(root)
    if zip_size is not None:
        report["zip_bytes"] = zip_size
        report["sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        if zip_size > 2 * MIB:
            report["warnings"].append("ZIP exceeds recommended 2 MiB target")
    for message in report["errors"]:
        print("ERROR: " + message)
    for message in report["warnings"]:
        print("WARN: " + message)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report["errors"]:
        print("FAILED: {} error(s), {} warning(s)".format(len(report["errors"]), len(report["warnings"])))
        return 1
    print("PASS: full mini-tool artifact audit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
