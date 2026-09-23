#!/usr/bin/env python3
"""Fail the build if the packaged HAP asks for a permission above the app's level.

WHY THIS EXISTS
---------------
An install on a HarmonyOS NEXT device (cloud-debug real device, AppGallery
review) is rejected *before the app ever runs* when the HAP declares a
permission whose `availableLevel` is higher than the app's own
`apl` in the signing profile:

    安装失败。应用等级为normal，只能使用normal等级的权限。
    (Install failed: the app level is normal and it may only use
     normal-level permissions.)

electerm-harmony ships with a normal-apl profile
(`"apl": "normal"`, `"app-feature": "hos_normal_app"`,
`"allowed-acls": []`), so any `system_basic` / `system_core` entry in
`module.json5` -> `requestPermissions` is fatal — and silently fatal: the
OpenHarmony emulator image is lax enough to install it anyway, so the bug only
shows up on real hardware. That is exactly the trap this check closes.

Two permissions used to be declared and both are system_basic:
  - ohos.permission.READ_WRITE_DESKTOP_DIRECTORY
  - ohos.permission.READ_PASTEBOARD

The level is *not* guesswork: it comes from the SDK's own permission list,
`${OHOS_SDK_HOME}/default/openharmony/toolchains/lib/PermissionDefinitions.json`
— the same file DevEco validates against when editing module.json5.

USAGE
-----
    scripts/check-permission-level.py <file.app | file.hap>
    scripts/check-permission-level.py <file.app> --defs /path/PermissionDefinitions.json
    scripts/check-permission-level.py <file.app> --allow-above-normal   # warn only

Exit codes: 0 ok (or nothing above normal / check skipped), 1 violation,
2 the HAP could not be read.
"""

import argparse
import io
import json
import os
import re
import sys
import zipfile

# Our signing profile is apl: normal — so `normal` is the whole allowlist.
ALLOWED_LEVELS = {"normal"}

DEFAULT_DEFS_REL = "default/openharmony/toolchains/lib/PermissionDefinitions.json"
FALLBACK_DEFS_REL = "toolchains/lib/PermissionDefinitions.json"

# Strip // and /* */ comments plus trailing commas so plain json can load the
# .json5 sources (module.json5 is the one we read when given a source tree).
_COMMENT_RE = re.compile(r"//[^\n]*|/\*.*?\*/", re.S)
_TRAILING_COMMA_RE = re.compile(r",(\s*[}\]])")


def log(msg):
    print(msg, flush=True)


def load_json5(text):
    text = _COMMENT_RE.sub("", text)
    text = _TRAILING_COMMA_RE.sub(r"\1", text)
    return json.loads(text)


def find_defs(explicit):
    """Locate the SDK permission list: --defs, then $OHOS_SDK_HOME, then the
    usual DevEco install. Returns None when it cannot be found (non-fatal)."""
    cands = []
    if explicit:
        cands.append(explicit)
    for env in ("OHOS_SDK_HOME", "DEVECO_SDK_HOME"):
        base = os.environ.get(env)
        if base:
            cands.append(os.path.join(base, DEFAULT_DEFS_REL))
            cands.append(os.path.join(base, FALLBACK_DEFS_REL))
    cands.append("/Applications/deveco-studio.app/Contents/sdk/" + DEFAULT_DEFS_REL)
    for c in cands:
        if c and os.path.isfile(c):
            return c
    return None


def read_module_json(path):
    """Return (module_json_dict, description) from a .hap, a .app, or a bare
    module.json / module.json5 file."""
    if path.endswith((".json", ".json5")) and not zipfile.is_zipfile(path):
        with open(path) as fh:
            text = fh.read()
        data = load_json5(text)
        return data, path

    if not zipfile.is_zipfile(path):
        raise SystemExit(f"::error::{path} is neither a zip (.app/.hap) nor JSON")

    with zipfile.ZipFile(path) as top:
        # A .hap carries module.json at its root; a .app wraps one or more .hap.
        if "module.json" in top.namelist():
            with top.open("module.json") as fh:
                return load_json5(fh.read().decode("utf-8")), f"{path}!module.json"

        haps = [n for n in top.namelist() if n.endswith(".hap")]
        if not haps:
            raise SystemExit(f"::error::no .hap inside {path}")
        hap_name = haps[0]
        with top.open(hap_name) as fh:
            blob = io.BytesIO(fh.read())
        with zipfile.ZipFile(blob) as hap:
            if "module.json" not in hap.namelist():
                raise SystemExit(f"::error::{hap_name} has no module.json")
            with hap.open("module.json") as fh:
                return (
                    load_json5(fh.read().decode("utf-8")),
                    f"{path}!{hap_name}!module.json",
                )


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("artifact", help=".app, .hap, or module.json(.5)")
    ap.add_argument("--defs", help="path to the SDK PermissionDefinitions.json")
    ap.add_argument(
        "--allow-above-normal",
        action="store_true",
        help="warn instead of failing (only correct for system-apl profiles)",
    )
    args = ap.parse_args()

    data, where = read_module_json(args.artifact)
    module = data.get("module", data)
    requested = module.get("requestPermissions") or []
    names = [p.get("name") for p in requested if p.get("name")]

    defs_path = find_defs(args.defs)
    levels = {}
    if defs_path:
        with open(defs_path) as fh:
            defs = json.load(fh)
        entries = defs["definePermissions"] if "definePermissions" in defs else defs
        levels = {p["name"]: p.get("availableLevel", "normal") for p in entries}

    log(f"==> Checking permission levels ({where})")
    if defs_path:
        log(f"    SDK permission list: {defs_path}")
    else:
        log("    ! SDK PermissionDefinitions.json not found — cannot verify levels")
        log("      (pass --defs, or set OHOS_SDK_HOME)")

    offenders = []
    unknown = []
    for name in names:
        if not levels:
            break
        level = levels.get(name)
        if level is None:
            # Not in the SDK list: a typo, or a permission newer than the SDK.
            unknown.append(name)
            continue
        mark = "✗" if level not in ALLOWED_LEVELS else "✓"
        log(f"  {mark} {name:48s} {level}")
        if level not in ALLOWED_LEVELS:
            offenders.append((name, level))

    if unknown:
        for name in unknown:
            log(f"  ? {name:48s} (not in SDK permission list)")

    if not names:
        log("    (no permissions requested)")

    if levels and unknown:
        # An unknown name is not install-fatal (the installer ignores what it
        # does not know) but it is always a mistake worth surfacing.
        log(f"::warning::unknown permission(s): {', '.join(unknown)}")

    if offenders:
        detail = ", ".join(f"{n} ({l})" for n, l in offenders)
        if args.allow_above_normal:
            log(f"::warning::above-normal permissions present: {detail}")
            return 0
        log("")
        log("::error::HAP requests permissions above the app level:")
        for n, l in offenders:
            log(f"::error::  {n} is {l}, app profile is apl: normal")
        log("")
        log("    The signing profile (apl: normal / hos_normal_app / allowed-acls: [])")
        log("    cannot be granted these, so installation fails with")
        log("    '应用等级为normal，只能使用normal等级的权限'.")
        log("    Remove them from entry/src/main/module.json5 (and from")
        log("    ALL_USER_PERMISSIONS in entry/src/main/ets/entryability/EntryAbility.ets),")
        log("    or ship a system-apl profile and pass --allow-above-normal.")
        return 1

    log("    ✓ all requested permissions are normal-level")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 - report, never crash the build
        print(f"::error::permission check failed: {exc}")
        sys.exit(2)
