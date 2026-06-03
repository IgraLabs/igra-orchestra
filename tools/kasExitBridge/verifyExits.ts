import { createHash, createPublicKey, verify as cryptoVerify } from "crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join, relative, resolve } from "path";
import { ethers } from "ethers";
import {
  ENV_KEB_CONFIG_PATH,
  loadKebSharedConfigWithPath,
  resolveHome,
  resolvePathFromConfig,
} from "./config";

type CliOpts = {
  configPath?: string;
  bundleDir?: string;
  exitDataFile: string;
  treeDataFile: string;
  treeSnapshotFile?: string;
  previousCheckpointFile?: string;
  manifestSigningPublicKey?: string;
  outChecksFile?: string;
};

type BundleManifest = {
  schemaVersion: number;
  kind: string;
  createdAt: string;
  artifactChecksums?: {
    exitDataSha256?: string;
    checksSha256?: string;
    treeDataSha256?: string;
    checkpointEndSha256?: string;
    contractPreVerificationSha256?: string;
  };
  bundleIntegral?: {
    algorithm?: string;
    canonicalization?: string;
    value?: string;
  };
  bundleIdentity?: {
    algorithm?: string;
    canonicalization?: string;
    payloadVersion?: number;
    value?: string;
  };
  signature?: {
    algorithm?: string;
    keyType?: string;
    keyId?: string;
    signatureFile?: string;
    signatureEncoding?: string;
  };
  files: Array<{
    path: string;
    sha256: string;
    size: number;
  }>;
};

type ExitRecord = {
  status: "success" | "reverted";
  requestId: number | null;
  blockNum: number;
  txHash: string;
  unlockAmountSompi: string;
  burnWei: string;
  messageId: string | null;
  dispatchMessage: string | null;
  insertedIntoTreeIndex: number | null;
  dispatchMessageDecoded: {
    outer: {
      version: number;
      nonce: number;
      originDomain: number;
      sender: string;
      destinationDomain: number;
      recipient: string;
    };
    body: {
      format: number;
      requestId: number;
      unlockAmountSompi: string;
      originBurner: string;
      kasPayoutAddressLength: number;
      kasPayoutAddress: string;
    };
  } | null;
};

type TreeEvent = {
  txHash: string;
  blockNum: number;
  messageId: string;
  index: number;
};

type TreeSnapshot = {
  blockNum: number;
  count: bigint;
  root: string;
  branch: string[];
  treeDepth?: number;
};

type KebCheckpoint = {
  blockTag: number;
  nextExitRequestId: bigint;
  totalBurnedWei: bigint;
};

type DeltaAnchorCheckpoint = {
  blockTag: number;
  merkleTreeHook: {
    root: string;
    count: bigint;
  };
  kasExitBridge: {
    nextExitRequestId: bigint;
    totalBurnedWei: bigint;
  };
};

const HYPERLANE_TREE_DEPTH = 32;
const HYPERLANE_MAX_LEAVES = (1n << 32n) - 1n;
const ZERO_ROOT = ethers.ZeroHash;
const SOMPI_SCALE = 10_000_000_000n;
const BUNDLE_INTEGRAL_CANONICALIZATION = "json-c14n-sorted-keys-no-whitespace-utf8";
const BUNDLE_IDENTITY_CANONICALIZATION = "json-c14n-sorted-keys-no-whitespace-utf8";
const DEFAULT_SIGNING_PUBLIC_KEY =
  "~/.local/share/igra/keb-manifest-signing/keb_manifest_signing_pub.pem";
