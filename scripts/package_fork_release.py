#!/usr/bin/env python3
"""Sign and package an already-built Cotabby Fork without altering the archive.

The fork target owns identity and updater policy. This boundary checks the built
bundle, copies it into an owned temporary directory, signs nested code inside-out
with secure timestamps, and packages that copy. It never builds, installs,
submits to Apple, publishes a release, or generates update keys.
"""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ID = "com.itsonlyfrans.cotabby"
APP_NAME = "Cotabby Fork.app"
TEAM_ID = "KU6R499PHR"
MACHO_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf",
               b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca",
               b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}


def validate_bundle(app: Path) -> dict:
    """Reject upstream/dev identity and update destinations before any signing effect."""
    if app.name != APP_NAME or not app.is_dir():
        raise ValueError(f"Expected an existing {APP_NAME} bundle")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise ValueError(f"Fork bundle identifier must be {BUNDLE_ID}")
    if any(key in info for key in ("SUFeedURL", "SUPublicEDKey")):
        raise ValueError("Fork must contain neither an update feed nor a Sparkle public key")
    for key in ("SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate", "SUEnableAutomaticChecks"):
        if info.get(key) is not False:
            raise ValueError(f"Fork updater setting must be false: {key}")
    for key in ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleExecutable"):
        if not isinstance(info.get(key), str) or not info[key].strip() or "$" in info[key]:
            raise ValueError(f"Built fork metadata must resolve {key}")
    executable = info["CFBundleExecutable"]
    if Path(executable).name != executable or not (app / "Contents/MacOS" / executable).is_file():
        raise ValueError("Fork executable is missing or has an invalid name")
    return info


def run(*arguments: str) -> None:
    subprocess.run(arguments, check=True)


def sign_bundle(app: Path, identity: str, temporary: Path) -> None:
    """Leaf binaries precede containing bundles; symlinks must not sign the same file twice."""
    candidates = []
    for path in app.rglob("*"):
        if path.is_symlink():
            continue
        if path.is_dir() and path.suffix in (".app", ".framework", ".xpc"):
            candidates.append(path)
        elif path.is_file():
            with path.open("rb") as stream:
                if stream.read(4) in MACHO_MAGIC:
                    candidates.append(path)
    command = ["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
    for path in sorted(candidates, key=lambda item: len(item.parts), reverse=True):
        run(*command, str(path))
    # Distribution must not inherit XCTest/debug injection entitlements from a local signer.
    entitlements = temporary / "distribution.entitlements"
    entitlements.write_bytes(plistlib.dumps({}))
    run(*command, "--entitlements", str(entitlements), str(app))
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
                               capture_output=True, text=True, check=True).stderr
    if f"TeamIdentifier={TEAM_ID}" not in signature or "Authority=Developer ID Application:" not in signature:
        raise ValueError(f"Distribution requires this fork's Developer ID Application team {TEAM_ID}")
    if "runtime" not in signature or "Timestamp=" not in signature:
        raise ValueError("Distribution signature must have hardened runtime and a secure timestamp")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app-path", type=Path, required=True)
    parser.add_argument("--identity", help="Full Developer ID Application identity from the local keychain")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "build/fork-release")
    parser.add_argument("--validate-only", action="store_true", help="Check built identity/update metadata; do not sign or write")
    args = parser.parse_args()
    app = args.app_path.resolve()
    info = validate_bundle(app)
    if args.validate_only:
        print(f"Validated fork bundle metadata: {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
        return 0
    if not args.identity or not args.identity.startswith("Developer ID Application:"):
        parser.error("--identity must name a Developer ID Application certificate")
    output_dir = args.output_dir.resolve()
    # Keep release writes contained; a supplied /Applications path cannot replace installed apps.
    if not output_dir.is_relative_to((ROOT / "build/fork-release").resolve()):
        parser.error("--output-dir must be inside this checkout's build/fork-release")
    output = output_dir / "Cotabby-Fork.dmg"
    if output.exists():
        raise FileExistsError(f"Refusing to overwrite an existing release artifact: {output}")
    if importlib.util.find_spec("dmgbuild") is None:
        raise RuntimeError('Use the release venv with dmgbuild[badge_icons]==1.6.7 installed')
    output_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="cotabby-fork-package-") as directory:
        temporary = Path(directory)
        staged = temporary / APP_NAME
        run("ditto", "--norsrc", "--noextattr", str(app), str(staged))
        run("xattr", "-cr", str(staged))
        sign_bundle(staged, args.identity, temporary)
        run(sys.executable, str(ROOT / "scripts/build_release_dmg.py"),
            "--app-path", str(staged), "--output-path", str(output),
            "--background-path", str(ROOT / "assets/release/dmg_background.png"),
            "--background-2x-path", str(ROOT / "assets/release/dmg_background@2x.png"),
            "--volume-name", "Cotabby Fork")
        run("codesign", "--force", "--timestamp", "--sign", args.identity, str(output))
        run("codesign", "--verify", "--strict", str(output))
    print(f"Signed fork DMG: {output}")
    print("Not notarized or published. Submit, staple, assess, and smoke-test before distribution.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, FileNotFoundError, FileExistsError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"Fork packaging failed: {error}", file=sys.stderr)
        raise SystemExit(1)
