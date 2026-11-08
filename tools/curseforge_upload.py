#!/usr/bin/env python3
"""Upload packaged addon zips to CurseForge.

For each zip: reads the addon's .toc inside it. Addons without "## X-Curse-Project-ID" are skipped.
Game versions are looked up from CurseForge by name from the .toc's "## Interface" numbers
(120105 -> "12.1.5", 16001 -> "1.60.1") instead of being hardcoded; set CF_GAME_VERSION_IDS="id,id"
to override when CurseForge names a version differently.

Upload endpoint and form layout are the ones the legacy DMGAssist used successfully:
    POST https://wow.curseforge.com/api/projects/<id>/upload-file   header X-Api-Token
    multipart: metadata (JSON) + file (zip)

Usage: CF_API_TOKEN=... python3 tools/curseforge_upload.py [--changelog notes.md] [--dry-run] dist/*.zip
"""
import argparse
import json
import os
import re
import sys
import urllib.request
import uuid
import zipfile

API = "https://wow.curseforge.com/api"


def read_toc(zip_path):
    with zipfile.ZipFile(zip_path) as z:
        tocs = [n for n in z.namelist() if re.match(r"^([^/]+)/\1\.toc$", n)]
        if not tocs:
            raise SystemExit(f"{zip_path}: no <Addon>/<Addon>.toc inside")
        text = z.read(tocs[0]).decode("utf-8", "replace")
    meta = {}
    for line in text.splitlines():
        m = re.match(r"^##\s*([^:]+):\s*(.*)$", line)
        if m:
            meta[m.group(1).strip()] = m.group(2).strip()
    meta["_addon"] = tocs[0].split("/")[0]
    return meta


def interface_to_version(n):
    n = int(n)
    return f"{n // 10000}.{(n // 100) % 100}.{n % 100}"


def api_get(path, token):
    req = urllib.request.Request(API + path, headers={"X-Api-Token": token})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def resolve_game_versions(interfaces, token):
    override = os.environ.get("CF_GAME_VERSION_IDS", "").strip()
    if override:
        return [int(x) for x in override.split(",") if x.strip()], []
    wanted = [interface_to_version(i) for i in interfaces]
    versions = api_get("/game/versions", token)
    by_name = {}
    for v in versions:
        by_name.setdefault(v.get("name"), []).append(v["id"])
    ids, missing = [], []
    for name in wanted:
        if name in by_name:
            ids += by_name[name]
        else:
            missing.append(name)
    return sorted(set(ids)), missing


def release_type(version):
    v = version.lower()
    if "alpha" in v:
        return "alpha"
    if "beta" in v or "-" in v:
        return "beta"
    return "release"


def upload(project_id, zip_path, metadata, token):
    boundary = "----dmgassist" + uuid.uuid4().hex
    with open(zip_path, "rb") as fh:
        data = fh.read()
    body = b"".join([
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\n"
        f"Content-Type: application/json\r\n\r\n{json.dumps(metadata)}\r\n".encode(),
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{os.path.basename(zip_path)}\"\r\n"
        f"Content-Type: application/zip\r\n\r\n".encode(),
        data,
        f"\r\n--{boundary}--\r\n".encode(),
    ])
    req = urllib.request.Request(f"{API}/projects/{project_id}/upload-file", data=body, method="POST",
                                 headers={"X-Api-Token": token,
                                          "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.load(r)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("zips", nargs="+")
    ap.add_argument("--changelog", help="markdown file used as the changelog")
    ap.add_argument("--dry-run", action="store_true", help="print what would be uploaded; no network calls")
    args = ap.parse_args()
    token = os.environ.get("CF_API_TOKEN", "")
    if not token and not args.dry_run:
        raise SystemExit("CF_API_TOKEN is not set")
    changelog = open(args.changelog, encoding="utf-8").read() if args.changelog else "See GitHub release notes."

    uploaded = 0
    for zip_path in args.zips:
        meta = read_toc(zip_path)
        project = meta.get("X-Curse-Project-ID")
        if not project:
            print(f"skip {zip_path}: no X-Curse-Project-ID")
            continue
        interfaces = [x.strip() for x in meta.get("Interface", "").split(",") if x.strip()]
        version = meta.get("Version", "0")
        metadata = {
            "changelog": changelog,
            "changelogType": "markdown",
            "displayName": f"{meta.get('Title', meta['_addon'])} {version}",
            "releaseType": release_type(version),
        }
        if args.dry_run:
            print(f"[dry-run] {zip_path} -> project {project}; interfaces {interfaces} "
                  f"-> {[interface_to_version(i) for i in interfaces]}; {json.dumps(metadata)[:200]}")
            continue
        ids, missing = resolve_game_versions(interfaces, token)
        if missing:
            print(f"warning: CurseForge has no game version named {missing}; set CF_GAME_VERSION_IDS to override",
                  file=sys.stderr)
        if not ids:
            raise SystemExit(f"{zip_path}: no CurseForge game version ids resolved")
        metadata["gameVersions"] = ids
        result = upload(project, zip_path, metadata, token)
        print(f"uploaded {zip_path} to project {project}: {result}")
        uploaded += 1
    print(f"{uploaded} file(s) uploaded")


if __name__ == "__main__":
    main()
