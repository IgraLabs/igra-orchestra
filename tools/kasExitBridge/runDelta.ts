import { existsSync, readdirSync, unlinkSync } from "fs";
import { join, resolve } from "path";
import { spawnSync } from "child_process";
import {
  ENV_KEB_CONFIG_PATH,
  loadKebSharedConfig,
  resolveHome,
} from "./config";

type CliOpts = {
  configPath?: string;
  reportsDir: string;
  startBlock?: number;
  endBlock?: number;
  delta: number;
  runs: number;
  previousCheckpointFile?: string;
  contractExpectedValuesFile?: string;
  manifestSigningPrivateKey?: string;
  manifestSigningKeyId?: string;
  manifestSigningKeyType?: "rsa" | "ecdsa";
  manifestSigningPublicKey?: string;
  cleanupCreatedOutsideBundle: boolean;
  dryRun: boolean;
};

type RunRef = {
  fromBlock: number;
  toBlock: number;
  timestamp: string;
  bundleDir: string;
  checkpointFile: string;
};

const NAME_RE = /^keb-from-(\d+)-to-(\d+)-(\d{8}T\d{6}Z)\.bundle$/;
const DEFAULT_DELTA = 86_400;
const ENV_SIGNING_PRIVATE_KEY = "KEB_MANIFEST_SIGNING_PRIVATE_KEY";
const ENV_SIGNING_PUBLIC_KEY = "KEB_MANIFEST_SIGNING_PUBLIC_KEY";
const ENV_SIGNING_KEY_ID = "KEB_MANIFEST_SIGNING_KEY_ID";
const ENV_SIGNING_KEY_TYPE = "KEB_MANIFEST_SIGNING_KEY_TYPE";
const ENV_REPORTS_DIR = "KEB_REPORTS_DIR";
const ENV_DELTA_BLOCKS = "KEB_DELTA_BLOCKS";
const ENV_CONTRACT_EXPECTED_VALUES_FILE = "KEB_CONTRACT_EXPECTED_VALUES_FILE";
const DEFAULT_SIGNING_PRIVATE_KEY =
  "~/.local/share/igra/keb-manifest-signing/keb_manifest_signing_priv.pem";
const DEFAULT_SIGNING_PUBLIC_KEY =
  "~/.local/share/igra/keb-manifest-signing/keb_manifest_signing_pub.pem";

