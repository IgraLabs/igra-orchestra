import { existsSync, readFileSync, mkdirSync, writeFileSync, readdirSync, statSync } from "fs";
import { dirname, resolve, relative, join } from "path";
import { createHash, createPrivateKey, sign as cryptoSign } from "crypto";
import { ethers } from "ethers";
import {
  ENV_KEB_CONFIG_PATH,
  loadKebSharedConfigWithPath,
  resolveHome,
  resolvePathFromConfig,
} from "./config";

type CliOpts = {
  configPath?: string;
  rpcUrl: string;
  kasExitBridge: string;
  mailbox: string;
  merkleTreeHook: string;
  contractExpectedValuesFile: string;
  traceMode: "auto" | "on" | "off";
  includeExternalRequestExitScan: boolean;
  verifyRootConsistency: boolean;
  treeSnapshotFile?: string;
  treeDataFile?: string;
  expectedRootStart?: string;
  expectedRootEnd?: string;
  expectedMethodologySha256: string;
  startBlockExpr: string;
  endBlockExpr: string;
  outBase?: string;
  outDataFile?: string;
  outChecksFile?: string;
  outTreeDataFile?: string;
  outTreeSnapshotFile?: string;
  outContractPreverifyFile?: string;
  outBundleDir?: string;
  previousCheckpointFile?: string;
  outEndCheckpointFile?: string;
  manifestSigningPrivateKey?: string;
  manifestSigningKeyId?: string;
  manifestSigningKeyType?: "rsa" | "ecdsa";
};

type TreeSnapshotInput = {
  version?: number;
  treeDepth?: number;
  blockNum: number;
  count: bigint;
  root: string;
  branch: string[];
};

type ReplayTreeDataInput = {
  start: {
    blockTag: number;
    root: string;
    count: bigint;
  };
  end: {
    blockTag: number;
    root: string;
    count: bigint;
  };
  events: Array<{
    messageId: string;
    index: bigint;
  }>;
};

type RootReplayReport = {
  enabled: boolean;
  skippedByConfig: boolean;
  dataSource: "tree-data-file" | "in-run-tree-data";
  snapshotFile?: string;
  treeDataFile?: string;
  snapshotValidated: boolean;
  replayedLeaves: number;
  snapshotCount?: string;
  snapshotRootProvided?: string;
  snapshotRootComputed?: string;
  startCheckpointRoot?: string;
  startCheckpointCount?: string;
  computedEndRoot?: string;
  onChainEndRoot?: string;
  match?: boolean;
};

type ExitTxReport = {
  status: "success" | "reverted";
  requestId: number | null;
  blockNum: number;
  txHash: string;
  unlockAmountSompi: string;
  burnWei: string;
  messageId: string | null;
  dispatchMessage: string | null;
  insertedIntoTreeIndex: number | null;
  eventCounts: {
    burnIKas: number;
    exitRequested: number;
    dispatch: number;
    dispatchId: number;
    insertedIntoTree: number;
  };
  checks: {
    eventCardinalityByTxStatus: boolean;
    dispatchMessageDecodesCorrectly: boolean;
    messageIdKeccakDispatchMessage: boolean;
    messageIdMatchesExitRequestedDispatchIdDispatchInserted: boolean;
    dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount: boolean;
    msgValueEqualsBurnIKasAmount: boolean;
  };
  errors: string[];
};

type ExitTxData = {
  status: "success" | "reverted";
  requestId: number | null;
  blockNum: number;
  txHash: string;
  unlockAmountSompi: string;
  burnWei: string;
  messageId: string | null;
  dispatchMessage: string | null;
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
  insertedIntoTreeIndex: number | null;
};

type CommonMetadata = {
  startedAt: string;
  endedAt: string;
  generatedAt: string;
  rpcUrl: string;
  chainId: number;
  fromBlock: number;
  toBlock: number;
  methodology: {
    path: string;
    expectedSha256: string;
    sha256: string;
  };
  links: {
    exitDataFile: string;
    treeDataFile: string;
    checksFile: string;
    contractPreverifyFile?: string;
    endCheckpointFile?: string;
  };
};

type DataReport = {
  metadata: {
    common: CommonMetadata;
    kasExitBridge: string;
    mailbox: string;
    checkpoints: {
      kasExitBridge: {
        start: {
          blockTag: number;
          nextExitRequestId: string;
          totalBurnedWei: string;
        };
        end: {
          blockTag: number;
          nextExitRequestId: string;
          totalBurnedWei: string;
        };
      };
    };
    totals: {
      exitTransactions: number;
      successfulExitTransactions: number;
      revertedExitTransactions: number;
      totalUnlockSompi: string;
      totalBurnWei: string;
      totalBurnIKas: string;
    };
  };
  exits: ExitTxData[];
};

type ChecksReport = {
  metadata: {
    common: CommonMetadata;
    exit: {
      kasExitBridge: string;
      mailbox: string;
      totals: {
        exitTransactions: number;
        successfulExitTransactions: number;
        revertedExitTransactions: number;
        burnEvents: number;
        exitRequestedEvents: number;
        dispatchEvents: number;
        totalUnlockSompi: string;
        totalBurnWei: string;
        totalBurnIKas: string;
        allChecksPassed: number;
        anyCheckFailed: number;
        kebEventCountsMatchSuccessfulExitTxCount: boolean;
      };
      checkFailures: {
        eventCardinalityByTxStatus: number;
        dispatchMessageDecodesCorrectly: number;
        messageIdKeccakDispatchMessage: number;
        messageIdMatchesExitRequestedDispatchIdDispatchInserted: number;
        dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount: number;
        msgValueEqualsBurnIKasAmount: number;
        kebEventCountsMatchSuccessfulExitTxCount: number;
      };
    };
    tree: {
      merkleTreeHook: string;
      mailbox: string;
      expectedRootStart?: string;
      expectedRootEnd?: string;
      rootReplay: RootReplayReport;
      checkpoints: {
        start: {
          blockTag: number;
          root: string;
          count: string;
        };
        end: {
          blockTag: number;
          root: string;
          count: string;
        };
      };
      totals: {
        insertedIntoTreeEvents: number;
        allChecksPassed: number;
        anyCheckFailed: number;
      };
      checkFailures: {
        mailboxMatchesConfiguredMailbox: number;
        countDeltaMatchesInsertedEvents: number;
        noDuplicateMessageIds: number;
        noDuplicateLeafIndices: number;
        noLeafIndexGaps: number;
        allSuccessfulExitInsertedEventsPresentAndMatching: number;
        rootReplayMatchesEndCheckpoint: number;
      };
    };
  };
  globalErrors: {
    exit: string[];
    tree: string[];
  };
  exits: Array<{
    status: "success" | "reverted";
    requestId: number | null;
    blockNum: number;
    txHash: string;
    eventCounts: ExitTxReport["eventCounts"];
    checks: ExitTxReport["checks"];
    errors: string[];
  }>;
};

type TreeInsertedEvent = {
  txHash: string;
  blockNum: number;
  messageId: string;
  index: number;
};

