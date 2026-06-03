import { existsSync, readFileSync } from "fs";
import { resolve } from "path";
import {
  loadKebSharedConfigWithPath,
  LoadedKebSharedConfig,
  resolvePathFromConfig,
} from "./config";

export type KebSignerEntry = {
  keyId: string;
  publicKeyPath: string;
  active: boolean;
};

export type KebSignerRegistry = {
  schemaVersion: 1;
  signers: KebSignerEntry[];
};

export type KebSigningPolicyMode = "any-active" | "explicit";

export type KebSigningPolicy = {
  schemaVersion: 1;
  policy: {
    allowedSignersMode: KebSigningPolicyMode;
    minSigners: number;
    allowedSigners: string[];
    requiredSigners: string[];
  };
};

export type LoadedKebSignerRegistry = {
  path: string;
  registry: KebSignerRegistry;
};

export type LoadedKebSigningPolicy = {
  path: string;
  signingPolicy: KebSigningPolicy;
};

export type ResolvedKebSigningPolicy = {
  mode: KebSigningPolicyMode;
  minSigners: number;
  requiredSignerKeyIds: string[];
  eligibleSignerKeyIds: string[];
  eligiblePublicKeysById: Record<string, string>;
};

export type KebPolicyEvaluation = {
  ok: boolean;
  minSigners: number;
  observedSignerKeyIds: string[];
  eligibleSignerKeyIds: string[];
  requiredSignerKeyIds: string[];
  distinctEligibleObservedSignerCount: number;
  missingRequiredSignerKeyIds: string[];
  unknownObservedSignerKeyIds: string[];
  inactiveObservedSignerKeyIds: string[];
  details: string[];
};

export function loadKebSignerRegistry(
  cliConfigPath?: string,
  signersPathOverride?: string,
): LoadedKebSignerRegistry {
  const shared = loadKebSharedConfigWithPath(cliConfigPath);
  const path = resolveRegistryPath(shared, signersPathOverride);
  const raw = readJsonOrThrow(path, "signer registry");
  return {
    path,
    registry: validateSignerRegistry(raw, path, shared),
  };
}

export function loadKebSigningPolicy(
  cliConfigPath?: string,
  policyPathOverride?: string,
): LoadedKebSigningPolicy {
  const shared = loadKebSharedConfigWithPath(cliConfigPath);
  const path = resolvePolicyPath(shared, policyPathOverride);
  const raw = readJsonOrThrow(path, "signing policy");
  return {
    path,
    signingPolicy: validateSigningPolicy(raw, path),
  };
}

export function resolveKebSigningPolicy(
  registry: KebSignerRegistry,
  signingPolicy: KebSigningPolicy,
): ResolvedKebSigningPolicy {
  const activeById = new Map<string, string>();
  for (const signer of registry.signers) {
    if (!signer.active) continue;
    activeById.set(signer.keyId, signer.publicKeyPath);
  }

  const mode = signingPolicy.policy.allowedSignersMode;
  const allowed = signingPolicy.policy.allowedSigners;
  const required = signingPolicy.policy.requiredSigners;

  const eligible = resolveEligibleSigners(mode, allowed, activeById);
  if (eligible.length === 0) {
    throw new Error("Resolved signer set is empty; policy is unsatisfiable");
  }
  for (const keyId of required) {
    if (!activeById.has(keyId)) {
      throw new Error(`Policy required signer is not active in registry: ${keyId}`);
    }
    if (!eligible.includes(keyId)) {
      throw new Error(`Policy required signer is not eligible under allowedSigners policy: ${keyId}`);
    }
  }

  if (signingPolicy.policy.minSigners > eligible.length) {
    throw new Error(
      `Policy minSigners=${signingPolicy.policy.minSigners} exceeds eligible signer count=${eligible.length}`,
    );
  }

  const minSigners = Math.max(signingPolicy.policy.minSigners, required.length);
  const eligiblePublicKeysById: Record<string, string> = {};
  for (const keyId of eligible) {
    eligiblePublicKeysById[keyId] = activeById.get(keyId)!;
  }

  return {
    mode,
    minSigners,
    requiredSignerKeyIds: [...required],
    eligibleSignerKeyIds: eligible,
    eligiblePublicKeysById,
  };
}