function parseCli(argv: string[]): CliOpts {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    if (k === "--dry-run") {
      map.set(k, "true");
      continue;
    }
    if (k === "--cleanup-created-outside-bundle") {
      map.set(k, "true");
      continue;
    }
    const v = argv[i + 1];
    if (!v || v.startsWith("--")) {
      throw new Error(`Missing value for ${k}`);
    }
    map.set(k, v);
    i++;
  }

  const configPath = map.get("--config");
  const shared = loadSharedConfigOrFallback(configPath);

  const delta = parsePositiveIntAny(
    map.get("--delta-blocks") ??
      process.env[ENV_DELTA_BLOCKS] ??
      shared?.kasExitBridge.deltaBlocksDefault,
    "--delta-blocks",
    DEFAULT_DELTA,
  );
  const runs = parsePositiveInt(map.get("--runs"), "--runs", 1);
  const startBlock = parseOptionalNonNegativeInt(map.get("--start-block"), "--start-block");
  const endBlock = parseOptionalNonNegativeInt(map.get("--end-block"), "--end-block");
  const reportsDir =
    map.get("--reports-dir") ??
    process.env[ENV_REPORTS_DIR] ??
    shared?.kasExitBridge.reportsDir ??
    "impl/reports";
  const previousCheckpointFile = map.get("--previous-checkpoint-file");
  const contractExpectedValuesFile =
    normalizePathMaybe(
      map.get("--contract-expected-values-file") ??
        process.env[ENV_CONTRACT_EXPECTED_VALUES_FILE] ??
        shared?.kasExitBridge.expectedValuesFile,
    ) ?? undefined;
  const defaultPrivate = normalizePath(DEFAULT_SIGNING_PRIVATE_KEY);
  const defaultPublic = normalizePath(DEFAULT_SIGNING_PUBLIC_KEY);
  const manifestSigningPrivateKey =
    normalizePathMaybe(
      map.get("--manifest-signing-private-key") ??
        process.env[ENV_SIGNING_PRIVATE_KEY] ??
        shared?.kasExitBridge.signing.privateKeyPath,
    ) ?? defaultPrivate;
  const manifestSigningPublicKey =
    normalizePathMaybe(
      map.get("--manifest-signing-public-key") ??
        process.env[ENV_SIGNING_PUBLIC_KEY] ??
        shared?.kasExitBridge.signing.publicKeyPath,
    ) ?? defaultPublic;
  const manifestSigningKeyId =
    map.get("--manifest-signing-key-id") ??
    process.env[ENV_SIGNING_KEY_ID] ??
    shared?.kasExitBridge.signing.keyId;
  const manifestSigningKeyType =
    map.get("--manifest-signing-key-type") ??
    process.env[ENV_SIGNING_KEY_TYPE] ??
    shared?.kasExitBridge.signing.keyType;
  const dryRun = map.get("--dry-run") === "true";
  const cleanupCreatedOutsideBundle = map.get("--cleanup-created-outside-bundle") === "true";

  if (endBlock !== undefined && runs !== 1) {
    throw new Error("--end-block can only be used with --runs 1");
  }
  if (startBlock !== undefined && endBlock !== undefined && startBlock > endBlock) {
    throw new Error(`--start-block (${startBlock}) > --end-block (${endBlock})`);
  }

  if (manifestSigningKeyType && manifestSigningKeyType !== "rsa" && manifestSigningKeyType !== "ecdsa") {
    throw new Error('Invalid --manifest-signing-key-type: use "rsa" or "ecdsa"');
  }
  if (!manifestSigningPrivateKey) {
    throw new Error(
      "run-delta requires --manifest-signing-private-key because verify enforces signed manifests" +
        ` (or env ${ENV_SIGNING_PRIVATE_KEY}, default ${defaultPrivate})`,
    );
  }
  if (!manifestSigningPublicKey) {
    throw new Error(
      "run-delta requires --manifest-signing-public-key because verify enforces signed manifests" +
        ` (or env ${ENV_SIGNING_PUBLIC_KEY}, default ${defaultPublic})`,
    );
  }

  return {
    configPath,
    reportsDir,
    startBlock,
    endBlock,
    delta,
    runs,
    previousCheckpointFile,
    contractExpectedValuesFile,
    manifestSigningPrivateKey,
    manifestSigningKeyId,
    manifestSigningKeyType: manifestSigningKeyType as "rsa" | "ecdsa" | undefined,
    manifestSigningPublicKey,
    cleanupCreatedOutsideBundle,
    dryRun,
  };
}

function parsePositiveInt(v: string | undefined, flag: string, fallback: number): number {
  if (v === undefined) return fallback;
  const n = Number(v);
  if (!Number.isInteger(n) || n <= 0) {
    throw new Error(`Invalid ${flag}: expected positive integer`);
  }
  return n;
}

function parseOptionalNonNegativeInt(v: string | undefined, flag: string): number | undefined {
  if (v === undefined) return undefined;
  const n = Number(v);
  if (!Number.isInteger(n) || n < 0) {
    throw new Error(`Invalid ${flag}: expected non-negative integer`);
  }
  return n;
}

function parsePositiveIntAny(value: unknown, flag: string, fallback: number): number {
  if (value === undefined || value === null) return fallback;
  if (typeof value === "number") {
    if (!Number.isInteger(value) || value <= 0) {
      throw new Error(`Invalid ${flag}: expected positive integer`);
    }
    return value;
  }
  if (typeof value === "string") {
    return parsePositiveInt(value, flag, fallback);
  }
  throw new Error(`Invalid ${flag}: expected positive integer`);
}

function loadSharedConfigOrFallback(configPath?: string) {
  const explicit = configPath ?? process.env[ENV_KEB_CONFIG_PATH];
  try {
    return loadKebSharedConfig(configPath);
  } catch (err) {
    if (explicit) throw err;
    return undefined;
  }
}

function normalizePath(pathValue: string): string {
  return resolve(resolveHome(pathValue));
}

