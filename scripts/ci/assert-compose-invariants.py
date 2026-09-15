#!/usr/bin/env python3
"""Assert the invariants CI must keep true for the rendered Compose config.

Covers parser mounts, wallet suffix handling, and the Traefik management surface.

Traefik's management API was exposed on a published :8080 (ENG-1265). These checks exist
so it cannot come back unnoticed, so they are deliberately strict about *how* Traefik is
configured, not only about what today's configuration happens to say.

Run against the widest render available (`docker compose --profile '*' config --format json`);
a narrower profile hides most services from the label sweep.
"""
import json
import sys
from pathlib import Path

PING_PORT = 8099
PING_ADDRESS = f"127.0.0.1:{PING_PORT}"
PUBLIC_PORTS = {"80", "443", "8001", "8010", "8545", "9001"}

# Each of these re-creates Traefik's internal :8080 entrypoint (static_config.go), or
# redirects configuration away from the flags below where CI cannot see it.
DENIED_FLAGS = (
    "api",
    "providers.rest",
    "metrics.prometheus",
    "entrypoints.traefik",
    # Selects a static config file; the file loader wins over flags entirely.
    "configfile",
    # Removes the internal ping router, so the healthcheck can never pass.
    "ping.manualrouting",
    # Gives the ping router TLS while the healthcheck probe stays plain HTTP.
    "entrypoints.ping.http.tls",
)

# Values that must be exactly these, because dropping them widens exposure silently.
PINNED_FLAGS = {
    "providers.docker.exposedbydefault": "false",
    "providers.file.directory": "/etc/traefik",
}

# config/traefik supplies middlewares only. Anything else there is either a static
# config (which would replace the CLI flags) or a route we have not reviewed.
ALLOWED_CONFIG_TOP = {"http"}
ALLOWED_CONFIG_HTTP = {"middlewares"}

failures = []


def require(condition, message):
    if not condition:
        failures.append(message)
    return condition


def flag_name(arg):
    """Normalised flag name, or None if this token is not a flag.

    Traefik's parser (paerser flag/flagparser.go, parseOne) accepts `-flag` and `--flag`
    identically, so matching a literal `--` prefix lets single-dash spellings through.
    """
    if not isinstance(arg, str) or not arg.startswith("-"):
        return None
    name = arg.lstrip("-").split("=", 1)[0].lower()
    return name or None


def flag_value(arg):
    return arg.split("=", 1)[1] if "=" in arg else None


def check_parser_and_wallet(services):
    parser_users = ["kaspad", *(n for n in services if n.startswith("kaswallet-"))]
    for name in parser_users:
        targets = {v.get("target") for v in services[name].get("volumes", [])}
        require("/app/parse-network-slug.sh" in targets, f"missing parser mount: {name}")

    kaswallet = "\n".join(services["kaswallet-0"].get("entrypoint", []))
    require("--testnet-suffix=$$KASPA_NETSUFFIX" in kaswallet,
            "kaswallet entrypoint does not propagate KASPA_NETSUFFIX")
    require("--subnetwork-id=$$IGRA_LANE_ID" in kaswallet,
            "kaswallet entrypoint does not forward IGRA_LANE_ID as --subnetwork-id")
    require("IGRA_LANE_ID must be set" in kaswallet,
            "kaswallet entrypoint is missing the IGRA_LANE_ID fail-fast guard")

    kaspad = "\n".join(services["kaspad"].get("entrypoint", []))
    require("--igra-lane-id=$$IGRA_LANE_ID" in kaspad,
            "kaspad entrypoint does not forward IGRA_LANE_ID as --igra-lane-id")
    require("IGRA_LANE_ID must be set" in kaspad,
            "kaspad entrypoint is missing the IGRA_LANE_ID fail-fast guard")
    require("TX_ID_PREFIX must be set" in kaspad,
            "kaspad entrypoint is missing the TX_ID_PREFIX fail-fast guard")


