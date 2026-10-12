#!/usr/bin/env python3
"""Self-test for the exact image-pin contract.

Three contracts, each checked at its real boundary:
  1. check-image-pins.py rejects tag-only, missing and duplicate pins before any lookup, and reports a digest
     mismatch apart from a failed lookup. Only the Docker Hub boundary is faked: a stub `docker` answers lookups.
  2. Every igranetwork image in docker-compose.yml and docker-compose.atan.yml comes from its own *_VERSION pin.
     The real `docker compose config` renders a distinct fixture pin per variable, so a hard-coded or cross-wired
     image fails.
  3. Setup (scripts/lib/setup-common.sh) reads the pins from .env and rejects any that are not exact, except on
     devnet, whose images are built locally.

Usage: test-image-pins.py   (needs python3, bash and the docker compose CLI; no daemon or network)
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
CHECKER = HERE / "check-image-pins.py"

spec = importlib.util.spec_from_file_location("check_image_pins", CHECKER)
check_image_pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check_image_pins)
REPOSITORIES = check_image_pins.REPOSITORIES
ATAN_KEYS = check_image_pins.ATAN_KEYS

# A distinct tag and digest per variable, so a value read from the wrong variable cannot match.
FIXTURE = {var: f"9.{i}.0@sha256:{format(i + 1, 'x') * 64}" for i, var in enumerate(REPOSITORIES)}
STUB_DOCKER = """#!/usr/bin/env python3
import json, os, sys
with open(os.environ["STUB_LOG"], "a") as log:
    log.write(" ".join(sys.argv[1:]) + "\\n")
mode = os.environ.get("STUB_MODE")
if mode == "fail":
    sys.exit("ERROR: registry unavailable")
if mode == "empty":
    sys.exit(0)
ref = sys.argv[4] if len(sys.argv) > 4 else ""
digest = json.loads(os.environ["STUB_DIGESTS"]).get(ref)
if not digest:
    sys.exit(f"ERROR: {ref}: not found")
sys.stdout.write(digest)
"""
results = []


def clean_env(**extra):
    """The caller's shell must not leak pins or compose settings into a case."""
    env = {k: v for k, v in os.environ.items() if not k.endswith("_VERSION") and not k.startswith("COMPOSE_")}
    env.update(extra)
    return env


def record(label, ok, detail=""):
    results.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label}")
    if not ok and detail:
        print(f"        {detail}")


def pin_lines(pins):
    return "".join(f"{key}={value}\n" for key, value in pins.items())


def registry_answers(pins):
    """What a correct registry returns for each pinned tag."""
    answers = {}
    for key, value in pins.items():
        tag, digest = value.split("@", 1)
        answers[f"igranetwork/{REPOSITORIES[key]}:{tag}"] = digest
    return answers


def run_checker(tmp, files, answers, mode=None):
    stub_dir = tmp / "bin"
    stub_dir.mkdir(exist_ok=True)
    stub = stub_dir / "docker"
    stub.write_text(STUB_DOCKER)
    stub.chmod(0o755)
    log = tmp / "lookups.log"
    log.unlink(missing_ok=True)
    env = clean_env(PATH=f"{stub_dir}{os.pathsep}{os.environ['PATH']}", STUB_LOG=str(log),
                    STUB_DIGESTS=json.dumps(answers), STUB_MODE=mode or "")
    proc = subprocess.run([sys.executable, str(CHECKER), *map(str, files)], capture_output=True, text=True, env=env,
                          cwd=REPO_ROOT)
    lookups = log.read_text().splitlines() if log.exists() else []
    return proc.returncode, proc.stderr, lookups, proc.stdout


def with_pin(text, key, value=None):
    """Copy of an env file with one pin replaced, or dropped when value is None."""
    lines = [line for line in text.splitlines() if not line.startswith(f"{key}=")]
    if value is not None:
        lines.append(f"{key}={value}")
    return "".join(line + "\n" for line in lines)


def write_pin_files(tmp, network_text, atan_text):
    network = tmp / "versions.test.env"
    atan = tmp / ".env.atan.example"
    network.write_text(network_text)
    atan.write_text(atan_text)
    return [network, atan]