function normalizePathMaybe(pathValue: string | undefined): string | undefined {
  if (!pathValue) return undefined;
  return normalizePath(pathValue);
}

function discoverRuns(reportsDir: string): RunRef[] {
  const absDir = resolve(reportsDir);
  if (!existsSync(absDir)) return [];
  const items = readdirSync(absDir);
  const out: RunRef[] = [];
  for (const name of items) {
    const m = NAME_RE.exec(name);
    if (!m) continue;
    const fromBlock = Number(m[1]);
    const toBlock = Number(m[2]);
    const timestamp = m[3];
    if (!Number.isInteger(fromBlock) || !Number.isInteger(toBlock)) continue;
    const bundleDir = join(absDir, name);
    const derivedCheckpointFile = join(bundleDir, "derived", "checkpoint.end.json");
    const legacyTopLevelCheckpointFile = join(
      absDir,
      `keb-from-${fromBlock}-to-${toBlock}-${timestamp}.checkpoint.end.json`,
    );
    const checkpointFile = existsSync(derivedCheckpointFile)
      ? derivedCheckpointFile
      : legacyTopLevelCheckpointFile;
    out.push({ fromBlock, toBlock, timestamp, bundleDir, checkpointFile });
  }
  out.sort((a, b) => {
    if (a.toBlock !== b.toBlock) return a.toBlock - b.toBlock;
    if (a.fromBlock !== b.fromBlock) return a.fromBlock - b.fromBlock;
    return a.timestamp.localeCompare(b.timestamp);
  });
  return out;
}

function findLatestRun(runs: RunRef[]): RunRef | undefined {
  return runs.length === 0 ? undefined : runs[runs.length - 1];
}

function findRunEndingAt(runs: RunRef[], endBlock: number): RunRef | undefined {
  const matches = runs.filter((r) => r.toBlock === endBlock);
  return matches.length === 0 ? undefined : matches[matches.length - 1];
}

function runCmd(args: string[], dryRun: boolean): void {
  const printable = args.map((v) => (v.includes(" ") ? JSON.stringify(v) : v)).join(" ");
  console.log(`$ ${printable}`);
  if (dryRun) return;
  const res = spawnSync(args[0], args.slice(1), { stdio: "inherit" });
  if ((res.status ?? 1) !== 0) {
    process.exit(res.status ?? 1);
  }
}

function toUtcStamp(): string {
  return new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
}

function cleanupTopLevelFilesCreatedByRun(args: {
  base: string;
  bundleDir: string;
  dryRun: boolean;
}): void {
  const candidates = [
    `${args.base}.exit.data.json`,
    `${args.base}.checks.json`,
    `${args.base}.tree.data.json`,
    `${args.base}.tree.snapshot.json`,
    `${args.base}.contract.preverify.json`,
    `${args.base}.checkpoint.end.json`,
  ].map((p) => resolve(p));

  const bundlePrefix = `${resolve(args.bundleDir)}/`;
  for (const file of candidates) {
    if (file === resolve(args.bundleDir) || file.startsWith(bundlePrefix)) {
      console.log(`[cleanup] skip (inside bundle): ${file}`);
      continue;
    }
    if (!existsSync(file)) {
      console.log(`[cleanup] skip (not found): ${file}`);
      continue;
    }
    if (args.dryRun) {
      console.log(`[cleanup] would delete: ${file}`);
      continue;
    }
    unlinkSync(file);
    console.log(`[cleanup] deleted: ${file}`);
  }
}