type HookCheckpoint = {
  blockTag: number;
  root: string;
  count: bigint;
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

type TreeDataReport = {
  metadata: {
    common: CommonMetadata;
    merkleTreeHook: string;
    mailbox: string;
    expectedRootStart?: string;
    expectedRootEnd?: string;
    checkpoints: {
      start: {
        blockTag: number;
        root: string;
        count: string;
      };
      end: {
        blockTag: number;
        root: string;
        count: string;
      };
    };
    totals: {
      insertedIntoTreeEvents: number;
    };
  };
  events: TreeInsertedEvent[];
};

type TreeSnapshotOutput = {
  version: number;
  treeDepth: number;
  blockNum: number;
  count: string;
  root: string;
  branch: string[];
};

type EndDeltaCheckpointOutput = {
  version: number;
  blockTag: number;
  merkleTreeHook: {
    root: string;
    count: string;
    mailbox: string;
  };
  kasExitBridge: {
    nextExitRequestId: string;
    totalBurnedWei: string;
  };
  sourceRange: {
    fromBlock: number;
    toBlock: number;
    startStateBlock: number;
    endStateBlock: number;
  };
};

type ContractExpectedValuesFile = {
  schemaVersion: 1;
  chainId: number;
  contracts: ContractExpectedValuesEntry[];
};

type ContractSlotExpected = {
  name: string;
  slot: string;
  decode: "raw-bytes32" | "address-right-20" | "uint256-decimal";
  expectedRaw?: string;
  expectedDecoded?: string;
};

type ContractExpectedValuesEntry = {
  id: "kasExitBridge" | "mailbox" | "merkleTreeHook";
  address: string;
  expectedCodeHash: string;
  slots: ContractSlotExpected[];
};

type ContractSlotObserved = {
  name: string;
  slot: string;
  decode: ContractSlotExpected["decode"];
  expectedRaw?: string;
  expectedDecoded?: string;
  actualRaw: string;
  actualDecoded: string;
  rawMatches: boolean;
  decodedMatches: boolean;
  matches: boolean;
};

type ContractBlockVerification = {
  blockTag: number;
  expectedCodeHash: string;
  actualCodeHash: string;
  codeHashMatches: boolean;
  slots: ContractSlotObserved[];
  allMatch: boolean;
};

type ContractPreVerificationOutput = {
  metadata: {
    expectedValuesFile: string;
    expectedValuesSha256: string;
    chainId: number;
    startStateBlock: number;
    endStateBlock: number;
  };
  contracts: Array<{
    id: ContractExpectedValuesEntry["id"];
    address: string;
    start: ContractBlockVerification;
    end: ContractBlockVerification;
    allMatch: boolean;
  }>;
};

type PassABundleManifest = {
  schemaVersion: 1;
  kind: "kas-exit-bridge-pass-a-bundle";
  createdAt: string;
  methodology: {
    path: string;
    expectedSha256: string;
    sha256: string;
  };
  context: {
    rpcUrl: string;
    chainId: number;
    fromBlock: number;
    toBlock: number;
    kasExitBridge: string;
    mailbox: string;
    merkleTreeHook: string;
  };
  artifactChecksums: {
    exitDataSha256: string;
    checksSha256: string;
    treeDataSha256: string;
    checkpointEndSha256: string;
    contractPreVerificationSha256: string;
  };
  bundleIntegral: {
    algorithm: "sha256";
    canonicalization: "json-c14n-sorted-keys-no-whitespace-utf8";
    value: string;
  };
  bundleIdentity: {
    algorithm: "sha256";
    canonicalization: "json-c14n-sorted-keys-no-whitespace-utf8";
    payloadVersion: 1 | 2;
    value: string;
  };
  signature?: {
    algorithm: "sha256-sign";
    keyType: "rsa" | "ecdsa";
    keyId: string;
    signatureFile: string;
    signatureEncoding: "base64";
  };
  files: Array<{
    path: string;
    sha256: string;
    size: number;
  }>;
};

const DEFAULT_RPC = "https://rpc.igralabs.com:8545";
const DEFAULT_KEB = "0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0";
const DEFAULT_MAILBOX = "0x3a867fCfFeC2B790970eeBDC9023E75B0a172aa7";
const DEFAULT_MERKLE_TREE_HOOK = "0x75719C858e0c73e07128F95B2C466d142490e933";
const DEFAULT_CONTRACT_EXPECTED_VALUES_FILE =
  "refs/kas-exit-bridge-contract-authenticity.expected.json";
const DEFAULT_SIGNING_PRIVATE_KEY = "~/.local/share/igra/keb-manifest-signing/keb_manifest_signing_priv.pem";
const ENV_SIGNING_PRIVATE_KEY = "KEB_MANIFEST_SIGNING_PRIVATE_KEY";
const ENV_SIGNING_KEY_ID = "KEB_MANIFEST_SIGNING_KEY_ID";
const ENV_SIGNING_KEY_TYPE = "KEB_MANIFEST_SIGNING_KEY_TYPE";
const ENV_RPC_URL = "KEB_RPC_URL";
const ENV_KEB_ADDRESS = "KEB_KAS_EXIT_BRIDGE";
const ENV_MAILBOX_ADDRESS = "KEB_MAILBOX";
const ENV_MERKLE_TREE_HOOK_ADDRESS = "KEB_MERKLE_TREE_HOOK";
const ENV_CONTRACT_EXPECTED_VALUES_FILE = "KEB_CONTRACT_EXPECTED_VALUES_FILE";
const METHODOLOGY_PATH = "docs/kas-exit-bridge-query-audit-methodology.md";
const DEFAULT_EXPECTED_METHODOLOGY_SHA256 =
  "90682609e89ec5c9107c97b09b1be820eef0efcb26c78aa0ae8ffb6bc49b2575";
const BUNDLE_INTEGRAL_CANONICALIZATION = "json-c14n-sorted-keys-no-whitespace-utf8";
const BUNDLE_IDENTITY_CANONICALIZATION = "json-c14n-sorted-keys-no-whitespace-utf8";
const BUNDLE_IDENTITY_PAYLOAD_VERSION = 2;
const MANIFEST_SIGNATURE_FILE = "manifest.signature.b64";

const KEB_IFACE = new ethers.Interface([
  "event ExitRequested(uint32 requestId, bytes32 messageId, uint64 feeAmountSompi)",
  "event BurnIKas(uint256 amount)",
  "function requestExit(string kasPayoutAddress, uint64 unlockAmountSompi) payable returns (uint32 requestId, bytes32 messageId)",
  "function nextExitRequested() view returns (uint32)",
  "function nextExitRequestId() view returns (uint32)",
  "function nextRequestId() view returns (uint32)",
  "function totalBurned() view returns (uint256)",
  "function totalBurnedWei() view returns (uint256)",
  "function totalBurn() view returns (uint256)",
]);

const MAILBOX_IFACE = new ethers.Interface([
  "event Dispatch(address indexed sender, uint32 indexed destination, bytes32 indexed recipient, bytes message)",
  "event DispatchId(bytes32 indexed messageId)",
  "event InsertedIntoTree(bytes32 messageId, uint32 index)",
  "event InsertedIntoTree(bytes32 indexed messageId, uint32 index)",
]);

const MERKLE_TREE_HOOK_IFACE = new ethers.Interface([
  "function root() view returns (bytes32)",
  "function count() view returns (uint256)",
  "function mailbox() view returns (address)",
  "function tree() view returns (bytes32[32] branch, uint256 count)",
]);

const EXIT_TOPIC = ethers.id("ExitRequested(uint32,bytes32,uint64)");
const BURN_TOPIC = ethers.id("BurnIKas(uint256)");
const DISPATCH_TOPIC = ethers.id("Dispatch(address,uint32,bytes32,bytes)");
const DISPATCH_ID_TOPIC = ethers.id("DispatchId(bytes32)");
const INSERTED_TOPIC = ethers.id("InsertedIntoTree(bytes32,uint32)");
const REQUEST_EXIT_SELECTOR = KEB_IFACE.getFunction("requestExit")!.selector;
const SOMPI_SCALE = 10_000_000_000n;
const ENVELOPE_PREFIX_LENGTH = 77;
const PROGRESS_INTERVAL_MS = 15_000;
const MAX_GET_LOGS_BLOCK_RANGE = 100_000;
const HYPERLANE_TREE_DEPTH = 32;
const HYPERLANE_MAX_LEAVES = (1n << 32n) - 1n;
const ZERO_ROOT = ethers.ZeroHash;
const ZERO_ADDRESS = ethers.ZeroAddress;
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

async function main() {
  const opts = parseCli(process.argv.slice(2));
  const provider = new ethers.JsonRpcProvider(opts.rpcUrl);
  const runStartedAt = new Date().toISOString();

  const [chainIdRaw, latest] = await Promise.all([
    provider.send("eth_chainId", []),
    provider.getBlockNumber(),
  ]);
  const chainId = Number(chainIdRaw);
  const fromBlock = resolveBlockExpr(opts.startBlockExpr, latest);
  const toBlock = resolveBlockExpr(opts.endBlockExpr, latest);

  if (fromBlock < 0 || toBlock < 0) {
    throw new Error("Block values must be non-negative");
  }
  if (fromBlock > toBlock) {
    throw new Error(`startBlock (${fromBlock}) > endBlock (${toBlock})`);
  }

  const safeTs = runStartedAt.replace(/:/g, "-");
  const outBase =
    opts.outBase ??
    `impl/reports/kas-exit-bridge-audit-from-${fromBlock}-to-${toBlock}-${safeTs}`;
  const outDataFile = opts.outDataFile ?? `${outBase}.exit.data.json`;
  const outChecksFile = opts.outChecksFile ?? `${outBase}.checks.json`;
  const outTreeDataFile = opts.outTreeDataFile ?? `${outBase}.tree.data.json`;
  const outTreeSnapshotFile = opts.outTreeSnapshotFile ?? `${outBase}.tree.snapshot.json`;
  const outContractPreverifyFile =
    opts.outContractPreverifyFile ?? `${outBase}.contract.preverify.json`;
  const outEndCheckpointFile = opts.outEndCheckpointFile ?? `${outBase}.checkpoint.end.json`;
  const outBundleDir = opts.outBundleDir ?? `${outBase}.bundle`;
  const mainProgress = createProgressTicker("main");
  mainProgress(
    `starting audit: blocks ${fromBlock}..${toBlock}, rpc=${opts.rpcUrl}, traceMode=${opts.traceMode}, includeExternalScan=${opts.includeExternalRequestExitScan}`,
    true,
  );

  const keb = ethers.getAddress(opts.kasExitBridge);
  const mailbox = ethers.getAddress(opts.mailbox);
  const merkleTreeHook = ethers.getAddress(opts.merkleTreeHook);
  const methodologySha256 = sha256FileHex(METHODOLOGY_PATH);
  if (methodologySha256 !== opts.expectedMethodologySha256) {
    throw new Error(
      `Methodology checksum mismatch: expected=${opts.expectedMethodologySha256} actual=${methodologySha256} path=${METHODOLOGY_PATH}`,
    );
  }
  if (opts.manifestSigningPrivateKey && !existsSync(resolve(opts.manifestSigningPrivateKey))) {
    throw new Error(
      `Manifest signing private key not found: ${resolve(opts.manifestSigningPrivateKey)}`,
    );
  }
  const paddedKebTopic = ethers.zeroPadValue(keb, 32).toLowerCase();
  const merkleTreeHookContract = new ethers.Contract(
    merkleTreeHook,
    MERKLE_TREE_HOOK_IFACE,
    provider,
  );
  const kebContract = new ethers.Contract(keb, KEB_IFACE, provider);

  const startStateBlock = Math.max(0, fromBlock - 1);
  const endStateBlock = toBlock;
  const [hookMailbox, startCheckpoint, endCheckpoint, kebStartCheckpoint, kebEndCheckpoint] =
    await Promise.all([
      readMerkleTreeMailbox(merkleTreeHookContract),
      readMerkleTreeCheckpoint(merkleTreeHookContract, startStateBlock),
      readMerkleTreeCheckpoint(merkleTreeHookContract, endStateBlock),
      readKasExitBridgeCheckpoint(kebContract, startStateBlock),
      readKasExitBridgeCheckpoint(kebContract, endStateBlock),
    ]);
  const rootStart = startCheckpoint.root;
  const rootEnd = endCheckpoint.root;
  const countStart = startCheckpoint.count;
  const countEnd = endCheckpoint.count;

  if (opts.previousCheckpointFile) {
    const prev = parseDeltaAnchorCheckpointOrThrow(
      loadJsonFileOrThrow(opts.previousCheckpointFile, "previous checkpoint"),
    );
    if (prev.blockTag !== startStateBlock) {
      throw new Error(
        `Previous checkpoint block mismatch: prev.blockTag=${prev.blockTag} expectedStartStateBlock=${startStateBlock}`,
      );
    }
    if (prev.merkleTreeHook.root !== rootStart) {
      throw new Error(
        `Previous checkpoint merkle root mismatch: prev=${prev.merkleTreeHook.root} start=${rootStart}`,
      );
    }
    if (prev.merkleTreeHook.count !== countStart) {
      throw new Error(
        `Previous checkpoint merkle count mismatch: prev=${prev.merkleTreeHook.count} start=${countStart}`,
      );
    }
    if (prev.kasExitBridge.nextExitRequestId !== kebStartCheckpoint.nextExitRequestId) {
      throw new Error(
        `Previous checkpoint KEB requestId mismatch: prev=${prev.kasExitBridge.nextExitRequestId} start=${kebStartCheckpoint.nextExitRequestId}`,
      );
    }
    if (prev.kasExitBridge.totalBurnedWei !== kebStartCheckpoint.totalBurnedWei) {
      throw new Error(
        `Previous checkpoint KEB totalBurned mismatch: prev=${prev.kasExitBridge.totalBurnedWei} start=${kebStartCheckpoint.totalBurnedWei}`,
      );
    }
  }

  if (opts.expectedRootStart && rootStart !== opts.expectedRootStart.toLowerCase()) {
    throw new Error(
      `Expected start root mismatch at block ${startStateBlock}: expected=${opts.expectedRootStart.toLowerCase()} actual=${rootStart}`,
    );
  }
  if (opts.expectedRootEnd && rootEnd !== opts.expectedRootEnd.toLowerCase()) {
    throw new Error(
      `Expected end root mismatch at block ${endStateBlock}: expected=${opts.expectedRootEnd.toLowerCase()} actual=${rootEnd}`,
    );
  }
  mainProgress(
    `contract pre-verification using ${opts.contractExpectedValuesFile} at blocks ${startStateBlock} and ${endStateBlock}`,
    true,
  );
  const contractPreVerificationOutput = await runContractPreVerification({
    provider,
    expectedValuesFile: opts.contractExpectedValuesFile,
    chainId,
    startStateBlock,
    endStateBlock,
    keb,
    mailbox,
    merkleTreeHook,
  });
  const preverifyMismatches: string[] = [];
  for (const c of contractPreVerificationOutput.contracts) {
    if (!c.start.codeHashMatches) {
      preverifyMismatches.push(
        `${c.id}@start codeHash mismatch: expected=${c.start.expectedCodeHash} actual=${c.start.actualCodeHash}`,
      );
    }
    if (!c.end.codeHashMatches) {
      preverifyMismatches.push(
        `${c.id}@end codeHash mismatch: expected=${c.end.expectedCodeHash} actual=${c.end.actualCodeHash}`,
      );
    }
    for (const blockCheck of [c.start, c.end]) {
      const phase = blockCheck.blockTag === startStateBlock ? "start" : "end";
      for (const s of blockCheck.slots) {
        if (!s.matches) {
          preverifyMismatches.push(
            `${c.id}@${phase} slot ${s.name} mismatch: expectedRaw=${s.expectedRaw ?? "<skip>"} actualRaw=${s.actualRaw} expectedDecoded=${s.expectedDecoded ?? "<skip>"} actualDecoded=${s.actualDecoded}`,
          );
        }
      }
    }
  }
  if (preverifyMismatches.length > 0) {
    throw new Error(
      `Contract pre-verification failed (${preverifyMismatches.length} mismatch(es)): ${preverifyMismatches.join(" | ")}`,
    );
  }

  const requestExitTxHashes = opts.includeExternalRequestExitScan
    ? await collectExternalRequestExitTxHashes(
        provider,
        keb,
        fromBlock,
        toBlock,
        (msg, force) => mainProgress(`scan-external ${msg}`, force),
      )
    : [];
  const successfulExitLogs = await getLogsChunked(
    provider,
    {
      address: keb,
      fromBlock,
      toBlock,
      topics: [EXIT_TOPIC],
    },
    (msg, force) => mainProgress(`scan-exit-logs ${msg}`, force),
  );
  const successTxHashesFromEvents = successfulExitLogs.map((l) => l.transactionHash);
  const hookInsertedLogs = await getLogsChunked(
    provider,
    {
      address: merkleTreeHook,
      fromBlock,
      toBlock,
      topics: [INSERTED_TOPIC],
    },
    (msg, force) => mainProgress(`scan-hook-inserted-logs ${msg}`, force),
  );
  const treeEvents: TreeInsertedEvent[] = hookInsertedLogs.map((log) => {
    const parsed = parseInsertedIntoTree(log);
    if (!parsed) {
      throw new Error(`Failed to parse InsertedIntoTree log in tx ${log.transactionHash}`);
    }
    return {
      txHash: log.transactionHash,
      blockNum: Number(log.blockNumber),
      messageId: parsed.messageId.toLowerCase(),
      index: parsed.index,
    };
  });
  const txHashSet = new Set<string>([...requestExitTxHashes, ...successTxHashesFromEvents]);
  const txHashes = Array.from(txHashSet);
  mainProgress(
    `candidate txs: external=${requestExitTxHashes.length}, successFromEvents=${successTxHashesFromEvents.length}, union=${txHashes.length}`,
    true,
  );
  const reportsByTx = new Map<string, ExitTxReport>();
  const rawCandidateTxs: any[] = [];
  const rawCandidateReceipts: any[] = [];
  let totalUnlockSompi = 0n;
  let totalBurnWei = 0n;
  let dispatchEventsCount = 0;
  let successfulExitTxCount = 0;
  let revertedExitTxCount = 0;

  for (let i = 0; i < txHashes.length; i++) {
    const txHash = txHashes[i];
    mainProgress(`processing tx ${i + 1}/${txHashes.length}`);
    const [tx, receipt] = await Promise.all([
      provider.getTransaction(txHash),
      provider.getTransactionReceipt(txHash),
    ]);
    if (!tx) {
      throw new Error(`Transaction not found: ${txHash}`);
    }
    if (!receipt) {
      throw new Error(`Transaction receipt not found: ${txHash}`);
    }
    rawCandidateTxs.push(serializeRpcValue(tx));
    rawCandidateReceipts.push(serializeRpcValue(receipt));

    const status: "success" | "reverted" = receipt.status === 1 ? "success" : "reverted";
    if (status === "success") successfulExitTxCount += 1;
    else revertedExitTxCount += 1;

    const errors: string[] = [];
    const burnLogs = receipt.logs.filter(
      (l) =>
        l.address.toLowerCase() === keb.toLowerCase() &&
        l.topics.length > 0 &&
        l.topics[0].toLowerCase() === BURN_TOPIC.toLowerCase(),
    );
    const exitRequestedLogs = receipt.logs.filter(
      (l) =>
        l.address.toLowerCase() === keb.toLowerCase() &&
        l.topics.length > 0 &&
        l.topics[0].toLowerCase() === EXIT_TOPIC.toLowerCase(),
    );
    const dispatchLogs = receipt.logs.filter(
      (l) =>
        l.address.toLowerCase() === mailbox.toLowerCase() &&
        l.topics.length > 1 &&
        l.topics[0].toLowerCase() === DISPATCH_TOPIC.toLowerCase() &&
        l.topics[1].toLowerCase() === paddedKebTopic,
    );
    const dispatchIdLogs = receipt.logs.filter(
      (l) =>
        l.address.toLowerCase() === mailbox.toLowerCase() &&
        l.topics.length > 0 &&
        l.topics[0].toLowerCase() === DISPATCH_ID_TOPIC.toLowerCase(),
    );
    const insertedLogs = receipt.logs.filter(
      (l) => l.topics.length > 0 && l.topics[0].toLowerCase() === INSERTED_TOPIC.toLowerCase(),
    );

    const eventCounts = {
      burnIKas: burnLogs.length,
      exitRequested: exitRequestedLogs.length,
      dispatch: dispatchLogs.length,
      dispatchId: dispatchIdLogs.length,
      insertedIntoTree: insertedLogs.length,
    };
    dispatchEventsCount += eventCounts.dispatch;

    const eventCardinalityByTxStatusOk =
      status === "success"
        ? eventCounts.burnIKas === 1 &&
          eventCounts.exitRequested === 1 &&
          eventCounts.dispatch === 1 &&
          eventCounts.dispatchId === 1 &&
          eventCounts.insertedIntoTree === 1
        : eventCounts.burnIKas === 0 &&
          eventCounts.exitRequested === 0 &&
          eventCounts.dispatch === 0 &&
          eventCounts.dispatchId === 0 &&
          eventCounts.insertedIntoTree === 0;
    if (!eventCardinalityByTxStatusOk) {
      errors.push(
        `Invalid event cardinality for ${status} tx: burn=${eventCounts.burnIKas}, exit=${eventCounts.exitRequested}, dispatch=${eventCounts.dispatch}, dispatchId=${eventCounts.dispatchId}, inserted=${eventCounts.insertedIntoTree}`,
      );
    }

    let requestId: number | null = null;
    let exitMessageId: string | null = null;
    if (eventCounts.exitRequested === 1) {
      const parsedExit = KEB_IFACE.parseLog(exitRequestedLogs[0]);
      if (parsedExit) {
        requestId = Number(parsedExit.args.requestId);
        exitMessageId = String(parsedExit.args.messageId).toLowerCase();
      } else {
        errors.push("Failed to parse ExitRequested event");
      }
    } else if (status === "success") {
      errors.push("Missing or duplicate ExitRequested event");
    }

    let burnWei = 0n;
    if (eventCounts.burnIKas === 1) {
      const parsedBurn = KEB_IFACE.parseLog(burnLogs[0]);
      if (!parsedBurn) {
        errors.push("Failed to parse BurnIKas event");
      } else {
        burnWei = BigInt(parsedBurn.args.amount);
      }
    } else {
      if (status === "success") errors.push("Missing or duplicate BurnIKas event");
    }

    let dispatchMessage = "";
    if (eventCounts.dispatch === 1) {
      const parsedDispatch = MAILBOX_IFACE.parseLog(dispatchLogs[0]);
      if (!parsedDispatch) {
        errors.push("Failed to parse Dispatch event");
      } else {
        dispatchMessage = String(parsedDispatch.args.message).toLowerCase();
      }
    } else if (status === "success") {
      errors.push("Missing or duplicate Mailbox Dispatch(sender=KasExitBridge) event");
    }

    let dispatchIdMessageId: string | null = null;
    if (eventCounts.dispatchId === 1) {
      const dispatchIdLog = dispatchIdLogs[0];
      if (dispatchIdLog.topics.length > 1) {
        dispatchIdMessageId = dispatchIdLog.topics[1].toLowerCase();
      } else {
        const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["bytes32"], dispatchIdLog.data);
        dispatchIdMessageId = String(decoded[0]).toLowerCase();
      }
    } else {
      if (status === "success") errors.push("Missing or duplicate Mailbox DispatchId event");
    }

    let insertedMessageId: string | null = null;
    let insertedIndex: number | null = null;
    if (eventCounts.insertedIntoTree === 1) {
      const parsedInserted = parseInsertedIntoTree(insertedLogs[0]);
      if (!parsedInserted) {
        errors.push("Failed to parse InsertedIntoTree event");
      } else {
        insertedMessageId = parsedInserted.messageId.toLowerCase();
        insertedIndex = parsedInserted.index;
      }
    } else if (status === "success") {
      errors.push("Missing or duplicate InsertedIntoTree event");
    }

    // Decode requestExit calldata (external direct calls) or trace-decode internal call input.
    let kasPayoutAddress = "";
    let unlockAmountSompi = 0n;
    const isTopLevelRequestExit =
      (tx.to ?? "").toLowerCase() === keb.toLowerCase() &&
      !!tx.data &&
      tx.data.slice(0, 10).toLowerCase() === REQUEST_EXIT_SELECTOR.toLowerCase();

    if (isTopLevelRequestExit) {
      try {
        const decoded = KEB_IFACE.decodeFunctionData("requestExit", tx.data);
        kasPayoutAddress = String(decoded.kasPayoutAddress);
        unlockAmountSompi = BigInt(decoded.unlockAmountSompi);
      } catch {
        errors.push("Failed to decode top-level requestExit calldata");
      }
    } else if (status === "success") {
      const traced = await tryDecodeInternalRequestExitFromTrace(provider, txHash, keb, opts.traceMode);
      if (!traced.ok) {
        errors.push("error" in traced ? traced.error : "Trace decoding failed");
      } else {
        kasPayoutAddress = traced.kasPayoutAddress;
        unlockAmountSompi = traced.unlockAmountSompi;
      }
    }

    // Check 1: messageId == keccak256(Dispatch.message)
    let checkMessageIdKeccakDispatchMessage = status === "reverted";
    if (dispatchMessage && exitMessageId) {
      const computed = ethers.keccak256(dispatchMessage).toLowerCase();
      checkMessageIdKeccakDispatchMessage = computed === exitMessageId;
      if (!checkMessageIdKeccakDispatchMessage) {
        errors.push(
          `messageId mismatch with keccak(dispatch.message): expected ${exitMessageId}, got ${computed}`,
        );
      }
    }

    // Check 2: messageId matches across all events
    const checkMessageIdAcrossEvents =
      status === "reverted"
        ? true
        : !!dispatchMessage &&
          exitMessageId !== null &&
          dispatchIdMessageId !== null &&
          insertedMessageId !== null &&
          dispatchIdMessageId === exitMessageId &&
          insertedMessageId === exitMessageId;
    if (status === "success" && !checkMessageIdAcrossEvents) {
      errors.push("messageId mismatch across ExitRequested / DispatchId / Dispatch / InsertedIntoTree");
    }

    // Check 3: Dispatch.message includes requestExit payout + unlock amount correctly
    let checkDispatchMessageDecodesCorrectly = status === "reverted";
    let checkDispatchMessageMatchesRequestExit = status === "reverted";
    let parsedDispatchMessage: ReturnType<typeof parseHyperlaneMessage> = null;
    if (dispatchMessage) {
      parsedDispatchMessage = parseHyperlaneMessage(dispatchMessage);
      if (!parsedDispatchMessage) {
        checkDispatchMessageDecodesCorrectly = false;
        errors.push("Failed to parse Dispatch.message Hyperlane envelope");
      } else {
        checkDispatchMessageDecodesCorrectly = true;
        const payoutBytes = ethers.toUtf8Bytes(kasPayoutAddress);
        checkDispatchMessageMatchesRequestExit =
          parsedDispatchMessage.body.format === 0x11 &&
          parsedDispatchMessage.body.requestId === requestId &&
          parsedDispatchMessage.body.unlockAmountSompi === unlockAmountSompi &&
          parsedDispatchMessage.body.kasPayoutAddress === kasPayoutAddress &&
          parsedDispatchMessage.body.kasPayoutAddressLength === payoutBytes.length;

        if (!checkDispatchMessageMatchesRequestExit) {
          errors.push("Dispatch.message body does not match requestExit payload");
        }
      }
    }

    // Check 4: msg.value == BurnIKas.amount
    const checkMsgValueEqualsBurn =
      status === "reverted" ? true : BigInt(tx.value) === burnWei;
    if (status === "success" && !checkMsgValueEqualsBurn) {
      errors.push(`msg.value (${tx.value}) != BurnIKas.amount (${burnWei})`);
    }

    if (status === "success") {
      totalUnlockSompi += unlockAmountSompi;
      totalBurnWei += burnWei;
    }

    reportsByTx.set(txHash, {
      status,
      requestId,
      blockNum: Number(receipt.blockNumber),
      txHash,
      unlockAmountSompi: unlockAmountSompi.toString(),
      burnWei: burnWei.toString(),
      messageId: exitMessageId,
      dispatchMessage: dispatchMessage || null,
      insertedIntoTreeIndex: insertedIndex,
      eventCounts,
      checks: {
        eventCardinalityByTxStatus: eventCardinalityByTxStatusOk,
        dispatchMessageDecodesCorrectly: checkDispatchMessageDecodesCorrectly,
        messageIdKeccakDispatchMessage: checkMessageIdKeccakDispatchMessage,
        messageIdMatchesExitRequestedDispatchIdDispatchInserted: checkMessageIdAcrossEvents,
        dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount: checkDispatchMessageMatchesRequestExit,
        msgValueEqualsBurnIKasAmount: checkMsgValueEqualsBurn,
      },
      errors,
    });
  }

  const reports = Array.from(reportsByTx.values()).sort((a, b) =>
    a.blockNum === b.blockNum ? a.txHash.localeCompare(b.txHash) : a.blockNum - b.blockNum,
  );

  const kebBurnLogs = await getLogsChunked(
    provider,
    {
      address: keb,
      fromBlock,
      toBlock,
      topics: [BURN_TOPIC],
    },
    (msg, force) => mainProgress(`scan-burn-logs ${msg}`, force),
  );
  const kebExitLogs = await getLogsChunked(
    provider,
    {
      address: keb,
      fromBlock,
      toBlock,
      topics: [EXIT_TOPIC],
    },
    (msg, force) => mainProgress(`scan-exit-logs-global ${msg}`, force),
  );
  const kebEventCountsMatchSuccessfulExitTxCount =
    kebBurnLogs.length === successfulExitTxCount &&
    kebExitLogs.length === successfulExitTxCount;

  const globalErrors: string[] = [];
  if (!kebEventCountsMatchSuccessfulExitTxCount) {
    globalErrors.push(
      `KasExitBridge event count mismatch: successfulExitTx=${successfulExitTxCount}, BurnIKas=${kebBurnLogs.length}, ExitRequested=${kebExitLogs.length}`,
    );
  }

  const checkFailures = {
    eventCardinalityByTxStatus: reports.filter((r) => !r.checks.eventCardinalityByTxStatus).length,
    dispatchMessageDecodesCorrectly: reports.filter((r) => !r.checks.dispatchMessageDecodesCorrectly).length,
    messageIdKeccakDispatchMessage: reports.filter((r) => !r.checks.messageIdKeccakDispatchMessage).length,
    messageIdMatchesExitRequestedDispatchIdDispatchInserted: reports.filter(
      (r) => !r.checks.messageIdMatchesExitRequestedDispatchIdDispatchInserted,
    ).length,
    dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount: reports.filter(
      (r) => !r.checks.dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount,
    ).length,
    msgValueEqualsBurnIKasAmount: reports.filter((r) => !r.checks.msgValueEqualsBurnIKasAmount).length,
    kebEventCountsMatchSuccessfulExitTxCount: kebEventCountsMatchSuccessfulExitTxCount ? 0 : 1,
  };

  const allChecksPassed = reports.filter((r) => r.errors.length === 0).length;
  const anyCheckFailed = reports.length - allChecksPassed + globalErrors.length;

  const treeEventsSorted = treeEvents
    .slice()
    .sort((a, b) => (a.index === b.index ? a.txHash.localeCompare(b.txHash) : a.index - b.index));
  const treeEventsByTxHash = new Map<string, TreeInsertedEvent[]>();
  for (const e of treeEvents) {
    const arr = treeEventsByTxHash.get(e.txHash) ?? [];
    arr.push(e);
    treeEventsByTxHash.set(e.txHash, arr);
  }

  const checkMailboxMatchesConfiguredMailbox = hookMailbox.toLowerCase() === mailbox.toLowerCase();
  const checkCountDeltaMatchesInsertedEvents = countEnd - countStart === BigInt(treeEvents.length);

  const seenMessageIds = new Set<string>();
  let checkNoDuplicateMessageIds = true;
  for (const e of treeEvents) {
    if (seenMessageIds.has(e.messageId)) {
      checkNoDuplicateMessageIds = false;
      break;
    }
    seenMessageIds.add(e.messageId);
  }

  const seenIndices = new Set<number>();
  let checkNoDuplicateLeafIndices = true;
  for (const e of treeEvents) {
    if (seenIndices.has(e.index)) {
      checkNoDuplicateLeafIndices = false;
      break;
    }
    seenIndices.add(e.index);
  }

  let checkNoLeafIndexGaps = true;
  for (let i = 0; i < treeEventsSorted.length; i++) {
    const expectedIndex = countStart + BigInt(i);
    if (BigInt(treeEventsSorted[i].index) !== expectedIndex) {
      checkNoLeafIndexGaps = false;
      break;
    }
  }

  const successfulExitReports = reports.filter((r) => r.status === "success");
  let checkAllSuccessfulExitInsertedEventsPresentAndMatching = true;
  for (const r of successfulExitReports) {
    if (!r.messageId || r.insertedIntoTreeIndex === null) {
      checkAllSuccessfulExitInsertedEventsPresentAndMatching = false;
      break;
    }
    const perTxTreeEvents = treeEventsByTxHash.get(r.txHash) ?? [];
    const found = perTxTreeEvents.some(
      (e) => e.messageId === r.messageId!.toLowerCase() && e.index === r.insertedIntoTreeIndex,
    );
    if (!found) {
      checkAllSuccessfulExitInsertedEventsPresentAndMatching = false;
      break;
    }
  }

  const treeGlobalErrors: string[] = [];
  if (!checkMailboxMatchesConfiguredMailbox) {
    treeGlobalErrors.push(
      `MerkleTreeHook mailbox mismatch: hook.mailbox=${hookMailbox} configuredMailbox=${mailbox}`,
    );
  }
  if (!checkCountDeltaMatchesInsertedEvents) {
    treeGlobalErrors.push(
      `count delta mismatch: startCount=${countStart} endCount=${countEnd} delta=${countEnd - countStart} insertedEvents=${treeEvents.length}`,
    );
  }
  if (!checkNoDuplicateMessageIds) {
    treeGlobalErrors.push("Duplicate messageId detected in MerkleTreeHook InsertedIntoTree events");
  }
  if (!checkNoDuplicateLeafIndices) {
    treeGlobalErrors.push("Duplicate leaf index detected in MerkleTreeHook InsertedIntoTree events");
  }
  if (!checkNoLeafIndexGaps) {
    treeGlobalErrors.push(
      `Leaf index gap detected; expected contiguous indices from ${countStart.toString()} to ${(countEnd - 1n).toString()}`,
    );
  }
  if (!checkAllSuccessfulExitInsertedEventsPresentAndMatching) {
    treeGlobalErrors.push(
      "Not all successful exit transactions have a matching InsertedIntoTree(txHash,messageId,index) event from MerkleTreeHook",
    );
  }

  let rootReplay: RootReplayReport = {
    enabled: opts.verifyRootConsistency,
    skippedByConfig: !opts.verifyRootConsistency,
    dataSource: opts.treeDataFile ? "tree-data-file" : "in-run-tree-data",
    snapshotFile: opts.treeSnapshotFile ? toReportPath(opts.treeSnapshotFile) : undefined,
    treeDataFile: opts.treeDataFile ? toReportPath(opts.treeDataFile) : undefined,
    snapshotValidated: false,
    replayedLeaves: 0,
  };

  if (opts.verifyRootConsistency) {
    try {
      const snapshotInput = validateSnapshotOrThrow(
        loadJsonFileOrThrow(opts.treeSnapshotFile!, "tree snapshot"),
      );
      const replayTreeData: ReplayTreeDataInput = opts.treeDataFile
        ? validateTreeDataForReplayOrThrow(
            loadJsonFileOrThrow(opts.treeDataFile, "tree data"),
          )
        : {
            start: {
              blockTag: startCheckpoint.blockTag,
              root: rootStart,
              count: countStart,
            },
            end: {
              blockTag: endCheckpoint.blockTag,
              root: rootEnd,
              count: countEnd,
            },
            events: treeEvents.map((e) => ({
              messageId: normalizeBytes32ValueOrThrow(
                e.messageId,
                `inRun.treeEvents.${e.txHash}.messageId`,
              ),
              index: BigInt(e.index),
            })),
          };

      if (snapshotInput.blockNum !== replayTreeData.start.blockTag) {
        throw new Error(
          `Snapshot block mismatch with tree-data start checkpoint: snapshot.blockNum=${snapshotInput.blockNum} treeData.start.blockTag=${replayTreeData.start.blockTag}`,
        );
      }
      if (snapshotInput.count !== replayTreeData.start.count) {
        throw new Error(
          `Snapshot count mismatch with tree-data start checkpoint: snapshot.count=${snapshotInput.count} treeData.start.count=${replayTreeData.start.count}`,
        );
      }
      if (snapshotInput.root !== replayTreeData.start.root) {
        throw new Error(
          `Snapshot root mismatch with tree-data start checkpoint: snapshot.root=${snapshotInput.root} treeData.start.root=${replayTreeData.start.root}`,
        );
      }

      if (opts.treeDataFile) {
        if (replayTreeData.start.blockTag !== startCheckpoint.blockTag) {
          throw new Error(
            `tree-data start block mismatch with current run: treeData.start.blockTag=${replayTreeData.start.blockTag} run.start.blockTag=${startCheckpoint.blockTag}`,
          );
        }
        if (replayTreeData.start.root !== rootStart) {
          throw new Error(
            `tree-data start root mismatch with current run: treeData.start.root=${replayTreeData.start.root} run.start.root=${rootStart}`,
          );
        }
        if (replayTreeData.start.count !== countStart) {
          throw new Error(
            `tree-data start count mismatch with current run: treeData.start.count=${replayTreeData.start.count} run.start.count=${countStart}`,
          );
        }
        if (replayTreeData.end.blockTag !== endCheckpoint.blockTag) {
          throw new Error(
            `tree-data end block mismatch with current run: treeData.end.blockTag=${replayTreeData.end.blockTag} run.end.blockTag=${endCheckpoint.blockTag}`,
          );
        }
        if (replayTreeData.end.root !== rootEnd) {
          throw new Error(
            `tree-data end root mismatch with current run: treeData.end.root=${replayTreeData.end.root} run.end.root=${rootEnd}`,
          );
        }
        if (replayTreeData.end.count !== countEnd) {
          throw new Error(
            `tree-data end count mismatch with current run: treeData.end.count=${replayTreeData.end.count} run.end.count=${countEnd}`,
          );
        }
      }

      const snapshotRootComputed = computeSnapshotRoot(snapshotInput.branch, snapshotInput.count);
      if (snapshotRootComputed !== snapshotInput.root) {
        throw new Error(
          `Snapshot root recomputation mismatch: provided=${snapshotInput.root} computed=${snapshotRootComputed}`,
        );
      }

      const eventsSorted = replayTreeData.events
        .slice()
        .sort((a, b) => (a.index === b.index ? a.messageId.localeCompare(b.messageId) : a.index < b.index ? -1 : 1));
      const seenReplayIndices = new Set<string>();
      const seenReplayMessageIds = new Set<string>();
      for (const event of eventsSorted) {
        const idx = event.index.toString();
        if (seenReplayIndices.has(idx)) {
          throw new Error(`Duplicate replay index in tree-data events: ${idx}`);
        }
        seenReplayIndices.add(idx);
        if (seenReplayMessageIds.has(event.messageId)) {
          throw new Error(`Duplicate replay messageId in tree-data events: ${event.messageId}`);
        }
        seenReplayMessageIds.add(event.messageId);
      }

      const expectedReplayLeaves = replayTreeData.end.count - replayTreeData.start.count;
      if (expectedReplayLeaves !== BigInt(eventsSorted.length)) {
        throw new Error(
          `Replay event count mismatch: expected=${expectedReplayLeaves} actual=${eventsSorted.length}`,
        );
      }

      for (let i = 0; i < eventsSorted.length; i++) {
        const expectedIndex = replayTreeData.start.count + BigInt(i);
        if (eventsSorted[i].index !== expectedIndex) {
          throw new Error(
            `Replay index gap: expected=${expectedIndex} actual=${eventsSorted[i].index}`,
          );
        }
      }

      const replayState = {
        branch: snapshotInput.branch.slice(),
        count: snapshotInput.count,
      };
      for (const event of eventsSorted) {
        merkleInsert(replayState, event.messageId);
      }
      if (replayState.count !== replayTreeData.end.count) {
        throw new Error(
          `Replay end count mismatch: expected=${replayTreeData.end.count} actual=${replayState.count}`,
        );
      }
      const computedEndRoot = merkleRootFromState(replayState);
      const replayMatch = computedEndRoot === replayTreeData.end.root;
      if (!replayMatch) {
        treeGlobalErrors.push(
          `Root replay mismatch: computedEndRoot=${computedEndRoot} onChainEndRoot=${replayTreeData.end.root}`,
        );
      }

      rootReplay = {
        enabled: true,
        skippedByConfig: false,
        dataSource: opts.treeDataFile ? "tree-data-file" : "in-run-tree-data",
        snapshotFile: opts.treeSnapshotFile ? toReportPath(opts.treeSnapshotFile) : undefined,
        treeDataFile: opts.treeDataFile ? toReportPath(opts.treeDataFile) : "[in-run]",
        snapshotValidated: true,
        replayedLeaves: eventsSorted.length,
        snapshotCount: snapshotInput.count.toString(),
        snapshotRootProvided: snapshotInput.root,
        snapshotRootComputed,
        startCheckpointRoot: replayTreeData.start.root,
        startCheckpointCount: replayTreeData.start.count.toString(),
        computedEndRoot,
        onChainEndRoot: replayTreeData.end.root,
        match: replayMatch,
      };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      treeGlobalErrors.push(`Root replay failed: ${msg}`);
      rootReplay = {
        enabled: true,
        skippedByConfig: false,
        dataSource: opts.treeDataFile ? "tree-data-file" : "in-run-tree-data",
        snapshotFile: opts.treeSnapshotFile ? toReportPath(opts.treeSnapshotFile) : undefined,
        treeDataFile: opts.treeDataFile ? toReportPath(opts.treeDataFile) : "[in-run]",
        snapshotValidated: false,
        replayedLeaves: 0,
        match: false,
      };
    }
  }

  const treeCheckFailures = {
    mailboxMatchesConfiguredMailbox: checkMailboxMatchesConfiguredMailbox ? 0 : 1,
    countDeltaMatchesInsertedEvents: checkCountDeltaMatchesInsertedEvents ? 0 : 1,
    noDuplicateMessageIds: checkNoDuplicateMessageIds ? 0 : 1,
    noDuplicateLeafIndices: checkNoDuplicateLeafIndices ? 0 : 1,
    noLeafIndexGaps: checkNoLeafIndexGaps ? 0 : 1,
    allSuccessfulExitInsertedEventsPresentAndMatching:
      checkAllSuccessfulExitInsertedEventsPresentAndMatching ? 0 : 1,
    rootReplayMatchesEndCheckpoint:
      opts.verifyRootConsistency && rootReplay.match === false ? 1 : 0,
  };
  const treeAllChecksPassed =
    Number(checkMailboxMatchesConfiguredMailbox) +
    Number(checkCountDeltaMatchesInsertedEvents) +
    Number(checkNoDuplicateMessageIds) +
    Number(checkNoDuplicateLeafIndices) +
    Number(checkNoLeafIndexGaps) +
    Number(checkAllSuccessfulExitInsertedEventsPresentAndMatching) +
    Number(!opts.verifyRootConsistency || rootReplay.match === true);
  const treeChecksTotal = Object.keys(treeCheckFailures).length;
  const treeAnyCheckFailed = treeChecksTotal - treeAllChecksPassed;

  const runEndedAt = new Date().toISOString();
  const outDataPath = resolve(outDataFile);
  const outChecksPath = resolve(outChecksFile);
  const outTreeDataPath = resolve(outTreeDataFile);
  const outTreeSnapshotPath = resolve(outTreeSnapshotFile);
  const outContractPreverifyPath = resolve(outContractPreverifyFile);
  const outEndCheckpointPath = resolve(outEndCheckpointFile);
  const outBundlePath = resolve(outBundleDir);
  const outDataReportPath = toReportPath(outDataPath);
  const outChecksReportPath = toReportPath(outChecksPath);
  const outTreeDataReportPath = toReportPath(outTreeDataPath);
  const outTreeSnapshotReportPath = toReportPath(outTreeSnapshotPath);
  const outContractPreverifyReportPath = toReportPath(outContractPreverifyPath);
  const outEndCheckpointReportPath = toReportPath(outEndCheckpointPath);
  const outBundleReportPath = toReportPath(outBundlePath);
  const commonMetadata: CommonMetadata = {
    startedAt: runStartedAt,
    endedAt: runEndedAt,
    generatedAt: runEndedAt,
    rpcUrl: opts.rpcUrl,
    chainId,
    fromBlock,
    toBlock,
    methodology: {
      path: METHODOLOGY_PATH,
      expectedSha256: opts.expectedMethodologySha256,
      sha256: methodologySha256,
    },
    links: {
      exitDataFile: outDataReportPath,
      treeDataFile: outTreeDataReportPath,
      checksFile: outChecksReportPath,
      contractPreverifyFile: outContractPreverifyReportPath,
      endCheckpointFile: outEndCheckpointReportPath,
    },
  };

  const dataOutput: DataReport = {
    metadata: {
      common: commonMetadata,
      kasExitBridge: keb,
      mailbox,
      checkpoints: {
        kasExitBridge: {
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
        },
      },
      totals: {
        exitTransactions: reports.length,
        successfulExitTransactions: successfulExitTxCount,
        revertedExitTransactions: revertedExitTxCount,
        totalUnlockSompi: totalUnlockSompi.toString(),
        totalBurnWei: totalBurnWei.toString(),
        totalBurnIKas: formatWithDecimals(totalBurnWei, 18),
      },
    },
    exits: reports.map((r) => ({
      status: r.status,
      requestId: r.requestId,
      blockNum: r.blockNum,
      txHash: r.txHash,
      unlockAmountSompi: r.unlockAmountSompi,
      burnWei: r.burnWei,
      messageId: r.messageId,
      dispatchMessage: r.dispatchMessage,
      dispatchMessageDecoded: (() => {
        if (!r.dispatchMessage) return null;
        const parsed = parseHyperlaneMessage(r.dispatchMessage);
        if (!parsed) return null;
        return {
          outer: parsed.outer,
          body: {
            format: parsed.body.format,
            requestId: parsed.body.requestId,
            unlockAmountSompi: parsed.body.unlockAmountSompi.toString(),
            originBurner: parsed.body.originBurner,
            kasPayoutAddressLength: parsed.body.kasPayoutAddressLength,
            kasPayoutAddress: parsed.body.kasPayoutAddress,
          },
        };
      })(),
      insertedIntoTreeIndex: r.insertedIntoTreeIndex,
    })),
  };

  const checksOutput: ChecksReport = {
    metadata: {
      common: commonMetadata,
      exit: {
        kasExitBridge: keb,
        mailbox,
        totals: {
          exitTransactions: reports.length,
          successfulExitTransactions: successfulExitTxCount,
          revertedExitTransactions: revertedExitTxCount,
          burnEvents: kebBurnLogs.length,
          exitRequestedEvents: kebExitLogs.length,
          dispatchEvents: dispatchEventsCount,
          totalUnlockSompi: totalUnlockSompi.toString(),
          totalBurnWei: totalBurnWei.toString(),
          totalBurnIKas: formatWithDecimals(totalBurnWei, 18),
          allChecksPassed,
          anyCheckFailed,
          kebEventCountsMatchSuccessfulExitTxCount,
        },
        checkFailures,
      },
      tree: {
        merkleTreeHook,
        mailbox: hookMailbox,
        expectedRootStart: opts.expectedRootStart,
        expectedRootEnd: opts.expectedRootEnd,
        rootReplay,
        checkpoints: {
          start: {
            blockTag: startCheckpoint.blockTag,
            root: rootStart,
            count: countStart.toString(),
          },
          end: {
            blockTag: endCheckpoint.blockTag,
            root: rootEnd,
            count: countEnd.toString(),
          },
        },
        totals: {
          insertedIntoTreeEvents: treeEvents.length,
          allChecksPassed: treeAllChecksPassed,
          anyCheckFailed: treeAnyCheckFailed + treeGlobalErrors.length,
        },
        checkFailures: treeCheckFailures,
      },
    },
    globalErrors: {
      exit: globalErrors,
      tree: treeGlobalErrors,
    },
    exits: reports.map((r) => ({
      status: r.status,
      requestId: r.requestId,
      blockNum: r.blockNum,
      txHash: r.txHash,
      eventCounts: r.eventCounts,
      checks: r.checks,
      errors: r.errors,
    })),
  };

  const treeDataOutput: TreeDataReport = {
    metadata: {
      common: commonMetadata,
      merkleTreeHook,
      mailbox: hookMailbox,
      expectedRootStart: opts.expectedRootStart,
      expectedRootEnd: opts.expectedRootEnd,
      checkpoints: {
        start: {
          blockTag: startCheckpoint.blockTag,
          root: rootStart,
          count: countStart.toString(),
        },
        end: {
          blockTag: endCheckpoint.blockTag,
          root: rootEnd,
          count: countEnd.toString(),
        },
      },
      totals: {
        insertedIntoTreeEvents: treeEvents.length,
      },
    },
    events: treeEvents
      .slice()
      .sort((a, b) =>
        a.blockNum === b.blockNum
          ? a.txHash === b.txHash
            ? a.index - b.index
            : a.txHash.localeCompare(b.txHash)
          : a.blockNum - b.blockNum,
      ),
  };
  const endSnapshot = await readMerkleTreeSnapshot(merkleTreeHookContract, endStateBlock);
  const treeSnapshotOutput: TreeSnapshotOutput = {
    version: 1,
    treeDepth: HYPERLANE_TREE_DEPTH,
    blockNum: endSnapshot.blockNum,
    count: endSnapshot.count.toString(),
    root: endSnapshot.root,
    branch: endSnapshot.branch,
  };
  const endDeltaCheckpoint: EndDeltaCheckpointOutput = {
    version: 1,
    blockTag: endStateBlock,
    merkleTreeHook: {
      root: rootEnd,
      count: countEnd.toString(),
      mailbox: hookMailbox,
    },
    kasExitBridge: {
      nextExitRequestId: kebEndCheckpoint.nextExitRequestId.toString(),
      totalBurnedWei: kebEndCheckpoint.totalBurnedWei.toString(),
    },
    sourceRange: {
      fromBlock,
      toBlock,
      startStateBlock,
      endStateBlock,
    },
  };
  mkdirSync(dirname(outDataPath), { recursive: true });
  mkdirSync(dirname(outChecksPath), { recursive: true });
  mkdirSync(dirname(outTreeDataPath), { recursive: true });
  mkdirSync(dirname(outTreeSnapshotPath), { recursive: true });
  mkdirSync(dirname(outContractPreverifyPath), { recursive: true });
  mkdirSync(dirname(outEndCheckpointPath), { recursive: true });
  writeFileSync(outDataPath, JSON.stringify(dataOutput, null, 2) + "\n", "utf8");
  writeFileSync(outChecksPath, JSON.stringify(checksOutput, null, 2) + "\n", "utf8");
  writeFileSync(outTreeDataPath, JSON.stringify(treeDataOutput, null, 2) + "\n", "utf8");
  writeFileSync(outTreeSnapshotPath, JSON.stringify(treeSnapshotOutput, null, 2) + "\n", "utf8");
  writeFileSync(
    outContractPreverifyPath,
    JSON.stringify(contractPreVerificationOutput, null, 2) + "\n",
    "utf8",
  );
  writeFileSync(outEndCheckpointPath, JSON.stringify(endDeltaCheckpoint, null, 2) + "\n", "utf8");
  buildPassABundle({
    outBundlePath,
    generatedAt: runEndedAt,
    opts,
    chainId,
    fromBlock,
    toBlock,
    keb,
    mailbox,
    merkleTreeHook,
    methodologySha256,
    dataOutput,
    checksOutput,
    treeDataOutput,
    treeSnapshotOutput,
    endDeltaCheckpoint,
    contractPreVerificationOutput,
    hookMailbox,
    startCheckpoint,
    endCheckpoint,
    kebStartCheckpoint,
    kebEndCheckpoint,
    successfulExitLogs: successfulExitLogs.map(serializeRpcValue),
    hookInsertedLogs: hookInsertedLogs.map(serializeRpcValue),
    kebBurnLogs: kebBurnLogs.map(serializeRpcValue),
    kebExitLogs: kebExitLogs.map(serializeRpcValue),
    candidateTxs: rawCandidateTxs,
    candidateReceipts: rawCandidateReceipts,
  });
  mainProgress("completed writing output files", true);

  printSummary(
    checksOutput,
    outDataReportPath,
    outChecksReportPath,
    outTreeDataReportPath,
    outTreeSnapshotReportPath,
    outContractPreverifyReportPath,
    outEndCheckpointReportPath,
    outBundleReportPath,
  );
}

