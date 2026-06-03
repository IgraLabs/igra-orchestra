import { existsSync, readFileSync, readdirSync } from "fs";
import { join, resolve } from "path";

type CliOpts = {
  bundleDir: string;
  exitIndex?: number;
  exitDataFile?: string;
  fundingFile?: string;
  requireUnsignedHex: boolean;
  allowMissingSigned2: boolean;
  verbose: boolean;
};

type FundingRecord = {
  utxo_id: string;
  bridge_utxo: {
    transaction_id: string;
    output_index: number;
    amount_sompi: number | string;
    script_public_key: string;
  };
};

type InputLockingUtxo = {
  transaction_id: string;
  index: number;
  amount_sompi: number | string;
  address: string;
  script_public_key?: {
    version?: number;
    script?: string;
  };
};

type InputExit = {
  message_id: string;
  recipient?: string;
  address?: string;
  amount_sompi: number | string;
};

type InputArtifact = {
  locking_utxos: InputLockingUtxo[];
  exits: InputExit[];
  change: {
    address: string;
    amount_sompi: number | string;
  };
  fee_sompi: number | string;
};

type ExitDataRecord = {
  status: "success" | "reverted";
  messageId: string | null;
  unlockAmountSompi: string;
  dispatchMessageDecoded: {
    body: {
      kasPayoutAddress: string;
      unlockAmountSompi: string;
    };
  } | null;
};

type ExitData = {
  exits: ExitDataRecord[];
};

type UnsignedArtifact = {
  protocol?: {
    payload_hex?: string;
  };
  exits?: InputExit[];
  locking_utxos?: InputLockingUtxo[];
};

type HexArtifacts = {
  unsignedHexPath: string;
  signed1Path: string;
  signed2Path: string;
};

function parseCli(argv: string[]): CliOpts {
  const map = new Map<string, string>();
  const flags = new Set<string>();

  for (let i = 0; i < argv.length; i++) {
    const key = argv[i];
    if (key === "-v") {
      flags.add("--verbose");
      continue;
    }
    if (!key.startsWith("--")) continue;
    if (key === "--require-unsigned-hex") {
      flags.add(key);
      continue;
    }
    if (key === "--allow-missing-signed-2") {
      flags.add(key);
      continue;
    }
    if (key === "--verbose") {
      flags.add(key);
      continue;
    }
    const value = argv[i + 1];
    if (!value || value.startsWith("--")) {
      throw new Error(`Missing value for ${key}`);
    }
    map.set(key, value);
    i++;
  }

  const bundleDir = map.get("--bundle-dir");
  if (!bundleDir) {
    throw new Error("Required: --bundle-dir <path>");
  }

  const exitIndexRaw = map.get("--exit-index");
  let exitIndex: number | undefined;
  if (exitIndexRaw !== undefined) {
    const n = Number(exitIndexRaw);
    if (!Number.isInteger(n) || n < 0) {
      throw new Error("Invalid --exit-index: expected non-negative integer");
    }
    exitIndex = n;
  }

  return {
    bundleDir,
    exitIndex,
    exitDataFile: map.get("--exit-data-file"),
    fundingFile: map.get("--funding-file"),
    requireUnsignedHex: flags.has("--require-unsigned-hex"),
    allowMissingSigned2: flags.has("--allow-missing-signed-2"),
    verbose: flags.has("--verbose"),
  };
}

function readJson<T>(path: string): T {
  return JSON.parse(readFileSync(path, "utf8")) as T;
}

function normHex(value: string): string {
  return value.trim().toLowerCase().replace(/^0x/, "");
}

function isHex(value: string): boolean {
  return /^[0-9a-f]+$/.test(value) && value.length % 2 === 0;
}

function toBigInt(value: number | string): bigint {
  if (typeof value === "number") return BigInt(value);
  if (/^\d+$/.test(value)) return BigInt(value);
  throw new Error(`Invalid integer value: ${String(value)}`);
}

function detectExitIndex(bundleDir: string, explicit?: number): number {
  if (explicit !== undefined) return explicit;
  const files = readdirSync(bundleDir).filter((name) =>
    /^exit-(\d+)-official-bridge\.input\.json$/.test(name),
  );
  if (files.length !== 1) {
    throw new Error(
      `Cannot auto-detect exit index in ${bundleDir}. Found ${files.length} input files: ${files.join(", ")}`,
    );
  }
  const m = /^exit-(\d+)-official-bridge\.input\.json$/.exec(files[0]);
  if (!m) throw new Error(`Unexpected input filename: ${files[0]}`);
  return Number(m[1]);
}