def expect(label, result, *needles, offline=False):
    """Record a checker case: with no needles it must pass; otherwise it must fail naming every needle."""
    code, err, lookups, _ = result
    if not needles:
        record(label, code == 0, err)
        return
    record(label, code != 0 and all(needle in err for needle in needles) and not (offline and lookups), err)


# Values the checker must reject before any registry lookup, each as KASWALLET_VERSION.
MALFORMED_PINS = [
    ("a tag-only pin fails before any lookup", "9.2.0"),
    ("an unmatched quote fails before any lookup", '"' + FIXTURE["KASWALLET_VERSION"]),
    ("a mismatched quote pair fails before any lookup", '"' + FIXTURE["KASWALLET_VERSION"] + "'"),
    ("uppercase hex fails before any lookup", "9.2.0@sha256:" + "AB" * 32),
    ("a digest without a tag fails before any lookup", "sha256:" + "ab" * 32),
]
# Lines Compose also reads as KASPAD_VERSION, so appending one must count as a duplicate.
OVERRIDE_LINES = [
    ("an appended `export KEY=` override is a duplicate", "export KASPAD_VERSION=9.0.0\n"),
    ("an appended `KEY:` override is a duplicate", "KASPAD_VERSION: 9.0.0\n"),
]


def checker_cases():
    print("check-image-pins.py:")
    exact = pin_lines(FIXTURE)
    answers = registry_answers(FIXTURE)
    moved = dict(answers)
    moved[f"igranetwork/kaspad:{FIXTURE['KASPAD_VERSION'].split('@')[0]}"] = "sha256:" + "f" * 64
    atan_text = pin_lines({key: FIXTURE[key] for key in ATAN_KEYS})
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)

        def run(network_text, registry=answers, mode=None):
            return run_checker(tmp, write_pin_files(tmp, network_text, atan_text), registry, mode)

        expect("exact pins that match the registry pass", run(exact))
        expect("CRLF and quoted pins pass, as Compose reads them",
               run("".join(f'{key}="{value}"\r\n' for key, value in FIXTURE.items())))
        for label, value in MALFORMED_PINS:
            expect(label, run(with_pin(exact, "KASWALLET_VERSION", value)), "is not <tag>@sha256", offline=True)
        expect("a missing pin fails", run(with_pin(exact, "NODE_HEALTH_CHECK_VERSION")),
               "missing NODE_HEALTH_CHECK_VERSION")
        for label, line in OVERRIDE_LINES:
            expect(label, run(exact + line), "duplicate KASPAD_VERSION", offline=True)
        expect("a tag that resolves elsewhere is a digest mismatch", run(exact, registry=moved),
               "KASPAD_VERSION: digest mismatch")
        expect("a failed lookup is reported as a lookup failure", run(exact, mode="fail"), "lookup failed")
        expect("an empty lookup answer is reported as a lookup failure", run(exact, mode="empty"), "lookup failed")
    default_files_case()


def default_files_case():
    """CI runs the checker without arguments, so the defaults must cover every pin file."""
    real = {}
    for name in check_image_pins.DEFAULT_FILES:
        real.update(check_image_pins.read_pins(REPO_ROOT / name)[0])
    with tempfile.TemporaryDirectory() as raw:
        code, err, _, out = run_checker(Path(raw), [], registry_answers(real))
    checked = [name for name in ("versions.mainnet.env", "versions.galleon-testnet.env", ".env.atan.example")
               if f"{name}: " in out]
    record("with no arguments, all three pin files are checked", code == 0 and len(checked) == 3,
           f"checked: {checked}; {err.strip()}")


def render_images(compose_file, env_text):
    with tempfile.TemporaryDirectory() as raw:
        env_file = Path(raw) / "pins.env"
        env_file.write_text(env_text)
        proc = subprocess.run(
            ["docker", "compose", "-f", compose_file, "--env-file", str(env_file), "--profile", "*",
             "config", "--format", "json"],
            cwd=REPO_ROOT, capture_output=True, text=True, env=clean_env())
    if proc.returncode != 0:
        return None, proc.stderr.strip().splitlines()[-1:]
    return {name: svc.get("image", "") for name, svc in json.loads(proc.stdout)["services"].items()}, None