def check_traefik_invocation(traefik):
    entrypoint = traefik.get("entrypoint", [])
    command = traefik.get("command")
    if not require(isinstance(command, list), "traefik command must be a list"):
        return []

    # The wrapper execs `traefik "$@"`. Pin that shape: a `sh -c '...'` entrypoint would
    # hide the real argv in a single token, leaving every check below inspecting nothing.
    require(entrypoint[:2] == ["sh", "/app/watch-dependencies.sh"],
            "traefik must start via the dependency watcher")
    require(entrypoint[-2:] == ["--", "traefik"],
            "the watcher must exec traefik with argv taken from command, nothing appended")

    flags = [(flag_name(a), flag_value(a)) for a in entrypoint + command]
    flags = [(n, v) for n, v in flags if n]

    for denied in DENIED_FLAGS:
        hits = [n for n, _ in flags if n == denied or n.startswith(denied + ".")]
        require(not hits, f"Traefik flag must be absent: {denied} (found {hits})")

    for name, want in PINNED_FLAGS.items():
        require([v for n, v in flags if n == name] == [want],
                f"{name} must be set exactly once to {want}")

    # Ping must be enabled exactly once, on its own entrypoint, bound to loopback.
    # paerser keeps the last value for scalars, so a duplicate silently overrides.
    enable = [v for n, v in flags if n == "ping"]
    require(enable in ([None], ["true"]),
            f"ping must be enabled exactly once and never disabled (got {enable})")
    require([v for n, v in flags if n == "ping.entrypoint"] == ["ping"],
            "ping must use its own entrypoint, not the default :8080 one")
    require([v for n, v in flags if n == "entrypoints.ping.address"] == [PING_ADDRESS],
            f"ping must listen only on {PING_ADDRESS}")
    return flags


def check_traefik_environment_and_mounts(traefik):
    env = traefik.get("environment", {})
    require(not any(k.upper() == "TRAEFIK_API" or k.upper().startswith("TRAEFIK_API_")
                    for k in env), "Traefik API environment must be absent")
    # The file loader searches $XDG_CONFIG_HOME and $HOME before flags are read, so either
    # one lets a static config replace everything checked above.
    for var in ("XDG_CONFIG_HOME", "HOME"):
        require(var not in env, f"{var} must not be set on traefik; it redirects config discovery")

    require("network_mode" not in traefik, "traefik must stay on its own compose networks")

    mounts = {v.get("target"): str(v.get("source", "")) for v in traefik.get("volumes", [])}
    require(mounts.get("/etc/traefik", "").rstrip("/").endswith("config/traefik"),
            "traefik's /etc/traefik must come from config/traefik, the directory CI inspects")


def check_traefik_ports(traefik):
    ports = traefik.get("ports", [])
    published = []
    for port in ports:
        # An entry with no `published` still publishes — Compose assigns a random host port.
        value = str(port.get("published", "")).strip()
        if not require(value, f"every traefik port must name an explicit published port: {port}"):
            continue
        require(value in PUBLIC_PORTS,
                f"traefik may publish only {sorted(PUBLIC_PORTS)}; got {value}")
        require(str(port.get("target")) == value,
                f"published and target must match for traefik port {value}")
        require(port.get("mode") != "host",
                f"host-mode publishing bypasses the port allowlist (port {value})")
        published.append(value)
    require(sorted(published) == sorted(PUBLIC_PORTS),
            f"traefik must publish exactly {sorted(PUBLIC_PORTS)}; got {sorted(published)}")