async function collectExternalRequestExitTxHashes(
  provider: ethers.JsonRpcProvider,
  kasExitBridge: string,
  fromBlock: number,
  toBlock: number,
  onProgress?: (msg: string, force?: boolean) => void,
): Promise<string[]> {
  const kebLower = kasExitBridge.toLowerCase();
  const selectorLower = REQUEST_EXIT_SELECTOR.toLowerCase();
  const out: string[] = [];
  const totalBlocks = toBlock - fromBlock + 1;

  for (let block = fromBlock; block <= toBlock; block++) {
    const done = block - fromBlock + 1;
    onProgress?.(`block ${done}/${totalBlocks} (${block})`);
    const blockHex = ethers.toQuantity(block);
    const fullBlock = await provider.send("eth_getBlockByNumber", [blockHex, true]);
    const txs: any[] = Array.isArray(fullBlock?.transactions) ? fullBlock.transactions : [];
    for (const tx of txs) {
      const to = typeof tx?.to === "string" ? tx.to.toLowerCase() : "";
      const input = typeof tx?.input === "string" ? tx.input.toLowerCase() : "";
      if (to === kebLower && input.startsWith(selectorLower)) {
        out.push(String(tx.hash));
      }
    }
  }

  onProgress?.(`finished block scan, external requestExit txs=${out.length}`, true);
  return out;
}