export function evaluateSignerSetAgainstPolicy(
  observedSignerKeyIds: string[],
  resolvedPolicy: ResolvedKebSigningPolicy,
  registry: KebSignerRegistry,
): KebPolicyEvaluation {
  const activeById = new Map<string, boolean>();
  for (const signer of registry.signers) {
    activeById.set(signer.keyId, signer.active);
  }
  const eligibleSet = new Set(resolvedPolicy.eligibleSignerKeyIds);
  const requiredSet = new Set(resolvedPolicy.requiredSignerKeyIds);
  const observedDistinct = [...new Set(observedSignerKeyIds)];

  const unknownObservedSignerKeyIds: string[] = [];
  const inactiveObservedSignerKeyIds: string[] = [];
  const eligibleObserved = new Set<string>();

  for (const keyId of observedDistinct) {
    if (!activeById.has(keyId)) {
      unknownObservedSignerKeyIds.push(keyId);
      continue;
    }
    if (!activeById.get(keyId)) {
      inactiveObservedSignerKeyIds.push(keyId);
      continue;
    }
    if (eligibleSet.has(keyId)) {
      eligibleObserved.add(keyId);
    }
  }

  const missingRequiredSignerKeyIds = [...requiredSet].filter((keyId) => !eligibleObserved.has(keyId));
  const distinctEligibleObservedSignerCount = eligibleObserved.size;
  const thresholdOk = distinctEligibleObservedSignerCount >= resolvedPolicy.minSigners;
  const requiredOk = missingRequiredSignerKeyIds.length === 0;
  const ok =
    thresholdOk &&
    requiredOk &&
    unknownObservedSignerKeyIds.length === 0 &&
    inactiveObservedSignerKeyIds.length === 0;

  const details: string[] = [];
  if (!thresholdOk) {
    details.push(
      `Observed eligible signer count ${distinctEligibleObservedSignerCount} is below minSigners=${resolvedPolicy.minSigners}`,
    );
  }
  if (!requiredOk) {
    details.push(`Missing required signers: ${missingRequiredSignerKeyIds.join(", ")}`);
  }
  if (unknownObservedSignerKeyIds.length > 0) {
    details.push(`Unknown observed signers: ${unknownObservedSignerKeyIds.join(", ")}`);
  }
  if (inactiveObservedSignerKeyIds.length > 0) {
    details.push(`Inactive observed signers: ${inactiveObservedSignerKeyIds.join(", ")}`);
  }

  return {
    ok,
    minSigners: resolvedPolicy.minSigners,
    observedSignerKeyIds: observedDistinct,
    eligibleSignerKeyIds: [...resolvedPolicy.eligibleSignerKeyIds],
    requiredSignerKeyIds: [...resolvedPolicy.requiredSignerKeyIds],
    distinctEligibleObservedSignerCount,
    missingRequiredSignerKeyIds,
    unknownObservedSignerKeyIds,
    inactiveObservedSignerKeyIds,
    details,
  };
}

function resolveRegistryPath(
  shared: LoadedKebSharedConfig,
  signersPathOverride?: string,
): string {
  if (signersPathOverride) {
    return resolvePathFromConfig(signersPathOverride);
  }
  return resolvePathFromConfig(shared.config.kasExitBridge.signersFile, shared.configPath);
}

function resolvePolicyPath(
  shared: LoadedKebSharedConfig,
  policyPathOverride?: string,
): string {
  if (policyPathOverride) {
    return resolvePathFromConfig(policyPathOverride);
  }
  return resolvePathFromConfig(shared.config.kasExitBridge.signingPolicyFile, shared.configPath);
}

