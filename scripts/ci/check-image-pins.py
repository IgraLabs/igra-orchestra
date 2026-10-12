#!/usr/bin/env python3
"""Check that every published IGRA image pin is exact and still matches Docker Hub.

Each pin is `<tag>@sha256:<index digest>` (doc/node-operations/environment-reference.md#image-versions).
Docker runs the digest, so a tag-only pin lets the image change under a node, and a pin whose tag no longer
resolves to its digest is mislabelled. Every file is validated before any registry lookup, so a malformed or
missing pin fails offline.

Usage: check-image-pins.py [pin-file ...]   (default: both network version files and the ATAN template)
"""
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DEFAULT_FILES = ["versions.mainnet.env", "versions.galleon-testnet.env", ".env.atan.example"]

# *_VERSION variable -> igranetwork/<repository>, as interpolated by docker-compose.yml and docker-compose.atan.yml.
REPOSITORIES = {
    "KASPAD_VERSION": "kaspad",
    "RETH_VERSION": "reth",
    "KASWALLET_VERSION": "kaswallet",
    "RPC_PROVIDER_VERSION": "rpc-provider",
    "NODE_HEALTH_CHECK_VERSION": "node-health-check-client",
    "ATAN_UPLOADER_VERSION": "atan-uploader",
}
# The ATAN-only stack runs just these two images.
ATAN_KEYS = {"KASPAD_VERSION", "ATAN_UPLOADER_VERSION"}
PIN = re.compile(r"(?P<tag>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})@(?P<digest>sha256:[0-9a-f]{64})")
# Compose's env-file reader also accepts `export KEY=value` and `KEY: value`; reading those forms here keeps an
# appended override from slipping past the duplicate and format checks.
ASSIGNMENT = re.compile(r"(?:export\s+)?(?P<key>[A-Za-z_][A-Za-z0-9_]*)\s*[=:]\s*(?P<value>.*)")
MATCHED_QUOTES = re.compile(r"""(['"])(?P<inner>.*)\1""")
DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
LOOKUP_TIMEOUT_SECONDS = 60


def shown(path):
    """Repo-relative path for files under the current directory, absolute otherwise."""
    relative = os.path.relpath(path)
    return str(path) if relative.startswith("..") else relative


def parse_assignment(raw):
    """Return (key, value) for an env-file assignment as Compose reads it, or None for any other line."""
    line = raw.strip()
    match = None if line.startswith("#") else ASSIGNMENT.fullmatch(line)
    if match is None:
        return None
    value = match["value"].strip()
    quoted = MATCHED_QUOTES.fullmatch(value)
    return match["key"], quoted["inner"] if quoted else value


def read_pins(path):
    """Return ({key: value}, [errors]) for the image pins assigned in one env file."""
    pins, errors = {}, []
    for number, raw in enumerate(path.read_text().splitlines(), start=1):
        assignment = parse_assignment(raw)
        if assignment is None or assignment[0] not in REPOSITORIES:
            continue
        key, value = assignment
        if key in pins:
            errors.append(f"{shown(path)}:{number}: duplicate {key}")
        elif not PIN.fullmatch(value):
            errors.append(f"{shown(path)}:{number}: {key}={value} is not <tag>@sha256:<64 lowercase hex>")
        pins[key] = value
    required = ATAN_KEYS if path.name.startswith(".env.atan") else set(REPOSITORIES)
    errors.extend(f"{shown(path)}: missing {key}" for key in sorted(required - pins.keys()))
    return pins, errors


def lookup(repository, tag):
    """Return (index digest, None) for igranetwork/<repository>:<tag>, or (None, error)."""
    ref = f"igranetwork/{repository}:{tag}"
    try:
        proc = subprocess.run(
            ["docker", "buildx", "imagetools", "inspect", ref, "--format", "{{.Manifest.Digest}}"],
            capture_output=True, text=True, timeout=LOOKUP_TIMEOUT_SECONDS)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"lookup failed for {ref}: {exc}"
    digest = proc.stdout.strip()
    if proc.returncode != 0 or not DIGEST.fullmatch(digest):
        detail = (proc.stderr or proc.stdout).strip().splitlines()
        return None, f"lookup failed for {ref}: {detail[-1] if detail else f'exit {proc.returncode}'}"
    return digest, None


def check_registry(pinned):
    """Compare each pin's digest with what its tag resolves to, looking each tag up once."""
    failures, resolved = [], {}
    for path, key, value in pinned:
        match = PIN.fullmatch(value)
        target = (REPOSITORIES[key], match["tag"])
        if target not in resolved:
            resolved[target] = lookup(*target)
            if resolved[target][1]:
                failures.append(resolved[target][1])
        digest = resolved[target][0]
        if digest is None:
            continue
        if digest != match["digest"]:
            failures.append(f"{shown(path)}: {key}: digest mismatch: igranetwork/{target[0]}:{target[1]} "
                            f"resolves to {digest}, but the pin says {match['digest']}")
        else:
            print(f"ok   {shown(path)}: {key}={value}")
    return failures


def main(argv):
    files = [Path(arg) for arg in argv] or [REPO_ROOT / name for name in DEFAULT_FILES]
    pinned, failures = [], []
    for path in files:
        try:
            pins, errors = read_pins(path)
        except OSError as exc:
            pins, errors = {}, [f"{shown(path)}: {exc.strerror}"]
        failures.extend(errors)
        pinned.extend((path, key, value) for key, value in pins.items())
    if not failures:
        failures = check_registry(pinned)
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