async function getLogsChunked(
  provider: ethers.JsonRpcProvider,
  filter: {
    address?: string;
    topics?: ethers.TopicFilter;
    fromBlock: number;
    toBlock: number;
  },
  onProgress?: (msg: string, force?: boolean) => void,
): Promise<ethers.Log[]> {
  const from = filter.fromBlock;
  const to = filter.toBlock;
  if (from > to) return [];

  const logs: ethers.Log[] = [];
  const totalBlocks = to - from + 1;
  const chunkSpan = MAX_GET_LOGS_BLOCK_RANGE;

  let chunkIdx = 0;
  for (let start = from; start <= to; start += chunkSpan) {
    const end = Math.min(start + chunkSpan - 1, to);
    chunkIdx += 1;
    const processed = end - from + 1;
    onProgress?.(
      `chunk ${chunkIdx}: blocks ${start}..${end} (${processed}/${totalBlocks})`,
    );
    const part = await provider.getLogs({
      address: filter.address,
      topics: filter.topics,
      fromBlock: start,
      toBlock: end,
    });
    logs.push(...part);
  }

  onProgress?.(`completed ${chunkIdx} chunks, total logs=${logs.length}`, true);
  return logs;
}

async function tryDecodeInternalRequestExitFromTrace(
  provider: ethers.JsonRpcProvider,
  txHash: string,
  kasExitBridge: string,
  traceMode: "auto" | "on" | "off",
): Promise<
  | { ok: true; kasPayoutAddress: string; unlockAmountSompi: bigint }
  | { ok: false; error: string }