const ENV_SIGNING_PUBLIC_KEY = "KEB_MANIFEST_SIGNING_PUBLIC_KEY";
const HYPERLANE_ZERO_HASHES = [
  "0x0000000000000000000000000000000000000000000000000000000000000000",
  "0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5",
  "0xb4c11951957c6f8f642c4af61cd6b24640fec6dc7fc607ee8206a99e92410d30",
  "0x21ddb9a356815c3fac1026b6dec5df3124afbadb485c9ba5a3e3398a04b7ba85",
  "0xe58769b32a1beaf1ea27375a44095a0d1fb664ce2dd358e7fcbfb78c26a19344",
  "0x0eb01ebfc9ed27500cd4dfc979272d1f0913cc9f66540d7e8005811109e1cf2d",
  "0x887c22bd8750d34016ac3c66b5ff102dacdd73f6b014e710b51e8022af9a1968",
  "0xffd70157e48063fc33c97a050f7f640233bf646cc98d9524c6b92bcf3ab56f83",
  "0x9867cc5f7f196b93bae1e27e6320742445d290f2263827498b54fec539f756af",
  "0xcefad4e508c098b9a7e1d8feb19955fb02ba9675585078710969d3440f5054e0",
  "0xf9dc3e7fe016e050eff260334f18a5d4fe391d82092319f5964f2e2eb7c1c3a5",
  "0xf8b13a49e282f609c317a833fb8d976d11517c571d1221a265d25af778ecf892",
  "0x3490c6ceeb450aecdc82e28293031d10c7d73bf85e57bf041a97360aa2c5d99c",
  "0xc1df82d9c4b87413eae2ef048f94b4d3554cea73d92b0f7af96e0271c691e2bb",
  "0x5c67add7c6caf302256adedf7ab114da0acfe870d449a3a489f781d659e8becc",
  "0xda7bce9f4e8618b6bd2f4132ce798cdc7a60e7e1460a7299e3c6342a579626d2",
  "0x2733e50f526ec2fa19a22b31e8ed50f23cd1fdf94c9154ed3a7609a2f1ff981f",
  "0xe1d3b5c807b281e4683cc6d6315cf95b9ade8641defcb32372f1c126e398ef7a",
  "0x5a2dce0a8a7f68bb74560f8f71837c2c2ebbcbf7fffb42ae1896f13f7c7479a0",
  "0xb46a28b6f55540f89444f63de0378e3d121be09e06cc9ded1c20e65876d36aa0",
  "0xc65e9645644786b620e2dd2ad648ddfcbf4a7e5b1a3a4ecfe7f64667a3f0b7e2",
  "0xf4418588ed35a2458cffeb39b93d26f18d2ab13bdce6aee58e7b99359ec2dfd9",
  "0x5a9c16dc00d6ef18b7933a6f8dc65ccb55667138776f7dea101070dc8796e377",
  "0x4df84f40ae0c8229d0d6069e5c8f39a7c299677a09d367fc7b05e3bc380ee652",
  "0xcdc72595f74c7b1043d0e1ffbab734648c838dfb0527d971b602bc216c9619ef",
  "0x0abf5ac974a1ed57f4050aa510dd9c74f508277b39d7973bb2dfccc5eeb0618d",
  "0xb8cd74046ff337f0a7bf2c8e03e10f642c1886798d71806ab1e888d9e5ee87d0",
  "0x838c5655cb21c6cb83313b5a631175dff4963772cce9108188b34ac87c81c41e",
  "0x662ee4dd2dd7b2bc707961b1e646c4047669dcb6584f0d8d770daf5d7e7deb2e",
  "0x388ab20e2573d171a88108e79d820e98f26c0b84aa8b2f4aa4968dbb818ea322",
  "0x93237c50ba75ee485f4c22adf2f741400bdf8d6a9cc7df7ecae576221665d735",
  "0x8448818bb4ae4562849e949e17ac16e0be16688e156b5cf15e098c627c0056a9",
];

function parseCli(argv: string[]): CliOpts {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    const v = argv[i + 1];
    if (!v || v.startsWith("--")) throw new Error(`Missing value for ${k}`);
    map.set(k, v);
    i++;
  }
  const configPath = map.get("--config");
  const shared = loadSharedConfigOrFallback(configPath);
  const bundleDir = map.get("--bundle-dir");
  let exitDataFile = map.get("--exit-data-file");
  let treeDataFile = map.get("--tree-data-file");
  let treeSnapshotFile = map.get("--tree-snapshot-file");
  const previousCheckpointFile = map.get("--previous-checkpoint-file");
  const cliPublicKey = map.get("--manifest-signing-public-key");
  const envPublicKey = process.env[ENV_SIGNING_PUBLIC_KEY];
  const configPublicKey = shared?.config.kasExitBridge.signing.publicKeyPath;
  const defaultPublicKey = normalizePath(DEFAULT_SIGNING_PUBLIC_KEY);
  const manifestSigningPublicKey =
    normalizePathMaybe(cliPublicKey) ??
    normalizePathMaybe(envPublicKey) ??
    normalizePathMaybeWithConfig(shared, configPublicKey) ??
    defaultPublicKey;

  if (bundleDir) {
    exitDataFile = exitDataFile ?? join(bundleDir, "derived", "exit.data.json");
    treeDataFile = treeDataFile ?? join(bundleDir, "derived", "tree.data.json");
  }
  if (!exitDataFile) throw new Error("Required: --exit-data-file <path> (or --bundle-dir <path>)");
  if (!treeDataFile) throw new Error("Required: --tree-data-file <path> (or --bundle-dir <path>)");
  return {
    configPath,
    bundleDir,
    exitDataFile,
    treeDataFile,
    treeSnapshotFile,
    previousCheckpointFile,
    manifestSigningPublicKey,
    outChecksFile: map.get("--out-checks"),
  };
}

