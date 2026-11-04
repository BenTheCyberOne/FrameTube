"""Build FrameTube's downloadable releases: export each platform with Godot and package it as a zip
with a plain-language install guide. The Linux executables are marked runnable inside the zip, so
nobody has to chmod anything.

Usage (from the project folder):
    python tools/build_release.py [path-to-godot-console-exe]
Needs Godot 4.7 with export templates installed. Output: build/release/*.zip
"""
import os
import re
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
GODOT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("GODOT", "godot")

# preset name, exported binary (relative to ROOT), zip name, install guide
TARGETS = [
    ("Windows", "build/FrameTube-Windows/FrameTube.exe", "FrameTube-Windows", "docs/install-windows.txt"),
    ("Steam Frame (Linux arm64)", "build/FrameTube-SteamFrame/FrameTube.arm64", "FrameTube-SteamFrame",
     "docs/install-steamframe.txt"),
    ("Linux x86_64", "build/FrameTube-Linux/FrameTube.x86_64", "FrameTube-Linux", "docs/install-steamframe.txt"),
]


def version() -> str:
    m = re.search(r'config/version="([^"]+)"', (ROOT / "project.godot").read_text(encoding="utf-8"))
    return m.group(1) if m else "dev"


def main() -> int:
    ver = version()
    out_dir = ROOT / "build" / "release"
    out_dir.mkdir(parents=True, exist_ok=True)
    ok = True
    for preset, binary, zip_name, guide in TARGETS:
        exe = ROOT / binary
        exe.parent.mkdir(parents=True, exist_ok=True)
        if exe.exists():
            exe.unlink()
        print(f"== Exporting {preset} ...", flush=True)
        r = subprocess.run([GODOT, "--headless", "--path", str(ROOT), "--export-release", preset, str(exe)],
                           capture_output=True, text=True)
        errors = [l for l in (r.stdout + r.stderr).splitlines() if "ERROR" in l and "XR" not in l]
        if not exe.exists():
            print(f"   FAILED (exit {r.returncode})\n   " + "\n   ".join(errors[-8:] or [r.stdout[-800:]]))
            ok = False
            continue
        zpath = out_dir / f"{zip_name}-v{ver}.zip"
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
            info = zipfile.ZipInfo(f"{zip_name}/{exe.name}")
            info.compress_type = zipfile.ZIP_DEFLATED
            info.create_system = 3  # Unix, so the permission bits below are honoured
            info.external_attr = (0o100755 << 16)  # regular file, rwxr-xr-x
            z.writestr(info, exe.read_bytes())
            txt = zipfile.ZipInfo(f"{zip_name}/How to install.txt")
            txt.compress_type = zipfile.ZIP_DEFLATED
            txt.create_system = 3
            txt.external_attr = (0o100644 << 16)  # readable by everyone
            z.writestr(txt, (ROOT / guide).read_text(encoding="utf-8").replace("\n", "\r\n"))
        print(f"   {zpath.relative_to(ROOT)}  ({zpath.stat().st_size / 1e6:.1f} MB)")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