def consumption_case(label, compose_file, env_text, expected_keys):
    images, error = render_images(compose_file, env_text)
    if images is None:
        record(label, False, f"render failed: {error}")
        return
    by_repo = {repo: key for key, repo in REPOSITORIES.items()}
    wrong, seen = [], set()
    for name, image in sorted(images.items()):
        if not image.startswith("igranetwork/"):
            continue
        repo = image.split("/", 1)[1].split(":", 1)[0].split("@", 1)[0]
        key = by_repo.get(repo)
        seen.add(key)
        if key is None or image != f"igranetwork/{repo}:{FIXTURE[key]}":
            wrong.append(f"{name}: {image}")
    missing = sorted(set(expected_keys) - seen)
    record(label, not wrong and not missing, f"not from their pin: {wrong}; no service uses: {missing}")


def compose_cases():
    print("compose pin consumption:")
    for network in ("mainnet", "galleon-testnet"):
        example = (REPO_ROOT / f".env.{network}.example").read_text()
        consumption_case(f"{network}: every igranetwork image comes from its pin", "docker-compose.yml",
                         example + "\n" + pin_lines(FIXTURE), REPOSITORIES)
    atan_example = (REPO_ROOT / ".env.atan.example").read_text().splitlines(keepends=True)
    atan_text = "".join(line for line in atan_example if line.split("=", 1)[0] not in REPOSITORIES)
    consumption_case("ATAN-only: both images come from their pins", "docker-compose.atan.yml",
                     atan_text + pin_lines({key: FIXTURE[key] for key in ATAN_KEYS}), ATAN_KEYS)


def run_setup_validation(versions_file, env_text):
    with tempfile.TemporaryDirectory() as raw:
        env_file = Path(raw) / ".env"
        env_file.write_text(env_text)
        script = ('source "$SCRIPT_DIR/lib/setup-common.sh" && refresh_image_versions_from_env "$1" '
                  '&& validate_required_image_versions && echo PINS_OK')
        proc = subprocess.run(["bash", "-c", script, "validate", str(env_file)], capture_output=True, text=True,
                              env=clean_env(SCRIPT_DIR=str(REPO_ROOT / "scripts"), VERSIONS_FILE=versions_file))
    return proc.returncode == 0 and "PINS_OK" in proc.stdout, proc.stderr


def setup_cases():
    print("setup validation (setup-common.sh):")
    exact = (REPO_ROOT / "versions.mainnet.env").read_text()
    cases = [
        ("exact pins pass", "versions.mainnet.env", exact, True, ""),
        ("a tag-only pin fails and is named", "versions.mainnet.env",
         with_pin(exact, "KASWALLET_VERSION", "3.1.0"), False,
         "must be pinned as <tag>@sha256:<digest>: KASWALLET_VERSION"),
        ("the devnet sentinel fails outside devnet", "versions.galleon-testnet.env",
         with_pin(exact, "KASPAD_VERSION", "devnet"), False,
         "must be pinned as <tag>@sha256:<digest>: KASPAD_VERSION"),
        ("a TODO placeholder keeps its own message", "versions.mainnet.env",
         with_pin(exact, "RETH_VERSION", "TODO_RETH_VERSION"), False, "still TODO placeholders: RETH_VERSION"),
        ("a pin missing from .env fails instead of using the default", "versions.mainnet.env",
         with_pin(exact, "NODE_HEALTH_CHECK_VERSION"), False,
         "missing or still TODO placeholders: NODE_HEALTH_CHECK_VERSION"),
        ("devnet keeps its locally built sentinel", "versions.devnet.env",
         (REPO_ROOT / "versions.devnet.env").read_text(), True, ""),
    ]
    for label, versions_file, env_text, should_pass, message in cases:
        passed, err = run_setup_validation(versions_file, env_text)
        record(label, passed == should_pass and (should_pass or message in err), err.strip())


def main():
    checker_cases()
    compose_cases()
    setup_cases()
    print()
    passed = sum(results)
    print(f"RESULT: {passed}/{len(results)} cases behaved as required")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