> {
  if (traceMode === "off") {
    return { ok: false, error: "Internal requestExit input is not decodable when --trace-mode=off" };
  }

  let trace: any;
  try {
    trace = await provider.send("debug_traceTransaction", [
      txHash,
      { tracer: "callTracer", timeout: "120s" },
    ]);
  } catch {
    if (traceMode === "on") {
      return { ok: false, error: "Trace required but debug_traceTransaction is unavailable" };
    }
    return { ok: false, error: "Trace unavailable: cannot decode internal requestExit input" };
  }

  const matches: Array<{ kasPayoutAddress: string; unlockAmountSompi: bigint }> = [];
  const selector = REQUEST_EXIT_SELECTOR.toLowerCase();
  const keb = kasExitBridge.toLowerCase();

  const walk = (node: any) => {
    if (!node || typeof node !== "object") return;
    const to = typeof node.to === "string" ? node.to.toLowerCase() : "";
    const input = typeof node.input === "string" ? node.input.toLowerCase() : "";
    const hasError = !!node.error;
    if (to === keb && input.startsWith(selector) && !hasError) {
      try {
        const decoded = KEB_IFACE.decodeFunctionData("requestExit", node.input);
        matches.push({
          kasPayoutAddress: String(decoded.kasPayoutAddress),
          unlockAmountSompi: BigInt(decoded.unlockAmountSompi),
        });
      } catch {
        // ignore malformed frame
      }
    }
    if (Array.isArray(node.calls)) {
      for (const c of node.calls) walk(c);
    }
  };

  walk(trace);

  if (matches.length === 0) {
    return { ok: false, error: "No successful internal requestExit call found in trace" };
  }
  if (matches.length > 1) {
    return { ok: false, error: "Multiple internal requestExit calls found in trace; ambiguous input binding" };
  }
  return { ok: true, kasPayoutAddress: matches[0].kasPayoutAddress, unlockAmountSompi: matches[0].unlockAmountSompi };
}

async function readMerkleTreeMailbox(contract: ethers.Contract): Promise<string> {
  const codeLatest = await contract.runner!.provider!.getCode(await contract.getAddress());
  if (codeLatest === "0x") {
    return ZERO_ADDRESS;
  }
  const mailboxRaw = await contract.mailbox();
  return ethers.getAddress(String(mailboxRaw));
}

async function readMerkleTreeCheckpoint(
  contract: ethers.Contract,
  blockTag: number,
): Promise<HookCheckpoint> {
  const provider = contract.runner!.provider!;
  const contractAddress = await contract.getAddress();
  const codeAtBlock = await provider.getCode(contractAddress, blockTag);
  if (codeAtBlock === "0x") {
    return {
      blockTag,
      root: ZERO_ROOT,
      count: 0n,
    };
  }

  const [rootRaw, countRaw] = await Promise.all([
    contract.root({ blockTag }),
    contract.count({ blockTag }),
  ]);
  return {
    blockTag,
    root: String(rootRaw).toLowerCase(),
    count: BigInt(countRaw),
  };
}

async function callCheckpointGetter(
  contract: ethers.Contract,
  getterName: string,
  blockTag: number,
): Promise<bigint | null> {
  const fnSig = `${getterName}()`;
  try {
    contract.interface.getFunction(fnSig);
  } catch {
    return null;
  }
  try {
    const out = await contract[getterName]({ blockTag });
    return BigInt(out);
  } catch {
    return null;
  }
}

async function readKasExitBridgeCheckpoint(
  contract: ethers.Contract,
  blockTag: number,
): Promise<KebCheckpoint> {
  const provider = contract.runner!.provider!;
  const contractAddress = await contract.getAddress();
  const codeAtBlock = await provider.getCode(contractAddress, blockTag);
  if (codeAtBlock === "0x") {
    return {
      blockTag,
      nextExitRequestId: 0n,
      totalBurnedWei: 0n,
    };
  }

  const requestIdGetters = ["nextExitRequested", "nextExitRequestId", "nextRequestId"];
  const totalBurnGetters = ["totalBurned", "totalBurnedWei", "totalBurn"];

  let nextExitRequestId: bigint | null = null;
  for (const getter of requestIdGetters) {
    nextExitRequestId = await callCheckpointGetter(contract, getter, blockTag);
    if (nextExitRequestId !== null) break;
  }

  let totalBurnedWei: bigint | null = null;
  for (const getter of totalBurnGetters) {
    totalBurnedWei = await callCheckpointGetter(contract, getter, blockTag);
    if (totalBurnedWei !== null) break;
  }

  if (nextExitRequestId === null) {
    throw new Error(
      `Cannot read KEB next requestId at block ${blockTag}. Tried getters: ${requestIdGetters.join(", ")}`,
    );
  }
  if (totalBurnedWei === null) {
    throw new Error(
      `Cannot read KEB total burned at block ${blockTag}. Tried getters: ${totalBurnGetters.join(", ")}`,
    );
  }

  return {
    blockTag,
    nextExitRequestId,
    totalBurnedWei,
  };
}

async function readMerkleTreeSnapshot(
  contract: ethers.Contract,
  blockTag: number,
): Promise<{ blockNum: number; root: string; count: bigint; branch: string[] }> {
  const provider = contract.runner!.provider!;
  const contractAddress = await contract.getAddress();
  const codeAtBlock = await provider.getCode(contractAddress, blockTag);
  if (codeAtBlock === "0x") {
    return {
      blockNum: blockTag,
      root: ZERO_ROOT,
      count: 0n,
      branch: Array.from({ length: HYPERLANE_TREE_DEPTH }, () => ZERO_ROOT),
    };
  }

  const [rootRaw, treeRaw] = await Promise.all([
    contract.root({ blockTag }),
    contract.tree({ blockTag }),
  ]);
  const branchRaw = Array.isArray(treeRaw?.branch) ? treeRaw.branch : treeRaw?.[0];
  const countRaw = treeRaw?.count ?? treeRaw?.[1];
  if (!Array.isArray(branchRaw) || branchRaw.length !== HYPERLANE_TREE_DEPTH) {
    throw new Error("Invalid tree().branch shape while reading end snapshot");
  }
  return {
    blockNum: blockTag,
    root: String(rootRaw).toLowerCase(),
    count: BigInt(countRaw),
    branch: branchRaw.map((v: unknown, i: number) =>
      normalizeBytes32ValueOrThrow(String(v), `snapshot.branch[${i}]`),
    ),
  };
}

function normalizeSlotHexOrThrow(value: string, field: string): string {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`Invalid ${field}: expected 0x-prefixed 32-byte hex`);
  }
  return value.toLowerCase();
}

function decodeSlotValue(raw: string, mode: ContractSlotExpected["decode"]): string {
  const rawNorm = normalizeSlotHexOrThrow(raw, "slotRaw");
  if (mode === "raw-bytes32") return rawNorm;
  if (mode === "address-right-20") {
    const tail = `0x${rawNorm.slice(-40)}`;
    return ethers.getAddress(tail);
  }
  if (mode === "uint256-decimal") {
    return BigInt(rawNorm).toString();
  }
  throw new Error(`Unsupported slot decode mode: ${mode}`);
}

