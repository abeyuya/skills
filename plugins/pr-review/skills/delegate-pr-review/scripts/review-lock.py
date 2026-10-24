#!/usr/bin/env python3
"""Coordinate one delegated review per PR across local chats."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import urlsplit


def pr_key(pr):
    url = urlsplit(pr)
    match = re.fullmatch(r"/([^/]+)/([^/]+)/pull/([1-9][0-9]*)/?", url.path)
    if (url.scheme != "https" or not url.netloc or url.username is not None
            or url.query or url.fragment or match is None):
        raise ValueError("Expected an HTTPS pull request URL without credentials, query or fragment")
    canonical = url.netloc.lower() + "/" + "/".join(match.groups()).lower()
    return hashlib.sha256(canonical.encode()).hexdigest()


def read_owner(lock):
    owner_path = lock / "owner.json"
    if lock.is_symlink() or owner_path.is_symlink():
        return None
    try:
        owner = json.loads(owner_path.read_text())
        return owner if isinstance(owner, dict) else None
    except (OSError, ValueError):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["acquire", "release"])
    parser.add_argument("--pr", required=True)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--registry-root", type=Path,
                        default=Path(tempfile.gettempdir()) / "codex-delegate-pr-review")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", args.request_id):
        parser.error("request-id must be a lowercase UUID")
    if not Path(args.state_path).is_absolute():
        parser.error("state-path must be absolute")
    try:
        key = pr_key(args.pr)
    except ValueError as error:
        parser.error(str(error))
    root = args.registry_root
    if root.is_symlink():
        parser.error("registry-root must not be a symlink")
    lock = root / key
    requested = {"pr": args.pr, "request_id": args.request_id,
                 "state_path": str(Path(args.state_path).resolve())}
    status = None
    if args.action == "acquire":
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            lock.mkdir(mode=0o700)
        except FileExistsError:
            owner = read_owner(lock)
            same = owner and all(owner.get(k) == requested[k] for k in ("request_id", "state_path"))
            status = "owned" if same else "busy"
        else:
            # Keep the directory locked if recording ownership fails; never start B in that state.
            fd = os.open(lock / "owner.json", os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(requested, stream)
            owner = requested
            status = "acquired"
    elif not lock.exists() and not lock.is_symlink():
        owner = None
        status = "absent"
    else:
        owner = read_owner(lock)
        same = owner and all(owner.get(k) == requested[k] for k in ("request_id", "state_path"))
        if same:
            (lock / "owner.json").unlink()
            lock.rmdir()
            status = "released"
        else:
            status = "busy"
    print(json.dumps({"status": status, "lock_path": str(lock), "owner": owner}))
    return 3 if status == "busy" else 0


if __name__ == "__main__":
    raise SystemExit(main())