function main() {
  const opts = parseCli(process.argv.slice(2));
  const reportsDirAbs = resolve(opts.reportsDir);
  const runs = discoverRuns(opts.reportsDir);

  let startBlock: number;
  let previousCheckpointFile: string;

  if (opts.startBlock !== undefined) {
    startBlock = opts.startBlock;
    if (opts.previousCheckpointFile) {
      previousCheckpointFile = resolve(opts.previousCheckpointFile);
    } else {
      const prior = findRunEndingAt(runs, startBlock - 1);
      if (!prior) {
        throw new Error(
          `No prior run ending at block ${startBlock - 1}. Provide --previous-checkpoint-file explicitly.`,
        );
      }
      previousCheckpointFile = prior.checkpointFile;
    }
  } else {
    const latest = findLatestRun(runs);
    if (!latest) {
      throw new Error(
        `No prior keb bundles found in ${reportsDirAbs}. Provide --start-block and --previous-checkpoint-file.`,
      );
    }
    startBlock = latest.toBlock + 1;
    previousCheckpointFile = latest.checkpointFile;
  }

  if (!existsSync(previousCheckpointFile)) {
    throw new Error(`Previous checkpoint file not found: ${previousCheckpointFile}`);
  }
  if (!opts.manifestSigningPrivateKey || !existsSync(resolve(opts.manifestSigningPrivateKey))) {
    throw new Error(
      `Manifest signing private key not found: ${resolve(opts.manifestSigningPrivateKey ?? "")}`,
    );
  }
  if (!opts.manifestSigningPublicKey || !existsSync(resolve(opts.manifestSigningPublicKey))) {
    throw new Error(
      `Manifest signing public key not found: ${resolve(opts.manifestSigningPublicKey ?? "")}`,
    );
  }

  console.log(`reportsDir=${reportsDirAbs}`);
  if (opts.configPath) console.log(`configPath=${resolve(opts.configPath)}`);
  console.log(`startBlock=${startBlock}`);
  console.log(`deltaBlocks=${opts.delta}`);
  console.log(`runs=${opts.runs}`);
  console.log(`previousCheckpointFile=${previousCheckpointFile}`);
  console.log(`cleanupCreatedOutsideBundle=${opts.cleanupCreatedOutsideBundle}`);
  if (opts.endBlock !== undefined) console.log(`explicitEndBlock=${opts.endBlock}`);
  if (opts.dryRun) console.log("dryRun=true");

  for (let i = 0; i < opts.runs; i++) {
    const fromBlock = startBlock;
    const toBlock = opts.endBlock !== undefined ? opts.endBlock : fromBlock + opts.delta - 1;
    if (fromBlock > toBlock) {
      throw new Error(`Computed invalid range: ${fromBlock}..${toBlock}`);
    }
    const stamp = toUtcStamp();
    const base = join(reportsDirAbs, `keb-from-${fromBlock}-to-${toBlock}-${stamp}`);
    const bundleDir = `${base}.bundle`;
    const endCheckpointFile = join(bundleDir, "derived", "checkpoint.end.json");

    runCmd(
      (() => {
        const cmd = [
        "npm",
        "run",
        "kas-exit:audit",
        "--",
        "--start-block",
        String(fromBlock),
        "--end-block",
        String(toBlock),
        "--out",
        base,
        "--out-bundle-dir",
        bundleDir,
        "--previous-checkpoint-file",
        previousCheckpointFile,
        ];
        if (opts.contractExpectedValuesFile) {
          cmd.push("--contract-expected-values-file", opts.contractExpectedValuesFile);
        }
        if (opts.manifestSigningPrivateKey) {
          cmd.push("--manifest-signing-private-key", opts.manifestSigningPrivateKey);
        }
        if (opts.manifestSigningKeyId) {
          cmd.push("--manifest-signing-key-id", opts.manifestSigningKeyId);
        }
        if (opts.manifestSigningKeyType) {
          cmd.push("--manifest-signing-key-type", opts.manifestSigningKeyType);
        }
        return cmd;
      })(),
      opts.dryRun,
    );

    runCmd(
      (() => {
        const cmd = [
        "npm",
        "run",
        "kas-exit:verify",
        "--",
        "--bundle-dir",
        bundleDir,
        "--previous-checkpoint-file",
        previousCheckpointFile,
        ];
        if (opts.manifestSigningPublicKey) {
          cmd.push("--manifest-signing-public-key", opts.manifestSigningPublicKey);
        }
        return cmd;
      })(),
      opts.dryRun,
    );

    if (opts.cleanupCreatedOutsideBundle) {
      cleanupTopLevelFilesCreatedByRun({
        base,
        bundleDir,
        dryRun: opts.dryRun,
      });
    }

    previousCheckpointFile = endCheckpointFile;
    startBlock = toBlock + 1;
  }
}

main();