function parseContractExpectedValuesOrThrow(
  path: string,
  expectedChainId: number,
): ContractExpectedValuesFile {
  const raw = loadJsonFileOrThrow(path, "contract expected values");
  if (!raw || typeof raw !== "object") {
    throw new Error(`Invalid contract expected values file "${path}": expected object`);
  }
  const o = raw as Record<string, unknown>;
  if (o.schemaVersion !== 1) {
    throw new Error(`Invalid contract expected values schemaVersion in "${path}"`);
  }
  if (Number(o.chainId) !== expectedChainId) {
    throw new Error(
      `contract expected values chainId mismatch: file=${String(o.chainId)} runtime=${expectedChainId}`,
    );
  }
  if (!Array.isArray(o.contracts)) {
    throw new Error(`Invalid contract expected values file "${path}": contracts[] missing`);
  }
  const contracts: ContractExpectedValuesEntry[] = o.contracts.map((item, i) => {
    if (!item || typeof item !== "object") {
      throw new Error(`Invalid contracts[${i}] in "${path}"`);
    }
    const c = item as Record<string, unknown>;
    const id = String(c.id);
    if (id !== "kasExitBridge" && id !== "mailbox" && id !== "merkleTreeHook") {
      throw new Error(`Invalid contracts[${i}].id "${id}" in "${path}"`);
    }
    const address = ethers.getAddress(String(c.address));
    const expectedCodeHash = normalizeBytes32ValueOrThrow(
      String(c.expectedCodeHash),
      `contracts[${i}].expectedCodeHash`,
    );
    if (!Array.isArray(c.slots)) {
      throw new Error(`Invalid contracts[${i}].slots in "${path}"`);
    }
    const slots: ContractSlotExpected[] = c.slots.map((slotRaw, j) => {
      if (!slotRaw || typeof slotRaw !== "object") {
        throw new Error(`Invalid contracts[${i}].slots[${j}] in "${path}"`);
      }
      const s = slotRaw as Record<string, unknown>;
      const decode = String(s.decode);
      if (decode !== "raw-bytes32" && decode !== "address-right-20" && decode !== "uint256-decimal") {
        throw new Error(`Invalid decode mode in contracts[${i}].slots[${j}]`);
      }
      const expectedRaw = s.expectedRaw === undefined ? undefined : normalizeSlotHexOrThrow(String(s.expectedRaw), `contracts[${i}].slots[${j}].expectedRaw`);
      const expectedDecoded =
        s.expectedDecoded === undefined ? undefined : String(s.expectedDecoded);
      if (expectedRaw === undefined && expectedDecoded === undefined) {
        throw new Error(
          `contracts[${i}].slots[${j}] must define expectedRaw and/or expectedDecoded`,
        );
      }
      return {
        name: String(s.name),
        slot: normalizeSlotHexOrThrow(String(s.slot), `contracts[${i}].slots[${j}].slot`),
        decode,
        expectedRaw,
        expectedDecoded,
      };
    });
    return {
      id: id as ContractExpectedValuesEntry["id"],
      address,
      expectedCodeHash,
      slots,
    };
  });
  return {
    schemaVersion: 1,
    chainId: expectedChainId,
    contracts,
  };
}

async function verifyContractAtBlock(
  provider: ethers.JsonRpcProvider,
  entry: ContractExpectedValuesEntry,
  blockTag: number,
): Promise<ContractBlockVerification> {
  const code = await provider.getCode(entry.address, blockTag);
  const actualCodeHash = ethers.keccak256(code).toLowerCase();
  const codeHashMatches = actualCodeHash === entry.expectedCodeHash.toLowerCase();
  const slots: ContractSlotObserved[] = [];
  for (const slot of entry.slots) {
    const actualRaw = normalizeSlotHexOrThrow(
      await provider.getStorage(entry.address, slot.slot, blockTag),
      `${entry.id}:${slot.name}.actualRaw`,
    );
    const actualDecoded = decodeSlotValue(actualRaw, slot.decode);
    const rawMatches =
      slot.expectedRaw === undefined || actualRaw === normalizeSlotHexOrThrow(slot.expectedRaw, `${entry.id}:${slot.name}.expectedRaw`);
    const decodedMatches =
      slot.expectedDecoded === undefined ||
      actualDecoded.toLowerCase() === slot.expectedDecoded.toLowerCase();
    slots.push({
      name: slot.name,
      slot: slot.slot,
      decode: slot.decode,
      expectedRaw: slot.expectedRaw,
      expectedDecoded: slot.expectedDecoded,
      actualRaw,
      actualDecoded,
      rawMatches,
      decodedMatches,
      matches: rawMatches && decodedMatches,
    });
  }
  return {
    blockTag,
    expectedCodeHash: entry.expectedCodeHash.toLowerCase(),
    actualCodeHash,
    codeHashMatches,
    slots,
    allMatch: codeHashMatches && slots.every((s) => s.matches),
  };
}

async function runContractPreVerification(args: {
  provider: ethers.JsonRpcProvider;
  expectedValuesFile: string;
  chainId: number;
  startStateBlock: number;
  endStateBlock: number;
  keb: string;
  mailbox: string;
  merkleTreeHook: string;
}): Promise<ContractPreVerificationOutput> {
  const expectedPath = resolve(args.expectedValuesFile);
  if (!existsSync(expectedPath)) {
    throw new Error(`Expected-values file not found: ${expectedPath}`);
  }
  const expected = parseContractExpectedValuesOrThrow(expectedPath, args.chainId);
  const byId = new Map(expected.contracts.map((c) => [c.id, c]));
  const expectedAddressMap: Record<ContractExpectedValuesEntry["id"], string> = {
    kasExitBridge: args.keb,
    mailbox: args.mailbox,
    merkleTreeHook: args.merkleTreeHook,
  };
  for (const id of Object.keys(expectedAddressMap) as ContractExpectedValuesEntry["id"][]) {
    const e = byId.get(id);
    if (!e) throw new Error(`Expected-values file missing entry for "${id}"`);
    if (e.address.toLowerCase() !== expectedAddressMap[id].toLowerCase()) {
      throw new Error(
        `Expected-values address mismatch for ${id}: file=${e.address} runtime=${expectedAddressMap[id]}`,
      );
    }
  }

  const contracts: ContractPreVerificationOutput["contracts"] = [];
  for (const id of ["kasExitBridge", "mailbox", "merkleTreeHook"] as ContractExpectedValuesEntry["id"][]) {
    const entry = byId.get(id)!;
    const [start, end] = await Promise.all([
      verifyContractAtBlock(args.provider, entry, args.startStateBlock),
      verifyContractAtBlock(args.provider, entry, args.endStateBlock),
    ]);
    contracts.push({
      id,
      address: entry.address,
      start,
      end,
      allMatch: start.allMatch && end.allMatch,
    });
  }
  return {
    metadata: {
      expectedValuesFile: toReportPath(expectedPath),
      expectedValuesSha256: sha256FileHex(expectedPath),
      chainId: args.chainId,
      startStateBlock: args.startStateBlock,
      endStateBlock: args.endStateBlock,
    },
    contracts,
  };
}

function serializeRpcValue(value: any): any {
  if (value === null || value === undefined) return value;
  if (typeof value === "bigint") return value.toString();
  if (Array.isArray(value)) return value.map((v) => serializeRpcValue(v));
  if (typeof value === "object") {
    if (typeof value.toJSON === "function") {
      return serializeRpcValue(value.toJSON());
    }
    const out: Record<string, any> = {};
    for (const [k, v] of Object.entries(value)) {
      if (typeof v === "function") continue;
      out[k] = serializeRpcValue(v);
    }
    return out;
  }
  return value;
}

function sha256Utf8(content: string): string {
  return createHash("sha256").update(content, "utf8").digest("hex");
}

function listFilesRecursive(dir: string): string[] {
  const out: string[] = [];
  const walk = (d: string) => {
    for (const name of readdirSync(d)) {
      const p = join(d, name);
      const st = statSync(p);
      if (st.isDirectory()) walk(p);
      else out.push(p);
    }
  };
  walk(dir);
  return out.sort((a, b) => a.localeCompare(b));
}

function writeJsonFile(path: string, value: any) {
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, JSON.stringify(value, null, 2) + "\n", "utf8");
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

function toManifestIntegralPayload(manifest: PassABundleManifest): Record<string, unknown> {
  const clone = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
  delete clone.signature;
  const bundleIntegral = (clone.bundleIntegral ?? {}) as Record<string, unknown>;
  delete bundleIntegral.value;
  clone.bundleIntegral = bundleIntegral;
  return clone;
}

function toManifestIdentityPayload(manifest: PassABundleManifest): Record<string, unknown> {
  const clone = JSON.parse(JSON.stringify(manifest)) as Record<string, unknown>;
  const payloadVersion =
    Number((manifest.bundleIdentity as { payloadVersion?: unknown } | undefined)?.payloadVersion ?? 1) || 1;
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

function computeManifestIntegral(manifest: PassABundleManifest): { payload: string; sha256: string } {
  const payload = canonicalizeJson(toManifestIntegralPayload(manifest));
  return {
    payload,
    sha256: sha256Utf8(payload),
  };
}

function computeManifestIdentity(manifest: PassABundleManifest): { payload: string; sha256: string } {
  const payload = canonicalizeJson(toManifestIdentityPayload(manifest));
  return {
    payload,
    sha256: sha256Utf8(payload),
  };
}

function signManifestPayload(args: {
  payload: string;
  privateKeyPath: string;
  keyId: string;
  keyTypeHint?: "rsa" | "ecdsa";
}): { signatureBase64: string; keyType: "rsa" | "ecdsa"; keyId: string } {
  const privatePem = readFileSync(args.privateKeyPath, "utf8");
  const privateKey = createPrivateKey(privatePem);
  const asymmetricType = privateKey.asymmetricKeyType;
  const keyType: "rsa" | "ecdsa" =
    args.keyTypeHint ??
    (asymmetricType === "rsa" || asymmetricType === "rsa-pss"
      ? "rsa"
      : asymmetricType === "ec"
        ? "ecdsa"
        : (() => {
            throw new Error(
              `Unsupported private key type "${String(asymmetricType)}"; use RSA or EC`,
            );
          })());
  const signature = cryptoSign("sha256", Buffer.from(args.payload, "utf8"), privateKey).toString(
    "base64",
  );
  return { signatureBase64: signature, keyType, keyId: args.keyId };
}

function buildPassABundle(args: {
  outBundlePath: string;
  generatedAt: string;
  opts: CliOpts;
  chainId: number;
  fromBlock: number;
  toBlock: number;
  keb: string;
  mailbox: string;
  merkleTreeHook: string;
  methodologySha256: string;
  dataOutput: DataReport;
  checksOutput: ChecksReport;
  treeDataOutput: TreeDataReport;
  treeSnapshotOutput: TreeSnapshotOutput;
  endDeltaCheckpoint: EndDeltaCheckpointOutput;
  contractPreVerificationOutput: ContractPreVerificationOutput;
  hookMailbox: string;
  startCheckpoint: HookCheckpoint;
  endCheckpoint: HookCheckpoint;
  kebStartCheckpoint: KebCheckpoint;
  kebEndCheckpoint: KebCheckpoint;
  successfulExitLogs: any[];
  hookInsertedLogs: any[];
  kebBurnLogs: any[];
  kebExitLogs: any[];
  candidateTxs: any[];
  candidateReceipts: any[];
}) {
  const derivedDir = join(args.outBundlePath, "derived");
  const rawDir = join(args.outBundlePath, "raw");
  const rawTxDir = join(rawDir, "tx");

  writeJsonFile(join(derivedDir, "exit.data.json"), args.dataOutput);
  writeJsonFile(join(derivedDir, "checks.json"), args.checksOutput);
  writeJsonFile(join(derivedDir, "tree.data.json"), args.treeDataOutput);
  writeJsonFile(join(derivedDir, "tree.snapshot.json"), args.treeSnapshotOutput);
  writeJsonFile(join(derivedDir, "checkpoint.end.json"), args.endDeltaCheckpoint);
  writeJsonFile(
    join(derivedDir, "contract.preverify.json"),
    args.contractPreVerificationOutput,
  );

  writeJsonFile(join(rawDir, "checkpoints.json"), {
    merkleTreeHook: {
      start: {
        blockTag: args.startCheckpoint.blockTag,
        root: args.startCheckpoint.root,
        count: args.startCheckpoint.count.toString(),
      },
      end: {
        blockTag: args.endCheckpoint.blockTag,
        root: args.endCheckpoint.root,
        count: args.endCheckpoint.count.toString(),
      },
      mailbox: args.hookMailbox,
    },
    kasExitBridge: {
      start: {
        blockTag: args.kebStartCheckpoint.blockTag,
        nextExitRequestId: args.kebStartCheckpoint.nextExitRequestId.toString(),
        totalBurnedWei: args.kebStartCheckpoint.totalBurnedWei.toString(),
      },
      end: {
        blockTag: args.kebEndCheckpoint.blockTag,
        nextExitRequestId: args.kebEndCheckpoint.nextExitRequestId.toString(),
        totalBurnedWei: args.kebEndCheckpoint.totalBurnedWei.toString(),
      },
    },
  });
  writeJsonFile(join(rawDir, "successful_exit_logs.json"), args.successfulExitLogs);
  writeJsonFile(join(rawDir, "hook_inserted_logs.json"), args.hookInsertedLogs);
  writeJsonFile(join(rawDir, "keb_burn_logs.json"), args.kebBurnLogs);
  writeJsonFile(join(rawDir, "keb_exit_logs.json"), args.kebExitLogs);

  mkdirSync(rawTxDir, { recursive: true });
  for (const tx of args.candidateTxs) {
    const txHash = String(tx?.hash ?? "").toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(txHash)) continue;
    writeJsonFile(join(rawTxDir, `${txHash}.tx.json`), tx);
  }
  for (const rcpt of args.candidateReceipts) {
    const txHash = String(rcpt?.hash ?? "").toLowerCase();
    if (!/^0x[0-9a-f]{64}$/.test(txHash)) continue;
    writeJsonFile(join(rawTxDir, `${txHash}.receipt.json`), rcpt);
  }

  const files = listFilesRecursive(args.outBundlePath)
    .filter((p) => {
      const rel = relative(args.outBundlePath, p);
      return rel !== "manifest.json" && rel !== MANIFEST_SIGNATURE_FILE;
    })
    .map((p) => {
      const rel = relative(args.outBundlePath, p);
      const content = readFileSync(p, "utf8");
      return {
        path: rel,
        sha256: sha256Utf8(content),
        size: Buffer.byteLength(content, "utf8"),
      };
    });

  const manifest: PassABundleManifest = {
    schemaVersion: 1,
    kind: "kas-exit-bridge-pass-a-bundle",
    createdAt: args.generatedAt,
    methodology: {
      path: METHODOLOGY_PATH,
      expectedSha256: args.opts.expectedMethodologySha256,
      sha256: args.methodologySha256,
    },
    context: {
      rpcUrl: args.opts.rpcUrl,
      chainId: args.chainId,
      fromBlock: args.fromBlock,
      toBlock: args.toBlock,
      kasExitBridge: args.keb,
      mailbox: args.mailbox,
      merkleTreeHook: args.merkleTreeHook,
    },
    artifactChecksums: {
      exitDataSha256: sha256Utf8(JSON.stringify(args.dataOutput, null, 2) + "\n"),
      checksSha256: sha256Utf8(JSON.stringify(args.checksOutput, null, 2) + "\n"),
      treeDataSha256: sha256Utf8(JSON.stringify(args.treeDataOutput, null, 2) + "\n"),
      checkpointEndSha256: sha256Utf8(JSON.stringify(args.endDeltaCheckpoint, null, 2) + "\n"),
      contractPreVerificationSha256: sha256Utf8(
        JSON.stringify(args.contractPreVerificationOutput, null, 2) + "\n",
      ),
    },
    bundleIntegral: {
      algorithm: "sha256",
      canonicalization: BUNDLE_INTEGRAL_CANONICALIZATION,
      value: "",
    },
    bundleIdentity: {
      algorithm: "sha256",
      canonicalization: BUNDLE_IDENTITY_CANONICALIZATION,
      payloadVersion: BUNDLE_IDENTITY_PAYLOAD_VERSION,
      value: "",
    },
    files,
  };
  const identity = computeManifestIdentity(manifest);
  manifest.bundleIdentity.value = identity.sha256;
  const integral = computeManifestIntegral(manifest);
  manifest.bundleIntegral.value = integral.sha256;
  if (args.opts.manifestSigningPrivateKey) {
    const signed = signManifestPayload({
      payload: integral.payload,
      privateKeyPath: resolve(args.opts.manifestSigningPrivateKey),
      keyId: args.opts.manifestSigningKeyId ?? "local-manifest-key",
      keyTypeHint: args.opts.manifestSigningKeyType,
    });
    writeFileSync(join(args.outBundlePath, MANIFEST_SIGNATURE_FILE), `${signed.signatureBase64}\n`, "utf8");
    manifest.signature = {
      algorithm: "sha256-sign",
      keyType: signed.keyType,
      keyId: signed.keyId,
      signatureFile: MANIFEST_SIGNATURE_FILE,
      signatureEncoding: "base64",
    };
  }
  writeJsonFile(join(args.outBundlePath, "manifest.json"), manifest);
}

