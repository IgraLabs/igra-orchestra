#!/usr/bin/env python3
"""Self-test for assert-compose-invariants.py.

A guard nobody tests is a guard nobody can trust: the first version of this check passed CI
while `-api.insecure=true` and a `sh -c` entrypoint walked straight past it. Every case below
is a bypass that was demonstrated against an earlier revision, plus the benign variations that
must keep passing so the guard is not merely strict.

Usage: test-compose-invariants.py <baseline-compose.json>
"""
import copy
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
GUARD = HERE / "assert-compose-invariants.py"
REPO_CONFIG = HERE.parent.parent / "config" / "traefik"

PING = "127.0.0.1:8099"
results = []


def run_guard(services, config_dir):
    with tempfile.TemporaryDirectory() as tmp:
        compose = Path(tmp) / "compose.json"
        compose.write_text(json.dumps({"services": services}))
        proc = subprocess.run(
            [sys.executable, str(GUARD), str(compose), "--config-dir", str(config_dir)],
            capture_output=True, text=True)
    return proc.returncode, (proc.stderr or proc.stdout).strip()


def case(label, mutate, expect_fail, baseline, config_dir):
    services = copy.deepcopy(baseline)
    mutate(services)
    code, output = run_guard(services, config_dir)
    failed = code != 0
    ok = failed == expect_fail
    results.append(ok)
    want = "reject" in ("reject" if expect_fail else "accept")
    status = "ok  " if ok else "FAIL"
    verb = "rejected" if failed else "accepted"
    print(f"  {status} {label:<62} {verb}")
    if not ok:
        print(f"        expected {'rejection' if expect_fail else 'acceptance'}; guard said: {output.splitlines()[:2]}")


def config_case(label, write, expect_fail, baseline):
    with tempfile.TemporaryDirectory() as tmp:
        mirror = Path(tmp) / "traefik"
        shutil.copytree(REPO_CONFIG, mirror)
        write(mirror)
        code, output = run_guard(copy.deepcopy(baseline), mirror)
    failed = code != 0
    ok = failed == expect_fail
    results.append(ok)
    print(f"  {'ok  ' if ok else 'FAIL'} {label:<62} {'rejected' if failed else 'accepted'}")
    if not ok:
        print(f"        guard said: {output.splitlines()[:2]}")


def add(flag):
    return lambda s: s["traefik"]["command"].append(flag)