def check_all_services(services):
    for name, service in services.items():
        for key, value in service.get("labels", {}).items():
            if not key.lower().startswith("traefik."):
                continue
            require("@internal" not in str(value).lower(),
                    f"{name}: management services must not be routed ({key}={value})")
            require(PING_ADDRESS not in str(value).replace(" ", ""),
                    f"{name}: must not proxy to the private ping listener ({key})")

        if name != "traefik":
            require(not str(service.get("image", "")).startswith("traefik"),
                    f"{name}: only the traefik service may run a traefik image")

        for port in service.get("ports", []):
            bounds = [int(p) for p in str(port.get("target", 0)).split("-")]
            require(not any(bounds[0] <= private <= bounds[-1] for private in (8080, PING_PORT)),
                    f"{name}: management ports must not be targeted, including in ranges")


def check_traefik_healthcheck(traefik):
    backends = [f"http://rpc-provider-{i}:8535/health" for i in range(20)]
    probe = "wget --quiet --spider --tries=1 --timeout=2 "
    expected = probe + f"http://{PING_ADDRESS}/ping && ( " + " || ".join(
        probe + url for url in backends) + " )"
    health = traefik.get("healthcheck", {})
    require(not health.get("disable", False), "traefik healthcheck must stay enabled")
    test = health.get("test", [])
    if require(len(test) == 2 and test[0] == "CMD-SHELL", "preserve shell healthcheck"):
        require(" ".join(test[1].split()) == expected,
                "health requires ping AND any of 20 backends")


def check_config_dir(config_dir):
    """config/traefik must hold dynamic middleware config only.

    Parsed, not grepped: a grep sees physical text, so it misses YAML escapes and
    trips over comments, and it cannot recognise a static config under a new filename.
    """
    directory = Path(config_dir)
    if not directory.is_dir():
        failures.append(f"{config_dir} is missing")
        return
    for path in sorted(directory.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() not in (".yml", ".yaml", ".toml"):
            require(False, f"{path}: unexpected file type in the Traefik config directory")
            continue
        try:
            if path.suffix.lower() == ".toml":
                import tomllib
                data = tomllib.loads(path.read_text(encoding="utf-8"))
            else:
                import yaml
                data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        except Exception as exc:                        # noqa: BLE001 - report, do not raise
            require(False, f"{path}: could not be parsed ({exc})")
            continue
        if not require(isinstance(data, dict), f"{path}: must be a mapping"):
            continue
        extra = set(data) - ALLOWED_CONFIG_TOP
        require(not extra,
                f"{path}: only {sorted(ALLOWED_CONFIG_TOP)} allowed here, found {sorted(extra)}; "
                "a static config file would override the Compose flags")
        http_extra = set(data.get("http") or {}) - ALLOWED_CONFIG_HTTP
        require(not http_extra,
                f"{path}: http may contain only {sorted(ALLOWED_CONFIG_HTTP)}, found {sorted(http_extra)}")


def main():
    args = [a for a in sys.argv[1:]]
    config_dir = "config/traefik"
    if "--config-dir" in args:
        index = args.index("--config-dir")
        config_dir = args[index + 1]
        del args[index:index + 2]
    compose_path = args[0] if args else "compose.json"

    with open(compose_path, encoding="utf-8") as handle:
        services = json.load(handle)["services"]

    # A tracked compose.yaml/compose.yml takes precedence over docker-compose.yml, so an
    # unexpected render is a finding in itself rather than something to crash on.
    missing = [n for n in ("traefik", "kaspad", "kaswallet-0") if n not in services]
    if missing:
        print(f"FAIL: rendered config is missing expected services: {missing}", file=sys.stderr)
        return 1

    check_parser_and_wallet(services)
    traefik = services["traefik"]
    check_traefik_invocation(traefik)
    check_traefik_environment_and_mounts(traefik)
    check_traefik_ports(traefik)
    check_traefik_healthcheck(traefik)
    check_all_services(services)
    check_config_dir(config_dir)

    if failures:
        for message in failures:
            print(f"FAIL: {message}", file=sys.stderr)
        return 1
    print(f"ok: {len(services)} services satisfy the compose invariants")
    return 0


if __name__ == "__main__":
    sys.exit(main())