function parseCli(argv: string[]): CliOpts {
  const map = new Map<string, string>();
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith("--")) continue;
    if (
      k === "--include-external-request-exit-scan" ||
      k === "--verify-root-consistency"
    ) {
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

  const start = map.get("--start-block");
  if (!start) {
    throw new Error("Required argument: --start-block <block|latest|latest +/- N>");
  }
  if (map.has("--out-tree-checks")) {
    throw new Error(
      "Unsupported argument: --out-tree-checks (tree checks were merged into --out-checks)",
    );
  }
  const traceModeRaw = map.get("--trace-mode") ?? "auto";
  if (traceModeRaw !== "auto" && traceModeRaw !== "on" && traceModeRaw !== "off") {
    throw new Error(`Invalid --trace-mode "${traceModeRaw}". Use one of: auto, on, off`);
  }
  const traceMode = traceModeRaw as CliOpts["traceMode"];
  const verifyRootConsistency = map.get("--verify-root-consistency") === "true";
  const treeSnapshotFile = map.get("--tree-snapshot-file");
  const treeDataFile = map.get("--tree-data-file");
  if (verifyRootConsistency && !treeSnapshotFile) {
    throw new Error("Missing required argument for replay mode: --tree-snapshot-file <path>");
  }
  const cliPrivate = map.get("--manifest-signing-private-key");
  const envPrivate = process.env[ENV_SIGNING_PRIVATE_KEY];
  const configPrivate = shared?.config.kasExitBridge.signing.privateKeyPath
    ? normalizeConfigPathMaybe(shared, shared.config.kasExitBridge.signing.privateKeyPath)
    : undefined;
  const defaultPrivate = normalizePath(DEFAULT_SIGNING_PRIVATE_KEY);
  const manifestSigningPrivateKey =
    normalizePathMaybe(cliPrivate) ??
    normalizePathMaybe(envPrivate) ??
    configPrivate ??
    (existsSync(resolve(defaultPrivate)) ? defaultPrivate : undefined);
  const manifestSigningKeyId =
    map.get("--manifest-signing-key-id") ??
    process.env[ENV_SIGNING_KEY_ID] ??
    shared?.config.kasExitBridge.signing.keyId;
  const manifestSigningKeyTypeRaw =
    map.get("--manifest-signing-key-type") ??
    process.env[ENV_SIGNING_KEY_TYPE] ??
    shared?.config.kasExitBridge.signing.keyType;
  if ((map.has("--manifest-signing-key-id") || process.env[ENV_SIGNING_KEY_ID]) && !manifestSigningPrivateKey) {
    throw new Error(
      "--manifest-signing-key-id was provided but no signing private key was found via CLI, env, or default path",
    );
  }
  if (map.has("--manifest-signing-private-key") && manifestSigningPrivateKey && !existsSync(resolve(manifestSigningPrivateKey))) {
    throw new Error(`--manifest-signing-private-key not found: ${resolve(manifestSigningPrivateKey)}`);
  }

  return {
    configPath,
    rpcUrl:
      map.get("--rpc-url") ??
      process.env[ENV_RPC_URL] ??
      shared?.config.kasExitBridge.rpcUrl ??
      DEFAULT_RPC,
    kasExitBridge:
      map.get("--kas-exit-bridge") ??
      process.env[ENV_KEB_ADDRESS] ??
      shared?.config.kasExitBridge.addresses.kasExitBridge ??
      DEFAULT_KEB,
    mailbox:
      map.get("--mailbox") ??
      process.env[ENV_MAILBOX_ADDRESS] ??
      shared?.config.kasExitBridge.addresses.mailbox ??
      DEFAULT_MAILBOX,
    merkleTreeHook:
      map.get("--merkle-tree-hook") ??
      process.env[ENV_MERKLE_TREE_HOOK_ADDRESS] ??
      shared?.config.kasExitBridge.addresses.merkleTreeHook ??
      DEFAULT_MERKLE_TREE_HOOK,
    contractExpectedValuesFile:
      normalizePathMaybeWithConfig(
        shared,
        map.get("--contract-expected-values-file") ??
          process.env[ENV_CONTRACT_EXPECTED_VALUES_FILE] ??
          shared?.config.kasExitBridge.expectedValuesFile,
      ) ?? DEFAULT_CONTRACT_EXPECTED_VALUES_FILE,
    traceMode,
    includeExternalRequestExitScan: map.get("--include-external-request-exit-scan") === "true",
    verifyRootConsistency,
    treeSnapshotFile,
    treeDataFile,
    expectedRootStart: normalizeBytes32OrThrow(map.get("--expected-root-start"), "--expected-root-start"),
    expectedRootEnd: normalizeBytes32OrThrow(map.get("--expected-root-end"), "--expected-root-end"),
    expectedMethodologySha256: normalizeSha256OrThrow(
      map.get("--expected-methodology-sha256") ?? DEFAULT_EXPECTED_METHODOLOGY_SHA256,
      "--expected-methodology-sha256",
    ),
    startBlockExpr: start,
    endBlockExpr: map.get("--end-block") ?? "latest - 100",
    outBase: map.get("--out"),
    outDataFile: map.get("--out-data"),
    outChecksFile: map.get("--out-checks"),
    outTreeDataFile: map.get("--out-tree-data"),
    outTreeSnapshotFile: map.get("--out-tree-snapshot"),
    outContractPreverifyFile: map.get("--out-contract-preverify"),
    outBundleDir: map.get("--out-bundle-dir"),
    previousCheckpointFile: map.get("--previous-checkpoint-file"),
    outEndCheckpointFile: map.get("--out-end-checkpoint"),
    manifestSigningPrivateKey,
    manifestSigningKeyId,
    manifestSigningKeyType: (() => {
      const raw = manifestSigningKeyTypeRaw;
      if (!raw) return undefined;
      if (raw !== "rsa" && raw !== "ecdsa") {
        throw new Error(`Invalid --manifest-signing-key-type "${raw}". Use rsa or ecdsa`);
      }
      return raw;
    })(),
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
  return normalizeConfigPathMaybe(shared, pathValue);
}

function normalizeConfigPathMaybe(
  shared: { configPath: string },
  pathValue: string | undefined,
): string | undefined {
  if (!pathValue) return undefined;
  return resolvePathFromConfig(pathValue, shared.configPath);
}

function normalizeSha256OrThrow(value: string, flag: string): string {
  const v = value.trim().toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(v)) {
    throw new Error(`Invalid ${flag}: expected 64-char lowercase hex SHA-256`);
  }
  return v;
}

function normalizeBytes32OrThrow(value: string | undefined, flag: string): string | undefined {
  if (!value) return undefined;
  return normalizeBytes32ValueOrThrow(value, flag);
}

function normalizeBytes32ValueOrThrow(value: string, field: string): string {
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) {
    throw new Error(`Invalid ${field}: expected 0x-prefixed 32-byte hex`);
  }
  return value.toLowerCase();
}

function parseBigIntStringOrThrow(value: unknown, field: string): bigint {
  if (typeof value !== "string" || !/^\d+$/.test(value)) {
    throw new Error(`Invalid ${field}: expected non-negative integer string`);
  }
  return BigInt(value);
}

function parseNonNegativeIntegerOrThrow(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isInteger(value) || value < 0) {
    throw new Error(`Invalid ${field}: expected non-negative integer`);
  }
  return value;
}

function parseDeltaAnchorCheckpointOrThrow(raw: unknown): DeltaAnchorCheckpoint {
  if (raw === null || typeof raw !== "object") {
    throw new Error("Invalid checkpoint file: expected object");
  }
  const o = raw as Record<string, unknown>;
  const mRootObj = (o.merkleTreeHook ??
    (o.checkpoints as any)?.merkleTreeHook ??
    {}) as Record<string, unknown>;
  const kRootObj = (o.kasExitBridge ??
    (o.checkpoints as any)?.kasExitBridge ??
    {}) as Record<string, unknown>;
  const mObj = (mRootObj.end ?? mRootObj) as Record<string, unknown>;
  const kObj = (kRootObj.end ?? kRootObj) as Record<string, unknown>;

  const blockTag = parseNonNegativeIntegerOrThrow(
    mObj.blockTag ?? o.blockTag,
    "checkpoint.blockTag",
  );
  const root = normalizeBytes32ValueOrThrow(String(mObj.root), "checkpoint.merkleTreeHook.root");
  const count = parseBigIntStringOrThrow(mObj.count, "checkpoint.merkleTreeHook.count");
  const nextExitRequestId = parseBigIntStringOrThrow(
    kObj.nextExitRequestId,
    "checkpoint.kasExitBridge.nextExitRequestId",
  );
  const totalBurnedWei = parseBigIntStringOrThrow(
    kObj.totalBurnedWei,
    "checkpoint.kasExitBridge.totalBurnedWei",
  );

  return {
    blockTag,
    merkleTreeHook: {
      root,
      count,
    },
    kasExitBridge: {
      nextExitRequestId,
      totalBurnedWei,
    },
  };
}

