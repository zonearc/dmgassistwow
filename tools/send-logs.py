#!/usr/bin/env python3
"""Send DMGAssist logs from your PC to GitHub, so they can be read without copy/paste.

Addons can't use the network or the clipboard, so this runs on your computer, outside the game. It collects:
    WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist_Watchdog.lua   (Watchdog log; written on /reload or logout)
    WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist.lua            (settings + what DMGAssist learned)
    Logs/taint.log                                                (blocked/forbidden actions; /dmgw taint on)
uploads them to the branch `watchdog-logs` of the repository (folder logs/<date-time>/), and opens an issue that
links them. The account folder name is replaced by "ACCOUNT" in everything uploaded.

Needs a GitHub token with access to the repository: the `gh` command line tool if you are logged in
(`gh auth login`), or a token in the environment variable DMGASSIST_GITHUB_TOKEN
(fine-grained token: Contents read/write + Issues read/write on this repository only).

Usage:
    python send-logs.py                      # find WoW, send once (asks first)
    python send-logs.py --watch              # keep running; send each time the game writes the log (/reload)
    python send-logs.py --wow "D:/Games/World of Warcraft" --yes
    python send-logs.py --dry-run            # show what would be sent; no network
    python send-logs.py --zip                # no GitHub: write a zip next to this script and open the issue page
"""
import argparse
import base64
import datetime as dt
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
import webbrowser
import zipfile

REPO = "zonearc/dmgassist-issues"
BRANCH = "watchdog-logs"
API = "https://api.github.com"
TAINT_MAX = 300_000  # bytes from the end of taint.log

DEFAULT_ROOTS = [
    r"C:\Program Files (x86)\World of Warcraft",
    r"C:\Program Files\World of Warcraft",
    r"D:\World of Warcraft",
    r"D:\Games\World of Warcraft",
    "/Applications/World of Warcraft",
    os.path.expanduser("~/Games/World of Warcraft"),
]


# ---------------------------------------------------------------------------
# Finding the files
# ---------------------------------------------------------------------------
def find_flavors(root):
    """Every game folder (_retail_, and any other _flavor_ such as the one Forever installs into)."""
    return sorted(d for d in glob.glob(os.path.join(root, "_*_")) if os.path.isdir(d))