function readJsonOrThrow(path: string, label: string): unknown {
  const absolutePath = resolve(path);
  if (!existsSync(absolutePath)) {
    throw new Error(`${label} file not found: ${absolutePath}`);
  }
  try {
    return JSON.parse(readFileSync(absolutePath, "utf8"));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Failed to parse ${label} file "${absolutePath}": ${msg}`);
  }
}

function validateSignerRegistry(
  raw: unknown,
  path: string,
  shared: LoadedKebSharedConfig,
): KebSignerRegistry {
  if (!isObjectRecord(raw)) {
    throw new Error(`Invalid signer registry "${path}": expected object`);
  }
  if (raw.schemaVersion !== 1) {
    throw new Error(`Invalid signer registry "${path}": schemaVersion must be 1`);
  }
  if (!Array.isArray(raw.signers)) {
    throw new Error(`Invalid signer registry "${path}": signers must be array`);
  }
  const seen = new Set<string>();
  const signers: KebSignerEntry[] = raw.signers.map((entry, idx) =>
    validateSignerEntry(entry, idx, path, shared, seen),
  );
  if (signers.length === 0) {
    throw new Error(`Invalid signer registry "${path}": signers must not be empty`);
  }
  return { schemaVersion: 1, signers };
}

function validateSignerEntry(
  raw: unknown,
  idx: number,
  path: string,
  shared: LoadedKebSharedConfig,
  seen: Set<string>,
): KebSignerEntry {
  const prefix = `signers[${idx}]`;
  if (!isObjectRecord(raw)) {
    throw new Error(`Invalid signer registry "${path}": ${prefix} must be object`);
  }
  const keyId = requireNonEmptyString(raw.keyId, `${prefix}.keyId`, path);
  if (seen.has(keyId)) {
    throw new Error(`Invalid signer registry "${path}": duplicate keyId "${keyId}"`);
  }
  seen.add(keyId);
  const publicKeyPathRaw = requireNonEmptyString(raw.publicKeyPath, `${prefix}.publicKeyPath`, path);
  const publicKeyPath = resolvePathFromConfig(publicKeyPathRaw, shared.configPath);
  const active = requireBoolean(raw.active, `${prefix}.active`, path);
  return {
    keyId,
    publicKeyPath,
    active,
  };
}

function validateSigningPolicy(raw: unknown, path: string): KebSigningPolicy {
  if (!isObjectRecord(raw)) {
    throw new Error(`Invalid signing policy "${path}": expected object`);
  }
  if (raw.schemaVersion !== 1) {
    throw new Error(`Invalid signing policy "${path}": schemaVersion must be 1`);
  }
  if (!isObjectRecord(raw.policy)) {
    throw new Error(`Invalid signing policy "${path}": policy must be object`);
  }

  const mode = String(raw.policy.allowedSignersMode ?? "");
  if (mode !== "any-active" && mode !== "explicit") {
    throw new Error(
      `Invalid signing policy "${path}": policy.allowedSignersMode must be "any-active" or "explicit"`,
    );
  }
  const minSigners = requirePositiveInteger(raw.policy.minSigners, "policy.minSigners", path);
  const allowedSigners = requireKeyIdArray(raw.policy.allowedSigners, "policy.allowedSigners", path);
  const requiredSigners = requireKeyIdArray(raw.policy.requiredSigners, "policy.requiredSigners", path);

  if (mode === "explicit" && allowedSigners.length === 0) {
    throw new Error(
      `Invalid signing policy "${path}": policy.allowedSigners must be non-empty when allowedSignersMode=explicit`,
    );
  }

  return {
    schemaVersion: 1,
    policy: {
      allowedSignersMode: mode,
      minSigners,
      allowedSigners,
      requiredSigners,
    },
  };
}

function resolveEligibleSigners(
  mode: KebSigningPolicyMode,
  allowedSigners: string[],
  activeById: Map<string, string>,
): string[] {
  const activeSignerIds = [...activeById.keys()];
  if (mode === "any-active") {
    if (allowedSigners.length === 0) return activeSignerIds;
    return activeSignerIds.filter((keyId) => allowedSigners.includes(keyId));
  }
  return activeSignerIds.filter((keyId) => allowedSigners.includes(keyId));
}

function requireKeyIdArray(value: unknown, field: string, path: string): string[] {
  if (!Array.isArray(value)) {
    throw new Error(`Invalid signing policy "${path}": ${field} must be array`);
  }
  const seen = new Set<string>();
  return value.map((v, idx) => {
    const keyId = requireNonEmptyString(v, `${field}[${idx}]`, path);
    if (seen.has(keyId)) {
      throw new Error(`Invalid signing policy "${path}": duplicate keyId "${keyId}" in ${field}`);
    }
    seen.add(keyId);
    return keyId;
  });
}

function requirePositiveInteger(value: unknown, field: string, path: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid signing policy "${path}": ${field} must be positive integer`);
  }
  return value;
}

function requireNonEmptyString(value: unknown, field: string, path: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Invalid config "${path}": ${field} must be non-empty string`);
  }
  return value;
}

function requireBoolean(value: unknown, field: string, path: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`Invalid config "${path}": ${field} must be boolean`);
  }
  return value;
}

function isObjectRecord(value: unknown): value is Record<string, any> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