def main():
    baseline = json.load(open(sys.argv[1], encoding="utf-8"))["services"]
    code, output = run_guard(copy.deepcopy(baseline), REPO_CONFIG)
    if code != 0:
        print("baseline does not pass the guard; aborting", file=sys.stderr)
        print(output, file=sys.stderr)
        return 1
    print("baseline: PASS\n")

    def c(label, mutate, expect_fail=True):
        case(label, mutate, expect_fail, baseline, REPO_CONFIG)

    print("Single-dash spellings (paerser accepts them exactly like --):")
    for flag in ("-api.insecure=true", "-api.dashboard=true", "-api=true",
                 "-providers.rest.insecure=true", "-metrics.prometheus=true",
                 "-entrypoints.traefik.address=:8080", "-ping.entrypoint=web",
                 "-entrypoints.ping.address=0.0.0.0:8099", "-configfile=/etc/traefik/x.yml"):
        c(flag, add(flag))

    print("\nDouble-dash equivalents (original coverage):")
    for flag in ("--api.insecure=true", "--api", "--providers.rest.insecure=true",
                 "--metrics.prometheus=true", "--entrypoints.traefik.address=:8080",
                 "--configfile=/etc/traefik/x.yml"):
        c(flag, add(flag))

    print("\nStatic-config redirection through the environment:")
    c("XDG_CONFIG_HOME set", lambda s: s["traefik"].setdefault("environment", {}).update(
        {"XDG_CONFIG_HOME": "/etc/traefik/x"}))
    c("HOME set", lambda s: s["traefik"].setdefault("environment", {}).update(
        {"HOME": "/etc/traefik/x"}))
    c("TRAEFIK_API_INSECURE set", lambda s: s["traefik"].setdefault("environment", {}).update(
        {"TRAEFIK_API_INSECURE": "true"}))

    print("\nEntrypoint shape (a shell string hides the real argv):")
    c("sh -c entrypoint carrying --api.insecure", lambda s: s["traefik"].__setitem__(
        "entrypoint", ["sh", "-c", "exec traefik --api.insecure=true \"$@\"", "traefik"]))
    c("watcher exec target renamed", lambda s: s["traefik"]["entrypoint"].__setitem__(-1, "sh"))
    c("flags appended after the exec target", lambda s: s["traefik"]["entrypoint"].append(
        "--api.insecure=true"))
    c("command replaced by a string", lambda s: s["traefik"].__setitem__("command", "--ping=true"))

    print("\nPing contract (health must keep working):")
    c("--ping.manualrouting=true", add("--ping.manualrouting=true"))
    c("--ping=false appended after --ping=true", add("--ping=false"))
    c("--entrypoints.ping.http.tls=true", add("--entrypoints.ping.http.tls=true"))
    c("ping bound to all interfaces", lambda s: s["traefik"]["command"].__setitem__(
        s["traefik"]["command"].index(f"--entrypoints.ping.address={PING}"),
        "--entrypoints.ping.address=:8099"))
    c("--ping.entrypoint removed", lambda s: s["traefik"]["command"].remove("--ping.entrypoint=ping"))
    c("ping disabled entirely", lambda s: s["traefik"]["command"].remove("--ping=true"))
    c("duplicate ping address overriding loopback",
      add(f"--entrypoints.ping.address=0.0.0.0:8099"))

    print("\nPinned provider flags:")
    c("exposedbydefault flipped to true", lambda s: s["traefik"]["command"].__setitem__(
        s["traefik"]["command"].index("--providers.docker.exposedbydefault=false"),
        "--providers.docker.exposedbydefault=true"))
    c("exposedbydefault removed", lambda s: s["traefik"]["command"].remove(
        "--providers.docker.exposedbydefault=false"))
    c("file provider pointed elsewhere", lambda s: s["traefik"]["command"].__setitem__(
        s["traefik"]["command"].index("--providers.file.directory=/etc/traefik"),
        "--providers.file.directory=/app"))
    c("/etc/traefik mounted from another source", lambda s: s["traefik"]["volumes"].__setitem__(
        next(i for i, v in enumerate(s["traefik"]["volumes"]) if v.get("target") == "/etc/traefik"),
        {"type": "bind", "source": "/repo/scripts", "target": "/etc/traefik"}))

    print("\nPublished ports:")
    c("extra port published", lambda s: s["traefik"]["ports"].append(
        {"mode": "ingress", "target": 9999, "published": "9999", "protocol": "tcp"}))
    c("8080 published", lambda s: s["traefik"]["ports"].append(
        {"mode": "ingress", "target": 8080, "published": "8080", "protocol": "tcp"}))
    c("container-only mapping (random host port)", lambda s: s["traefik"]["ports"].append(
        {"mode": "ingress", "target": 8081, "protocol": "tcp"}))
    c("published empty string", lambda s: s["traefik"]["ports"].append(
        {"mode": "ingress", "target": 8081, "published": "", "protocol": "tcp"}))
    c("target does not match published", lambda s: s["traefik"]["ports"].append(
        {"mode": "ingress", "target": 8080, "published": "8545", "protocol": "tcp"}))
    c("an allowlisted port dropped", lambda s: s["traefik"]["ports"].pop())
    c("host-mode publishing", lambda s: s["traefik"]["ports"].__setitem__(
        0, dict(s["traefik"]["ports"][0], mode="host")))

    print("\nOther services:")
    c("second traefik-image service", lambda s: s.update({"traefik-admin": {
        "image": "traefik:v3", "command": ["--api.insecure=true"],
        "ports": [{"mode": "ingress", "target": 8080, "published": "8080", "protocol": "tcp"}]}}))
    c("another service targets 8080", lambda s: s["kaspad"].setdefault("ports", []).append(
        {"mode": "ingress", "target": 8080, "published": "18080", "protocol": "tcp"}))
    for internal in ("api@internal", "ping@internal", "dashboard@internal",
                     "rest@internal", "prometheus@internal"):
        c(f"label routes {internal}", lambda s, i=internal: s["traefik"]["labels"].__setitem__(
            "traefik.http.routers.probe.service", i))
    c("label proxies to the private ping listener",
      lambda s: s["traefik"]["labels"].__setitem__(
          "traefik.http.services.probe.loadbalancer.server.url", f"http://{PING}"))

    print("\nHealthcheck:")
    c("healthcheck disabled", lambda s: s["traefik"].setdefault("healthcheck", {}).__setitem__(
        "disable", True))
    c("probe pointed back at :8080", lambda s: s["traefik"]["healthcheck"]["test"].__setitem__(
        1, s["traefik"]["healthcheck"]["test"][1].replace("8099", "8080")))
    c("network_mode host", lambda s: s["traefik"].__setitem__("network_mode", "host"))

    print("\nBenign variations that must keep passing:")
    c("Traefik's documented camelCase --entryPoints", lambda s: s["traefik"]["command"].__setitem__(
        s["traefik"]["command"].index(f"--entrypoints.ping.address={PING}"),
        f"--entryPoints.ping.address={PING}"), expect_fail=False)
    c("extra --entrypoints.ping.transport tuning",
      add("--entrypoints.ping.transport.respondingTimeouts.readTimeout=5s"), expect_fail=False)
    c("bare --ping instead of --ping=true", lambda s: s["traefik"]["command"].__setitem__(
        s["traefik"]["command"].index("--ping=true"), "--ping"), expect_fail=False)
    c("a publication narrowed to loopback", lambda s: s["traefik"]["ports"].__setitem__(
        0, dict(s["traefik"]["ports"][0], host_ip="127.0.0.1")), expect_fail=False)

    print("\nconfig/traefik contents:")
    def cc(label, write, expect_fail=True):
        config_case(label, write, expect_fail, baseline)

    cc("static config under a non-default filename", lambda d: (d / "custom.yml").write_text(
        "api:\n  insecure: true\nentryPoints:\n  traefik:\n    address: ':8545'\n"))
    cc("static config in a subdirectory", lambda d: (
        (d / "x").mkdir(), (d / "x" / "traefik.yml").write_text("api: {}\n")))
    cc("static config named traefik.toml", lambda d: (d / "traefik.toml").write_text("[api]\n"))
    cc("router escaping ping@internal across a line break",
       lambda d: (d / "extra.yml").write_text(
           'http:\n  routers:\n    p:\n      rule: "Path(`/x`)"\n      service: "ping@\\\n  internal"\n'))
    cc("plain reverse proxy to the private ping listener",
       lambda d: (d / "extra.yml").write_text(
           "http:\n  routers:\n    p:\n      rule: \"Path(`/ping`)\"\n      entryPoints: [web]\n"
           "      service: local-probe\n  services:\n    local-probe:\n      loadBalancer:\n"
           f"        servers:\n          - url: \"http://{PING}\"\n"))
    cc("a comment mentioning api@internal", lambda d: (d / "note.yml").write_text(
        "# NOTE: never route api@internal from here\nhttp:\n  middlewares: {}\n"), expect_fail=False)
    cc("a service legitimately named api", lambda d: (d / "note.yml").write_text(
        "http:\n  middlewares:\n    api:\n      compress: {}\n"), expect_fail=False)

    print()
    passed = sum(results)
    print(f"RESULT: {passed}/{len(results)} cases behaved as required")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
