#!/usr/bin/env python3
"""Set version labels after a TF3 upload; preview first, never upload files.

Run it, paste your mod.io OAuth access token when asked, pick the uploads to
relabel if they are not found automatically, then confirm with y.

--sync labels every upload whose changelog starts with a version, e.g.
"v1.4.1 — Fixes ...". The scheduled GitHub workflow runs it with --apply.
"""
import argparse
import datetime
import getpass
import html
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

REPOSITORY = Path(__file__).resolve().parents[1]
def target_base():
    config = json.loads((REPOSITORY / "release.json").read_text(encoding="utf-8"))
    game_id = config["modio_game_id"]
    mod_id = os.environ.get("MODIO_MOD_ID", "").strip() or config.get("modio_mod_id")
    if type(game_id) is not int or game_id != 10640:
        raise ValueError("Expected the Transport Fever 3 mod.io game ID (10640)")
    if isinstance(mod_id, str) and re.fullmatch(r"[1-9][0-9]*", mod_id):
        mod_id = int(mod_id)
    if type(mod_id) is not int or mod_id <= 0:
        raise ValueError("Set Easier Waypoints' own mod.io ID in release.json or MODIO_MOD_ID; no request was made")
    return f"https://g-{game_id}.modapi.io/v1/games/{game_id}/mods/{mod_id}/files"



class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, token):
        self.base = target_base()
        self.token = token
        self.opener = build_opener(NoRedirect())

    def request(self, suffix="", fields=None):
        body = None if fields is None else urlencode(fields).encode("ascii")
        request = Request(self.base + suffix, data=body,
                          method="GET" if fields is None else "PUT",
                          headers={"Authorization": "Bearer " + self.token,
                                   "User-Agent": "EasierWaypointsReleaseTool/0.1",
                                   "Accept": "application/json",
                                   "Content-Type": "application/x-www-form-urlencoded"})
        try:
            with self.opener.open(request, timeout=30) as response:
                return json.load(response)
        except HTTPError as error:
            raise RuntimeError(f"mod.io returned HTTP {error.code}; check token permissions or retry later") from None
        except URLError:
            raise RuntimeError("Could not reach mod.io; check your connection") from None

    def files(self):
        result = []
        offset = 0
        while True:
            page = self.request("?" + urlencode({"_limit": 100, "_offset": offset}))
            rows = page["data"]
            result.extend(rows)
            offset += len(rows)
            if offset >= page["result_total"]:
                return result
            if not rows:
                raise RuntimeError("Incomplete mod.io file listing; no changes made")


def plain_text(changelog):
    # The mod.io website stores edited changelogs as HTML, e.g. "<p>v1.4.0 ...</p>".
    return html.unescape(re.sub(r"<[^>]+>", " ", changelog or ""))


def select_files(files, version, ids=()):
    if ids:
        selected = [file for file in files if file["id"] in ids]
        if {file["id"] for file in selected} != set(ids):
            raise ValueError("A requested file ID does not belong to this mod")
    else:
        # Only a release heading at the start counts; mentions of older releases do not.
        heading = re.compile(r"^\s*v?" + re.escape(version) + r"(?=$|[\s:—–-])", re.I)
        selected = [file for file in files if heading.search(plain_text(file.get("changelog")))]
    if not selected:
        raise ValueError("No matching release files. Put vMAJOR.MINOR.PATCH at the start of the upload changelog, or supply --file-id for each reviewed file.")
    return selected


# Release headings for --sync: no leading zeros, so "v1.2.01" is not a release.
RELEASE_HEADING = re.compile(r"^\s*v?((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))(?=$|[\s:—–-])", re.I)
RELEASE_LABEL = re.compile(r"\d+\.\d+\.\d+")


def plan_sync(files):
    """Group uploads still carrying a default label by their changelog release."""
    plan, conflicts = {}, []
    for file in sorted(files, key=lambda file: file["id"]):
        match = RELEASE_HEADING.search(plain_text(file.get("changelog")))
        if not match or file.get("version") == match.group(1):
            continue
        # Unattended runs never overwrite a deliberate release label.
        if RELEASE_LABEL.fullmatch(str(file.get("version") or "")):
            conflicts.append((file, match.group(1)))
        else:
            plan.setdefault(match.group(1), []).append(file)
    return plan, conflicts