def collect(root):
    """Returns [(published_name, bytes)] and the newest SavedVariables mtime."""
    files, newest = [], 0.0
    for flavor in find_flavors(root):
        tag = os.path.basename(flavor).strip("_")
        for sv in glob.glob(os.path.join(flavor, "WTF", "Account", "*", "SavedVariables", "DMGAssist*.lua")):
            account = sv.split(os.sep)[-3]
            data = open(sv, "rb").read()
            data = data.replace(account.encode(), b"ACCOUNT")
            files.append((f"{tag}/{os.path.basename(sv)}", data))
            newest = max(newest, os.path.getmtime(sv))
        taint = os.path.join(flavor, "Logs", "taint.log")
        if os.path.exists(taint):
            with open(taint, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                size = fh.tell()
                fh.seek(max(0, size - TAINT_MAX))
                files.append((f"{tag}/taint.log", fh.read()))
    return files, newest


def summarize(files):
    """A few counts for the issue body (the full files are linked)."""
    lines = []
    for name, data in files:
        text = data.decode("utf-8", "replace")
        if name.endswith("DMGAssist_Watchdog.lua"):
            counts = {k: len(re.findall(k, text)) for k in
                      ("blocked", "forbidden", "readability", "call_error", "clue_disabled", "interrupt_skipped")}
            lines.append(f"- `{name}`: {len(data):,} bytes; " + ", ".join(f"{k} {v}" for k, v in counts.items()))
        elif name.endswith("taint.log"):
            blocked = len(re.findall(r"blocked|forbidden", text, re.I))
            dmga = len(re.findall(r"DMGAssist", text))
            lines.append(f"- `{name}`: {len(data):,} bytes; blocked/forbidden lines {blocked}, mentions DMGAssist {dmga}")
        else:
            lines.append(f"- `{name}`: {len(data):,} bytes")
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# GitHub
# ---------------------------------------------------------------------------
def token():
    t = os.environ.get("DMGASSIST_GITHUB_TOKEN", "").strip()
    if t:
        return t
    if shutil.which("gh"):
        try:
            return subprocess.check_output(["gh", "auth", "token"], text=True).strip()
        except subprocess.CalledProcessError:
            pass
    return None


def api(method, path, tok, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {tok}", "Accept": "application/vnd.github+json",
                                          "User-Agent": "dmgassist-send-logs"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise SystemExit(f"GitHub {method} {path}: {e.code} {e.read().decode(errors='replace')[:300]}")


def ensure_branch(tok):
    if api("GET", f"/repos/{REPO}/branches/{BRANCH}", tok):
        return
    repo = api("GET", f"/repos/{REPO}", tok)
    base = api("GET", f"/repos/{REPO}/git/ref/heads/{repo['default_branch']}", tok)
    api("POST", f"/repos/{REPO}/git/refs", tok, {"ref": f"refs/heads/{BRANCH}", "sha": base["object"]["sha"]})


def upload(files, tok, stamp):
    ensure_branch(tok)
    links = []
    for name, data in files:
        path = f"logs/{stamp}/{name}"
        api("PUT", f"/repos/{REPO}/contents/{path}", tok, {
            "message": f"Watchdog logs {stamp}: {name}", "branch": BRANCH,
            "content": base64.b64encode(data).decode()})
        links.append(f"https://github.com/{REPO}/blob/{BRANCH}/{path}")
    return links


def open_issue(tok, stamp, summary, links, note):
    body = (f"Watchdog logs sent {stamp} by tools/send-logs.py.\n\n{note}\n\n**Files** (branch `{BRANCH}`):\n"
            + "\n".join(f"- {u}" for u in links) + f"\n\n**Quick counts**\n{summary}\n")
    issue = api("POST", f"/repos/{REPO}/issues", tok, {"title": f"Watchdog logs {stamp}", "body": body,
                                                         "labels": ["watchdog-log"]})
    return issue["html_url"]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def find_root(given):
    if given:
        return given
    for r in DEFAULT_ROOTS:
        if find_flavors(r):
            return r
    raise SystemExit("World of Warcraft not found; pass --wow \"<folder that contains _retail_>\"")


def send_once(root, args):
    files, _ = collect(root)
    if not files:
        print("No DMGAssist logs found yet (play, then /reload or log out).")
        return
    stamp = dt.datetime.now().strftime("%Y-%m-%d-%H%M%S")
    summary = summarize(files)
    print(f"Logs ({stamp}):\n{summary}")
    if args.dry_run:
        return
    if args.zip:
        out = os.path.join(os.path.dirname(os.path.abspath(__file__)), f"dmgassist-logs-{stamp}.zip")
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
            for name, data in files:
                z.writestr(name, data)
        print(f"Wrote {out}. Attach it to the issue page that opens now.")
        webbrowser.open(f"https://github.com/{REPO}/issues/new?title=Watchdog+logs+{stamp}&labels=watchdog-log")
        return
    tok = token()
    if not tok:
        raise SystemExit("No GitHub login: run `gh auth login`, set DMGASSIST_GITHUB_TOKEN, or use --zip.")
    if not args.yes and input("Send these to GitHub? [y/N] ").strip().lower() != "y":
        return
    links = upload(files, tok, stamp)
    url = open_issue(tok, stamp, summary, links, args.note or "")
    print(f"Sent: {url}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--wow", help="World of Warcraft folder (the one containing _retail_)")
    ap.add_argument("--watch", action="store_true", help="keep running and send whenever the game writes the log")
    ap.add_argument("--yes", action="store_true", help="don't ask before sending")
    ap.add_argument("--dry-run", action="store_true", help="show what would be sent")
    ap.add_argument("--zip", action="store_true", help="no GitHub API: write a zip and open the new-issue page")
    ap.add_argument("--note", help="a line describing what you were doing (spec, dungeon, what looked wrong)")
    args = ap.parse_args()
    root = find_root(args.wow)
    print(f"World of Warcraft: {root}")
    if not args.watch:
        send_once(root, args)
        return
    args.yes = True
    _, last = collect(root)
    print("Watching. Play, then /reload or log out; logs are sent each time. Ctrl+C to stop.")
    while True:
        time.sleep(5)
        _, newest = collect(root)
        if newest > last:
            time.sleep(3)  # let the game finish writing
            last = newest
            send_once(root, args)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
