import { createHash, createPublicKey, verify as cryptoVerify } from "crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "fs";
import { dirname, join, resolve } from "path";
import {
  evaluateSignerSetAgainstPolicy,
  loadKebSignerRegistry,
  loadKebSigningPolicy,
  resolveKebSigningPolicy,
} from "./signingPolicy";

type CliOpts = {
  configPath?: string;
  bundleDirs: string[];
  reportOut?: string;
  signersFileOverride?: string;
  signingPolicyFileOverride?: string;
};

type BundleManifest = {
  kind?: string;
  bundleIdentity?: {
    algorithm?: string;
    canonicalization?: string;
    payloadVersion?: number;
    value?: string;
  };
  bundleIntegral?: {
    algorithm?: string;
    canonicalization?: string;
    value?: string;
  };
  signature?: {
    algorithm?: string;
    keyType?: string;
    keyId?: string;
    signatureFile?: string;
    signatureEncoding?: string;
  };
  files?: Array<{
    path?: string;
    sha256?: string;
    size?: number;
  }>;
  [k: string]: unknown;
};

type BundleCheck = {
  bundleDir: string;
  manifestPath: string;
  ok: boolean;
  errors: string[];
  identity: {
    present: boolean;
    payloadVersion?: number;
    recomputed?: string;
    manifestValue?: string;
    matchesManifestValue?: boolean;
  };
  signature: {
    present: boolean;
    keyId?: string;
    verified: boolean;
    error?: string;
  };
};

type IdentityGroup = {
  identityHash: string;
  bundleDirs: string[];
  allBundlesSelfConsistent: boolean;
  allBundlesValid: boolean;
  observedSignerKeyIds: string[];
  policy: ReturnType<typeof evaluateSignerSetAgainstPolicy>;
  representativeBundleDir?: string;
};

const BUNDLE_IDENTITY_CANONICALIZATION = "json-c14n-sorted-keys-no-whitespace-utf8";
const DEFAULT_REPORT_OUT = "impl/reports/keb-bundle-match.report.json";

function parseCli(argv: string[]): CliOpts {
  const map = new Map<string, string>();
  const bundleDirs: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    if (k === "--bundle-dir") {
      const v = argv[i + 1];
      if (!v || v.startsWith("--")) throw new Error("Missing value for --bundle-dir");
      bundleDirs.push(v);
      i++;
      continue;
    }
    const v = argv[i + 1];
    if (!v || v.startsWith("--")) throw new Error(`Missing value for ${k}`);
    map.set(k, v);
    i++;
  }

  const csv = map.get("--bundle-dirs");
  if (csv) {
    for (const part of csv.split(",")) {
      const p = part.trim();
      if (p) bundleDirs.push(p);
    }
  }
  const listFile = map.get("--bundle-list-file");
  if (listFile) {
    const listPath = resolve(listFile);
    if (!existsSync(listPath)) throw new Error(`Bundle list file not found: ${listPath}`);
    const lines = readFileSync(listPath, "utf8").split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    bundleDirs.push(...lines);
  }
  if (bundleDirs.length === 0) {
    throw new Error(
      "Provide bundle inputs via --bundle-dir <path> (repeatable), --bundle-dirs <csv>, or --bundle-list-file <path>",
    );
  }

  return {
    configPath: map.get("--config"),
    bundleDirs: [...new Set(bundleDirs.map((d) => resolve(d)))],
    reportOut: map.get("--out"),
    signersFileOverride: map.get("--signers-file"),
    signingPolicyFileOverride: map.get("--signing-policy-file"),
  };
}