def show_files(files, limit=None):
    newest = sorted(files, key=lambda file: file.get("date_added") or 0, reverse=True)
    for file in newest[:limit]:
        added = datetime.datetime.fromtimestamp(file.get("date_added") or 0).strftime("%Y-%m-%d %H:%M")
        platforms = ", ".join(entry.get("platform", "?") for entry in file.get("platforms") or []) or "-"
        changelog = " ".join(plain_text(file.get("changelog")).split())[:40]
        print(f"  ID {file['id']:<10} {file.get('filename', '?'):<28} version {file.get('version')!r:<9} added {added}  [{platforms}]  {changelog}")


def choose_files(files, version, ids=(), ask=None):
    if ids:
        return select_files(files, version, ids)
    try:
        return select_files(files, version)
    except ValueError:
        if ask is None:
            raise
    print(f"No upload changelog starts with v{version}. Your most recent uploads:")
    show_files(files, limit=10)
    answer = ask(f"Type the ID(s) to label {version}, separated by spaces (or press Enter to cancel): ")
    try:
        picked = [int(part) for part in re.split(r"[\s,]+", answer.strip()) if part]
    except ValueError:
        raise ValueError("File IDs must be numbers; no changes made") from None
    if not picked:
        raise ValueError("Cancelled; no changes made")
    return select_files(files, version, picked)


def update(client, files, version, apply=False, confirm=None):
    for file in files:
        print(f"File {file['id']} ({file['filename']}): {file.get('version')!r} -> {version!r}")
    if not apply and confirm is not None:
        apply = confirm()
    if not apply:
        print("No changes made." if confirm is not None else "Preview only. Run with --apply to update these labels.")
        return
    for file in files:
        if file.get("version") == version:
            print(f"File {file['id']}: already correct")
            continue
        # Recheck before writing so a changed release cannot be silently relabelled.
        current = client.request(f"/{file['id']}")
        if any(current.get(key) != file.get(key) for key in ("id", "version", "changelog")):
            raise RuntimeError(f"File {file['id']} changed since listing; rerun to review. Earlier files may already be updated.")
        client.request(f"/{file['id']}", {"version": version})
        verified = client.request(f"/{file['id']}")
        if verified.get("version") != version:
            raise RuntimeError(f"File {file['id']}: version verification failed. Earlier files may already be updated.")
        print(f"File {file['id']}: updated and verified")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="write without asking for confirmation")
    parser.add_argument("--version", help="override VERSION for an older release")
    parser.add_argument("--file-id", type=int, action="append", default=[], help="explicit reviewed file ID; repeat for PC/console")
    parser.add_argument("--list", action="store_true", help="only list this mod's uploads and their IDs")
    parser.add_argument("--sync", action="store_true", help="label every upload from the version its changelog starts with")
    args = parser.parse_args()
    if args.sync and (args.version or args.file_id or args.list):
        parser.error("--sync reads each version from the changelog; do not combine it with --version, --file-id or --list")
    version = args.version or (REPOSITORY / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        parser.error("version must be MAJOR.MINOR.PATCH")
    if any(file_id <= 0 for file_id in args.file_id):
        parser.error("file IDs must be positive")
    target_base()
    token = os.environ.get("MODIO_ACCESS_TOKEN")
    if not token:
        if not sys.stdin.isatty():
            parser.error("set MODIO_ACCESS_TOKEN (in GitHub Actions, the repository secret of that name)")
        token = getpass.getpass("Paste your mod.io OAuth access token (it stays hidden), then press Enter: ")
    if not token.strip():
        parser.error("an OAuth access token is required")
    client = Client(token.strip())
    files = client.files()
    if args.list:
        show_files(files)
        return
    # Interactive runs can pick files and confirm in one go; scripted runs never prompt.
    interactive = sys.stdin.isatty() and not args.apply
    if args.sync:
        plan, conflicts = plan_sync(files)
        for file, wanted in conflicts:
            print(f"Left file {file['id']} unchanged: labelled {file.get('version')!r}, but its changelog starts with v{wanted}")
        if not plan:
            print("Every upload with a version at the start of its changelog is labelled.")
            return
        for release, group in plan.items():
            confirm = (lambda release=release, group=group: input(f"Apply {release} to these {len(group)} file(s)? [y/N] ").strip().lower() in ("y", "yes")) if interactive else None
            update(client, group, release, args.apply, confirm)
        return
    selected = choose_files(files, version, args.file_id, input if interactive else None)
    confirm = (lambda: input(f"Apply {version} to these {len(selected)} file(s)? [y/N] ").strip().lower() in ("y", "yes")) if interactive else None
    update(client, selected, version, args.apply, confirm)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, KeyError, OSError) as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