function loadJsonFileOrThrow(path: string, label: string): unknown {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Failed to load ${label} file "${path}": ${msg}`);
  }
}

function toReportPath(path: string): string {
  const rel = relative(process.cwd(), resolve(path));
  return rel === "" ? "." : rel;
}

function validateSnapshotOrThrow(raw: unknown): TreeSnapshotInput {
  if (!raw || typeof raw !== "object") {
    throw new Error("Invalid tree snapshot: expected object");
  }
  const o = raw as Record<string, unknown>;
  const blockNum = parseNonNegativeIntegerOrThrow(o.blockNum, "snapshot.blockNum");
  const count = parseBigIntStringOrThrow(o.count, "snapshot.count");
  const root = normalizeBytes32ValueOrThrow(String(o.root), "snapshot.root");
  const treeDepthRaw = o.treeDepth;
  if (treeDepthRaw !== undefined && treeDepthRaw !== HYPERLANE_TREE_DEPTH) {
    throw new Error(
      `Invalid snapshot.treeDepth: expected ${HYPERLANE_TREE_DEPTH}, got ${String(treeDepthRaw)}`,
    );
  }
  if (!Array.isArray(o.branch)) {
    throw new Error("Invalid tree snapshot: branch must be an array");
  }
  if (o.branch.length !== HYPERLANE_TREE_DEPTH) {
    throw new Error(
      `Invalid tree snapshot: branch length must be ${HYPERLANE_TREE_DEPTH}, got ${o.branch.length}`,
    );
  }
  const branch = o.branch.map((v, i) =>
    normalizeBytes32ValueOrThrow(String(v), `snapshot.branch[${i}]`),
  );
  return {
    version: typeof o.version === "number" ? o.version : undefined,
    treeDepth:
      typeof o.treeDepth === "number" ? o.treeDepth : undefined,
    blockNum,
    count,
    root,
    branch,
  };
}

function validateTreeDataForReplayOrThrow(raw: unknown): ReplayTreeDataInput {
  if (!raw || typeof raw !== "object") {
    throw new Error("Invalid tree-data file: expected object");
  }
  const o = raw as Record<string, unknown>;
  const metadata = o.metadata as Record<string, unknown> | undefined;
  const checkpoints = (metadata?.checkpoints ?? {}) as Record<string, unknown>;
  const start = (checkpoints.start ?? {}) as Record<string, unknown>;
  const end = (checkpoints.end ?? {}) as Record<string, unknown>;

  const startBlockTag = parseNonNegativeIntegerOrThrow(
    start.blockTag,
    "treeData.metadata.checkpoints.start.blockTag",
  );
  const endBlockTag = parseNonNegativeIntegerOrThrow(
    end.blockTag,
    "treeData.metadata.checkpoints.end.blockTag",
  );
  const startRoot = normalizeBytes32ValueOrThrow(
    String(start.root),
    "treeData.metadata.checkpoints.start.root",
  );
  const endRoot = normalizeBytes32ValueOrThrow(
    String(end.root),
    "treeData.metadata.checkpoints.end.root",
  );
  const startCount = parseBigIntStringOrThrow(
    start.count,
    "treeData.metadata.checkpoints.start.count",
  );
  const endCount = parseBigIntStringOrThrow(
    end.count,
    "treeData.metadata.checkpoints.end.count",
  );
  if (endCount < startCount) {
    throw new Error(
      `Invalid tree-data checkpoints: end.count (${endCount}) < start.count (${startCount})`,
    );
  }

  if (!Array.isArray(o.events)) {
    throw new Error("Invalid tree-data file: events must be an array");
  }
  const events = o.events.map((evt, i) => {
    if (!evt || typeof evt !== "object") {
      throw new Error(`Invalid tree-data event at index ${i}: expected object`);
    }
    const e = evt as Record<string, unknown>;
    const messageId = normalizeBytes32ValueOrThrow(
      String(e.messageId),
      `treeData.events[${i}].messageId`,
    );
    const indexNum = parseNonNegativeIntegerOrThrow(
      e.index,
      `treeData.events[${i}].index`,
    );
    return { messageId, index: BigInt(indexNum) };
  });

  return {
    start: {
      blockTag: startBlockTag,
      root: startRoot,
      count: startCount,
    },
    end: {
      blockTag: endBlockTag,
      root: endRoot,
      count: endCount,
    },
    events,
  };
}

function sha256FileHex(path: string): string {
  try {
    const data = readFileSync(path);
    return createHash("sha256").update(data).digest("hex");
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    throw new Error(`Failed to read methodology file "${path}": ${msg}`);
  }
}

function resolveBlockExpr(expr: string, latest: number): number {
  const trimmed = expr.trim().toLowerCase();
  if (/^\d+$/.test(trimmed)) {
    return Number(trimmed);
  }
  if (trimmed === "latest") {
    return latest;
  }
  const m = /^latest\s*([+-])\s*(\d+)$/.exec(trimmed);
  if (!m) {
    throw new Error(`Invalid block expression: "${expr}"`);
  }
  const n = Number(m[2]);
  return m[1] === "+" ? latest + n : latest - n;
}

function parseInsertedIntoTree(log: ethers.Log): { messageId: string; index: number } | null {
  // Case A: indexed messageId
  if (log.topics.length >= 2) {
    const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["uint32"], log.data);
    return { messageId: log.topics[1], index: Number(decoded[0]) };
  }

  // Case B: non-indexed messageId
  const decoded = ethers.AbiCoder.defaultAbiCoder().decode(["bytes32", "uint32"], log.data);
  return { messageId: String(decoded[0]), index: Number(decoded[1]) };
}

function parseHyperlaneMessage(messageHex: string): {
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
    unlockAmountSompi: bigint;
    originBurner: string;
    kasPayoutAddressLength: number;
    kasPayoutAddress: string;
  };
} | null {
  try {
    const bytes = ethers.getBytes(messageHex);
    if (bytes.length < ENVELOPE_PREFIX_LENGTH + 34) {
      return null;
    }

    const version = bytes[0];
    const nonce = Number(readU32BE(bytes, 1));
    const originDomain = Number(readU32BE(bytes, 5));
    const sender = ethers.getAddress(ethers.dataSlice(bytes, 9 + 12, 9 + 32));
    const destinationDomain = Number(readU32BE(bytes, 41));
    const recipient = ethers.hexlify(ethers.dataSlice(bytes, 45, 77)).toLowerCase();

    const body = bytes.slice(ENVELOPE_PREFIX_LENGTH);
    const bodyFormat = body[0];
    const bodyRequestId = Number(readU32BE(body, 1));
    const bodyUnlockAmountSompi = readU64BE(body, 5);
    const originBurner = ethers.getAddress(ethers.hexlify(body.slice(13, 33)));
    const payoutLen = body[33];
    const payoutStart = 34;
    const payoutEnd = payoutStart + payoutLen;
    if (payoutEnd > body.length) {
      return null;
    }
    // Body must be exactly the declared fixed header + declared payout bytes.
    if (payoutEnd !== body.length) {
      return null;
    }
    const payoutBytes = body.slice(payoutStart, payoutEnd);
    const payoutAddress = ethers.toUtf8String(payoutBytes);

    return {
      outer: {
        version,
        nonce,
        originDomain,
        sender,
        destinationDomain,
        recipient,
      },
      body: {
        format: bodyFormat,
        requestId: bodyRequestId,
        unlockAmountSompi: bodyUnlockAmountSompi,
        originBurner,
        kasPayoutAddressLength: payoutLen,
        kasPayoutAddress: payoutAddress,
      },
    };
  } catch {
    return null;
  }
}

function merkleInsert(
  state: { branch: string[]; count: bigint },
  node: string,
) {
  if (state.branch.length !== HYPERLANE_TREE_DEPTH) {
    throw new Error(
      `Replay state branch length must be ${HYPERLANE_TREE_DEPTH}, got ${state.branch.length}`,
    );
  }
  if (state.count >= HYPERLANE_MAX_LEAVES) {
    throw new Error("Replay state merkle tree full");
  }

  let next = normalizeBytes32ValueOrThrow(node, "replay.leaf");
  state.count += 1n;
  let size = state.count;
  for (let i = 0; i < HYPERLANE_TREE_DEPTH; i++) {
    if ((size & 1n) === 1n) {
      state.branch[i] = next;
      return;
    }
    next = ethers
      .keccak256(ethers.concat([state.branch[i], next]))
      .toLowerCase();
    size >>= 1n;
  }
  throw new Error("Unreachable merkleInsert state");
}

function merkleRootFromState(state: { branch: string[]; count: bigint }): string {
  if (state.branch.length !== HYPERLANE_TREE_DEPTH) {
    throw new Error(
      `Replay state branch length must be ${HYPERLANE_TREE_DEPTH}, got ${state.branch.length}`,
    );
  }

  let current = ZERO_ROOT;
  let index = state.count;
  for (let i = 0; i < HYPERLANE_TREE_DEPTH; i++) {
    const bit = (index >> BigInt(i)) & 1n;
    const next = normalizeBytes32ValueOrThrow(
      state.branch[i],
      `replay.branch[${i}]`,
    );
    current =
      bit === 1n
        ? ethers.keccak256(ethers.concat([next, current]))
        : ethers.keccak256(ethers.concat([current, HYPERLANE_ZERO_HASHES[i]]));
  }
  return current.toLowerCase();
}

function computeSnapshotRoot(branch: string[], count: bigint): string {
  return merkleRootFromState({
    branch: branch.map((v, i) =>
      normalizeBytes32ValueOrThrow(v, `snapshot.branch[${i}]`),
    ),
    count,
  });
}

function readU32BE(data: Uint8Array, offset: number): bigint {
  return (
    (BigInt(data[offset]) << 24n) |
    (BigInt(data[offset + 1]) << 16n) |
    (BigInt(data[offset + 2]) << 8n) |
    BigInt(data[offset + 3])
  );
}

function readU64BE(data: Uint8Array, offset: number): bigint {
  let out = 0n;
  for (let i = 0; i < 8; i++) {
    out = (out << 8n) | BigInt(data[offset + i]);
  }
  return out;
}

function formatWithDecimals(value: bigint, decimals: number): string {
  const base = 10n ** BigInt(decimals);
  const whole = value / base;
  const frac = value % base;
  if (frac === 0n) return whole.toString();
  const fracStr = frac.toString().padStart(decimals, "0").replace(/0+$/, "");
  return `${whole.toString()}.${fracStr}`;
}

function createProgressTicker(label: string) {
  const startedAt = Date.now();
  let lastLoggedAt = 0;
  return (message: string, force = false) => {
    const now = Date.now();
    if (!force && now - lastLoggedAt < PROGRESS_INTERVAL_MS) return;
    const elapsedSec = ((now - startedAt) / 1000).toFixed(1);
    console.log(`[progress][${label}] t+${elapsedSec}s ${message}`);
    lastLoggedAt = now;
  };
}

function printSummary(
  report: ChecksReport,
  outDataPath: string,
  outChecksPath: string,
  outTreeDataPath: string,
  outTreeSnapshotPath: string,
  outContractPreverifyPath: string,
  outEndCheckpointPath: string,
  outBundlePath: string,
) {
  const m = report.metadata.common;
  const exit = report.metadata.exit;
  const tree = report.metadata.tree;
  const rootReplay = tree.rootReplay;
  const t = exit.totals;
  const f = exit.checkFailures;
  const tt = tree.totals;
  const tf = tree.checkFailures;
  const sep = "-".repeat(72);
  console.log(sep);
  console.log("KasExitBridge Exit Audit");
  console.log(sep);
  console.log(`RPC:                ${m.rpcUrl}`);
  console.log(`Chain ID:           ${m.chainId}`);
  console.log(`KasExitBridge:      ${exit.kasExitBridge}`);
  console.log(`Mailbox:            ${exit.mailbox}`);
  console.log(`Block range:        ${m.fromBlock} .. ${m.toBlock}`);
  console.log(sep);
  console.log(`Exit tx count:      ${t.exitTransactions}`);
  console.log(`  - successful:     ${t.successfulExitTransactions}`);
  console.log(`  - reverted:       ${t.revertedExitTransactions}`);
  console.log(`Burn event count:   ${t.burnEvents}`);
  console.log(`Exit event count:   ${t.exitRequestedEvents}`);
  console.log(`Dispatch count:     ${t.dispatchEvents}`);
  console.log(`Total unlock sompi: ${t.totalUnlockSompi}`);
  console.log(`Total burn wei:     ${t.totalBurnWei}`);
  console.log(`Total burn iKAS:    ${t.totalBurnIKas}`);
  console.log(sep);
  console.log(`All checks passed:  ${t.allChecksPassed}`);
  console.log(`Any check failed:   ${t.anyCheckFailed}`);
  console.log(
    `KEB events == successful exits: ${t.kebEventCountsMatchSuccessfulExitTxCount}`,
  );
  console.log("Failures by check:");
  console.log(
    `  - event cardinality by tx:            ${f.eventCardinalityByTxStatus}`,
  );
  console.log(
    `  - dispatch message decodes:           ${f.dispatchMessageDecodesCorrectly}`,
  );
  console.log(
    `  - messageId == keccak(message):        ${f.messageIdKeccakDispatchMessage}`,
  );
  console.log(
    `  - messageId consistent across events:  ${f.messageIdMatchesExitRequestedDispatchIdDispatchInserted}`,
  );
  console.log(
    `  - Dispatch.message payload matches:    ${f.dispatchMessageMatchesRequestExitKasPayoutAndUnlockAmount}`,
  );
  console.log(
    `  - msg.value == BurnIKas.amount:        ${f.msgValueEqualsBurnIKasAmount}`,
  );
  console.log(
    `  - KEB events == successful exits:      ${f.kebEventCountsMatchSuccessfulExitTxCount}`,
  );
  if (report.globalErrors.exit.length > 0) {
    console.log("Global errors:");
    for (const err of report.globalErrors.exit) {
      console.log(`  - ${err}`);
    }
  }
  console.log(sep);
  console.log("MerkleTreeHook Checks");
  console.log(sep);
  console.log(`MerkleTreeHook:     ${tree.merkleTreeHook}`);
  console.log(`Hook mailbox:       ${tree.mailbox}`);
  console.log(
    `Tree start:         block=${tree.checkpoints.start.blockTag}, root=${tree.checkpoints.start.root}, count=${tree.checkpoints.start.count}`,
  );
  console.log(
    `Tree end:           block=${tree.checkpoints.end.blockTag}, root=${tree.checkpoints.end.root}, count=${tree.checkpoints.end.count}`,
  );
  console.log(`Inserted events:    ${tt.insertedIntoTreeEvents}`);
  console.log(`All checks passed:  ${tt.allChecksPassed}`);
  console.log(`Any check failed:   ${tt.anyCheckFailed}`);
  console.log("Failures by check:");
  console.log(
    `  - mailbox matches configured:         ${tf.mailboxMatchesConfiguredMailbox}`,
  );
  console.log(
    `  - count delta matches events:         ${tf.countDeltaMatchesInsertedEvents}`,
  );
  console.log(
    `  - no duplicate messageId:             ${tf.noDuplicateMessageIds}`,
  );
  console.log(
    `  - no duplicate leaf index:            ${tf.noDuplicateLeafIndices}`,
  );
  console.log(
    `  - no leaf index gaps:                 ${tf.noLeafIndexGaps}`,
  );
  console.log(
    `  - exit InsertedIntoTree coverage:     ${tf.allSuccessfulExitInsertedEventsPresentAndMatching}`,
  );
  console.log(
    `  - root replay matches end checkpoint: ${tf.rootReplayMatchesEndCheckpoint}`,
  );
  if (rootReplay.enabled) {
    console.log("Root replay:");
    console.log(`  - enabled:                            true`);
    console.log(`  - snapshot validated:                 ${rootReplay.snapshotValidated}`);
    console.log(`  - replayed leaves:                    ${rootReplay.replayedLeaves}`);
    console.log(
      `  - computed end root:                  ${rootReplay.computedEndRoot ?? "n/a"}`,
    );
    console.log(
      `  - on-chain end root:                  ${rootReplay.onChainEndRoot ?? "n/a"}`,
    );
    console.log(`  - match:                              ${rootReplay.match}`);
  } else {
    console.log("Root replay:");
    console.log(`  - enabled:                            false`);
    console.log(`  - skipped by config:                  ${rootReplay.skippedByConfig}`);
  }
  if (report.globalErrors.tree.length > 0) {
    console.log("Tree global errors:");
    for (const err of report.globalErrors.tree) {
      console.log(`  - ${err}`);
    }
  }
  console.log(sep);
  console.log(`Wrote data JSON:   ${outDataPath}`);
  console.log(`Wrote checks JSON: ${outChecksPath}`);
  console.log(`Wrote tree data JSON: ${outTreeDataPath}`);
  console.log(`Wrote tree snapshot JSON: ${outTreeSnapshotPath}`);
  console.log(`Wrote contract preverify JSON: ${outContractPreverifyPath}`);
  console.log(`Wrote end checkpoint JSON: ${outEndCheckpointPath}`);
  console.log(`Wrote pass-A bundle: ${outBundlePath}`);
}

main().catch((err) => {
  console.error(`Error: ${(err as Error).message}`);
  process.exit(1);
});