function readJson(path: string): any {
  return JSON.parse(readFileSync(path, "utf8"));
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

function sha256Utf8(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
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

function verifyManifestSignature(args: {
  bundleDir: string;
  manifest: BundleManifest;
  signerPublicKeyById: Map<string, string>;
}): { present: boolean; keyId?: string; verified: boolean; error?: string } {
  const sig = args.manifest.signature;
  if (!sig) {
    return { present: false, verified: false, error: "Manifest signature block missing" };
  }
  const keyId = typeof sig.keyId === "string" ? sig.keyId : undefined;
  if (!keyId) {
    return { present: true, verified: false, error: "Manifest signature.keyId missing/invalid" };
  }
  if (sig.algorithm !== "sha256-sign") {
    return { present: true, keyId, verified: false, error: `Unsupported signature algorithm: ${String(sig.algorithm)}` };
  }
  if (sig.signatureEncoding !== "base64") {
    return { present: true, keyId, verified: false, error: `Unsupported signature encoding: ${String(sig.signatureEncoding)}` };
  }
  const signatureFile = typeof sig.signatureFile === "string" ? sig.signatureFile : "";
  if (!signatureFile) {
    return { present: true, keyId, verified: false, error: "Manifest signature.signatureFile missing/invalid" };
  }
  const pubPath = args.signerPublicKeyById.get(keyId);
  if (!pubPath) {
    return { present: true, keyId, verified: false, error: `Unknown signer keyId: ${keyId}` };
  }
  const signaturePath = resolve(join(args.bundleDir, signatureFile));
  if (!existsSync(signaturePath)) {
    return { present: true, keyId, verified: false, error: `Signature file not found: ${signaturePath}` };
  }
  if (!existsSync(pubPath)) {
    return { present: true, keyId, verified: false, error: `Signer public key not found: ${pubPath}` };
  }
  try {
    const payload = canonicalizeJson(toManifestIntegralPayload(args.manifest));
    const signatureBin = Buffer.from(readFileSync(signaturePath, "utf8").trim(), "base64");
    const publicKey = createPublicKey(readFileSync(pubPath, "utf8"));
    const verified = cryptoVerify("sha256", Buffer.from(payload, "utf8"), publicKey, signatureBin);
    return {
      present: true,
      keyId,
      verified,
      error: verified ? undefined : "Manifest signature verification failed",
    };
  } catch (err) {
    return {
      present: true,
      keyId,
      verified: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

function toManifestIntegralPayload(manifest: BundleManifest): Record<string, unknown> {
  const clone = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
  delete clone.signature;
  const bundleIntegral = (clone.bundleIntegral ?? {}) as Record<string, unknown>;
  delete bundleIntegral.value;
  clone.bundleIntegral = bundleIntegral;
  return clone;
}

function checkBundle(args: {
  bundleDir: string;
  signerPublicKeyById: Map<string, string>;
}): BundleCheck {
  const manifestPath = resolve(join(args.bundleDir, "manifest.json"));
  const errors: string[] = [];
  if (!existsSync(manifestPath)) {
    return {
      bundleDir: args.bundleDir,
      manifestPath,
      ok: false,
      errors: [`Missing manifest: ${manifestPath}`],
      identity: { present: false },
      signature: { present: false, verified: false, error: "Manifest missing" },
    };
  }
  const manifest = readJson(manifestPath) as BundleManifest;
  if (manifest.kind !== "kas-exit-bridge-pass-a-bundle") {
    errors.push(`Unexpected manifest.kind: ${String(manifest.kind ?? "")}`);
  }
  const identity = manifest.bundleIdentity;
  const identityResult: BundleCheck["identity"] = {
    present: !!identity,
    payloadVersion: identity?.payloadVersion,
    recomputed: undefined,
    manifestValue: identity?.value,
    matchesManifestValue: undefined,
  };
  if (!identity) {
    errors.push("Missing bundleIdentity");
  } else {
    if (identity.algorithm !== "sha256") {
      errors.push(`bundleIdentity.algorithm must be sha256, got ${String(identity.algorithm)}`);
    }
    if (identity.canonicalization !== BUNDLE_IDENTITY_CANONICALIZATION) {
      errors.push(
        `bundleIdentity.canonicalization must be ${BUNDLE_IDENTITY_CANONICALIZATION}, got ${String(identity.canonicalization)}`,
      );
    }
    if (identity.payloadVersion !== 1 && identity.payloadVersion !== 2) {
      errors.push(`bundleIdentity.payloadVersion must be 1 or 2, got ${String(identity.payloadVersion)}`);
    }
    if (!identity.value || !/^[0-9a-f]{64}$/.test(String(identity.value))) {
      errors.push("bundleIdentity.value must be 64-char lowercase hex");
    }
    const payload = canonicalizeJson(toManifestIdentityPayload(manifest));
    const recomputed = sha256Utf8(payload);
    identityResult.recomputed = recomputed;
    if (identity.value) {
      identityResult.matchesManifestValue = recomputed === String(identity.value).toLowerCase();
      if (!identityResult.matchesManifestValue) {
        errors.push(
          `bundleIdentity mismatch: manifest=${String(identity.value).toLowerCase()} recomputed=${recomputed}`,
        );
      }
    }
  }

  const signature = verifyManifestSignature({
    bundleDir: args.bundleDir,
    manifest,
    signerPublicKeyById: args.signerPublicKeyById,
  });
  if (!signature.verified) {
    errors.push(signature.error ?? "Signature not verified");
  }

  return {
    bundleDir: args.bundleDir,
    manifestPath,
    ok: errors.length === 0,
    errors,
    identity: identityResult,
    signature,
  };
}

function pickRepresentative(bundleDirs: string[]): string {
  return [...bundleDirs].sort((a, b) => a.localeCompare(b))[0];
}

function main() {
  const opts = parseCli(process.argv.slice(2));
  const loadedRegistry = loadKebSignerRegistry(opts.configPath, opts.signersFileOverride);
  const loadedPolicy = loadKebSigningPolicy(opts.configPath, opts.signingPolicyFileOverride);
  const resolvedPolicy = resolveKebSigningPolicy(loadedRegistry.registry, loadedPolicy.signingPolicy);

  const signerPublicKeyById = new Map<string, string>();
  for (const signer of loadedRegistry.registry.signers) {
    signerPublicKeyById.set(signer.keyId, signer.publicKeyPath);
  }

  const bundleChecks = opts.bundleDirs.map((bundleDir) =>
    checkBundle({
      bundleDir,
      signerPublicKeyById,
    }),
  );

  const groupsByIdentity = new Map<string, BundleCheck[]>();
  const unmatched: BundleCheck[] = [];
  for (const check of bundleChecks) {
    if (!check.identity.recomputed) {
      unmatched.push(check);
      continue;
    }
    const arr = groupsByIdentity.get(check.identity.recomputed) ?? [];
    arr.push(check);
    groupsByIdentity.set(check.identity.recomputed, arr);
  }

  const identityGroups: IdentityGroup[] = [...groupsByIdentity.entries()]
    .map(([identityHash, checks]) => {
      const observedSignerKeyIds = checks
        .filter((c) => c.signature.verified && c.signature.keyId)
        .map((c) => c.signature.keyId!) as string[];
      const policy = evaluateSignerSetAgainstPolicy(
        observedSignerKeyIds,
        resolvedPolicy,
        loadedRegistry.registry,
      );
      const allBundlesSelfConsistent = checks.every((c) => c.identity.matchesManifestValue === true);
      const allBundlesValid = checks.every((c) => c.ok);
      const validBundleDirs = checks
        .filter((c) => c.ok)
        .map((c) => c.bundleDir);
      return {
        identityHash,
        bundleDirs: checks.map((c) => c.bundleDir).sort((a, b) => a.localeCompare(b)),
        allBundlesSelfConsistent,
        allBundlesValid,
        observedSignerKeyIds: [...new Set(observedSignerKeyIds)].sort((a, b) => a.localeCompare(b)),
        policy,
        representativeBundleDir:
          allBundlesValid && validBundleDirs.length > 0
            ? pickRepresentative(validBundleDirs)
            : undefined,
      };
    })
    .sort((a, b) => {
      if (b.bundleDirs.length !== a.bundleDirs.length) return b.bundleDirs.length - a.bundleDirs.length;
      return a.identityHash.localeCompare(b.identityHash);
    });

  const acceptableGroups = identityGroups.filter(
    (g) => g.allBundlesSelfConsistent && g.allBundlesValid && g.policy.ok,
  );
  const selectedRepresentativeBundleDir =
    acceptableGroups.length > 0
      ? acceptableGroups[0].representativeBundleDir
      : undefined;

  const report = {
    metadata: {
      generatedAt: new Date().toISOString(),
      mode: "offline",
      configPath: opts.configPath ?? "(auto)",
      signersFile: loadedRegistry.path,
      signingPolicyFile: loadedPolicy.path,
      bundleCount: opts.bundleDirs.length,
    },
    policy: {
      resolved: resolvedPolicy,
    },
    bundles: bundleChecks,
    groups: identityGroups,
    unmatchedBundles: unmatched.map((b) => b.bundleDir),
    summary: {
      groupCount: identityGroups.length,
      acceptableGroupCount: acceptableGroups.length,
      selectedRepresentativeBundleDir,
      selectedRepresentativeVerifyCommand: selectedRepresentativeBundleDir
        ? `npx ts-node scripts/kasExitBridge/verifyExits.ts --config ${opts.configPath ?? "refs/keb-config.json"} --bundle-dir ${selectedRepresentativeBundleDir}`
        : undefined,
    },
  };

  const out = resolve(opts.reportOut ?? DEFAULT_REPORT_OUT);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(report, null, 2)}\n`, "utf8");
  console.log(`Wrote bundle match report: ${out}`);
  if (selectedRepresentativeBundleDir) {
    console.log(`Selected representative bundle: ${selectedRepresentativeBundleDir}`);
  } else {
    console.log(
      "No representative bundle selected (no group passed full per-bundle validation + identity consistency + signer policy).",
    );
    process.exitCode = 1;
  }
}

main();