function detectFundingFile(bundleDir: string, explicit?: string): string {
  if (explicit) return explicit;
  const candidates = ["funding_utxos.json", "funding-utxos.json"].map((name) => join(bundleDir, name));
  for (const path of candidates) {
    if (existsSync(path)) return path;
  }
  throw new Error(
    `Funding file not found in ${bundleDir}. Expected one of: funding_utxos.json, funding-utxos.json`,
  );
}

function buildHexPaths(bundleDir: string, exitIndex: number): HexArtifacts {
  const prefix = `exit-${exitIndex}-official-bridge`;
  return {
    unsignedHexPath: join(bundleDir, `${prefix}.unsigned.hex`),
    signed1Path: join(bundleDir, `${prefix}.signed-1.hex`),
    signed2Path: join(bundleDir, `${prefix}.signed-2.hex`),
  };
}

function failIfErrors(errors: string[]): void {
  if (errors.length === 0) return;
  const body = errors.map((e) => `- ${e}`).join("\n");
  throw new Error(`Validation failed:\n${body}`);
}

function main(): void {
  const opts = parseCli(process.argv.slice(2));
  const bundleDir = resolve(opts.bundleDir);
  if (!existsSync(bundleDir)) {
    throw new Error(`Bundle directory not found: ${bundleDir}`);
  }

  const exitIndex = detectExitIndex(bundleDir, opts.exitIndex);
  const prefix = `exit-${exitIndex}-official-bridge`;

  const inputPath = join(bundleDir, `${prefix}.input.json`);
  const unsignedJsonPath = join(bundleDir, `${prefix}.unsigned.json`);
  const exitDataFile = resolve(opts.exitDataFile ?? join(bundleDir, "derived", "exit.data.json"));
  const fundingFile = resolve(detectFundingFile(bundleDir, opts.fundingFile));
  const hexPaths = buildHexPaths(bundleDir, exitIndex);

  const errors: string[] = [];
  const checkResults: Array<{ name: string; ok: boolean; issues: string[] }> = [];
  const runCheck = (name: string, fn: () => void) => {
    const start = errors.length;
    try {
      fn();
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      errors.push(`${name}: ${message}`);
    }
    const issues = errors.slice(start);
    const ok = issues.length === 0;
    checkResults.push({ name, ok, issues });
    if (opts.verbose) {
      console.log(`[${ok ? "PASS" : "FAIL"}] ${name}`);
      for (const issue of issues) {
        console.log(`  - ${issue}`);
      }
    }
  };

  runCheck("required-artifacts", () => {
    if (!existsSync(inputPath)) errors.push(`Missing input artifact: ${inputPath}`);
    if (!existsSync(exitDataFile)) errors.push(`Missing exit data file: ${exitDataFile}`);
    if (!existsSync(fundingFile)) errors.push(`Missing funding file: ${fundingFile}`);
    if (!existsSync(hexPaths.signed1Path)) errors.push(`Missing signed-1 hex: ${hexPaths.signed1Path}`);
    if (!opts.allowMissingSigned2 && !existsSync(hexPaths.signed2Path)) {
      errors.push(`Missing signed-2 hex: ${hexPaths.signed2Path}`);
    }
    if (opts.requireUnsignedHex && !existsSync(hexPaths.unsignedHexPath)) {
      errors.push(`Missing unsigned hex (required): ${hexPaths.unsignedHexPath}`);
    }
  });
  failIfErrors(errors);

  const input = readJson<InputArtifact>(inputPath);
  const exitData = readJson<ExitData>(exitDataFile);
  const funding = readJson<FundingRecord[]>(fundingFile);
  const hasUnsignedJson = existsSync(unsignedJsonPath);
  const unsignedJson = hasUnsignedJson ? readJson<UnsignedArtifact>(unsignedJsonPath) : undefined;

  runCheck("input-shape", () => {
    if (!Array.isArray(input.locking_utxos) || input.locking_utxos.length === 0) {
      errors.push("input.locking_utxos must contain at least one UTXO");
    }
    if (!Array.isArray(input.exits) || input.exits.length === 0) {
      errors.push("input.exits must contain at least one exit");
    }
  });

  const fundingByUtxoId = new Map<string, FundingRecord>();
  for (const row of funding) {
    const key = row.utxo_id.toLowerCase();
    if (fundingByUtxoId.has(key)) {
      errors.push(`Duplicate utxo_id in funding file: ${row.utxo_id}`);
      continue;
    }
    fundingByUtxoId.set(key, row);
  }

  const inputByUtxoId = new Map<string, InputLockingUtxo>();
  for (const utxo of input.locking_utxos) {
    const key = `${utxo.transaction_id}:${utxo.index}`.toLowerCase();
    if (inputByUtxoId.has(key)) {
      errors.push(`Duplicate locking UTXO in input.json: ${key}`);
      continue;
    }
    inputByUtxoId.set(key, utxo);
  }

  runCheck("funding-utxos-vs-input-locking-utxos", () => {
    if (fundingByUtxoId.size !== inputByUtxoId.size) {
      errors.push(
        `UTXO count mismatch: funding has ${fundingByUtxoId.size}, input.locking_utxos has ${inputByUtxoId.size}`,
      );
    }

    for (const [utxoId, fundingRow] of fundingByUtxoId.entries()) {
      const lock = inputByUtxoId.get(utxoId);
      if (!lock) {
        errors.push(`Funding UTXO missing in input.locking_utxos: ${utxoId}`);
        continue;
      }

      const fundingAmount = toBigInt(fundingRow.bridge_utxo.amount_sompi);
      const lockAmount = toBigInt(lock.amount_sompi);
      if (fundingAmount !== lockAmount) {
        errors.push(`Amount mismatch for ${utxoId}: funding=${fundingAmount} input=${lockAmount}`);
      }

      const fundingScript = normHex(fundingRow.bridge_utxo.script_public_key);
      const lockScript = normHex(lock.script_public_key?.script ?? "");
      if (!lockScript) {
        errors.push(`Missing script_public_key.script in input.locking_utxos for ${utxoId}`);
      } else if (fundingScript !== lockScript) {
        errors.push(`Script mismatch for ${utxoId}`);
      }
    }

    for (const utxoId of inputByUtxoId.keys()) {
      if (!fundingByUtxoId.has(utxoId)) {
        errors.push(`input.locking_utxos has UTXO not present in funding file: ${utxoId}`);
      }
    }
  });

  runCheck("change-address-policy", () => {
    const lockAddresses = new Set(input.locking_utxos.map((u) => u.address));
    if (lockAddresses.size !== 1) {
      errors.push(
        `All locking UTXOs must use one funding address. Found ${lockAddresses.size} addresses: ${[...lockAddresses].join(", ")}`,
      );
    }
    const onlyFundingAddress = [...lockAddresses][0];
    if (onlyFundingAddress && input.change.address !== onlyFundingAddress) {
      errors.push(
        `Change address mismatch: expected ${onlyFundingAddress}, got ${input.change.address}`,
      );
    }
  });

  const successfulExitRecords = exitData.exits.filter(
    (row) => row.status === "success" && row.messageId && row.dispatchMessageDecoded,
  );

  let expectedExitsFromData: InputExit[] = [];
  runCheck("exit-data-decoded-body-self-consistency", () => {
    expectedExitsFromData = successfulExitRecords.map((row) => {
      const decoded = row.dispatchMessageDecoded!.body;
      if (decoded.unlockAmountSompi !== row.unlockAmountSompi) {
        errors.push(
          `exit.data mismatch for message ${String(row.messageId)}: unlockAmountSompi != dispatchMessageDecoded.body.unlockAmountSompi`,
        );
      }
      return {
        message_id: String(row.messageId),
        address: decoded.kasPayoutAddress,
        amount_sompi: decoded.unlockAmountSompi,
      };
    });
  });

  runCheck("exit-data-vs-input-exits-order-address-amount", () => {
    if (expectedExitsFromData.length !== input.exits.length) {
      errors.push(
        `Exit count mismatch: exit.data successful exits=${expectedExitsFromData.length}, input.exits=${input.exits.length}`,
      );
    }

    const seenMessageIds = new Set<string>();
    for (let i = 0; i < input.exits.length; i++) {
      const inputExit = input.exits[i];
      const expected = expectedExitsFromData[i];
      const messageId = inputExit.message_id.toLowerCase();

      if (seenMessageIds.has(messageId)) {
        errors.push(`Duplicate message_id in input.exits: ${inputExit.message_id}`);
      }
      seenMessageIds.add(messageId);

      if (!expected) continue;

      if (messageId !== expected.message_id.toLowerCase()) {
        errors.push(
          `Exit order/message mismatch at index ${i}: input=${inputExit.message_id}, exit.data=${expected.message_id}`,
        );
      }
      const inputAddress = inputExit.address ?? inputExit.recipient;
      if (!inputAddress) {
        errors.push(`Missing input exit address/recipient at index ${i} for message ${inputExit.message_id}`);
      } else if (inputAddress !== expected.address) {
        errors.push(
          `Address mismatch at index ${i} for message ${inputExit.message_id}: input=${inputAddress}, exit.data.dispatchMessageDecoded.body.kasPayoutAddress=${expected.address}`,
        );
      }
      const inputAmt = toBigInt(inputExit.amount_sompi);
      const expectedAmt = toBigInt(expected.amount_sompi);
      if (inputAmt !== expectedAmt) {
        errors.push(
          `Amount mismatch at index ${i} for message ${inputExit.message_id}: input=${inputAmt} exit.data=${expectedAmt}`,
        );
      }
    }
  });

  runCheck("sompi-conservation", () => {
    const totalInputSompi = input.locking_utxos.reduce((acc, utxo) => acc + toBigInt(utxo.amount_sompi), 0n);
    const exitsTotalSompi = input.exits.reduce((acc, ex) => acc + toBigInt(ex.amount_sompi), 0n);
    const changeSompi = toBigInt(input.change.amount_sompi);
    const feeSompi = toBigInt(input.fee_sompi);
    if (totalInputSompi !== exitsTotalSompi + changeSompi + feeSompi) {
      errors.push(
        `Sompi conservation mismatch: input=${totalInputSompi}, exits+change+fee=${exitsTotalSompi + changeSompi + feeSompi}`,
      );
    }
  });

  const messageIdsNoPrefix = input.exits.map((ex) => normHex(ex.message_id));
  const expectedPayloadCore = `93${messageIdsNoPrefix.join("")}`;
  const presentHexFiles = [hexPaths.unsignedHexPath, hexPaths.signed1Path, hexPaths.signed2Path].filter((p) =>
    existsSync(p),
  );
  runCheck("payload-core-fragment-in-hex", () => {
    if (messageIdsNoPrefix.some((id) => id.length !== 64 || !isHex(id))) {
      errors.push("All input.exits[].message_id must be 32-byte hex values");
    }
    for (const hexPath of presentHexFiles) {
      const raw = readFileSync(hexPath, "utf8").trim();
      const hex = normHex(raw);
      if (!hex || !isHex(hex)) {
        errors.push(`Invalid hex encoding in ${hexPath}`);
        continue;
      }
      if (!hex.includes(expectedPayloadCore)) {
        errors.push(
          `Expected payload fragment (0x93 + messageIds) not found in ${hexPath}`,
        );
      }
    }
  });

  runCheck("signed-progression", () => {
    if (existsSync(hexPaths.signed1Path) && existsSync(hexPaths.signed2Path)) {
      const s1 = normHex(readFileSync(hexPaths.signed1Path, "utf8"));
      const s2 = normHex(readFileSync(hexPaths.signed2Path, "utf8"));
      if (s1 === s2) {
        errors.push("signed-1.hex and signed-2.hex are identical; expected two-signature progression");
      }
      if (s2.length <= s1.length) {
        errors.push(
          `signed-2.hex should be larger than signed-1.hex (got ${s2.length} <= ${s1.length})`,
        );
      }
    }
  });

  runCheck("unsigned-json-payload", () => {
    if (hasUnsignedJson && unsignedJson?.protocol?.payload_hex) {
      const payloadHex = normHex(unsignedJson.protocol.payload_hex);
      if (!payloadHex.startsWith(expectedPayloadCore)) {
        errors.push("unsigned.json protocol.payload_hex does not start with expected payload core");
      } else {
        const suffix = payloadHex.slice(expectedPayloadCore.length);
        if (!/^[0-9a-f]{8}$/.test(suffix)) {
          errors.push(
            `unsigned.json payload suffix must be 4-byte nonce (8 hex chars), got length=${suffix.length}`,
          );
        }
      }

      if (Array.isArray(unsignedJson.exits)) {
        if (unsignedJson.exits.length !== input.exits.length) {
          errors.push(
            `unsigned.json exits length (${unsignedJson.exits.length}) != input exits length (${input.exits.length})`,
          );
        }
      }
    }
  });

  failIfErrors(errors);

  console.log("Exit artifact consistency checks passed.");
  console.log(`bundleDir=${bundleDir}`);
  console.log(`exitIndex=${exitIndex}`);
  console.log(`fundingUtxos=${fundingByUtxoId.size}`);
  console.log(`successfulExits=${expectedExitsFromData.length}`);
  console.log(`hexFilesChecked=${presentHexFiles.length}`);
  console.log(`unsignedJsonChecked=${hasUnsignedJson}`);
  if (opts.verbose) {
    const passed = checkResults.filter((r) => r.ok).length;
    const failed = checkResults.length - passed;
    console.log(`checksPassed=${passed}`);
    console.log(`checksFailed=${failed}`);
  }
}

try {
  main();
} catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  console.error(message);
  process.exit(1);
}