function loadSharedConfigOrFallback(configPath?: string) {
  const explicit = configPath ?? process.env[ENV_KEB_CONFIG_PATH];
  try {
    return loadKebSharedConfigWithPath(configPath);
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

function normalizePathMaybeWithConfig(
  shared: { configPath: string } | undefined,
  pathValue: string | undefined,
): string | undefined {
  if (!pathValue) return undefined;
  if (!shared) return normalizePath(pathValue);
  return resolvePathFromConfig(pathValue, shared.configPath);
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
}

function toReportPath(path: string): string {
  const rel = relative(process.cwd(), resolve(path));
  return rel === "" ? "." : rel;
}

function sha256Utf8(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

function canonicalizeJson(value: unknown): string {
  if (value === null) return "null";
  const t = typeof value;
  if (t === "string" || t === "number" || t === "boolean") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map((v) => canonicalizeJson(v)).join(",")}]`;
  if (t === "object") {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort((a, b) => a.localeCompare(b));
    return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalizeJson(obj[k])}`).join(",")}}`;
  }
  throw new Error(`Unsupported value for canonical JSON: ${String(value)}`);
}

function toManifestIntegralPayload(manifest: BundleManifest): Record<string, unknown> {
  const clone = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
  delete clone.signature;
  const bundleIntegral = (clone.bundleIntegral ?? {}) as Record<string, unknown>;
  delete bundleIntegral.value;
  clone.bundleIntegral = bundleIntegral;
  return clone;
}

function toManifestIdentityPayload(manifest: BundleManifest): Record<string, unknown> {
  const clone = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
  const payloadVersion = Number(manifest.bundleIdentity?.payloadVersion ?? 1) || 1;
  delete clone.signature;
  delete clone.files;
  delete clone.createdAt;
  if (payloadVersion >= 2) {
    delete clone.artifactChecksums;
  }
  const context = (clone.context ?? {}) as Record<string, unknown>;
  delete context.rpcUrl;
  clone.context = context;
  const bundleIntegral = (clone.bundleIntegral ?? {}) as Record<string, unknown>;
  delete bundleIntegral.value;
  clone.bundleIntegral = bundleIntegral;
  const bundleIdentity = (clone.bundleIdentity ?? {}) as Record<string, unknown>;
  delete bundleIdentity.value;
  clone.bundleIdentity = bundleIdentity;
  return clone;
}

function verifyBundleManifest(bundleDir: string, manifestSigningPublicKey?: string): {
  checked: boolean;
  manifestPath: string;
  fileCount: number;
  signatureVerified: boolean;
  errors: string[];
  keyId?: string;
} {
  const manifestPath = resolve(join(bundleDir, "manifest.json"));
  const manifestReportPath = toReportPath(manifestPath);
  if (!existsSync(manifestPath)) {
    return {
      checked: false,
      manifestPath: manifestReportPath,
      fileCount: 0,
      signatureVerified: false,
      errors: [`Missing bundle manifest: ${manifestReportPath}`],
    };
  }
  const raw = readJson(manifestPath) as BundleManifest;
  if (raw?.kind !== "kas-exit-bridge-pass-a-bundle") {
    return {
      checked: false,
      manifestPath: manifestReportPath,
      fileCount: 0,
      signatureVerified: false,
      errors: [`Invalid manifest kind: ${String(raw?.kind ?? "")}`],
    };
  }
  if (!Array.isArray(raw.files)) {
    return {
      checked: false,
      manifestPath: manifestReportPath,
      fileCount: 0,
      signatureVerified: false,
      errors: ["Invalid manifest: files[] missing"],
    };
  }

  const errors: string[] = [];
  const sig = raw.signature;
  const integral = raw.bundleIntegral;
  const identity = raw.bundleIdentity;
  const artifacts = raw.artifactChecksums;
  if (!integral || integral.algorithm !== "sha256") {
    errors.push("Manifest missing bundleIntegral.algorithm=sha256");
  }
  if (!integral || integral.canonicalization !== BUNDLE_INTEGRAL_CANONICALIZATION) {
    errors.push(
      `Manifest canonicalization mismatch: expected=${BUNDLE_INTEGRAL_CANONICALIZATION}`,
    );
  }
  if (!integral?.value || !/^[0-9a-f]{64}$/.test(String(integral.value))) {
    errors.push("Manifest missing valid bundleIntegral.value (64-char lowercase hex)");
  }
  if (identity) {
    if (identity.algorithm !== "sha256") {
      errors.push("Manifest bundleIdentity.algorithm must be sha256");
    }
    if (identity.canonicalization !== BUNDLE_IDENTITY_CANONICALIZATION) {
      errors.push(
        `Manifest bundleIdentity canonicalization mismatch: expected=${BUNDLE_IDENTITY_CANONICALIZATION}`,
      );
    }
    if (identity.payloadVersion !== 1 && identity.payloadVersion !== 2) {
      errors.push("Manifest bundleIdentity.payloadVersion must be 1 or 2");
    }
    if (!identity.value || !/^[0-9a-f]{64}$/.test(String(identity.value))) {
      errors.push("Manifest bundleIdentity.value must be 64-char lowercase hex");
    }
  }
  if (!artifacts) {
    errors.push("Manifest missing artifactChecksums");
  } else {
    const requiredArtifactKeys = [
      "exitDataSha256",
      "checksSha256",
      "treeDataSha256",
      "checkpointEndSha256",
      "contractPreVerificationSha256",
    ] as const;
    for (const key of requiredArtifactKeys) {
      const v = artifacts[key];
      if (typeof v !== "string" || !/^[0-9a-f]{64}$/.test(v)) {
        errors.push(`Manifest missing/invalid artifactChecksums.${key}`);
      }
    }
  }
  const fileHashByPath = new Map<string, string>();
  for (const f of raw.files) {
    const rel = String(f.path ?? "");
    const abs = resolve(join(bundleDir, rel));
    if (!existsSync(abs)) {
      errors.push(`Manifest file missing: ${rel}`);
      continue;
    }
    const content = readFileSync(abs, "utf8");
    const hash = sha256Utf8(content);
    fileHashByPath.set(rel, hash);
    const size = Buffer.byteLength(content, "utf8");
    const expectedHash = String(f.sha256 ?? "").toLowerCase();
    if (hash !== expectedHash) {
      errors.push(`Manifest hash mismatch: ${rel} expected=${expectedHash} actual=${hash}`);
    }
    if (size !== Number(f.size)) {
      errors.push(`Manifest size mismatch: ${rel} expected=${f.size} actual=${size}`);
    }
  }
  const expectedDerivedChecks: Array<{ path: string; key: keyof NonNullable<BundleManifest["artifactChecksums"]> }> = [
    { path: "derived/exit.data.json", key: "exitDataSha256" },
    { path: "derived/checks.json", key: "checksSha256" },
    { path: "derived/tree.data.json", key: "treeDataSha256" },
    { path: "derived/checkpoint.end.json", key: "checkpointEndSha256" },
    { path: "derived/contract.preverify.json", key: "contractPreVerificationSha256" },
  ];
  if (artifacts) {
    for (const target of expectedDerivedChecks) {
      const actual = fileHashByPath.get(target.path);
      const expected = String(artifacts[target.key] ?? "").toLowerCase();
      if (!actual) {
        errors.push(`Missing manifest file entry for required artifact: ${target.path}`);
        continue;
      }
      if (actual !== expected) {
        errors.push(
          `Artifact checksum mismatch: ${target.path} expected=${expected} actual=${actual}`,
        );
      }
    }
  }
  const payload = canonicalizeJson(toManifestIntegralPayload(raw));
  const payloadHash = sha256Utf8(payload);
  if (integral?.value && payloadHash !== String(integral.value).toLowerCase()) {
    errors.push(
      `Manifest integral mismatch: expected=${String(integral.value).toLowerCase()} actual=${payloadHash}`,
    );
  }
  if (identity?.value) {
    const identityPayload = canonicalizeJson(toManifestIdentityPayload(raw));
    const identityHash = sha256Utf8(identityPayload);
    if (identityHash !== String(identity.value).toLowerCase()) {
      errors.push(
        `Manifest bundleIdentity mismatch: expected=${String(identity.value).toLowerCase()} actual=${identityHash}`,
      );
    }
  }

  let signatureVerified = false;
  const publicKeyPath = manifestSigningPublicKey
    ? resolve(manifestSigningPublicKey)
    : undefined;
  if (!publicKeyPath) {
    errors.push("Missing required --manifest-signing-public-key for strict manifest verification");
  } else if (!existsSync(publicKeyPath)) {
    errors.push(`Manifest signing public key not found: ${publicKeyPath}`);
  }
  if (!sig) {
    errors.push("Manifest missing signature block");
  } else {
    if (sig.algorithm !== "sha256-sign") {
      errors.push(`Unsupported manifest signature algorithm: ${String(sig.algorithm)}`);
    }
    if (sig.signatureEncoding !== "base64") {
      errors.push(`Unsupported manifest signature encoding: ${String(sig.signatureEncoding)}`);
    }
    if (!sig.signatureFile || typeof sig.signatureFile !== "string") {
      errors.push("Manifest missing signature.signatureFile");
    }
    if (publicKeyPath && sig.signatureFile) {
      const signaturePath = resolve(join(bundleDir, sig.signatureFile));
      if (!existsSync(signaturePath)) {
        errors.push(`Manifest signature file missing: ${toReportPath(signaturePath)}`);
      } else {
        try {
          const signatureBase64 = readFileSync(signaturePath, "utf8").trim();
          const signatureBin = Buffer.from(signatureBase64, "base64");
          const publicKey = createPublicKey(readFileSync(publicKeyPath, "utf8"));
          signatureVerified = cryptoVerify(
            "sha256",
            Buffer.from(payload, "utf8"),
            publicKey,
            signatureBin,
          );
          if (!signatureVerified) {
            errors.push("Manifest signature verification failed");
          }
        } catch (err) {
          const msg = err instanceof Error ? err.message : String(err);
          errors.push(`Manifest signature verification error: ${msg}`);
        }
      }
    }
  }

  return {
    checked: true,
    manifestPath: manifestReportPath,
    fileCount: raw.files.length,
    signatureVerified,
    errors,
    keyId: sig?.keyId,
  };
}

function normBytes32(v: string, field: string): string {
  if (!/^0x[0-9a-fA-F]{64}$/.test(v)) throw new Error(`Invalid ${field}: expected bytes32`);
  return v.toLowerCase();
}

function parseSnapshot(raw: any): TreeSnapshot {
  if (!raw || typeof raw !== "object") throw new Error("Invalid snapshot: object expected");
  if (!Array.isArray(raw.branch) || raw.branch.length !== HYPERLANE_TREE_DEPTH) {
    throw new Error(`Invalid snapshot.branch length: expected ${HYPERLANE_TREE_DEPTH}`);
  }
  if (raw.treeDepth !== undefined && raw.treeDepth !== HYPERLANE_TREE_DEPTH) {
    throw new Error(`Invalid snapshot.treeDepth: expected ${HYPERLANE_TREE_DEPTH}`);
  }
  return {
    blockNum: Number(raw.blockNum),
    count: BigInt(String(raw.count)),
    root: normBytes32(String(raw.root), "snapshot.root"),
    branch: raw.branch.map((x: unknown, i: number) =>
      normBytes32(String(x), `snapshot.branch[${i}]`),
    ),
    treeDepth: raw.treeDepth,
  };
}

function parseKebCheckpoint(raw: any, pathPrefix: string): KebCheckpoint {
  if (!raw || typeof raw !== "object") {
    throw new Error(`Invalid ${pathPrefix}: object expected`);
  }
  const blockTag = Number(raw.blockTag);
  const nextExitRequestId = BigInt(String(raw.nextExitRequestId));
  const totalBurnedWei = BigInt(String(raw.totalBurnedWei));
  if (!Number.isInteger(blockTag) || blockTag < 0) {
    throw new Error(`Invalid ${pathPrefix}.blockTag`);
  }
  if (nextExitRequestId < 0n) {
    throw new Error(`Invalid ${pathPrefix}.nextExitRequestId`);
  }
  if (totalBurnedWei < 0n) {
    throw new Error(`Invalid ${pathPrefix}.totalBurnedWei`);
  }
  return { blockTag, nextExitRequestId, totalBurnedWei };
}

function parseDeltaAnchorCheckpoint(raw: any): DeltaAnchorCheckpoint {
  if (!raw || typeof raw !== "object") {
    throw new Error("Invalid previous checkpoint file: object expected");
  }
  const mRootObj = (raw.merkleTreeHook ?? raw?.checkpoints?.merkleTreeHook ?? {}) as any;
  const kRootObj = (raw.kasExitBridge ?? raw?.checkpoints?.kasExitBridge ?? {}) as any;
  const mObj = (mRootObj.end ?? mRootObj) as any;
  const kObj = (kRootObj.end ?? kRootObj) as any;
  const blockTag = Number(mObj.blockTag ?? raw?.blockTag);
  if (!Number.isInteger(blockTag) || blockTag < 0) {
    throw new Error("Invalid previousCheckpoint.blockTag");
  }
  return {
    blockTag,
    merkleTreeHook: {
      root: normBytes32(String(mObj.root), "previousCheckpoint.merkleTreeHook.root"),
      count: BigInt(String(mObj.count)),
    },
    kasExitBridge: {
      nextExitRequestId: BigInt(String(kObj.nextExitRequestId)),
      totalBurnedWei: BigInt(String(kObj.totalBurnedWei)),
    },
  };
}

function merkleInsert(state: { branch: string[]; count: bigint }, leaf: string) {
  if (state.count >= HYPERLANE_MAX_LEAVES) throw new Error("Merkle tree full");
  let node = normBytes32(leaf, "leaf");
  state.count += 1n;
  let size = state.count;
  for (let i = 0; i < HYPERLANE_TREE_DEPTH; i++) {
    if ((size & 1n) === 1n) {
      state.branch[i] = node;
      return;
    }
    node = ethers.keccak256(ethers.concat([state.branch[i], node])).toLowerCase();
    size >>= 1n;
  }
  throw new Error("Unreachable insert state");
}

function merkleRoot(state: { branch: string[]; count: bigint }): string {
  let current = ZERO_ROOT;
  for (let i = 0; i < HYPERLANE_TREE_DEPTH; i++) {
    const bit = (state.count >> BigInt(i)) & 1n;
    const b = normBytes32(state.branch[i], `branch[${i}]`);
    current =
      bit === 1n
        ? ethers.keccak256(ethers.concat([b, current]))
        : ethers.keccak256(ethers.concat([current, HYPERLANE_ZERO_HASHES[i]]));
  }
  return current.toLowerCase();
}

async function main() {
  const opts = parseCli(process.argv.slice(2));
  const startedAt = new Date().toISOString();
  const manifestCheck = opts.bundleDir
    ? verifyBundleManifest(opts.bundleDir, opts.manifestSigningPublicKey)
    : null;
  const exitData = readJson(opts.exitDataFile);
  const treeData = readJson(opts.treeDataFile);

  const errors: string[] = [];
  if (manifestCheck) errors.push(...manifestCheck.errors);
  const exits: ExitRecord[] = Array.isArray(exitData.exits) ? exitData.exits : [];
  const events: TreeEvent[] = Array.isArray(treeData.events) ? treeData.events : [];

  const start = treeData?.metadata?.checkpoints?.start;
  const end = treeData?.metadata?.checkpoints?.end;
  if (!start || !end) throw new Error("tree-data missing checkpoints");

  const startCount = BigInt(String(start.count));
  const endCount = BigInt(String(end.count));
  const startRoot = normBytes32(String(start.root), "tree.start.root");
  const endRoot = normBytes32(String(end.root), "tree.end.root");
  const startBlock = Number(start.blockTag);
  const endBlock = Number(end.blockTag);

  const eventList = events.map((e, i) => ({
    txHash: String(e.txHash).toLowerCase(),
    messageId: normBytes32(String(e.messageId), `events[${i}].messageId`),
    index: BigInt(Number(e.index)),
  }));
  const sorted = eventList.slice().sort((a, b) => (a.index < b.index ? -1 : a.index > b.index ? 1 : a.txHash.localeCompare(b.txHash)));

  const seenIds = new Set<string>();
  const seenIdx = new Set<string>();
  let noDuplicateMessageIds = true;
  let noDuplicateLeafIndices = true;
  for (const e of sorted) {
    if (seenIds.has(e.messageId)) noDuplicateMessageIds = false;
    seenIds.add(e.messageId);
    const k = e.index.toString();
    if (seenIdx.has(k)) noDuplicateLeafIndices = false;
    seenIdx.add(k);
  }
  if (!noDuplicateMessageIds) errors.push("Duplicate messageId in tree events");
  if (!noDuplicateLeafIndices) errors.push("Duplicate index in tree events");

  const expectedEventCount = endCount - startCount;
  const countDeltaMatchesInsertedEvents = expectedEventCount === BigInt(sorted.length);
  if (!countDeltaMatchesInsertedEvents) {
    errors.push(`Count delta mismatch: end-start=${expectedEventCount} events=${sorted.length}`);
  }

  let noLeafIndexGaps = true;
  for (let i = 0; i < sorted.length; i++) {
    const expected = startCount + BigInt(i);
    if (sorted[i].index !== expected) {
      noLeafIndexGaps = false;
      break;
    }
  }
  if (!noLeafIndexGaps) errors.push("Leaf index gaps detected");

  const successfulExits = exits.filter((e) => e.status === "success");
  const successfulDecoded = successfulExits.filter((e) => e.dispatchMessageDecoded !== null);

  const kebCheckpointRoot = exitData?.metadata?.checkpoints?.kasExitBridge;
  let kebStartCheckpoint: KebCheckpoint | null = null;
  let kebEndCheckpoint: KebCheckpoint | null = null;
  if (!kebCheckpointRoot) {
    errors.push("Missing exit-data.metadata.checkpoints.kasExitBridge");
  } else {
    kebStartCheckpoint = parseKebCheckpoint(
      kebCheckpointRoot.start,
      "exitData.metadata.checkpoints.kasExitBridge.start",
    );
    kebEndCheckpoint = parseKebCheckpoint(
      kebCheckpointRoot.end,
      "exitData.metadata.checkpoints.kasExitBridge.end",
    );
    if (kebEndCheckpoint.nextExitRequestId < kebStartCheckpoint.nextExitRequestId) {
      errors.push(
        `KEB requestId checkpoint regression: end(${kebEndCheckpoint.nextExitRequestId}) < start(${kebStartCheckpoint.nextExitRequestId})`,
      );
    }
    if (kebEndCheckpoint.totalBurnedWei < kebStartCheckpoint.totalBurnedWei) {
      errors.push(
        `KEB totalBurned checkpoint regression: end(${kebEndCheckpoint.totalBurnedWei}) < start(${kebStartCheckpoint.totalBurnedWei})`,
      );
    }
    if (kebStartCheckpoint.blockTag !== startBlock) {
      errors.push(
        `KEB checkpoint start block mismatch: ${kebStartCheckpoint.blockTag} != tree.start.blockTag ${startBlock}`,
      );
    }
    if (kebEndCheckpoint.blockTag !== endBlock) {
      errors.push(
        `KEB checkpoint end block mismatch: ${kebEndCheckpoint.blockTag} != tree.end.blockTag ${endBlock}`,
      );
    }
  }

  if (opts.previousCheckpointFile) {
    const prev = parseDeltaAnchorCheckpoint(readJson(opts.previousCheckpointFile));
    if (prev.blockTag !== startBlock) {
      errors.push(
        `Previous checkpoint block mismatch: prev.blockTag=${prev.blockTag} expectedStartBlock=${startBlock}`,
      );
    }
    if (prev.merkleTreeHook.root !== startRoot) {
      errors.push(
        `Previous checkpoint merkle root mismatch: prev=${prev.merkleTreeHook.root} start=${startRoot}`,
      );
    }
    if (prev.merkleTreeHook.count !== startCount) {
      errors.push(
        `Previous checkpoint merkle count mismatch: prev=${prev.merkleTreeHook.count} start=${startCount}`,
      );
    }
    if (kebStartCheckpoint) {
      if (prev.kasExitBridge.nextExitRequestId !== kebStartCheckpoint.nextExitRequestId) {
        errors.push(
          `Previous checkpoint KEB requestId mismatch: prev=${prev.kasExitBridge.nextExitRequestId} start=${kebStartCheckpoint.nextExitRequestId}`,
        );
      }
      if (prev.kasExitBridge.totalBurnedWei !== kebStartCheckpoint.totalBurnedWei) {
        errors.push(
          `Previous checkpoint KEB totalBurned mismatch: prev=${prev.kasExitBridge.totalBurnedWei} start=${kebStartCheckpoint.totalBurnedWei}`,
        );
      }
    }
  }

  let dispatchRequestIdIncrementalNoGaps = true;
  let dispatchRequestIdRangeMatchesCheckpoints = true;
  let dispatchOuterConstantFieldsExceptNonce = true;
  let requestIdDeltaMatchesSuccessfulExits = true;
  let totalBurnedDeltaMatchesSuccessfulBurns = true;

  const decodedReqIds = successfulDecoded
    .map((e) => e.dispatchMessageDecoded!.body.requestId)
    .slice()
    .sort((a, b) => a - b);
  for (let i = 1; i < decodedReqIds.length; i++) {
    if (decodedReqIds[i] !== decodedReqIds[i - 1] + 1) {
      dispatchRequestIdIncrementalNoGaps = false;
      break;
    }
  }
  if (!dispatchRequestIdIncrementalNoGaps) {
    errors.push("Dispatch.message.body.requestId is not strictly incremental by one without gaps");
  }

  if (successfulDecoded.length > 0) {
    const base = successfulDecoded[0].dispatchMessageDecoded!.outer;
    for (let i = 1; i < successfulDecoded.length; i++) {
      const cur = successfulDecoded[i].dispatchMessageDecoded!.outer;
      if (
        cur.version !== base.version ||
        cur.originDomain !== base.originDomain ||
        cur.sender.toLowerCase() !== base.sender.toLowerCase() ||
        cur.destinationDomain !== base.destinationDomain ||
        cur.recipient.toLowerCase() !== base.recipient.toLowerCase()
      ) {
        dispatchOuterConstantFieldsExceptNonce = false;
        break;
      }
    }
  }
  if (!dispatchOuterConstantFieldsExceptNonce) {
    errors.push("Dispatch outer envelope fields (except nonce) are not constant across KEB messages");
  }

  const totalBurnFromSuccessful = successfulExits.reduce(
    (acc, e) => acc + BigInt(e.burnWei),
    0n,
  );
  const totalUnlockSompiFromSuccessful = successfulExits.reduce(
    (acc, e) => acc + BigInt(e.unlockAmountSompi),
    0n,
  );
  if (totalBurnFromSuccessful !== totalUnlockSompiFromSuccessful * SOMPI_SCALE) {
    errors.push(
      `Successful exits burn/unlock mismatch: burnWei=${totalBurnFromSuccessful} unlockSompiScaled=${totalUnlockSompiFromSuccessful * SOMPI_SCALE}`,
    );
  }

  if (kebStartCheckpoint && kebEndCheckpoint) {
    const requestIdDelta = kebEndCheckpoint.nextExitRequestId - kebStartCheckpoint.nextExitRequestId;
    const totalBurnDelta = kebEndCheckpoint.totalBurnedWei - kebStartCheckpoint.totalBurnedWei;
    requestIdDeltaMatchesSuccessfulExits = requestIdDelta === BigInt(successfulExits.length);
    totalBurnedDeltaMatchesSuccessfulBurns = totalBurnDelta === totalBurnFromSuccessful;
    if (!requestIdDeltaMatchesSuccessfulExits) {
      errors.push(
        `KEB requestId delta mismatch: end-start=${requestIdDelta} successfulExits=${successfulExits.length}`,
      );
    }
    if (!totalBurnedDeltaMatchesSuccessfulBurns) {
      errors.push(
        `KEB totalBurned delta mismatch: end-start=${totalBurnDelta} successfulBurnWei=${totalBurnFromSuccessful}`,
      );
    }

    if (successfulDecoded.length > 0) {
      const firstReqId = BigInt(decodedReqIds[0]);
      const lastReqId = BigInt(decodedReqIds[decodedReqIds.length - 1]);
      dispatchRequestIdRangeMatchesCheckpoints =
        firstReqId === kebStartCheckpoint.nextExitRequestId &&
        lastReqId + 1n === kebEndCheckpoint.nextExitRequestId;
      if (!dispatchRequestIdRangeMatchesCheckpoints) {
        errors.push(
          `Dispatch requestId range mismatch with checkpoints: first=${firstReqId} last=${lastReqId} start.next=${kebStartCheckpoint.nextExitRequestId} end.next=${kebEndCheckpoint.nextExitRequestId}`,
        );
      }
    }
  }
  let allSuccessfulExitInsertedEventsPresentAndMatching = true;
  for (const e of successfulExits) {
    if (!e.messageId || e.insertedIntoTreeIndex === null) {
      allSuccessfulExitInsertedEventsPresentAndMatching = false;
      break;
    }
    const msg = normBytes32(e.messageId, `exit:${e.txHash}:messageId`);
    const idx = BigInt(e.insertedIntoTreeIndex);
    const tx = e.txHash.toLowerCase();
    const ok = sorted.some((x) => x.txHash === tx && x.index === idx && x.messageId === msg);
    if (!ok) {
      allSuccessfulExitInsertedEventsPresentAndMatching = false;
      break;
    }
  }
  if (!allSuccessfulExitInsertedEventsPresentAndMatching) {
    errors.push("Not all successful exits matched a tree event (txHash,messageId,index)");
  }

  let messageIdKeccakDispatchMessageFailures = 0;
  for (const e of successfulExits) {
    if (!e.dispatchMessage || !e.messageId) {
      messageIdKeccakDispatchMessageFailures += 1;
      continue;
    }
    const k = ethers.keccak256(e.dispatchMessage).toLowerCase();
    if (k !== e.messageId.toLowerCase()) messageIdKeccakDispatchMessageFailures += 1;
  }

  let rootReplayEnabled = false;
  let rootReplayMatch: boolean | undefined;
  let computedEndRoot: string | undefined;
  let snapshotRootComputed: string | undefined;
  if (opts.treeSnapshotFile) {
    rootReplayEnabled = true;
    const snap = parseSnapshot(readJson(opts.treeSnapshotFile));
    if (snap.blockNum !== startBlock) errors.push(`Snapshot block mismatch: ${snap.blockNum} != ${startBlock}`);
    if (snap.count !== startCount) errors.push(`Snapshot count mismatch: ${snap.count} != ${startCount}`);
    if (snap.root !== startRoot) errors.push(`Snapshot root mismatch: ${snap.root} != ${startRoot}`);
    snapshotRootComputed = merkleRoot({ branch: snap.branch.slice(), count: snap.count });
    if (snapshotRootComputed !== snap.root) {
      errors.push(`Snapshot recomputed root mismatch: ${snapshotRootComputed} != ${snap.root}`);
    }

    const state = { branch: snap.branch.slice(), count: snap.count };
    for (const ev of sorted) merkleInsert(state, ev.messageId);
    computedEndRoot = merkleRoot(state);
    rootReplayMatch = computedEndRoot === endRoot;
    if (!rootReplayMatch) {
      errors.push(`Replay end root mismatch: ${computedEndRoot} != ${endRoot}`);
    }
  }

  const out = {
    metadata: {
      mode: "verify-only",
      startedAt,
      generatedAt: new Date().toISOString(),
      inputs: {
        bundleDir: opts.bundleDir ? toReportPath(opts.bundleDir) : undefined,
        exitDataFile: toReportPath(opts.exitDataFile),
        treeDataFile: toReportPath(opts.treeDataFile),
        treeSnapshotFile: opts.treeSnapshotFile ? toReportPath(opts.treeSnapshotFile) : undefined,
        previousCheckpointFile: opts.previousCheckpointFile
          ? toReportPath(opts.previousCheckpointFile)
          : undefined,
        manifestSigningPublicKey: opts.manifestSigningPublicKey
          ? toReportPath(opts.manifestSigningPublicKey)
          : undefined,
      },
      bundleManifest: manifestCheck
        ? {
            checked: manifestCheck.checked,
            path: manifestCheck.manifestPath,
            fileCount: manifestCheck.fileCount,
            signatureVerified: manifestCheck.signatureVerified,
            keyId: manifestCheck.keyId,
            errorCount: manifestCheck.errors.length,
          }
        : undefined,
      range: { fromBlock: startBlock + 1, toBlock: endBlock, startCheckpointBlock: startBlock },
      checkpoints: {
        start: { blockTag: startBlock, root: startRoot, count: startCount.toString() },
        end: { blockTag: endBlock, root: endRoot, count: endCount.toString() },
        kasExitBridge:
          kebStartCheckpoint && kebEndCheckpoint
            ? {
                start: {
                  blockTag: kebStartCheckpoint.blockTag,
                  nextExitRequestId: kebStartCheckpoint.nextExitRequestId.toString(),
                  totalBurnedWei: kebStartCheckpoint.totalBurnedWei.toString(),
                },
                end: {
                  blockTag: kebEndCheckpoint.blockTag,
                  nextExitRequestId: kebEndCheckpoint.nextExitRequestId.toString(),
                  totalBurnedWei: kebEndCheckpoint.totalBurnedWei.toString(),
                },
              }
            : undefined,
      },
    },
    totals: {
      exitTransactions: exits.length,
      successfulExitTransactions: successfulExits.length,
      insertedIntoTreeEvents: sorted.length,
    },
    checks: {
      countDeltaMatchesInsertedEvents,
      noDuplicateMessageIds,
      noDuplicateLeafIndices,
      noLeafIndexGaps,
      dispatchRequestIdIncrementalNoGaps,
      dispatchRequestIdRangeMatchesCheckpoints,
      dispatchOuterConstantFieldsExceptNonce,
      requestIdDeltaMatchesSuccessfulExits,
      totalBurnedDeltaMatchesSuccessfulBurns,
      allSuccessfulExitInsertedEventsPresentAndMatching,
      messageIdKeccakDispatchMessageFailures,
      rootReplay: {
        enabled: rootReplayEnabled,
        snapshotRootComputed,
        computedEndRoot,
        match: rootReplayMatch,
      },
    },
    errors,
  };

  const outPath = resolve(
    opts.outChecksFile ??
      (opts.bundleDir ? join(opts.bundleDir, "derived", "verify.checks.json") : undefined) ??
      opts.treeDataFile.replace(/\.tree\.data\.json$/i, ".verify.checks.json"),
  );
  const outReportPath = toReportPath(outPath);
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, JSON.stringify(out, null, 2) + "\n", "utf8");
  console.log(`Wrote verify checks JSON: ${outReportPath}`);
  if (errors.length > 0) {
    console.log(`Verification completed with ${errors.length} error(s).`);
    process.exit(1);
  }
  console.log("Verification completed successfully.");
}

main().catch((err) => {
  console.error(`Error: ${(err as Error).message}`);
  process.exit(1);
});
