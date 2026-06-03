import { existsSync, readFileSync } from "fs";
import { dirname, join, resolve } from "path";

export const DEFAULT_KEB_CONFIG_PATH = "refs/keb-config.json";
export const ENV_KEB_CONFIG_PATH = "KEB_CONFIG";

export type KebSharedConfig = {
  schemaVersion: 1;
  kasExitBridge: {
    network: string;
    rpcUrl: string;
    chainId: number;
    addresses: {
      kasExitBridge: string;
      mailbox: string;
      merkleTreeHook: string;
    };
    reportsDir: string;
    deltaBlocksDefault: number;
    expectedValuesFile: string;
    methodologyFile: string;
    signing: {
      privateKeyPath?: string;
      publicKeyPath: string;
      keyId: string;
      keyType: "rsa" | "ecdsa";
    };
    signersFile: string;
    signingPolicyFile: string;
  };
};

export function resolveHome(path: string): string {
  if (!path.startsWith("~")) return path;
  const home = process.env.HOME;
  if (!home) {
    throw new Error("Cannot expand ~ path: HOME is not set");
  }
  if (path === "~") return home;
  if (path.startsWith("~/")) return `${home}/${path.slice(2)}`;
  return path;
}

export function resolveConfigPath(cliConfigPath?: string): string {
  const raw = cliConfigPath ?? process.env[ENV_KEB_CONFIG_PATH];
  if (!raw) {
    return detectDefaultConfigPath();
  }
  return resolve(resolveHome(raw));
}

function detectDefaultConfigPath(): string {
  const starts = [process.cwd(), __dirname].map((p) => resolve(p));
  for (const start of starts) {
    let cur = start;
    while (true) {
      const candidate = join(cur, DEFAULT_KEB_CONFIG_PATH);
      if (existsSync(candidate)) return candidate;
      const parent = dirname(cur);
      if (parent === cur) break;
      cur = parent;
    }
  }
  return resolve(process.cwd(), DEFAULT_KEB_CONFIG_PATH);
}

export function loadKebSharedConfig(cliConfigPath?: string): KebSharedConfig {
  const path = resolveConfigPath(cliConfigPath);
  if (!existsSync(path)) {
    throw new Error(`Config file not found: ${path}`);
  }
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Failed to parse config file "${path}": ${msg}`);
  }
  return validateKebSharedConfig(raw, path);
}

export type LoadedKebSharedConfig = {
  configPath: string;
  config: KebSharedConfig;
};

export function loadKebSharedConfigWithPath(cliConfigPath?: string): LoadedKebSharedConfig {
  const configPath = resolveConfigPath(cliConfigPath);
  return {
    configPath,
    config: loadKebSharedConfig(cliConfigPath),
  };
}

export function resolvePathFromConfig(
  pathValue: string,
  configPath?: string,
): string {
  const expanded = resolveHome(pathValue);
  if (expanded.startsWith("/")) return resolve(expanded);
  if (configPath && isDotRelative(expanded)) {
    return resolve(dirname(configPath), expanded);
  }
  if (configPath) {
    return resolve(resolveProjectRootFromConfig(configPath), expanded);
  }
  return resolve(expanded);
}

function isDotRelative(pathValue: string): boolean {
  return (
    pathValue === "." ||
    pathValue === ".." ||
    pathValue.startsWith("./") ||
    pathValue.startsWith("../")
  );
}

function resolveProjectRootFromConfig(configPath: string): string {
  const configDir = dirname(configPath);
  if (configDir.endsWith("/refs")) {
    return dirname(configDir);
  }
  return configDir;
}

function validateKebSharedConfig(raw: unknown, path: string): KebSharedConfig {
  if (!raw || typeof raw !== "object") {
    throw new Error(`Invalid config "${path}": expected object`);
  }
  const o = raw as Record<string, unknown>;
  if (o.schemaVersion !== 1) {
    throw new Error(`Invalid config "${path}": schemaVersion must be 1`);
  }
  if (!isObjectRecord(o.kasExitBridge)) {
    throw new Error(`Invalid config "${path}": kasExitBridge must be an object`);
  }
  const keb = o.kasExitBridge;
  if (!isObjectRecord(keb.addresses)) {
    throw new Error(`Invalid config "${path}": kasExitBridge.addresses must be an object`);
  }
  const addrs = keb.addresses;
  if (!isObjectRecord(keb.signing)) {
    throw new Error(`Invalid config "${path}": kasExitBridge.signing must be an object`);
  }
  const signing = keb.signing;

  const keyType = String(signing.keyType ?? "");
  if (keyType !== "rsa" && keyType !== "ecdsa") {
    throw new Error(`Invalid config "${path}": signing.keyType must be "rsa" or "ecdsa"`);
  }
  const cfg: KebSharedConfig = {
    schemaVersion: 1,
    kasExitBridge: {
      network: requireString(keb.network, "kasExitBridge.network", path),
      rpcUrl: requireString(keb.rpcUrl, "kasExitBridge.rpcUrl", path),
      chainId: requirePositiveInteger(keb.chainId, "kasExitBridge.chainId", path),
      addresses: {
        kasExitBridge: requireString(addrs.kasExitBridge, "kasExitBridge.addresses.kasExitBridge", path),
        mailbox: requireString(addrs.mailbox, "kasExitBridge.addresses.mailbox", path),
        merkleTreeHook: requireString(
          addrs.merkleTreeHook,
          "kasExitBridge.addresses.merkleTreeHook",
          path,
        ),
      },
      reportsDir: requireString(keb.reportsDir, "kasExitBridge.reportsDir", path),
      deltaBlocksDefault: requirePositiveInteger(
        keb.deltaBlocksDefault,
        "kasExitBridge.deltaBlocksDefault",
        path,
      ),
      expectedValuesFile: requireString(
        keb.expectedValuesFile,
        "kasExitBridge.expectedValuesFile",
        path,
      ),
      methodologyFile: requireString(keb.methodologyFile, "kasExitBridge.methodologyFile", path),
      signing: {
        privateKeyPath: optionalStringOrThrow(
          signing.privateKeyPath,
          "kasExitBridge.signing.privateKeyPath",
          path,
        ),
        publicKeyPath: requireString(
          signing.publicKeyPath,
          "kasExitBridge.signing.publicKeyPath",
          path,
        ),
        keyId: requireString(signing.keyId, "kasExitBridge.signing.keyId", path),
        keyType,
      },
      signersFile: requireString(keb.signersFile, "kasExitBridge.signersFile", path),
      signingPolicyFile: requireString(
        keb.signingPolicyFile,
        "kasExitBridge.signingPolicyFile",
        path,
      ),
    },
  };
  return cfg;
}

function requireString(value: unknown, field: string, path: string): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`Invalid config "${path}": ${field} must be non-empty string`);
  }
  return value;
}

function requirePositiveInteger(value: unknown, field: string, path: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new Error(`Invalid config "${path}": ${field} must be a positive integer`);
  }
  return value;
}

function optionalStringOrThrow(
  value: unknown,
  field: string,
  path: string,
): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") {
    throw new Error(`Invalid config "${path}": ${field} must be a string when provided`);
  }
  const trimmed = value.trim();
  if (trimmed === "") {
    throw new Error(`Invalid config "${path}": ${field} must be non-empty when provided`);
  }
  return trimmed;
}

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
